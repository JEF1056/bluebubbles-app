import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/layouts/conversation_details/conversation_details.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/tablet_mode_wrapper.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';

const Duration kHeaderHoverDuration = Duration(milliseconds: 140);
const Curve kHeaderHoverCurve = Curves.easeOutCubic;

@visibleForTesting
bool? webHeaderIsWebOverride;

@visibleForTesting
Widget Function(Chat chat)? webHeaderDetailsBuilderOverride;

bool get isWebHeader => webHeaderIsWebOverride ?? kIsWeb;

bool canToggleWebInspector(BuildContext context) {
  if (!isWebHeader) return false;
  final size = MediaQuery.sizeOf(context);
  final aspectRatio = size.height > 0 ? size.width / size.height : 1.0;
  final tabletWrapper = context.findAncestorWidgetOfExactType<TabletModeWrapper>();
  final inspectorEnabled = tabletWrapper?.enableInspector ?? true;
  return inspectorEnabled &&
      SettingsSvc.settings.tabletMode.value &&
      !LifecycleSvc.isBubble &&
      (!context.isPhone || aspectRatio > 0.8) &&
      size.width > 1024;
}

void openOrToggleConversationDetails(
  BuildContext context,
  Chat chat, {
  bool preferOpenInspector = false,
}) {
  if (canToggleWebInspector(context)) {
    if (preferOpenInspector) {
      NavigationSvc.showInspectorDrawer.value = true;
    } else {
      NavigationSvc.toggleInspectorDrawer();
    }
    return;
  }
  NavigationSvc.push(
    context,
    webHeaderDetailsBuilderOverride?.call(chat) ?? ConversationDetails(chat: chat),
  );
}

Color resolveHeaderHoverColor(
  BuildContext context, {
  required bool hovered,
  required bool pressed,
  required bool hasWallpaper,
}) {
  if (!hovered && !pressed) return Colors.transparent;
  if (hasWallpaper) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (pressed) {
      return Colors.white.withValues(alpha: isDark ? 0.16 : 0.30);
    }
    return Colors.white.withValues(alpha: isDark ? 0.10 : 0.20);
  }
  final onSurface = Theme.of(context).colorScheme.onSurface;
  return onSurface.withValues(alpha: pressed ? 0.11 : 0.07);
}

class HeaderHitRegion extends StatelessWidget {
  const HeaderHitRegion({
    super.key,
    required this.child,
    required this.onHoverChanged,
    required this.onPressChanged,
    required this.onTap,
    this.semanticLabel,
  });

  final Widget child;
  final ValueChanged<bool> onHoverChanged;
  final ValueChanged<bool> onPressChanged;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      child: MouseRegion(
        cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => onHoverChanged(true),
        onExit: (_) {
          onHoverChanged(false);
          onPressChanged(false);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => onPressChanged(true),
          onTapUp: (_) => onPressChanged(false),
          onTapCancel: () => onPressChanged(false),
          onTap: onTap,
          child: child,
        ),
      ),
    );
  }
}

class HeaderHoverSurface extends StatefulWidget {
  const HeaderHoverSurface({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.padding = EdgeInsets.zero,
    this.hasWallpaper = false,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final bool hasWallpaper;
  final String? semanticLabel;

  @override
  State<HeaderHoverSurface> createState() => _HeaderHoverSurfaceState();
}

class _HeaderHoverSurfaceState extends State<HeaderHoverSurface> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return HeaderHitRegion(
      onHoverChanged: (v) {
        if (_hovered != v) setState(() => _hovered = v);
      },
      onPressChanged: (v) {
        if (_pressed != v) setState(() => _pressed = v);
      },
      onTap: widget.onTap,
      semanticLabel: widget.semanticLabel,
      child: AnimatedContainer(
        duration: kHeaderHoverDuration,
        curve: kHeaderHoverCurve,
        padding: widget.padding,
        decoration: BoxDecoration(
          color: resolveHeaderHoverColor(
            context,
            hovered: _hovered,
            pressed: _pressed,
            hasWallpaper: widget.hasWallpaper,
          ),
          borderRadius: widget.borderRadius,
        ),
        child: widget.child,
      ),
    );
  }
}

class HeaderLocationChip extends StatelessWidget {
  const HeaderLocationChip({
    super.key,
    required this.loc,
    required this.isCupertino,
    required this.onTap,
    this.hasWallpaper = false,
    this.maxWidth,
  });

  final FindMyChatLocation loc;
  final bool isCupertino;
  final VoidCallback onTap;
  final bool hasWallpaper;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelText = loc.distanceLabel != null && loc.distanceLabel!.isNotEmpty
        ? '${loc.shortLabel} · ${loc.distanceLabel}'
        : loc.shortLabel;
    final textWidget = Text(
      labelText,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: isCupertino ? null : FontWeight.w500,
        fontSize: isCupertino ? 11 : null,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    return HeaderHoverSurface(
      borderRadius: BorderRadius.circular(999),
      padding: EdgeInsets.symmetric(horizontal: isCupertino ? 7 : 6, vertical: 1.5),
      hasWallpaper: hasWallpaper,
      semanticLabel: labelText,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isCupertino ? CupertinoIcons.location_fill : Icons.location_on_outlined,
            size: isCupertino ? 10 : 12,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 3),
          if (maxWidth != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth!),
              child: textWidget,
            )
          else
            Flexible(child: textWidget),
          if (loc.isLive) ...[
            SizedBox(width: isCupertino ? 4 : 5),
            Container(
              width: isCupertino ? 5 : 6,
              height: isCupertino ? 5 : 6,
              decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle),
            ),
          ],
        ],
      ),
    );
  }
}

