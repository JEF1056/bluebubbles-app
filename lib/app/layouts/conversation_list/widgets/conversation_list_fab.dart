import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';

class ConversationListFAB extends CustomStateful<ConversationListController> {
  const ConversationListFAB({super.key, required super.parentController});

  @override
  State<StatefulWidget> createState() => _ConversationListFABState();
}

class _ConversationListFABState extends CustomState<ConversationListFAB, void, ConversationListController> {
  // Cache these values to prevent rebuild on every scroll event
  double _lastScrollOffset = 0;
  ScrollDirection _lastScrollDirection = ScrollDirection.idle;

  @override
  void initState() {
    super.initState();

    // Optimize scroll listener to reduce setState calls
    controller.materialScrollController.addListener(_handleScroll);

    NavigationSvc.listener.stream.listen((event) {
      if (!mounted) return;
      if (NavigationSvc.isAvatarOnly(context) && controller.showMaterialFABText) {
        setState(() {
          controller.showMaterialFABText = false;
        });
      }
    });
  }

  void _handleScroll() {
    if (!material) return;

    final offset = controller.materialScrollController.offset;
    final direction = controller.materialScrollController.position.userScrollDirection;

    // Only process if direction actually changed (reduces unnecessary checks)
    if (direction == _lastScrollDirection && (offset - _lastScrollOffset).abs() < 75) {
      return;
    }

    _lastScrollOffset = offset;
    _lastScrollDirection = direction;

    final scrollDelta = controller.materialScrollStartPosition - offset;

    if (scrollDelta < -75 && direction == ScrollDirection.reverse && controller.showMaterialFABText) {
      setState(() {
        controller.showMaterialFABText = false;
      });
    } else if (scrollDelta > 75 && direction == ScrollDirection.forward && !controller.showMaterialFABText) {
      setState(() {
        controller.showMaterialFABText = true;
      });
    }
  }

  @override
  void dispose() {
    controller.materialScrollController.removeListener(_handleScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Extract iOS/Samsung widget to prevent rebuild on Material changes
    final iosAndSamsungWidget = _IOSAndSamsungFAB(
      controller: controller,
      context: context,
    );

    return ThemeSwitcher(
      iOSSkin: iosAndSamsungWidget,
      materialSkin: _MaterialFAB(
        controller: controller,
        onScrollToTop: () async {
          await controller.materialScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
          setState(() {
            controller.showMaterialFABText = true;
          });
        },
      ),
      samsungSkin: iosAndSamsungWidget,
    );
  }
}

/// Extracted iOS/Samsung FAB to prevent unnecessary rebuilds
class _IOSAndSamsungFAB extends StatelessWidget {
  const _IOSAndSamsungFAB({
    required this.controller,
    required this.context,
  });

  final ConversationListController controller;
  final BuildContext context;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;
      return Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Camera FAB (iOS only)
          if (SettingsSvc.settings.cameraFAB.value && isIOS && !kIsWeb && !kIsDesktop)
            _CameraFAB(
              controller: controller,
              context: context,
              isIOS: isIOS,
            ),
          if (SettingsSvc.settings.cameraFAB.value && isIOS && !kIsWeb && !kIsDesktop) const SizedBox(height: 10),
          // Main compose FAB
          _ComposeFAB(
            controller: controller,
            context: context,
            isIOS: isIOS,
            showLongPress: isIOS || !SettingsSvc.settings.cameraFAB.value || kIsWeb || kIsDesktop,
          ),
        ],
      );
    });
  }
}

/// Extracted camera FAB to isolate rebuild scope
class _CameraFAB extends StatelessWidget {
  const _CameraFAB({
    required this.controller,
    required this.context,
    required this.isIOS,
  });

  final ConversationListController controller;
  final BuildContext context;
  final bool isIOS;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 45,
        maxHeight: 45,
      ),
      child: FloatingActionButton(
        heroTag: null,
        backgroundColor: context.theme.colorScheme.primaryContainer,
        onPressed: () => controller.openCamera(context),
        child: Icon(
          isIOS ? CupertinoIcons.camera : Icons.photo_camera,
          size: 20,
          color: context.theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// Extracted compose FAB to isolate rebuild scope
class _ComposeFAB extends StatelessWidget {
  const _ComposeFAB({
    required this.controller,
    required this.context,
    required this.isIOS,
    required this.showLongPress,
  });

  final ConversationListController controller;
  final BuildContext context;
  final bool isIOS;
  final bool showLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onLongPress: showLongPress ? null : () => controller.openCamera(context),
      child: FloatingActionButton(
        backgroundColor: context.theme.colorScheme.primary,
        onPressed: () => controller.openNewChatCreator(context),
        child: Icon(
          isIOS ? CupertinoIcons.pencil : Icons.message,
          color: context.theme.colorScheme.onPrimary,
          size: 25,
        ),
      ),
    );
  }
}

/// Extracted Material FAB to prevent iOS/Samsung rebuilds
class _MaterialFAB extends StatelessWidget {
  const _MaterialFAB({
    required this.controller,
    required this.onScrollToTop,
  });

  final ConversationListController controller;
  final VoidCallback onScrollToTop;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: controller.selectedChats.isNotEmpty
          ? const SizedBox.shrink()
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (!controller.showMaterialFABText) ...[
                  _ScrollToTopFAB(
                    controller: controller,
                    onPressed: onScrollToTop,
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MaterialSearchFAB(context: context),
                    const SizedBox(width: 10),
                    _MaterialComposeFAB(controller: controller),
                  ],
                ),
              ],
            ),
    );
  }
}

class _MaterialSearchFAB extends StatelessWidget {
  const _MaterialSearchFAB({required this.context});

  final BuildContext context;

  @override
  Widget build(BuildContext _) {
    return SizedBox(
      width: 48,
      height: 48,
      child: FloatingActionButton(
        heroTag: null,
        elevation: 3,
        shape: const CircleBorder(),
        backgroundColor: context.theme.colorScheme.surfaceContainerHigh,
        foregroundColor: context.theme.colorScheme.onSurface,
        tooltip: 'Search',
        onPressed: () {
          NavigationSvc.pushLeft(context, const SearchView());
        },
        child: const Icon(Icons.search_rounded),
      ),
    );
  }
}

/// Extracted scroll to top FAB to isolate animation
class _ScrollToTopFAB extends StatelessWidget {
  const _ScrollToTopFAB({
    required this.controller,
    required this.onPressed,
  });

  final ConversationListController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      heroTag: null,
      backgroundColor: context.theme.colorScheme.secondaryContainer,
      foregroundColor: context.theme.colorScheme.onSecondaryContainer,
      onPressed: onPressed,
      child: const Icon(Icons.arrow_upward),
    );
  }
}

/// Extracted Material compose FAB
class _MaterialComposeFAB extends StatelessWidget {
  const _MaterialComposeFAB({
    required this.controller,
  });

  final ConversationListController controller;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress:
          SettingsSvc.settings.cameraFAB.value && !kIsWeb && !kIsDesktop ? () => controller.openCamera(context) : null,
      child: FloatingActionButton.extended(
        heroTag: null,
        shape: const StadiumBorder(),
        backgroundColor: context.theme.colorScheme.primaryContainer,
        foregroundColor: context.theme.colorScheme.onPrimaryContainer,
        isExtended: controller.showMaterialFABText,
        onPressed: () => controller.openNewChatCreator(context),
        icon: const Icon(Icons.chat_outlined),
        label: const Text('Start chat'),
      ),
    );
  }
}
