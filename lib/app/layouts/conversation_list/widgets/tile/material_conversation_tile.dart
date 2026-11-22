import 'package:bluebubbles/app/components/blur_fade_switcher.dart';
import 'package:bluebubbles/app/components/m3e/m3e.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/trailing_state_mixin.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class MaterialConversationTile extends CustomStateful<ConversationTileController> {
  const MaterialConversationTile({super.key, required super.parentController});

  @override
  State<StatefulWidget> createState() => _MaterialConversationTileState();
}

class _MaterialConversationTileState extends CustomState<MaterialConversationTile, void, ConversationTileController> {
  bool _isHovered = false;

  bool get shouldPartialHighlight => controller.shouldPartialHighlight.value;

  bool get shouldHighlight => controller.shouldHighlight.value;

  @override
  void initState() {
    super.initState();
    tag = controller.chat.guid;
    // keep controller in memory since the widget is part of a list
    // (it will be disposed when scrolled out of view)
    forceDelete = false;
  }

  @override
  Widget build(BuildContext context) {
    final leading = ChatLeading(controller: controller);
    return ChatStateScope(
      chatState: controller.chatState,
      child: Obx(() {
        NavigationSvc.listener.value;
        final isSelected = controller.isSelected;
        final unread = ChatsSvc.getChatState(controller.chat.guid)?.hasUnreadMessage.value ?? false;
        final tileRadius = (isSelected || shouldHighlight)
            ? const BorderRadius.all(Radius.circular(9999))
            : shouldPartialHighlight
                ? M3EShapes.radiusXl
                : M3EShapes.radiusLgIncreased;
        final child = Material(
          color: Colors.transparent,
          borderRadius: tileRadius,
          child: InkWell(
            mouseCursor: SystemMouseCursors.click,
            onTap: () => controller.onTap(context),
            onSecondaryTapUp: (details) => controller.onSecondaryTap(context, details),
            onLongPress: controller.onLongPress,
            borderRadius: tileRadius,
            child: ListTile(
              mouseCursor: SystemMouseCursors.click,
              dense: SettingsSvc.settings.denseChatTiles.value,
              visualDensity: SettingsSvc.settings.denseChatTiles.value ? VisualDensity.compact : null,
              minTileHeight: SettingsSvc.settings.denseChatTiles.value ? null : (kIsWeb ? 72 : 76),
              minVerticalPadding: SettingsSvc.settings.denseChatTiles.value ? 7.5 : 10,
              title: Obx(() {
                final titleUnread = ChatsSvc.getChatState(controller.chat.guid)?.hasUnreadMessage.value ?? false;
                return ChatTitle(
                  parentController: controller,
                  style: context.theme.textTheme.bodyLarge!.copyWith(
                    fontWeight: titleUnread
                        ? FontWeight.w700
                        : controller.shouldHighlight.value
                            ? FontWeight.w500
                            : null,
                    color: context.theme.colorScheme.onSurface,
                  ),
                );
              }),
              subtitle: controller.subtitle ??
                  Obx(() {
                    final subUnread = ChatsSvc.getChatState(controller.chat.guid)?.hasUnreadMessage.value ?? false;
                    return ChatSubtitle(
                      parentController: controller,
                      style: context.theme.textTheme.bodyMedium!.copyWith(
                        fontWeight: subUnread ? FontWeight.w700 : null,
                        color: controller.shouldHighlight.value || subUnread
                            ? context.theme.colorScheme.onSurface
                            : context.theme.colorScheme.onSurfaceVariant,
                        height: 1.43,
                      ),
                    );
                  }),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              leading: leading,
              trailing: MaterialTrailing(parentController: controller, isHovered: _isHovered),
            ),
          ),
        );

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (!_isHovered) setState(() => _isHovered = true);
          },
          onExit: (_) {
            if (_isHovered) setState(() => _isHovered = false);
          },
          child: AnimatedContainer(
            margin: EdgeInsets.symmetric(horizontal: isSelected ? 12 : 8, vertical: 1.5),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: tileRadius,
              color: isSelected
                  ? context.theme.colorScheme.secondaryContainer.withValues(alpha: 0.7)
                  : shouldPartialHighlight
                      ? context.theme.colorScheme.surfaceContainerHighest
                      : shouldHighlight
                          ? context.theme.colorScheme.secondaryContainer
                          : _isHovered
                              ? context.theme.colorScheme.surfaceContainerHigh
                              : context.theme.colorScheme.surface,
            ),
            duration: M3EMotion.spatialFast.duration,
            curve: M3EMotion.spatialFast.curve,
            child: NavigationSvc.isAvatarOnly(context)
                ? InkWell(
                    mouseCursor: SystemMouseCursors.click,
                    onTap: () => controller.onTap(context),
                    onSecondaryTapUp: (details) => controller.onSecondaryTap(context, details),
                    onLongPress: controller.onLongPress,
                    borderRadius: tileRadius,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 15.0),
                      child: Center(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            leading,
                            if (unread)
                              Positioned(
                                top: 0,
                                right: 0,
                                child: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: context.theme.colorScheme.primary,
                                    border: Border.all(
                                      color: context.theme.colorScheme.surface,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  )
                : child,
          ),
        );
      }),
    );
  }
}