class ManualMark extends StatefulWidget {
  const ManualMark({super.key, required this.controller});

  final ConversationViewController controller;

  @override
  State<StatefulWidget> createState() => ManualMarkState();
}

class ManualMarkState extends State<ManualMark> with ThemeHelpers {
  bool marked = false;
  bool marking = false;

  Chat get chat => widget.controller.chat;

  @override
  Widget build(BuildContext context) {
    final manualMark = SettingsSvc.settings.enablePrivateAPI.value &&
        SettingsSvc.settings.privateManualMarkAsRead.value &&
        !(chat.autoSendReadReceipts ?? false);
    return Obx(() {
      if (!manualMark && !widget.controller.inSelectMode.value) return const SizedBox.shrink();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              widget.controller.inSelectMode.value
                  ? (iOS ? CupertinoIcons.trash : Icons.delete_outlined)
                  : marking
                      ? (iOS ? CupertinoIcons.arrow_2_circlepath : Icons.sync)
                      : marked
                          ? (iOS ? CupertinoIcons.app : Icons.mark_chat_read_outlined)
                          : (iOS ? CupertinoIcons.app_badge : Icons.mark_chat_unread_outlined),
              color: !iOS
                  ? context.theme.colorScheme.onSurface
                  : (!marked && !marking || widget.controller.inSelectMode.value)
                      ? context.theme.colorScheme.primary
                      : context.theme.colorScheme.outline,
            ),
            tooltip: widget.controller.inSelectMode.value
                ? "Delete"
                : marking
                    ? null
                    : marked
                        ? "Mark Unread"
                        : "Mark Read",
            onPressed: () async {
              if (widget.controller.inSelectMode.value) {
                for (Message m in widget.controller.selected) {
                  await MessagesSvc(chat.guid).softDeleteMessage(m);
                }
                widget.controller.inSelectMode.value = false;
                widget.controller.selected.clear();
                return;
              }
              if (marking) return;
              setState(() {
                marking = true;
              });
              if (!marked) {
                await HttpSvc.chat.markRead(chat.guid);
              } else {
                await HttpSvc.chat.markUnread(chat.guid);
              }
              setState(() {
                marking = false;
                marked = !marked;
              });
            },
          ),
          if (widget.controller.inSelectMode.value)
            IconButton(
              icon: Icon(
                iOS ? CupertinoIcons.arrow_right : Icons.forward_outlined,
                color: !iOS ? context.theme.colorScheme.onSurface : context.theme.colorScheme.primary,
              ),
              onPressed: () async {
                List<PlatformFile> attachments = [];
                String text = "";
                widget.controller.selected.sort((a, b) => Message.sort(a, b, descending: false));
                for (Message m in widget.controller.selected) {
                  final _attachments = m.dbAttachments
                      .where((e) => AttachmentsSvc.getContent(e, autoDownload: false) is PlatformFile)
                      .map((e) => AttachmentsSvc.getContent(e, autoDownload: false) as PlatformFile);
                  for (PlatformFile a in _attachments) {
                    Uint8List? bytes = a.bytes;
                    if (bytes == null && !kIsWeb && a.path != null) {
                      bytes = await File(a.path!).readAsBytes();
                    }
                    if (bytes == null) continue;
                    attachments.add(PlatformFile(
                      name: a.name,
                      path: a.path,
                      size: bytes.length,
                      bytes: bytes,
                    ));
                  }
                  if (!isNullOrEmpty(m.text)) {
                    if (text.isEmpty) {
                      text = m.text!;
                    } else {
                      text = "$text\n\n${m.text}";
                    }
                  }
                }
                widget.controller.inSelectMode.value = false;
                widget.controller.selected.clear();
                NavigationSvc.pushAndRemoveUntil(
                  context,
                  NewChatCreator(
                    initialText: text,
                    initialAttachments: attachments,
                  ),
                  (route) => route.isFirst,
                );
              },
            ),
        ],
      );
    });
  }
}

/// A send-progress [LinearProgressIndicator] shared by both header skins.
///
/// Reads [Chat.sendProgress] from [ChatStateScope] so it never needs a
/// [Chat] constructor parameter.  Place it in a [Positioned] at the bottom
/// of the header stack.
class HeaderProgressIndicator extends StatelessWidget {
  const HeaderProgressIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = ChatStateScope.chatOf(context);
    return Obx(() => TweenAnimationBuilder<double>(
          duration: chat.sendProgress.value == 0
              ? Duration.zero
              : chat.sendProgress.value == 1
                  ? const Duration(milliseconds: 250)
                  : const Duration(seconds: 10),
          curve: chat.sendProgress.value == 1 ? Curves.easeInOut : Curves.easeOutExpo,
          tween: Tween<double>(
            begin: 0,
            end: chat.sendProgress.value,
          ),
          builder: (context, value, _) => AnimatedOpacity(
            opacity: value == 1 ? 0 : 1,
            duration: const Duration(milliseconds: 250),
            child: LinearProgressIndicator(
              value: value,
              backgroundColor: Colors.transparent,
              minHeight: 3,
            ),
          ),
        ));
  }
}
