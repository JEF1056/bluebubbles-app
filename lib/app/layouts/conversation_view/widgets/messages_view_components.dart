import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/typing/typing_indicator.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

// Helper to check if iOS skin is active
bool get iOS => SettingsSvc.settings.skin.value == Skins.iOS;

/// Extracted widget for typing indicator row with avatar
class TypingIndicatorRow extends StatelessWidget {
  const TypingIndicatorRow({
    super.key,
    required this.controller,
  });

  final ConversationViewController controller;

  @override
  Widget build(BuildContext context) {
    final chat = ChatStateScope.chatOf(context);
    return Obx(() => Row(
          key: controller.typingInfoKey,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (controller.showTypingIndicator.value && SettingsSvc.settings.alwaysShowAvatars.value && iOS)
              Padding(
                padding: const EdgeInsets.only(left: 10.0),
                child: ContactAvatarWidget(
                  key: Key("${chat.handles.first.address}-typing-indicator"),
                  handle: chat.handles.first,
                  size: 30,
                  fontSize: 14,
                  borderThickness: 0.1,
                ),
              ),
            TypingIndicator(
              controller: controller,
            )
          ],
        ));
  }
}

/// Extracted widget for notifications silenced banner
class NotificationsSilencedBanner extends StatelessWidget {
  const NotificationsSilencedBanner({
    super.key,
    required this.controller,
    required this.latestMessage,
  });

  final ConversationViewController controller;
  final Message? latestMessage;

  @override
  Widget build(BuildContext context) {
    final chat = ChatStateScope.chatOf(context);
    const moonIcon = CupertinoIcons.moon_fill;

    return AnimatedSize(
      key: controller.focusInfoKey,
      duration: const Duration(milliseconds: 250),
      child: Obx(() => controller.recipientNotifsSilenced.value
          ? Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        String.fromCharCode(moonIcon.codePoint),
                        style: TextStyle(
                          fontFamily: moonIcon.fontFamily,
                          package: moonIcon.fontPackage,
                          fontSize: context.theme.textTheme.bodyMedium!.fontSize,
                          color: context.theme.colorScheme.tertiary,
                        ),
                      ),
                      Text(
                        " ${chat.getTitle()} has notifications silenced",
                        style: context.theme.textTheme.bodyMedium!
                            .copyWith(color: context.theme.colorScheme.tertiary),
                      ),
                    ],
                  ),
                  _NotifyAnywayButton(latestMessage: latestMessage),
                ],
              ),
            )
          : const SizedBox.shrink()),
    );
  }
}

/// Nested widget for "Notify Anyway" button to further isolate rebuilds
class _NotifyAnywayButton extends StatelessWidget {
  const _NotifyAnywayButton({required this.latestMessage});

  final Message? latestMessage;

  @override
  Widget build(BuildContext context) {
    // Check conditions for showing the button
    if (latestMessage?.isFromMe == true &&
        latestMessage?.dateRead == null &&
        latestMessage?.wasDeliveredQuietly == true &&
        latestMessage?.didNotifyRecipient == false) {
      return TextButton(
        child: Text(
          "Notify Anyway",
          style: context.theme.textTheme.labelLarge!.copyWith(color: context.theme.colorScheme.tertiary),
        ),
        onPressed: () async {
          await HttpSvc.message.notify(latestMessage!.guid!);
        },
      );
    }
    return const SizedBox.shrink();
  }
}

/// The row of pills above the text field. It shows two independent kinds:
/// [smartReplies], ML suggestions that only exist when smart replies are enabled
/// and are cleared on send, and [quickActions], the app's own shortcuts ("Attach
/// recent photo", "Jump to oldest unread"), which show regardless of that setting
/// and survive a send.
class ConversationPillsRow extends StatelessWidget {
  const ConversationPillsRow({
    super.key,
    required this.controller,
    required this.smartReplies,
    required this.quickActions,
  });

  final ConversationViewController controller;
  final RxList<String> smartReplies;
  final RxMap<String, Widget> quickActions;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final bool visible = smartReplies.isNotEmpty || quickActions.isNotEmpty;
      final double rowHeight = context.theme.extension<BubbleText>()!.bubbleText.fontSize! + 35;
      final double topPadding = iOS ? 8.0 : 0.0;
      final double totalHeight = visible ? rowHeight + topPadding : 0.0;

      controller.updatePillRowLayout(
        visible: visible,
        height: totalHeight,
        hasQuickActions: quickActions.isNotEmpty,
      );

