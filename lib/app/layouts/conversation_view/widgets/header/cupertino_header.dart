import 'dart:async';
import 'dart:ui';

import 'package:bluebubbles/app/layouts/conversation_details/conversation_details.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/header_widgets.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_group_widget.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/ui/route_transition_helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide BackButton;
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';

class CupertinoHeader extends StatelessWidget implements PreferredSizeWidget {
  const CupertinoHeader({super.key, required this.controller});

  final ConversationViewController controller;

  // simulate apple's saturatioon
  static const List<double> darkMatrix = <double>[
    1.385, -0.56, -0.112, 0.0, 0.3, //
    -0.315, 1.14, -0.112, 0.0, 0.3, //
    -0.315, -0.56, 1.588, 0.0, 0.3, //
    0.0, 0.0, 0.0, 1.0, 0.0
  ];

  static const List<double> lightMatrix = <double>[
    1.74, -0.4, -0.17, 0.0, 0.0, //
    -0.26, 1.6, -0.17, 0.0, 0.0, //
    -0.26, -0.4, 1.83, 0.0, 0.0, //
    0.0, 0.0, 0.0, 1.0, 0.0
  ];

  @override
  Widget build(BuildContext context) {
    final filter = ImageFilter.compose(
      outer: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      inner: ColorFilter.matrix(
        CupertinoTheme.maybeBrightnessOf(context) == Brightness.dark ? darkMatrix : lightMatrix,
      ),
    );
    return ClipRect(
      child: Obx(
        () => RouteSettledBackdropFilter(
          enabled: !SettingsSvc.settings.highPerfMode.value,
          filter: filter,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    tileMode: TileMode.clamp,
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 1.0),
                      context.theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: (ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false) ? 0.72 : 0.5,
                      ),
                    ],
                  ),
                  border: Border(
                    bottom:
                        BorderSide(color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.25), width: 0.5),
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: Padding(
                    padding: EdgeInsets.only(
                        left: 20.0,
                        right: 20,
                        top: (MediaQuery.of(context).viewPadding.top - 2).clamp(0, double.infinity)),
                    child: Stack(alignment: Alignment.center, children: [
                      Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () {
                                if (controller.inSelectMode.value) {
                                  controller.inSelectMode.value = false;
                                  controller.selected.clear();
                                  return;
                                }
                                if (LifecycleSvc.isBubble) {
                                  SystemNavigator.pop();
                                  return;
                                }
                                controller.close();
                                if (Get.isSnackbarOpen) {
                                  Get.closeAllSnackbars();
                                }
                                Navigator.of(context).pop();
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(3.0),
                                child: _UnreadIcon(controller: controller),
                              ),
                            ),
                          )),
                      Align(
                        alignment: Alignment.center,
                        child: _ChatIconAndTitle(
                          parentController: controller,
                          hasWallpaper: ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false,
                        ),
                      ),
                      Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Align(
                            alignment: Alignment.topRight,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ManualMark(controller: controller),
                                if (!kIsWeb && Platform.isAndroid && canAudioCall(controller.chat))
                                  IconButton(
                                    tooltip: 'Call',
                                    icon: Icon(
                                      CupertinoIcons.phone,
                                      size: 22,
                                      color: context.theme.colorScheme.primary,
                                    ),
                                    onPressed: () => startAudioCall(context, controller.chat),
                                  ),
                                if (canVideoCall(controller.chat))
                                  IconButton(
                                    tooltip: 'Video',
                                    icon: Icon(
                                      CupertinoIcons.video_camera,
                                      size: 24,
                                      color: context.theme.colorScheme.primary,
                                    ),
                                    onPressed: () => startVideoCall(context, controller.chat),
                                  ),
                                if (!isWebHeader && kIsDesktop && MediaQuery.sizeOf(context).width > 1024)
                                  Obx(() {
                                    final open = NavigationSvc.showInspectorDrawer.value;
                                    return IconButton(
                                      tooltip: open ? 'Hide chat details (Alt+I)' : 'Show chat details (Alt+I)',
                                      isSelected: open,
                                      icon: Icon(
                                        open ? CupertinoIcons.info_circle_fill : CupertinoIcons.info_circle,
                                        size: 20,
                                        color: open
                                            ? context.theme.colorScheme.primary
                                            : context.theme.colorScheme.onSurface,
                                      ),
                                      onPressed: NavigationSvc.toggleInspectorDrawer,
                                    );
                                  }),
                              ],
                            ),
                          )),
                    ]),
                  ),
                ),
              ),
              const Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: HeaderProgressIndicator(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Size get preferredSize =>
      Size.fromHeight((Get.context?.orientation == Orientation.landscape && Platform.isAndroid ? 55 : 75) *
          SettingsSvc.settings.avatarScale.value);
}

class _UnreadIcon extends StatefulWidget {
  const _UnreadIcon({required this.controller});

  final ConversationViewController controller;

  @override
  State<StatefulWidget> createState() => _UnreadIconState();
}

class _UnreadIconState extends State<_UnreadIcon> {
  late final StreamSubscription<Query<Chat>> sub;
  bool hasStream = false;