class MaterialTrailing extends CustomStateful<ConversationTileController> {
  const MaterialTrailing({super.key, required super.parentController, this.isHovered = false});

  final bool isHovered;

  @visibleForTesting
  static int computeUnreadCount(
    Chat chat,
    String? lastReadGuid, {
    List<Message> Function(Chat chat, {int limit})? fetchMessages,
  }) {
    if (chat.id == null) return 1;
    try {
      final messages = (fetchMessages ?? (c, {int limit = 25}) => Chat.getMessages(c, limit: limit))(chat, limit: 25);
      int count = 0;
      for (final m in messages) {
        if (lastReadGuid != null && m.guid == lastReadGuid) break;
        if (m.isFromMe != true && m.associatedMessageGuid == null) {
          count++;
        }
      }
      return count > 0 ? count : 1;
    } catch (_) {
      return 1;
    }
  }

  @override
  State<StatefulWidget> createState() => _MaterialTrailingState();
}

class _MaterialTrailingState extends CustomState<MaterialTrailing, void, ConversationTileController>
    with TrailingStateMixin<MaterialTrailing> {
  @override
  Widget build(BuildContext context) {
    final chatState = ChatStateScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 3),
      child: Obx(() {
        final message = chatState.latestMessage.value;
        final hasError = (message?.error ?? 0) > 0;
        final unread = chatState.hasUnreadMessage.value;
        final muteType = chatState.muteType.value;
        final hasMention = unread &&
            message != null &&
            message.isFromMe != true &&
            message.attributedBody.any((b) => b.runs.any((r) => r.hasMention));
        final showHoverMenu = (kIsDesktop || kIsWeb) && widget.isHovered && !controller.isSelected;
        final unreadCount = unread ? MaterialTrailing.computeUnreadCount(controller.chat, chatState.lastReadMessageGuid.value) : 0;
        syncRelativeTimestamp(hasError ? null : message?.dateCreated, isRelative: true);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  hasError ? "Error" : buildChatListDateMaterial(message?.dateCreated),
                  textAlign: TextAlign.right,
                  style: context.theme.textTheme.bodySmall!.copyWith(
                    color: hasError
                        ? context.theme.colorScheme.error
                        : unread
                            ? context.theme.colorScheme.primary
                            : controller.shouldHighlight.value
                                ? context.theme.colorScheme.onSurface
                                : context.theme.colorScheme.onSurfaceVariant,
                    fontWeight: unread
                        ? FontWeight.w700
                        : controller.shouldHighlight.value
                            ? FontWeight.w500
                            : null,
                  ),
                  overflow: TextOverflow.clip,
                ),
              ],
            ),
            const SizedBox(height: 5),
            BlurFadeSwitcher(
              alignment: AlignmentDirectional.centerEnd,
              child: controller.isSelected
                  ? Icon(
                      Icons.check_circle_rounded,
                      key: const ValueKey('selected'),
                      size: 20,
                      color: context.theme.colorScheme.primary,
                    )
                  : showHoverMenu
                      ? Builder(
                          key: const ValueKey('hover_menu'),
                          builder: (btnContext) => IconButton(
                            icon: Icon(
                              Icons.more_vert,
                              size: 18,
                              color: context.theme.colorScheme.onSurfaceVariant,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                            tooltip: 'More options',
                            onPressed: () {
                              final box = btnContext.findRenderObject() as RenderBox?;
                              final pos = box != null
                                  ? box.localToGlobal(Offset(box.size.width, box.size.height))
                                  : Offset.zero;
                              showConversationTileMenu(
                                context,
                                controller,
                                controller.chat,
                                pos,
                                context.textTheme,
                              );
                            },
                          ),
                        )
                      : Row(
                          key: ValueKey('meta_${chatState.isPinned.value}_${muteType == "mute"}_${unread}_$hasMention'),
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisAlignment: MainAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (chatState.isPinned.value)
                              Icon(Icons.push_pin_outlined, size: 18, color: context.theme.colorScheme.onSurfaceVariant),
                            if (hasMention) ...[
                              if (chatState.isPinned.value) const SizedBox(width: 4),
                              Container(
                                width: 16,
                                height: 16,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: context.theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '@',
                                  style: context.theme.textTheme.labelSmall?.copyWith(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: context.theme.colorScheme.onSurface,
                                    height: 1.0,
                                  ),
                                ),
                              ),
                            ],
                            if (muteType != "mute" && unread) ...[
                              if (chatState.isPinned.value || hasMention) const SizedBox(width: 5),
                              _MaterialUnreadBadge(count: unreadCount),
                            ],
                            if (muteType == "mute") const SizedBox(width: 5),
                            if (muteType == "mute")
                              Icon(
                                Icons.notifications_off_outlined,
                                color: controller.shouldHighlight.value || unread
                                    ? context.theme.colorScheme.primary
                                    : context.theme.colorScheme.onSurfaceVariant,
                                size: 18,
                              ),
                          ],
                        ),
            ),
          ],
        );
      }),
    );
  }
}