      return AnimatedSize(
        duration: const Duration(milliseconds: 400),
        child: visible
            ? Padding(
                padding: EdgeInsets.only(top: topPadding, right: 5),
                child: SizedBox(
                  height: rowHeight,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    children: smartReplies.map((suggestion) => _buildSmartReply(context, suggestion)).toList()
                      ..addAll(quickActions.values),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      );
    });
  }

  Widget _buildSmartReply(BuildContext context, String suggestion) {
    final hasBackground = ChatsSvc.getChatState(controller.chat.guid)?.hasCustomWallpaper ?? false;
    return Container(
      margin: const EdgeInsets.all(5),
      decoration: hasBackground
          ? BoxDecoration(
              color: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.86),
              borderRadius: BorderRadius.circular(19),
            )
          : BoxDecoration(
              border: Border.all(
                width: 2,
                style: BorderStyle.solid,
                color: context.theme.colorScheme.surfaceContainerHighest,
              ),
              borderRadius: BorderRadius.circular(19),
            ),
      child: InkWell(
        borderRadius: BorderRadius.circular(19),
        onTap: () {
          OutgoingMsgHandler.queue(OutgoingMessage(
            chat: controller.chat,
            message: Message(
              text: suggestion,
              dateCreated: DateTime.now(),
              hasAttachments: false,
              isFromMe: true,
              handleId: 0,
            ),
          ));
        },
        child: Center(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 1.5, left: 13.0, right: 13.0),
            child: RichText(
              text: TextSpan(
                children: MessageHelper.buildEmojiText(
                  suggestion,
                  context.theme.extension<BubbleText>()!.bubbleText,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Extracted widget for scroll down button & GMsg "New messages" pill
class ScrollDownButton extends StatefulWidget {
  const ScrollDownButton({
    super.key,
    required this.controller,
    this.unreadWhileScrolledCount,
  });

  final ConversationViewController controller;
  final ValueNotifier<int>? unreadWhileScrolledCount;

  @override
  State<ScrollDownButton> createState() => _ScrollDownButtonState();
}

class _ScrollDownButtonState extends State<ScrollDownButton> {
  bool _scrolledUp = false;

  @override
  void initState() {
    super.initState();
    widget.controller.scrollController.addListener(_onScroll);
    widget.unreadWhileScrolledCount?.addListener(_onUnreadChanged);
  }

  @override
  void didUpdateWidget(covariant ScrollDownButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.scrollController != widget.controller.scrollController) {
      oldWidget.controller.scrollController.removeListener(_onScroll);
      widget.controller.scrollController.addListener(_onScroll);
    }
    if (oldWidget.unreadWhileScrolledCount != widget.unreadWhileScrolledCount) {
      oldWidget.unreadWhileScrolledCount?.removeListener(_onUnreadChanged);
      widget.unreadWhileScrolledCount?.addListener(_onUnreadChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.scrollController.removeListener(_onScroll);
    widget.unreadWhileScrolledCount?.removeListener(_onUnreadChanged);
    super.dispose();
  }

  void _onUnreadChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    final sc = widget.controller.scrollController;
    if (!sc.hasClients || sc.positions.length != 1) return;
    final offset = sc.offset;
    if (offset < 120 && (widget.unreadWhileScrolledCount?.value ?? 0) > 0) {
      widget.unreadWhileScrolledCount!.value = 0;
    }
    final up = offset >= 250;
    if (up != _scrolledUp && mounted) {
      setState(() => _scrolledUp = up);
    }
  }

  void _jumpToBottom() {
    widget.unreadWhileScrolledCount?.value = 0;
    widget.controller.scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: iOS ? Alignment.bottomRight : Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10, right: 10, left: 10),
        child: Obx(() {
          final unreadCount = widget.unreadWhileScrolledCount?.value ?? 0;
          final showScrollDown = widget.controller.showScrollDown.value;
          final showDesktopOrWeb = (kIsWeb || kIsDesktop) && (_scrolledUp || unreadCount > 0);
          final visible = showDesktopOrWeb || showScrollDown || unreadCount > 0;
          final cs = context.theme.colorScheme;

          Widget button;
          if (unreadCount > 0) {
            button = Material(
              color: cs.inverseSurface,
              elevation: 4,
              borderRadius: BorderRadius.circular(9999),
              child: InkWell(
                borderRadius: BorderRadius.circular(9999),
                onTap: _jumpToBottom,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 36),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.arrow_downward_rounded, size: 16, color: cs.onInverseSurface),
                        const SizedBox(width: 6),
                        Text(
                          unreadCount == 1 ? "New messages" : "$unreadCount new messages",
                          style: context.textTheme.labelMedium?.copyWith(
                            color: cs.onInverseSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          } else if (iOS) {
            button = TextButton(
              style: TextButton.styleFrom(
                backgroundColor: cs.secondary,
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
                maximumSize: const Size(32, 32),
                minimumSize: const Size(32, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _jumpToBottom,
              child: Container(
                constraints: const BoxConstraints(minHeight: 32, minWidth: 32),
                decoration: const BoxDecoration(shape: BoxShape.circle),
                padding: const EdgeInsets.only(top: 3, left: 1),
                alignment: Alignment.center,
                child: Icon(
                  CupertinoIcons.chevron_down,
                  color: cs.onSecondary,
                  size: 20,
                ),
              ),
            );
          } else {
            final bg = (kIsWeb || kIsDesktop) ? cs.surfaceContainerHigh : cs.secondary;
            final fg = (kIsWeb || kIsDesktop) ? cs.onSurface : cs.onSecondary;
            button = Material(
              color: bg,
              elevation: 3,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _jumpToBottom,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(Icons.arrow_downward_rounded, color: fg, size: 22),
                ),
              ),
            );
          }

          return IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: AnimatedScale(
                scale: visible ? 1.0 : 0.85,
                duration: const Duration(milliseconds: 150),
                child: button,
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Extracted widget for drag and drop overlay
class DragDropOverlay extends StatelessWidget {
  const DragDropOverlay({
    super.key,
    required this.dragging,
  });

  final RxBool dragging;

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    return Obx(
      () => IgnorePointer(
        ignoring: !dragging.value,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          color: cs.surface.withValues(alpha: dragging.value ? 0.72 : 0),
          child: dragging.value
              ? Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: cs.primary, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          iOS ? CupertinoIcons.paperclip : Icons.upload_file_rounded,
                          color: cs.primary,
                          size: 44,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          "Drop files to attach",
                          style: context.theme.textTheme.titleLarge?.copyWith(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