  @override
  void dispose() {
    if (!kIsWeb && hasStream) sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3.0, right: 3),
          child: Obx(() {
            final icon = widget.controller.inSelectMode.value ? CupertinoIcons.xmark : CupertinoIcons.back;
            return Text(
              String.fromCharCode(icon.codePoint),
              style: TextStyle(
                fontFamily: icon.fontFamily,
                package: icon.fontPackage,
                fontSize: 36,
                color: context.theme.colorScheme.primary,
              ),
            );
          }),
        ),
        const SizedBox(width: 2),
        Obx(() {
          final _count =
              widget.controller.inSelectMode.value ? widget.controller.selected.length : ChatsSvc.unreadCount.value;
          if (_count == 0) return const SizedBox.shrink();
          return Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Container(
                  height: 25.0,
                  width: 25.0,
                  constraints: const BoxConstraints(minWidth: 20),
                  decoration: BoxDecoration(
                    color: context.theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  alignment: Alignment.center,
                  child: Padding(
                    padding: _count > 99 ? const EdgeInsets.symmetric(horizontal: 2.5) : EdgeInsets.zero,
                    child: Text(
                      _count.toString(),
                      style: context.textTheme.bodyMedium!.copyWith(
                          color: context.theme.colorScheme.onPrimary,
                          fontSize: _count > 99
                              ? context.textTheme.bodyMedium!.fontSize! - 1.0
                              : context.textTheme.bodyMedium!.fontSize),
                    ),
                  )));
        }),
      ],
    );
  }
}

class _ChatIconAndTitle extends CustomStateful<ConversationViewController> {
  const _ChatIconAndTitle({
    required super.parentController,
    required this.hasWallpaper,
  });

  final bool hasWallpaper;

  @override
  State<StatefulWidget> createState() => _ChatIconAndTitleState();
}

class _ChatIconAndTitleState extends CustomState<_ChatIconAndTitle, void, ConversationViewController> {
  late final FindMyController _fm;

  @override
  void initState() {
    super.initState();
    tag = controller.chat.guid;
    // keep controller in memory since the widget is part of a list
    // (it will be disposed when scrolled out of view)
    forceDelete = false;
    _fm = FindMyController.ensure();
    if (!controller.chat.isGroup) {
      unawaited(_fm.ensureFriendsLoaded());
    }
  }

  void _openDetails() {
    if (isWebHeader) {
      openOrToggleConversationDetails(context, controller.chat);
      return;
    }
    NavigationSvc.push(context, ConversationDetails(chat: controller.chat));
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Get chat state from scope - handles title logic including redacted mode
      final chatState = ChatStateScope.of(context);
      final hasWallpaper = widget.hasWallpaper || chatState.hasCustomWallpaper;
      final _title = chatState.title.value ?? controller.chat.getTitle();
      final loc = controller.chat.isGroup ? null : _fm.locationForChat(controller.chat);
      final isLandscapeAndroid = context.orientation == Orientation.landscape && Platform.isAndroid;

      final titleRow = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: NavigationSvc.width(context) / 2.5,
            ),
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              text: TextSpan(
                style: context.theme.textTheme.bodyMedium,
                children: MessageHelper.buildEmojiText(
                  _title,
                  context.theme.textTheme.bodyMedium!,
                ),
              ),
            ),
          ),
          Icon(
            CupertinoIcons.chevron_right,
            size: context.theme.textTheme.bodyMedium!.fontSize!,
            color: context.theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
        ],
      );

      final locationChip = loc == null
          ? null
          : HeaderLocationChip(
              key: const ValueKey('cupertino_header_location_chip'),
              loc: loc,
              isCupertino: true,
              hasWallpaper: hasWallpaper,
              maxWidth: NavigationSvc.width(context) / 2.6,
              onTap: () => _fm.openForChat(context, controller.chat),
            );

      if (isLandscapeAndroid) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            HeaderHoverSurface(
              key: const ValueKey('cupertino_header_name_card'),
              borderRadius: BorderRadius.circular(14),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              hasWallpaper: hasWallpaper,
              semanticLabel: _title,
              onTap: _openDetails,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const IgnorePointer(
                    ignoring: true,
                    child: ContactAvatarGroupWidget(size: 36),
                  ),
                  const SizedBox(width: 6),
                  titleRow,
                ],
              ),
            ),
            if (locationChip != null) ...[
              const SizedBox(width: 6),
              locationChip,
            ],
          ],
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          HeaderHoverSurface(
            key: const ValueKey('cupertino_header_name_card'),
            borderRadius: BorderRadius.circular(14),
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: loc != null ? 2 : 3),
            hasWallpaper: hasWallpaper,
            semanticLabel: _title,
            onTap: _openDetails,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IgnorePointer(
                  ignoring: true,
                  child: ContactAvatarGroupWidget(
                    size: loc != null ? 40 : 54,
                  ),
                ),
                SizedBox(height: loc != null ? 2 : 4),
                titleRow,
              ],
            ),
          ),
          if (locationChip != null) ...[
            const SizedBox(height: 1),
            locationChip,
          ],
        ],
      );
    });
  }
}
