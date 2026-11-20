import 'dart:math';
import 'dart:ui';

import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/platform/shims/desktop_window.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_devices_tab_view.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_friends_tab_view.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_items_tab_view.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_map_widget.dart';
import 'package:bluebubbles/app/wrappers/scrollbar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

class FindMyPage extends StatefulWidget {
  const FindMyPage({super.key});

  @override
  State<StatefulWidget> createState() => _FindMyPageState();
}

class _FindMyPageState extends State<FindMyPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final FindMyController controller;
  late final bool _ownsController;
  static const double _detailSnapPoint = 0.48;
  bool _hasSnappedInitialPhoneSheet = false;
  bool _pendingInitialPhoneSnap = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final wasRegistered = Get.isRegistered<FindMyController>();
    _ownsController = !wasRegistered;
    controller = wasRegistered ? Get.find<FindMyController>() : Get.put(FindMyController(), permanent: true);
    controller.tabController = TabController(vsync: this, length: 3);
    controller.tabController!.addListener(_handleTabChange);
    controller.onRequestDetailSheetOpen = _openDetailSheet;
    controller.detailSheetOffsetProvider = _detailSheetOffsetPx;
    controller.fitAllPinsPaddingProvider = _fitAllPinsPadding;
    if (wasRegistered) {
      if (controller.isBackgroundShared) {
        controller.activatePage();
      }
      controller.consumePendingFocus();
    }
    // Start at the mid snap point (48%) like iOS Find My so rows show above the floating tab bar.
    _scheduleInitialPhoneSheetSnap();
  }

  void _scheduleInitialPhoneSheetSnap() {
    if (_hasSnappedInitialPhoneSheet || _pendingInitialPhoneSnap) return;
    _pendingInitialPhoneSnap = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingInitialPhoneSnap = false;
      if (!mounted || !context.isPhone || _hasSnappedInitialPhoneSheet) return;
      if (controller.panelController.isAttached) {
        _hasSnappedInitialPhoneSheet = true;
        controller.panelController.panelPosition = _detailSnapPoint;
      }
    });
  }

  void _openDetailSheet() {
    if (!mounted || !context.isPhone) return;
    if (controller.panelController.isAttached) {
      controller.panelController.animatePanelToPosition(
        _detailSnapPoint,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  double _detailSheetOffsetPx() {
    if (!mounted || !context.isPhone) return 0;
    final h = MediaQuery.of(context).size.height;
    return h * _detailSnapPoint * 0.34;
  }

  EdgeInsets _fitAllPinsPadding() {
    if (!mounted) return FindMyController.defaultFitAllPinsPadding;
    final mq = MediaQuery.of(context);
    if (!context.isPhone) {
      return computeFindMyFitAllPadding(
        viewportSize: mq.size,
        viewPadding: mq.padding,
        isPhone: false,
      );
    }
    final minHeight = 146.0 + mq.padding.bottom;
    final maxHeight = mq.size.height * 0.78;
    final effectivePos = (_hasSnappedInitialPhoneSheet && controller.panelController.isAttached)
        ? controller.panelController.panelPosition
        : _detailSnapPoint;
    final sheetHeight = minHeight + (maxHeight - minHeight) * effectivePos.clamp(0.0, 1.0);
    return computeFindMyFitAllPadding(
      viewportSize: mq.size,
      viewPadding: mq.padding,
      isPhone: true,
      bottomSheetHeight: sheetHeight,
    );
  }

  void _handleTabChange() {
    final tabCtrl = controller.tabController;
    if (tabCtrl == null || tabCtrl.indexIsChanging) return;
    if (controller.tabIndex.value != tabCtrl.index) {
      controller.tabIndex.value = tabCtrl.index;
    }
    controller.onTabChanged(tabCtrl.index);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.onAppResumed();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      controller.onAppPaused();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.onRequestDetailSheetOpen = null;
    controller.detailSheetOffsetProvider = null;
    controller.fitAllPinsPaddingProvider = null;
    controller.tabController?.removeListener(_handleTabChange);
    if (_ownsController || !controller.isBackgroundShared) {
      Get.delete<FindMyController>(force: true);
    } else {
      controller.tabController?.dispose();
      controller.tabController = null;
      controller.clearSelection();
      controller.deactivatePage();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (context.isPhone) {
          _scheduleInitialPhoneSheetSnap();
          return _buildNormalLayout(context);
        }
        _hasSnappedInitialPhoneSheet = false;
        return _buildTabletLayout(context);
      },
    );
  }

  Widget _buildTabletLayout(BuildContext context) {
    return Obx(() {
      final hasSelection =
          controller.selectedFriendId.value != null || controller.selectedDeviceId.value != null;
      return PopScope(
        canPop: !hasSelection,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && hasSelection) {
            controller.clearSelection();
          }
        },
        child: BBScaffold(
          backgroundColor: context.theme.colorScheme.surface.themeOpacity(context),
          safeAreaLeft: false,
          safeAreaRight: false,
          body: Stack(
            children: [
              Row(
                children: [
                  ConstrainedBox(
                    constraints:
                        BoxConstraints(minWidth: 300, maxWidth: max(300, min(500, NavigationSvc.width(context) / 3))),
                    child: Container(
                      width: 500,
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        FindMyMapWidget(controller: controller),
                        if (kIsDesktop) _buildDesktopTitleBar(context),
                      ],
                    ),
                  ),
                ],
              ),
              ConstrainedBox(
                constraints:
                    BoxConstraints(minWidth: 300, maxWidth: max(300, min(500, NavigationSvc.width(context) / 3))),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      if (!context.samsung)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
                          child: SizedBox(
                            height: 48,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: buildBackButton(context),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    "Find My",
                                    style: context.theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (!context.samsung) _buildDesktopTabBar(),
                      Expanded(
                        child: SizedBox(
                          width: 500,
                          child: Column(
                            children: [
                              _buildSheetHeader(context),
                              Expanded(
                                child: TabBarView(
                                  key: const ValueKey('tabs-view'),
                                  controller: controller.tabController,
                                  children: [
                                    _buildTab(context, controller.friendsController, "FindMy Friends", FindMyFriendsTabView(controller: controller)),
                                    _buildTab(context, controller.devicesController, "FindMy Devices", FindMyDevicesTabView(controller: controller)),
                                    _buildTab(context, controller.itemsController, "FindMy Items", FindMyItemsTabView(controller: controller)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (context.samsung) _buildDesktopTabBar(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildTab(BuildContext context, ScrollController scrollController, String samsungTitle, Widget tabView) {
    return ScrollbarWrapper(
      controller: scrollController,
      child: Obx(
        () => RefreshIndicator(
          onRefresh: () => controller.hardRefresh(),
          child: CustomScrollView(
            controller: scrollController,
            physics: ThemeSwitcher.getScrollPhysics(),
            slivers: [
              if (context.samsung) _buildSamsungAppBar(context, samsungTitle),
              if (!context.samsung) tabView,
              if (context.samsung)
                SliverToBoxAdapter(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minHeight:
                            context.height - 50 - context.mediaQueryPadding.top - context.mediaQueryViewPadding.top),
                    child: CustomScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      slivers: [tabView],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopTabBar() {
    final cs = context.theme.colorScheme;
    return TabBar(
      controller: controller.tabController,
      dividerHeight: 1,
      dividerColor: cs.outlineVariant.withValues(alpha: 0.45),
      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
      tabs: [
        Tab(
          height: 54,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(context.iOS ? CupertinoIcons.person_2 : Icons.people_outline, size: 20),
              const SizedBox(height: 3),
              const Text("People"),
            ],
          ),
        ),
        Tab(
          height: 54,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(context.iOS ? CupertinoIcons.device_desktop : Icons.devices, size: 20),
              const SizedBox(height: 3),
              const Text("Devices"),
            ],
          ),
        ),
        Tab(
          height: 54,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(context.iOS ? CupertinoIcons.tag : Icons.adjust_rounded, size: 20),
              const SizedBox(height: 3),
              const Text("Items"),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNormalLayout(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Obx(() {
      final hasSelection =
          controller.selectedFriendId.value != null || controller.selectedDeviceId.value != null;
      return PopScope(
        canPop: !hasSelection,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && hasSelection) {
            controller.clearSelection();
          }
        },
        child: BBScaffold(
          backgroundColor: context.material ? context.tileColor : context.headerColor,
          safeAreaLeft: false,
          safeAreaRight: false,
          body: Stack(
            children: [
              SlidingUpPanel(
                controller: controller.panelController,
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(25.0),
                  topRight: Radius.circular(25.0),
                ),
                minHeight: 146 + bottomInset,
                maxHeight: MediaQuery.of(context).size.height * 0.78,
                snapPoint: _detailSnapPoint,
                disableDraggableOnScrolling: true,
                backdropEnabled: false,
                parallaxEnabled: false,
                panelSnapping: true,
                header: ForceDraggableWidget(
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10.0, bottom: 8),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          width: 44,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                panelBuilder: () => Padding(
                  padding: const EdgeInsets.only(top: 22),
                  child: Column(
                    children: [
                      _buildSheetHeader(context),
                      Expanded(
                        child: TabBarView(
                          key: const ValueKey('tabs-view'),
                          physics: const NeverScrollableScrollPhysics(),
                          controller: controller.tabController,
                          children: <Widget>[
                            _buildScrollNotificationWrapper(
                              controller.friendsController,
                              _buildTab(context, controller.friendsController, "FindMy Friends", FindMyFriendsTabView(controller: controller)),
                            ),
                            _buildScrollNotificationWrapper(
                              controller.devicesController,
                              _buildTab(context, controller.devicesController, "FindMy Devices", FindMyDevicesTabView(controller: controller)),
                            ),
                            _buildScrollNotificationWrapper(
                              controller.itemsController,
                              _buildTab(context, controller.itemsController, "FindMy Items", FindMyItemsTabView(controller: controller)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                body: FindMyMapWidget(controller: controller),
              ),
              if (!context.samsung)
                Positioned(
                  top: 12 + (kIsDesktop ? appWindow.titleBarHeight : MediaQuery.of(context).padding.top),
                  left: 16,
                  child: ClipOval(
                    child: Builder(builder: (context) {
                      final button = Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.86),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.38),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.22),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: buildBackButton(context, padding: const EdgeInsets.only(right: 2)),
                      );
                      final highPerf = GetIt.I.isRegistered<SettingsService>() && SettingsSvc.settings.highPerfMode.value;
                      return highPerf
                          ? button
                          : BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                              child: button,
                            );
                    }),
                  ),
                ),
              if (kIsDesktop) _buildDesktopTitleBar(context),
              Positioned(
                left: 16,
                right: 16,
                bottom: 12 + bottomInset,
                child: FindMyFloatingNavPill(
                  controller: controller,
                  onSelectTab: _onSelectBottomTab,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  String _sheetTitleForTab(int index) => switch (index) {
        0 => 'People',
        1 => 'Devices',
        _ => 'Items',
      };

  Widget _buildSheetHeader(BuildContext context) {
    final cs = context.theme.colorScheme;
    final tt = context.theme.textTheme;
    return Obx(() {
      final isRefreshing = controller.refreshing.value || controller.refreshing2.value;
      final title = _sheetTitleForTab(controller.tabIndex.value);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: tt.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: 24,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            SizedBox(
              width: 36,
              height: 36,
              child: IconButton.filledTonal(
                key: const ValueKey('findmy-sheet-refresh'),
                padding: EdgeInsets.zero,
                tooltip: 'Refresh Locations',
                onPressed: controller.canRefresh.value && !isRefreshing ? () => controller.hardRefresh() : null,
                icon: isRefreshing
                    ? Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                        ),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
              ),
            ),
          ],
        ),
      );
    });
  }

  void _onSelectBottomTab(int page) {
    final oldIndex = controller.tabIndex.value;
    if (oldIndex != page && (controller.selectedFriendId.value != null || controller.selectedDeviceId.value != null)) {
      controller.clearSelection();
    }
    controller.tabIndex.value = page;
    controller.tabController?.animateTo(page);
    controller.onTabChanged(page);

    if (!controller.panelController.isAttached) return;
    final wasOpen = controller.panelController.isPanelOpen;
    if (oldIndex == page && wasOpen) {
      controller.panelController.close();
    } else if (!wasOpen) {
      controller.panelController.animatePanelToPosition(
        _detailSnapPoint,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _buildScrollNotificationWrapper(ScrollController scrollController, Widget child) {
    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        if (SettingsSvc.settings.skin.value != Skins.Samsung || kIsWeb || kIsDesktop) return false;
        final scrollDistance = context.height / 3 - 57;

        if (scrollController.hasClients && scrollController.offset > 0 && scrollController.offset < scrollDistance) {
          final double snapOffset = scrollController.offset / scrollDistance > 0.5 ? scrollDistance : 0;

          Future.microtask(() => scrollController.animateTo(snapOffset,
              duration: const Duration(milliseconds: 200), curve: Curves.linear));
        }
        return false;
      },
      child: child,
    );
  }

  Widget _buildDesktopTitleBar(BuildContext context) {
    return SizedBox(
      height: appWindow.titleBarHeight,
      child: AbsorbPointer(
        child: Row(children: [
          Expanded(child: Container()),
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaY: 2, sigmaX: 2),
              child: Container(
                  height: appWindow.titleBarHeight,
                  width: appWindow.titleBarButtonSize.width * 3,
                  color: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildSamsungAppBar(BuildContext context, String title) {
    return Obx(
      () => SliverAppBar(
        backgroundColor: context.headerColor,
        pinned: true,
        stretch: true,
        expandedHeight: context.height / 3,
        elevation: 0,
        automaticallyImplyLeading: false,
        flexibleSpace: LayoutBuilder(
          builder: (context, constraints) {
            var expandRatio = (constraints.maxHeight - 50) / (context.height / 3 - 50);

            if (expandRatio > 1.0) expandRatio = 1.0;
            if (expandRatio < 0.0) expandRatio = 0.0;
            final animation = AlwaysStoppedAnimation<double>(expandRatio);

            return Stack(
              fit: StackFit.expand,
              children: [
                FadeTransition(
                  opacity: Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
                    parent: animation,
                    curve: const Interval(0.3, 1.0, curve: Curves.easeIn),
                  )),
                  child: Center(
                      child: Text(title,
                          style: context.theme.textTheme.displaySmall!
                              .copyWith(color: context.theme.colorScheme.onSurface),
                          textAlign: TextAlign.center)),
                ),
                FadeTransition(
                  opacity: Tween(begin: 1.0, end: 0.0).animate(CurvedAnimation(
                    parent: animation,
                    curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
                  )),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Container(
                      padding: const EdgeInsets.only(left: 40),
                      height: 50,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          title,
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
                        child: buildBackButton(context),
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
                        children: [
                          SizedBox(
                            width: 48,
                            height: 48,
                            child: Container(
                              width: 48,
                              margin: const EdgeInsets.only(right: 8),
                              child: controller.refreshing.value || controller.refreshing2.value
                                  ? Center(child: buildProgressIndicator(context))
                                  : IconButton(
                                      iconSize: 22,
                                      icon: Icon(context.iOS ? CupertinoIcons.arrow_counterclockwise : Icons.refresh,
                                          color: context.theme.colorScheme.onSurface, size: 22),
                                      onPressed: controller.canRefresh.value ? () => controller.hardRefresh() : null,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class FindMyFloatingNavPill extends StatelessWidget {
  const FindMyFloatingNavPill({
    super.key,
    required this.controller,
    required this.onSelectTab,
  });

  final FindMyController controller;
  final ValueChanged<int> onSelectTab;

  static const items = [
    (label: 'People', icon: Icons.people_outline, activeIcon: Icons.people),
    (label: 'Devices', icon: Icons.devices_outlined, activeIcon: Icons.devices),
    (label: 'Items', icon: Icons.adjust_outlined, activeIcon: Icons.adjust_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    return Obx(() {
      final selectedIndex = controller.tabIndex.value;
      final nav = Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.90),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.42)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: List.generate(items.length, (i) {
            final item = items[i];
            final active = selectedIndex == i;
            return Expanded(
              child: Material(
                color: active ? cs.secondaryContainer.withValues(alpha: 0.85) : Colors.transparent,
                borderRadius: BorderRadius.circular(26),
                child: InkWell(
                  borderRadius: BorderRadius.circular(26),
                  onTap: () => onSelectTab(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        active ? item.activeIcon : item.icon,
                        size: 21,
                        color: active ? cs.primary : cs.onSurfaceVariant,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.theme.textTheme.labelSmall?.copyWith(
                          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                          color: active ? cs.primary : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      );
      final highPerf = GetIt.I.isRegistered<SettingsService>() && SettingsSvc.settings.highPerfMode.value;
      return ClipRRect(
        key: const ValueKey('findmy-floating-nav'),
        borderRadius: BorderRadius.circular(32),
        child: highPerf
            ? nav
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: nav,
              ),
      );
    });
  }
}
