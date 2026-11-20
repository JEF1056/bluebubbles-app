import 'package:bluebubbles/app/components/custom/custom_bouncing_scroll_physics.dart';
import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Inline message editing field with keyboard shortcuts
/// Extracted from MessageHolder to improve maintainability
class MessageEditField extends StatefulWidget {
  const MessageEditField({
    super.key,
    required this.part,
    required this.editController,
    required this.cvController,
    required this.onComplete,
  });

  final int part;
  final SpellCheckTextEditingController editController;
  final ConversationViewController cvController;
  final void Function(String text, int part) onComplete;

  @override
  State<MessageEditField> createState() => _MessageEditFieldState();
}

class _MessageEditFieldState extends State<MessageEditField> {
  final FocusNode _shortcutFocusNode = FocusNode();

  @override
  void dispose() {
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  MessageState _getController(Message message) => MessagesSvc(widget.cvController.chat.guid).getOrCreateState(message);

  void _cancelEdit(Message message) {
    widget.cvController.editing.removeWhere((e2) => e2.message.guid == message.guid! && e2.part.part == widget.part);
    if (widget.cvController.editing.isEmpty) {
      widget.cvController.lastFocusedNode.requestFocus();
    } else {
      widget.cvController.editing.last.controller.focusNode?.requestFocus();
    }
  }

  KeyEventResult _handleKeyEvent(KeyEvent ev, Message message) {
    if (ev is! KeyDownEvent) {
      if (ev.logicalKey == LogicalKeyboardKey.tab) {
        return KeyEventResult.skipRemainingHandlers;
      }
      return KeyEventResult.ignored;
    }

    // Enter without shift = submit
    if (ev.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
      widget.onComplete(widget.editController.text, widget.part);
      return KeyEventResult.handled;
    }

    // Escape = cancel
    if (ev.logicalKey == LogicalKeyboardKey.escape) {
      _cancelEdit(message);
      return KeyEventResult.handled;
    }

    // Absorb tab
    if (ev.logicalKey == LogicalKeyboardKey.tab) {
      return KeyEventResult.skipRemainingHandlers;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final message = MessageStateScope.messageOf(context);
    final controller = _getController(message);
    final iOS = SettingsSvc.settings.skin.value == Skins.iOS;

    return Obx(() {
      final isTempMessage = controller.isSending.value;
      return Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: !message.isBigEmoji
                  ? context.theme.colorScheme.primary.darkenAmount(isTempMessage ? 0.2 : 0)
                  : context.theme.colorScheme.surface,
            ),
            constraints: BoxConstraints(
              maxWidth: MessageState.maxBubbleWidth(context, inset: 40),
              minHeight: 40,
            ),
            padding: EdgeInsets.only(right: iOS ? 10 : 0).add(const EdgeInsets.all(5)),
            child: Focus(
              focusNode: _shortcutFocusNode,
              onKeyEvent: (_, ev) => _handleKeyEvent(ev, message),
              child: TextField(
                textCapitalization: TextCapitalization.sentences,
                autocorrect: true,
                controller: widget.editController,
                focusNode: widget.editController.focusNode,
                scrollPhysics: const CustomBouncingScrollPhysics(),
                style: context.theme.extension<BubbleText>()!.bubbleText.apply(
                      fontSizeFactor: message.isBigEmoji ? 3 : 1,
                    ),
                keyboardType: TextInputType.multiline,
                maxLines: 14,
                minLines: 1,
                autofocus: true,
                enableIMEPersonalizedLearning: !SettingsSvc.settings.incognitoKeyboard.value,
                textInputAction: SettingsSvc.settings.sendWithReturn.value && !kIsWeb && !kIsDesktop
                    ? TextInputAction.send
                    : TextInputAction.newline,
                cursorColor: context.theme.extension<BubbleText>()!.bubbleText.color,
                cursorHeight:
                    context.theme.extension<BubbleText>()!.bubbleText.fontSize! * 1.25 * (message.isBigEmoji ? 3 : 1),
                decoration: InputDecoration(
                  contentPadding: EdgeInsets.all(iOS ? 10 : 12.5),
                  isDense: true,
                  isCollapsed: true,
                  hintText: "Edited Message",
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: context.theme.colorScheme.outline, width: 1.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: context.theme.colorScheme.outline, width: 1.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: context.theme.colorScheme.onSurface, width: 1.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  fillColor: Colors.transparent,
                  hintStyle: context.theme.extension<BubbleText>()!.bubbleText.copyWith(
                        color: context.theme.colorScheme.onSurface,
                      ),
                  prefixIconConstraints: const BoxConstraints(minHeight: 0, minWidth: 40),
                  prefixIcon: IconButton(
                    constraints: const BoxConstraints(maxWidth: 27),
                    padding: const EdgeInsets.only(left: 5),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      CupertinoIcons.xmark_circle_fill,
                      color: context.theme.colorScheme.onSurface,
                      size: 20,
                    ),
                    onPressed: () => _cancelEdit(message),
                  ),
                  suffixIconConstraints: const BoxConstraints(minHeight: 0, minWidth: 40),
                  suffixIcon: IconButton(
                    constraints: const BoxConstraints(maxWidth: 27),
                    padding: const EdgeInsets.only(right: 5),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      iOS ? CupertinoIcons.checkmark_alt_circle_fill : Icons.check_circle,
                      color: context.theme.colorScheme.onSurface,
                      size: 20,
                    ),
                    onPressed: () => widget.onComplete(widget.editController.text, widget.part),
                  ),
                ),
                onSubmitted: (value) {
                  if (!SettingsSvc.settings.sendWithReturn.value || kIsWeb || kIsDesktop) return;
                  widget.onComplete(value, widget.part);
                },
              ),
            ), // Container closes
          )); // Material closes
    }); // Obx closes
  }
}