class _MaterialUnreadBadge extends StatelessWidget {
  const _MaterialUnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count > 25 ? '25+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: EdgeInsets.symmetric(horizontal: label.length > 1 ? 6 : 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: M3EShapes.radiusXl,
        color: context.theme.colorScheme.primary,
      ),
      child: Text(
        label,
        style: context.theme.textTheme.labelSmall?.copyWith(
          fontSize: 11,
          color: context.theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      ),
    );
  }
}

class UnreadIcon extends CustomStateful<ConversationTileController> {
  const UnreadIcon({super.key, required super.parentController});

  @override
  State<StatefulWidget> createState() => _UnreadIconState();
}

class _UnreadIconState extends CustomState<UnreadIcon, void, ConversationTileController> {
  @override
  void initState() {
    super.initState();
    tag = controller.chat.guid;
    // keep controller in memory since the widget is part of a list
    // (it will be disposed when scrolled out of view)
    forceDelete = false;
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final hasUnread = ChatsSvc.getChatState(controller.chat.guid)?.hasUnreadMessage.value ?? false;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5.0),
        child: SizedBox(
          width: 8,
          height: 8,
          child: AnimatedScale(
            scale: hasUnread ? 1.0 : 0.0,
            duration: M3EMotion.spatialFast.duration,
            curve: M3EMotion.spatialOvershoot,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: M3EShapes.radiusXl,
                color: context.theme.colorScheme.primary,
              ),
            ),
          ),
        ),
      );
    });
  }
}
