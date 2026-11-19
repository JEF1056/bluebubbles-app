import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_line_painter.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Extracted widget for reply bubble section
/// Displays the message being replied to, with appropriate styling based on platform
class ReplyBubbleSection extends StatelessWidget {
  const ReplyBubbleSection({
    super.key,
    required this.replyTo,
    required this.cvController,
    required this.showAvatar,
    required this.alwaysShowAvatars,
    required this.avatarScale,
    required this.isIOS,
    required this.isFirstPart,
  });

  final Message replyTo;
  final ConversationViewController cvController;
  final bool showAvatar;
  final bool alwaysShowAvatars;
  final double avatarScale;
  final bool isIOS;
  final bool isFirstPart;

  @override
  Widget build(BuildContext context) {
    final chat = ChatStateScope.chatOf(context);
    final message = MessageStateScope.messageOf(context);
    final service = MessagesSvc(cvController.chat.guid);
    final rootTarget = resolveRootReplyTarget(message, message.normalizedThreadPart, service: service);
    final part = replyTo.guid == rootTarget.guid ? rootTarget.part : 0;
    final isSamsung = SettingsSvc.settings.skin.value == Skins.Samsung;
    final showReplyAvatar = (chat.isGroup || alwaysShowAvatars || isSamsung) && !replyTo.isFromMe!;

    // Provide the replyTo message's state so ReplyBubble displays the original
    // message content rather than the current (reply) message's content.
    final replyToState = service.getOrCreateState(replyTo);

    Widget replyBubble = MessageStateScope(
      messageState: replyToState,
      child: ReplyBubble(
        part: part,
        showAvatar: showReplyAvatar,
        cvController: cvController,
      ),
    );

    if (isIOS) {
      // iOS style - integrated with message bubble
      // Note: Padding is handled by the parent MessageHolder, not here
      return DecoratedBox(
        decoration: ReplyLineDecoration(
          isFromMe: message.isFromMe!,
          color: context.theme.colorScheme.surfaceContainerHighest,
          connectUpper: false,
          connectLower: false,
          context: context,
        ),
        child: Container(
          width: double.infinity,
          alignment: replyTo.isFromMe! ? Alignment.centerRight : Alignment.centerLeft,
          child: replyBubble,
        ),
      );
    } else {
      // Android/Material style - compact iOS-inspired quoted mini-bubble aligned to originator side
      // with a subtle curved upper hook down into the reply bubble.
      final hasBackground = ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false;
      final quotedFromMe = replyTo.isFromMe ?? false;
      final replyFromMe = message.isFromMe ?? false;
      final hookColor = hasBackground
          ? Colors.white.withValues(alpha: 0.42)
          : context.theme.colorScheme.outlineVariant;
      final bubbleColor = quotedFromMe
          ? context.theme.colorScheme.primaryContainer.withValues(alpha: hasBackground ? 0.78 : 0.92)
          : context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: hasBackground ? 0.78 : 0.92);
      final leftPad = !replyFromMe && (showAvatar || alwaysShowAvatars) ? 35.0 * avatarScale : 0.0;
      return Padding(
        padding: EdgeInsets.only(left: leftPad, bottom: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: quotedFromMe ? Alignment.centerRight : Alignment.centerLeft,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: bubbleColor,
                    border: Border.fromBorderSide(
                      BorderSide(
                        color: hasBackground
                            ? Colors.white.withValues(alpha: 0.18)
                            : context.theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  child: replyBubble,
                ),
              ),
            ),
            SizedBox(
              height: 18,
              width: double.infinity,
              child: CustomPaint(
                painter: _ReplyQuoteHookPainter(
                  replyFromMe: replyFromMe,
                  color: hookColor,
                ),
              ),
            ),
          ],
        ),
      );
    }
  }
}

class _ReplyQuoteHookPainter extends CustomPainter {
  final bool replyFromMe;
  final Color color;

  const _ReplyQuoteHookPainter({required this.replyFromMe, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    final path = Path();
    const double edgeInset = 18.0;
    const double hookLen = 28.0;
    const double r = 12.0;
    if (replyFromMe) {
      final x = size.width - edgeInset;
      path.moveTo(x - hookLen, 4);
      path.lineTo(x - r, 4);
      path.arcToPoint(Offset(x, 4 + r), clockwise: true, radius: const Radius.circular(r));
      path.lineTo(x, size.height);
    } else {
      const x = edgeInset;
      path.moveTo(x + hookLen, 4);
      path.lineTo(x + r, 4);
      path.arcToPoint(const Offset(x, 4 + r), clockwise: false, radius: const Radius.circular(r));
      path.lineTo(x, size.height);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ReplyQuoteHookPainter oldDelegate) =>
      oldDelegate.replyFromMe != replyFromMe || oldDelegate.color != color;
}
