import 'dart:async';
import 'dart:ui';

import 'package:bluebubbles/app/layouts/conversation_details/conversation_details.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/header_widgets.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_group_widget.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/app/components/wallpaper/chat_wallpaper_type.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide BackButton;
import 'package:flutter/services.dart';
import 'package:bluebubbles/platform/shims/window_effect.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

const double _kTopBarCurveRadius = 26.0;

/// Clips the Material top bar background to include the downward-curving
/// corner ears that sit above the rounded conversation sheet edge.
class CurvedTopBarClipper extends CustomClipper<Path> {
  const CurvedTopBarClipper({required this.radius});

  final double radius;

  @override
  Path getClip(Size size) {
    final r = radius.clamp(0.0, size.width / 2).clamp(0.0, size.height);
    final barBottom = size.height - r;
    return Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..arcToPoint(
        Offset(size.width - r, barBottom),
        radius: Radius.circular(r),
        clockwise: false,
      )
      ..lineTo(r, barBottom)
      ..arcToPoint(
        Offset(0, size.height),
        radius: Radius.circular(r),
        clockwise: false,
      )
      ..close();
  }

  @override
  bool shouldReclip(CurvedTopBarClipper oldClipper) => oldClipper.radius != radius;
}

class MaterialHeader extends StatelessWidget implements PreferredSizeWidget {
  const MaterialHeader({super.key, required this.controller});

  final ConversationViewController controller;

