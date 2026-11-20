import 'dart:math' as math;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/media_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/message_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/navigation_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/text_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/details_menu_action.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_action_context.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/widgets/emoji_tapback_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_line_painter.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show MessageReplyContext;
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

const List<String> _kGMsgQuickEmojis = ['👍', '❤️', '😂', '😮', '😢', '😡'];

enum _HoverMenuItem {
  copyText,
  edit,
  unsend,
  download,
  openInBrowser,
  forward,
  select,
  info,
  delete,
}

String formatHoverTimestampTooltip(DateTime? dateCreated, {bool use24Hr = false}) {
  if (dateCreated == null || dateCreated.millisecondsSinceEpoch == 0) return '';
  final timeStr = buildTime(dateCreated);
  final dateStr = buildFullDate(dateCreated);
  return '$dateStr, $timeStr';
}

class MessageHoverBar extends StatefulWidget {
  const MessageHoverBar({
    super.key,
    required this.controller,
    required this.part,
    required this.cvController,
    required this.service,
    required this.hovered,
    required this.isReplyThread,
  });

  final MessageState controller;
  final MessagePart part;
  final ConversationViewController cvController;
  final MessagesService service;
  final bool hovered;
  final bool isReplyThread;

  @override
  State<MessageHoverBar> createState() => _MessageHoverBarState();
}

class _MessageHoverBarState extends State<MessageHoverBar> {
  final GlobalKey _reactBtnKey = GlobalKey();
  bool _popoverOpen = false;

  void _setPopoverOpen(bool open) {
    if (!mounted || _popoverOpen == open) return;
    setState(() => _popoverOpen = open);
  }

  Message get _message => widget.controller.message;

  bool _matchesQuickEmoji(Message reactionMsg, String emoji) {
    final mapped = ReactionTypes.emojiToReaction[emoji];
    final type = reactionMsg.associatedMessageType ?? '';
    if (mapped != null && type == mapped) return true;
    return type == ReactionTypes.EMOJI && reactionMsg.associatedMessageEmoji == emoji;
  }

  Message? _ownReactionForEmoji(String emoji) {
    return widget.controller.associatedMessages.firstWhereOrNull(
      (m) {
        final type = m.associatedMessageType ?? '';
        final isRemoved = type.startsWith('-') || type == ReactionTypes.REMOVED_EMOJI;
        return (m.isFromMe ?? false) &&
            !isRemoved &&
            (m.associatedMessagePart ?? 0) == widget.part.part &&
            _matchesQuickEmoji(m, emoji);
      },
    );
  }

  void _toggleEmojiReaction(String emoji) {
    HapticFeedback.lightImpact();
    widget.cvController.onUserChatInteraction(immediate: true);
    final existing = _ownReactionForEmoji(emoji);
    final mapped = ReactionTypes.emojiToReaction[emoji];
    final String reactionType;
    final String? emojiPayload;
    if (existing != null) {
      if (mapped != null && existing.associatedMessageType == mapped) {
        reactionType = '-$mapped';
        emojiPayload = null;
      } else {
        reactionType = ReactionTypes.REMOVED_EMOJI;
        emojiPayload = emoji;
      }
    } else if (mapped != null) {
      reactionType = mapped;
      emojiPayload = null;
    } else {
      reactionType = ReactionTypes.EMOJI;
      emojiPayload = emoji;
    }

    final tempMessage = Message(
      associatedMessageGuid: _message.guid,
      associatedMessageType: reactionType,
      associatedMessageEmoji: emojiPayload,
      associatedMessagePart: widget.part.part,
      dateCreated: DateTime.now(),
      hasAttachments: false,
      isFromMe: true,
      handleId: 0,
    );
    OutgoingMsgHandler.queue(
      OutgoingReaction(
        chat: _message.chat.target ?? widget.cvController.chat,
        message: tempMessage,
        selectedMessage: _message,
        reaction: reactionType,
      ),
    );
  }

