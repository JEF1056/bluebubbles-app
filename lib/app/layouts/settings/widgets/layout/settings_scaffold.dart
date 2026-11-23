import 'package:bluebubbles/app/components/m3e/m3e_motion.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/wrappers/bb_app_bar.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/app/wrappers/scrollbar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class SettingsScaffold extends StatefulWidget {
  final String title;
  final String? initialHeader;
  final TextStyle? iosSubtitle;
  final TextStyle? materialSubtitle;
  final Color headerColor;
  final Color tileColor;
  final List<Widget> bodySlivers;
  final List<Widget> actions;
  final Widget? stickyPrefix;
  final Widget? stickySuffix;
  final Widget? fab;
  final Widget? leading;
  final bool minimalAppBar;

  const SettingsScaffold({
    super.key,
    required this.title,
    required this.initialHeader,
    required this.iosSubtitle,
    required this.materialSubtitle,
    required this.headerColor,
    required this.tileColor,
    required this.bodySlivers,
    this.actions = const [],
    this.stickyPrefix,
    this.stickySuffix,
    this.fab,
    this.leading,
    this.minimalAppBar = false,
  });

  @override
  State<SettingsScaffold> createState() => _SettingsScaffoldState();
}

class _SettingsScaffoldState extends State<SettingsScaffold> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _expressiveMaterial => SettingsSvc.settings.skin.value == Skins.Material;

  /// Expressive Material with no title bar at all — just a bare back button above the
  /// content, mirroring Android Contacts' profile page rather than a titled `SliverAppBar`.
  bool get _minimalMaterial => _expressiveMaterial && widget.minimalAppBar;

  bool get _expressiveSamsung => SettingsSvc.settings.skin.value == Skins.Samsung;

  bool get extend => widget.actions.isNotEmpty && kIsDesktop;

  @override
  Widget build(BuildContext context) {
    final scaffoldSw = Stopwatch()..start();
    WidgetsBinding.instance.addPostFrameCallback((_) {});

    final widgetTree = BBScaffold(
      backgroundColor: SettingsSvc.settings.skin.value == Skins.Material
          ? (_expressiveMaterial ? widget.headerColor : widget.tileColor)
          : widget.headerColor,
      appBar: SettingsSvc.settings.skin.value == Skins.Samsung || _expressiveMaterial
          ? null
          : BBAppBar(
              titleText: widget.title,
              leading: widget.leading ?? buildBackButton(context),
              backgroundColor: widget.headerColor,
              toolbarHeight: extend ? 80 : 50,
              actions: widget.actions,
            ),
      floatingActionButton: widget.fab,
      extendBodyBehindAppBar: false,
      safeAreaTop: _minimalMaterial,
      body: NotificationListener<ScrollEndNotification>(
        onNotification: (_) {
          if (SettingsSvc.settings.skin.value != Skins.Samsung || kIsWeb || kIsDesktop || !_controller.hasClients) {
            return false;
          }
          final scrollDistance = context.height / 3 - 57;
          if (_controller.offset > 0 &&
              _controller.offset < scrollDistance &&
              _controller.offset != _controller.position.maxScrollExtent) {
            final double snapOffset = _controller.offset / scrollDistance > 0.5 ? scrollDistance : 0;

            Future.microtask(() {
              if (!mounted || !_controller.hasClients) return;
              _controller.animateTo(
                snapOffset,
                duration: _expressiveSamsung ? M3EMotion.spatialDefault.duration : const Duration(milliseconds: 200),
                curve: _expressiveSamsung ? M3EMotion.spatialDefault.curve : Curves.linear,
              );
            });
          }
          return false;
        },
        child: ScrollbarWrapper(
          showScrollbar: kIsDesktop || kIsWeb,
          controller: _controller,
          child: Column(
            children: [
              widget.stickyPrefix ?? const SizedBox.shrink(),
              Expanded(
                child: Obx(
                  () {
                    final listSw = Stopwatch()..start();
                    final view = CustomScrollView(
                      controller: _controller,
                      physics: ThemeSwitcher.getScrollPhysics(),
                      slivers: <Widget>[
                        if (_minimalMaterial)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4, top: 4),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: widget.leading ?? buildBackButton(context),
                              ),
                            ),
                          ),
                        if (_expressiveMaterial && !widget.minimalAppBar)
                          SliverAppBar.large(
                            title: Text(
                              widget.title,
                              style: context.theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            leading: widget.leading ?? buildBackButton(context),
                            actions: widget.actions,
                            backgroundColor: widget.headerColor,
                            surfaceTintColor: context.theme.colorScheme.surfaceTint,
                            scrolledUnderElevation: 3,
                            pinned: true,
                            automaticallyImplyLeading: false,
                          ),
                        if (SettingsSvc.settings.skin.value == Skins.Samsung)
                          SliverAppBar(
                            backgroundColor: widget.headerColor,
                            pinned: true,
                            stretch: true,
                            expandedHeight: context.height / 3,
                            elevation: 0,
                            automaticallyImplyLeading: false,
                            flexibleSpace: LayoutBuilder(
                              builder: (context, _) {
                                final offset = _controller.hasClients ? _controller.offset : 0.0;
                                var expandRatio = 1 - offset / (context.height / 3 - 50);
                                if (expandRatio > 1.0) expandRatio = 1.0;
                                if (expandRatio < 0.1) expandRatio = 0.0;
                                final animation = AlwaysStoppedAnimation<double>(expandRatio);

                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    FadeTransition(
                                      opacity: Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
                                        parent: animation,
                                        curve: Interval(0.3, 1.0,
                                            curve: _expressiveSamsung ? M3EMotion.spatialDefault.curve : Curves.easeIn),
                                      )),
                                      child: Center(
                                          child: Text(widget.title,
                                              style: context.theme.textTheme.displaySmall!.copyWith(
                                                  color: context.theme.colorScheme.onSurface,
                                                  fontWeight: _expressiveSamsung ? FontWeight.w700 : null),
                                              textAlign: TextAlign.center)),
                                    ),
                                    FadeTransition(
                                      opacity: Tween(begin: 1.0, end: 0.0).animate(CurvedAnimation(
                                        parent: animation,
                                        curve: Interval(0.0, 0.7,
                                            curve:
                                                _expressiveSamsung ? M3EMotion.spatialDefault.curve : Curves.easeOut),
                                      )),
                                      child: Align(
                                        alignment: Alignment.bottomLeft,
                                        child: Container(
                                          padding: const EdgeInsets.only(left: 50),
                                          height: 50,
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              widget.title,
                                              style: context.theme.textTheme.titleLarge,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(left: 8.0),
                                      child: Align(
                                        alignment: Alignment.bottomLeft,
                                        child: SizedBox(
                                          height: 50,
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: widget.leading ?? buildBackButton(context),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.bottomRight,
                                      child: SizedBox(
                                        height: 50,
                                        child: Align(
                                          alignment: Alignment.centerRight,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: widget.actions,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        if (SettingsSvc.settings.skin.value != Skins.Samsung && widget.initialHeader != null)
                          SliverToBoxAdapter(
                            child: Container(
                                height: 50,
                                alignment: Alignment.bottomLeft,
                                color: SettingsSvc.settings.skin.value == Skins.iOS || _expressiveMaterial
                                    ? widget.headerColor
                                    : widget.tileColor,
                                child: Padding(
                                  padding: EdgeInsets.only(
                                      bottom: 8.0, left: SettingsSvc.settings.skin.value == Skins.iOS ? 30 : 15),
                                  child: Text(widget.initialHeader!.psCapitalize,
                                      style: SettingsSvc.settings.skin.value == Skins.iOS
                                          ? widget.iosSubtitle
                                          : widget.materialSubtitle),
                                )),
                          ),
                        if (SettingsSvc.settings.skin.value != Skins.Samsung) ...widget.bodySlivers,
                        if (SettingsSvc.settings.skin.value == Skins.Samsung)
                          SliverToBoxAdapter(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                  minHeight: context.height -
                                      50 -
                                      context.mediaQueryPadding.top -
                                      context.mediaQueryViewPadding.top),
                              child: CustomScrollView(
                                physics: const NeverScrollableScrollPhysics(),
                                shrinkWrap: true,
                                slivers: widget.bodySlivers,
                              ),
                            ),
                          ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 30 + MediaQuery.paddingOf(context).bottom,
                          ),
                        ),
                      ],
                    );
                    listSw.stop();
                    return view;
                  },
                ),
              ),
              widget.stickySuffix ?? const SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
    scaffoldSw.stop();
    return widgetTree;
  }
}