  @override
  Widget build(BuildContext context) {
    final Color _foregroundColor = context.theme.colorScheme.onSurface;
    final hasWindowEffect = kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled;

    return Stack(clipBehavior: Clip.none, children: [
      Obx(() {
        final hasCurve = SettingsSvc.settings.skin.value == Skins.Material &&
            !(kIsWeb && MediaQuery.sizeOf(context).width >= 680);
        final chatState = ChatStateScope.maybeOf(context) ?? ChatsSvc.getChatState(controller.chat.guid);
        final hasDynamicWallpaper = chatState?.wallpaperType.value == ChatWallpaperType.dynamic;
        final hasWallpaper = chatState?.hasCustomWallpaper ?? false;
        final useBlur = !SettingsSvc.settings.highPerfMode.value && !hasDynamicWallpaper;
        final backgroundColor = context.theme.colorScheme.surfaceContainer.withValues(
          alpha: hasWindowEffect ? 0.4 : ((hasCurve || hasWallpaper) ? 0.86 : 1.0),
        );
        final appBar = AppBar(
          backgroundColor: hasCurve ? Colors.transparent : backgroundColor,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          systemOverlayStyle: context.systemUiOverlayStyle(
            statusBarColor: (hasCurve || hasWallpaper) ? Colors.transparent : backgroundColor,
            backgroundBrightness: ThemeData.estimateBrightnessForColor(backgroundColor),
          ),
            automaticallyImplyLeading: false,
            toolbarHeight: (kIsDesktop ? 25 : 0) + kToolbarHeight,
            leadingWidth: 56,
            leading: Padding(
              padding: EdgeInsets.only(left: 4.0, top: kIsDesktop ? 20 : 0),
              child: BackButton(
                color: _foregroundColor,
                onPressed: () {
                  if (controller.inSelectMode.value) {
                    controller.inSelectMode.value = false;
                    controller.selected.clear();
                    return true;
                  }
                  if (LifecycleSvc.isBubble) {
                    SystemNavigator.pop();
                    return true;
                  }
                  controller.close();
                  return false;
                },
              ),
            ),
            title: Padding(
              padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
              child: _ChatIconAndTitle(
                parentController: controller,
                hasWallpaper: hasWallpaper,
              ),
            ),
            actions: [
              Padding(
                padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
                child: ManualMark(controller: controller),
              ),
              if (!isWebHeader && kIsDesktop && MediaQuery.sizeOf(context).width > 1024)
                Padding(
                  padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
                  child: Obx(() {
                    final open = NavigationSvc.showInspectorDrawer.value;
                    return IconButton(
                      tooltip: open ? 'Hide chat details (Alt+I)' : 'Show chat details (Alt+I)',
                      isSelected: open,
                      icon: Icon(
                        open ? Icons.info : Icons.info_outlined,
                        color: open ? context.theme.colorScheme.primary : _foregroundColor,
                      ),
                      onPressed: NavigationSvc.toggleInspectorDrawer,
                    );
                  }),
                ),
              if (canVideoCall(controller.chat))
                Padding(
                  padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
                  child: IconButton(
                    icon: Icon(Icons.videocam_outlined, color: _foregroundColor),
                    tooltip: 'Video',
                    onPressed: () => startVideoCall(context, controller.chat),
                  ),
                ),
              if (!kIsWeb && Platform.isAndroid && canAudioCall(controller.chat))
                Padding(
                  padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
                  child: IconButton(
                    icon: Icon(Icons.call_outlined, color: _foregroundColor),
                    tooltip: 'Call',
                    onPressed: () => startAudioCall(context, controller.chat),
                  ),
                )
              else if (kIsWeb &&
                  MediaQuery.sizeOf(context).width < 680 &&
                  !controller.chat.isGroup &&
                  controller.chat.handles.isNotEmpty &&
                  controller.chat.handles.first.address.isPhoneNumber)
                Padding(
                  padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
                  child: IconButton(
                    icon: Icon(Icons.call_outlined, color: _foregroundColor),
                    onPressed: () {
                      launchUrl(Uri(scheme: "tel", path: controller.chat.handles.first.address));
                    },
                  ),
                ),
              if ((Platform.isAndroid || kIsWeb) &&
                  !controller.chat.isGroup &&
                  controller.chat.handles.isNotEmpty &&
                  controller.chat.handles.first.address.isEmail)
                Padding(
                  padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
                  child: IconButton(
                    icon: Icon(Icons.mail_outlined, color: _foregroundColor),
                    onPressed: () {
                      launchUrl(Uri(scheme: "mailto", path: controller.chat.handles.first.address));
                    },
                  ),
                ),
              Padding(
                padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
                child: PopupMenuButton<int>(
                  color: hasWallpaper
                      ? context.theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.90)
                      : context.theme.colorScheme.surfaceContainerHigh,
                  shape: SettingsSvc.settings.skin.value != Skins.Material
                      ? const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(
                            Radius.circular(20.0),
                          ),
                        )
                      : null,
                  onSelected: (int value) {
                    if (value == 0) {
                      if (isWebHeader) {
                        openOrToggleConversationDetails(context, controller.chat, preferOpenInspector: true);
                      } else {
                        Navigator.of(context).push(
                          ThemeSwitcher.buildPageRoute(
                            builder: (context) => ConversationDetails(
                              chat: controller.chat,
                            ),
                          ),
                        );
                      }
                    } else if (value == 1) {
                      ChatsSvc.setChatArchived(controller.chat, !controller.chat.isArchived!);
                      if (Get.isSnackbarOpen) {
                        Get.closeAllSnackbars();
                      }
                      Navigator.of(context).pop();
                    } else if (value == 2) {
                      showBBDialog(
                        barrierDismissible: false,
                        context: context,
                        title: "Are you sure?",
                        body: "This chat will be deleted from this device only",
                        actions: <BBDialogAction>[
                          BBDialogAction(
                            text: "No",
                            onPressed: () {
                              if (Get.isSnackbarOpen) {
                                Get.closeAllSnackbars();
                              }
                              Navigator.of(context, rootNavigator: true).pop();
                            },
                          ),
                          BBDialogAction(
                            text: "Yes",
                            isDestructive: true,
                            onPressed: () async {
                              ChatsSvc.removeChat(controller.chat);
                              ChatsSvc.softDeleteChat(controller.chat);
                              if (Get.isSnackbarOpen) {
                                Get.closeAllSnackbars();
                              }
                              Navigator.of(context, rootNavigator: true).pop();
                            },
                          ),
                        ],
                      );
                    } else if (value == 3) {
                      showBookmarksThread(controller, context);
                    }
                  },
                  itemBuilder: (context) {
                    return <PopupMenuItem<int>>[
                      PopupMenuItem(
                        value: 0,
                        child: Text(
                          'Details',
                          style: context.textTheme.bodyLarge!.apply(color: context.theme.colorScheme.onSurface),
                        ),
                      ),
                      if (!LifecycleSvc.isBubble)
                        PopupMenuItem(
                          value: 1,
                          child: Text(
                            controller.chat.isArchived! ? 'Unarchive' : 'Archive',
                            style:
                                context.textTheme.bodyLarge!.apply(color: context.theme.colorScheme.onSurface),
                          ),
                        ),
                      if (!LifecycleSvc.isBubble)
                        PopupMenuItem(
                          value: 2,
                          child: Text(
                            'Delete',
                            style:
                                context.textTheme.bodyLarge!.apply(color: context.theme.colorScheme.onSurface),
                          ),
                        ),
                      PopupMenuItem(
                        value: 3,
                        child: Text(
                          'Bookmarks',
                          style: context.textTheme.bodyLarge!.apply(color: context.theme.colorScheme.onSurface),
                        ),
                      ),
                    ];
                  },
                  icon: Icon(
                    Icons.more_vert,
                    color: _foregroundColor,
                  ),
                ),
              )
            ],
          );
        if (hasCurve) {
          Widget curvedSurface = ColoredBox(color: backgroundColor);
          if (useBlur) {
            curvedSurface = BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: curvedSurface,
            );
          }
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                bottom: -_kTopBarCurveRadius,
                child: IgnorePointer(
                  child: ClipPath(
                    clipper: const CurvedTopBarClipper(radius: _kTopBarCurveRadius),
                    child: curvedSurface,
                  ),
                ),
              ),
              appBar,
            ],
          );
        }
        if (hasWallpaper && useBlur) {
          return ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: appBar,
            ),
          );
        }
        return appBar;
      }),
      const Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: HeaderProgressIndicator(),
      ),
    ]);
  }

  @override
  Size get preferredSize => Size.fromHeight(kIsDesktop ? 90 : kToolbarHeight);
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
  bool _avatarHovered = false;
  bool _avatarPressed = false;
  bool _titleHovered = false;
  bool _titlePressed = false;

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
    Navigator.of(context).push(
      ThemeSwitcher.buildPageRoute(
        builder: (context) => ConversationDetails(
          chat: controller.chat,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ChatStateScope.of(context);

    return Obx(() {
      final hasWallpaper = widget.hasWallpaper || chatState.hasCustomWallpaper;
      final _title = controller.inSelectMode.value
          ? "${controller.selected.length} selected"
          : chatState.title.value ?? controller.chat.getTitle();
      final loc = (controller.chat.isGroup || controller.inSelectMode.value)
          ? null
          : _fm.locationForChat(controller.chat);

      final titleWidget = Text(
        _title,
        style: context.theme.textTheme.titleLarge!
            .apply(color: context.theme.colorScheme.onSurface, fontSizeFactor: 0.9),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );

      final avatar = Padding(
        padding: const EdgeInsets.only(right: 10),
        child: IgnorePointer(
          ignoring: true,
          child: ContactAvatarGroupWidget(
            size: !controller.chat.isGroup ? 35 : 40,
          ),
        ),
      );

      if (loc == null) {
        final String? samsungSubtitle = !controller.chat.isGroup
            ? (!controller.inSelectMode.value &&
                    samsung &&
                    controller.chat.handles.isNotEmpty &&
                    !controller.chat.getTitle().isPhoneNumber &&
                    !controller.chat.getTitle().isEmail
                ? controller.chat.handles[0].address
                : null)
            : (samsung ? "${controller.chat.people.length} recipients" : null);

        return HeaderHoverSurface(
          key: const ValueKey('material_header_name_card'),
          borderRadius: BorderRadius.circular(14),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          hasWallpaper: hasWallpaper,
          semanticLabel: _title,
          onTap: _openDetails,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              avatar,
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titleWidget,
                    if (samsungSubtitle != null)
                      Text(
                        samsungSubtitle,
                        style: context.theme.textTheme.labelLarge!.apply(color: context.theme.colorScheme.outline),
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      }

      // Split hit regions so hovering/clicking location never double-highlights or triggers the name card.
      return AnimatedContainer(
        key: const ValueKey('material_header_name_card'),
        duration: kHeaderHoverDuration,
        curve: kHeaderHoverCurve,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: resolveHeaderHoverColor(
            context,
            hovered: _avatarHovered || _titleHovered,
            pressed: _avatarPressed || _titlePressed,
            hasWallpaper: hasWallpaper,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HeaderHitRegion(
              key: const ValueKey('material_header_avatar_target'),
              onHoverChanged: (v) {
                if (_avatarHovered != v) setState(() => _avatarHovered = v);
              },
              onPressChanged: (v) {
                if (_avatarPressed != v) setState(() => _avatarPressed = v);
              },
              onTap: _openDetails,
              child: avatar,
            ),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HeaderHitRegion(
                    key: const ValueKey('material_header_title_target'),
                    semanticLabel: _title,
                    onHoverChanged: (v) {
                      if (_titleHovered != v) setState(() => _titleHovered = v);
                    },
                    onPressChanged: (v) {
                      if (_titlePressed != v) setState(() => _titlePressed = v);
                    },
                    onTap: _openDetails,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      child: titleWidget,
                    ),
                  ),
                  const SizedBox(height: 1),
                  HeaderLocationChip(
                    key: const ValueKey('material_header_location_chip'),
                    loc: loc,
                    isCupertino: false,
                    hasWallpaper: hasWallpaper,
                    onTap: () => _fm.openForChat(context, controller.chat),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
}