  Future<void> _openReactPopover() async {
    final box = _reactBtnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    const barWidth = 286.0;
    const barHeight = 44.0;
    final left =
        (origin.dx - barWidth / 2 + box.size.width / 2).clamp(12.0, math.max(12.0, screen.width - barWidth - 12)).toDouble();
    final top = (origin.dy - barHeight - 8).clamp(12.0, math.max(12.0, screen.height - barHeight - 12)).toDouble();
    final cs = context.theme.colorScheme;

    _setPopoverOpen(true);
    try {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Close reaction picker',
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 110),
        pageBuilder: (dialogCtx, _, __) {
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(dialogCtx).pop(),
            },
            child: Focus(
              autofocus: true,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () => Navigator.of(dialogCtx).pop(),
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: top,
                    child: Material(
                      elevation: 6,
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(24),
                      child: Container(
                        height: barHeight,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ..._kGMsgQuickEmojis.map((emoji) {
                              final selected = _ownReactionForEmoji(emoji) != null;
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 2),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(18),
                                  onTap: () {
                                    Navigator.of(dialogCtx).pop();
                                    _toggleEmojiReaction(emoji);
                                  },
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: selected ? cs.primaryContainer : Colors.transparent,
                                    ),
                                    child: Text(
                                      emoji,
                                      style: const TextStyle(
                                        fontSize: 19,
                                        fontFamilyFallback: [
                                          "Apple Color Emoji",
                                          "Noto Color Emoji",
                                          "Segoe UI Emoji",
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }),
                            InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () async {
                                Navigator.of(dialogCtx).pop();
                                final picked = await showEmojiTapbackPicker(context);
                                if (!mounted) return;
                                if (picked != null && picked.isNotEmpty) {
                                  _toggleEmojiReaction(picked);
                                }
                              },
                              child: Container(
                                width: 32,
                                height: 32,
                                alignment: Alignment.center,
                                child: Icon(Icons.add, size: 18, color: cs.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      if (mounted) _setPopoverOpen(false);
    }
  }

  MessagePopupActionContext _buildActionContext(DetailsMenuAction action) {
    final chat = widget.cvController.chat;
    return MessagePopupActionContext(
      context: context,
      widthContext: context,
      cvController: widget.cvController,
      messageState: widget.controller,
      message: _message,
      part: widget.part,
      chat: chat,
      service: widget.service,
      serverDetails: MessagePopupServerDetails(
        minSierra: SettingsSvc.serverDetails.isMinSierra,
        minBigSur: SettingsSvc.serverDetails.isMinBigSur,
        supportsOriginalDownload: SettingsSvc.serverDetails.supportsOriginalDownload,
      ),
      action: action,
      popDetails: ({bool returnVal = true}) {},
      showSnack: (title, body, {type = SnackbarType.info}) => showSnackbar(title, body, type: type),
      dmChat: null,
      isEmbeddedMedia: false,
    );
  }

  void _handleMenuSelected(_HoverMenuItem item) {
    switch (item) {
      case _HoverMenuItem.copyText:
        copyText(_buildActionContext(DetailsMenuAction.CopyText));
      case _HoverMenuItem.edit:
        edit(_buildActionContext(DetailsMenuAction.Edit));
      case _HoverMenuItem.unsend:
        unsend(_buildActionContext(DetailsMenuAction.UndoSend));
      case _HoverMenuItem.download:
        downloadAttachment(_buildActionContext(DetailsMenuAction.Save));
      case _HoverMenuItem.openInBrowser:
        openAttachmentWeb(_buildActionContext(DetailsMenuAction.OpenInBrowser));
      case _HoverMenuItem.forward:
        forward(_buildActionContext(DetailsMenuAction.Forward));
      case _HoverMenuItem.select:
        selectMultiple(_buildActionContext(DetailsMenuAction.SelectMultiple));
      case _HoverMenuItem.info:
        messageInfo(_buildActionContext(DetailsMenuAction.MessageInfo));
      case _HoverMenuItem.delete:
        delete(_buildActionContext(DetailsMenuAction.Delete));
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.hovered || _popoverOpen;
    final cs = context.theme.colorScheme;
    final iconColor = cs.onSurfaceVariant;
    final isTemp = widget.controller.isSending.value;
    final chat = widget.cvController.chat;
    final serviceType = ChatServiceType.fromServiceName(_message.service);
    final supportsTapback = chat.isIMessage || chat.isRCS || (serviceType?.supportsTapbackAndReply ?? false);
    final canReply = !widget.isReplyThread && supportsTapback && !isTemp && _message.guid != null;
    final canEdit = (_message.isFromMe ?? false) &&
        !isTemp &&
        !isNullOrEmpty(widget.part.text) &&
        (chat.isIMessage || chat.isRCS) &&
        SettingsSvc.settings.enablePrivateAPI.value &&
        SettingsSvc.serverDetails.isMinVentura;
    final canUnsend = (_message.isFromMe ?? false) &&
        !isTemp &&
        (chat.isIMessage || chat.isRCS) &&
        SettingsSvc.settings.enablePrivateAPI.value &&
        SettingsSvc.serverDetails.isMinVentura;
    final hasAttachment = widget.part.attachments.isNotEmpty;
    final hasWebUrl = widget.part.attachments.firstOrNull?.webUrl?.isNotEmpty ?? false;
    final hasText = !isNullOrEmpty(widget.part.fullText);

    return AnimatedOpacity(
      opacity: active ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 100),
      child: IgnorePointer(
        ignoring: !active,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (supportsTapback && !isTemp && _message.guid != null)
                Tooltip(
                  message: 'Add reaction',
                  child: InkWell(
                    key: _reactBtnKey,
                    borderRadius: BorderRadius.circular(14),
                    onTap: _openReactPopover,
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: Icon(Icons.add_reaction_outlined, size: 17, color: iconColor),
                    ),
                  ),
                ),
              if (canReply)
                Tooltip(
                  message: 'Reply',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      widget.cvController.replyToMessage = MessageReplyContext(
                        _message,
                        widget.part.part,
                        attachmentGuid: widget.part.attachments.length == 1 ? widget.part.attachments.first.guid : null,
                      );
                      widget.cvController.focusNode.requestFocus();
                    },
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: Icon(Icons.reply_rounded, size: 17, color: iconColor),
                    ),
                  ),
                ),
              PopupMenuButton<_HoverMenuItem>(
                tooltip: 'More options',
                padding: EdgeInsets.zero,
                onOpened: () => _setPopoverOpen(true),
                onCanceled: () => _setPopoverOpen(false),
                onSelected: (item) {
                  _setPopoverOpen(false);
                  _handleMenuSelected(item);
                },
                itemBuilder: (_) => [
                  if (hasText)
                    const PopupMenuItem(value: _HoverMenuItem.copyText, child: Text('Copy text')),
                  if (canEdit)
                    const PopupMenuItem(value: _HoverMenuItem.edit, child: Text('Edit')),
                  if (canUnsend)
                    const PopupMenuItem(value: _HoverMenuItem.unsend, child: Text('Unsend')),
                  if (hasAttachment)
                    const PopupMenuItem(value: _HoverMenuItem.download, child: Text('Download')),
                  if (kIsWeb && hasWebUrl)
                    const PopupMenuItem(value: _HoverMenuItem.openInBrowser, child: Text('Open in browser')),
                  if (!isTemp && (hasText || hasAttachment))
                    const PopupMenuItem(value: _HoverMenuItem.forward, child: Text('Forward')),
                  const PopupMenuItem(value: _HoverMenuItem.select, child: Text('Select')),
                  const PopupMenuItem(value: _HoverMenuItem.info, child: Text('Info')),
                  const PopupMenuItem(value: _HoverMenuItem.delete, child: Text('Delete')),
                ],
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: Icon(Icons.more_vert, size: 17, color: iconColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HoverablePartRow extends StatefulWidget {
  const HoverablePartRow({
    super.key,
    required this.enabled,
    required this.showHoverBar,
    required this.isFromMe,
    required this.controller,
    required this.part,
    required this.cvController,
    required this.service,
    required this.isReplyThread,
    required this.bubbleChild,
    this.leadingChildren = const [],
    this.trailingChildren = const [],
  });

  final bool enabled;
  final bool showHoverBar;
  final bool isFromMe;
  final MessageState controller;
  final MessagePart part;
  final ConversationViewController cvController;
  final MessagesService service;
  final bool isReplyThread;
  final Widget bubbleChild;
  final List<Widget> leadingChildren;
  final List<Widget> trailingChildren;

  @override
  State<HoverablePartRow> createState() => _HoverablePartRowState();
}

class _HoverablePartRowState extends State<HoverablePartRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final boundedBubble = ReplyBubbleBounds(child: widget.bubbleChild);
    if (!widget.enabled) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...widget.leadingChildren,
          Flexible(child: boundedBubble),
          ...widget.trailingChildren,
        ].conditionalReverse(widget.isFromMe),
      );
    }

    final tooltipMsg = formatHoverTimestampTooltip(
      widget.controller.dateCreated.value,
      use24Hr: SettingsSvc.settings.use24HrFormat.value,
    );

    final bubbleWithTooltip = tooltipMsg.isEmpty
        ? boundedBubble
        : Tooltip(
            message: tooltipMsg,
            waitDuration: const Duration(milliseconds: 450),
            child: boundedBubble,
          );

    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...widget.leadingChildren,
          // Place before bubble so conditionalReverse puts hover bar on the inner/open side
          // (left of sent bubbles, right of received bubbles) instead of pushing edges inward.
          if (!kIsWeb && widget.showHoverBar)
            MessageHoverBar(
              controller: widget.controller,
              part: widget.part,
              cvController: widget.cvController,
              service: widget.service,
              hovered: _hovered,
              isReplyThread: widget.isReplyThread,
            ),
          Flexible(child: bubbleWithTooltip),
          ...widget.trailingChildren,
        ].conditionalReverse(widget.isFromMe),
      ),
    );
  }
}
