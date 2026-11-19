import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/trailing_state_mixin.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class MaterialConversationTile extends CustomStateful<ConversationTileController> {
  const MaterialConversationTile({super.key, required super.parentController});

  @override
  State<StatefulWidget> createState() => _MaterialConversationTileState();
}

class _MaterialConversationTileState extends CustomState<MaterialConversationTile, void, ConversationTileController> {
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
    final child = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        mouseCursor: MouseCursor.defer,
        onTap: () => controller.onTap(context),
        onSecondaryTapUp: (details) => controller.onSecondaryTap(Get.context!, details),
        onLongPress: controller.onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: ListTile(
          mouseCursor: MouseCursor.defer,
          dense: SettingsSvc.settings.denseChatTiles.value,
          visualDensity: SettingsSvc.settings.denseChatTiles.value ? VisualDensity.compact : null,
          minVerticalPadding: SettingsSvc.settings.denseChatTiles.value ? 7.5 : 10,
          title: Obx(() => ChatTitle(
                parentController: controller,
                style: context.theme.textTheme.bodyLarge!.copyWith(
                  fontWeight: controller.shouldHighlight.value
                      ? FontWeight.w500
                      : (ChatsSvc.getChatState(controller.chat.guid)?.hasUnreadMessage.value ?? false)
                          ? FontWeight.bold
                          : null,
                  color: context.theme.colorScheme.onSurface,
                ),
              )),
          subtitle: controller.subtitle ??
              Obx(() {
                final unread = ChatsSvc.getChatState(controller.chat.guid)?.hasUnreadMessage.value ?? false;
                return ChatSubtitle(
                  parentController: controller,
                  style: context.theme.textTheme.bodyMedium!.copyWith(
                    fontWeight: unread ? FontWeight.w600 : null,
                    color: controller.shouldHighlight.value || unread
                        ? context.theme.colorScheme.onSurface
                        : context.theme.colorScheme.onSurfaceVariant,
                    height: 1.43,
                  ),
                );
              }),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: leading,
          trailing: MaterialTrailing(parentController: controller),
        ),
      ),
    );

    return ChatStateScope(
      chatState: controller.chatState,
      child: Obx(() {
        NavigationSvc.listener.value;
        return AnimatedContainer(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: controller.isSelected
                ? context.theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                : shouldPartialHighlight
                    ? context.theme.colorScheme.surfaceContainerHighest
                    : shouldHighlight
                        ? context.theme.colorScheme.primaryContainer
                        : context.theme.colorScheme.surface,
          ),
          duration: const Duration(milliseconds: 100),
          child: NavigationSvc.isAvatarOnly(context)
              ? InkWell(
                  mouseCursor: MouseCursor.defer,
                  onTap: () => controller.onTap(context),
                  onSecondaryTapUp: (details) => controller.onSecondaryTap(Get.context!, details),
                  onLongPress: controller.onLongPress,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 15.0),
                    child: Center(child: leading),
                  ),
                )
              : child,
        );
      }),
    );
  }
}

class MaterialTrailing extends CustomStateful<ConversationTileController> {
  const MaterialTrailing({super.key, required super.parentController});

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
        final unreadCount = unread ? MaterialTrailing.computeUnreadCount(controller.chat, chatState.lastReadMessageGuid.value) : 0;
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisAlignment: MainAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (chatState.isPinned.value)
                  Icon(Icons.push_pin_outlined, size: 18, color: context.theme.colorScheme.onSurfaceVariant),
                if (muteType != "mute" && unread) ...[
                  if (chatState.isPinned.value) const SizedBox(width: 5),
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
        borderRadius: BorderRadius.circular(10),
        color: context.theme.colorScheme.primary,
      ),
      child: Text(
        label,
        style: context.theme.textTheme.labelSmall?.copyWith(
          color: context.theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w700,
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
    return Obx(() => Padding(
          padding: const EdgeInsets.only(left: 5.0, right: 5.0),
          child: (ChatsSvc.getChatState(controller.chat.guid)?.hasUnreadMessage.value ?? false)
              ? Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(35),
                    color: context.theme.colorScheme.primary,
                  ),
                  width: 10,
                  height: 10,
                )
              : const SizedBox(width: 10),
        ));
  }
}
