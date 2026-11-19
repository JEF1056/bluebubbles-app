import 'dart:math';

import 'package:bluebubbles/app/state/message_state.dart';
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
      final bubbleAlpha = hasBackground ? 0.58 : 0.72;
      final bubbleColor = quotedFromMe
          ? context.theme.colorScheme.primaryContainer.withValues(alpha: bubbleAlpha)
          : context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: bubbleAlpha);
      final leftPad = !replyFromMe && (showAvatar || alwaysShowAvatars) ? 35.0 * avatarScale : 0.0;
      const double bottomGap = 8.0;
      final maxBubbleWidth = NavigationSvc.width(context) * MessageState.maxBubbleSizeFactor - 30;
      void openReplyThread() {
        if (cvController.inSelectMode.value) return;
        showReplyThread(
          context,
          replyTo,
          replyToState.partById(part) ?? MessagePart(part: part),
          service,
          cvController,
        );
      }

      return Padding(
        padding: EdgeInsets.only(left: leftPad, bottom: 2),
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: ReplyLineHitRegion(
                containsPoint: (pos, size) => ReplyQuoteHookPainter.hitTestHook(
                  pos,
                  size,
                  quotedFromMe: quotedFromMe,
                  replyFromMe: replyFromMe,
                  quotedBubbleWidth: maxBubbleWidth,
                  bottomGap: bottomGap,
                ),
                onTap: openReplyThread,
              ),
            ),
            CustomPaint(
              painter: ReplyQuoteHookPainter(
                quotedFromMe: quotedFromMe,
                replyFromMe: replyFromMe,
                color: hookColor,
                maxBubbleWidth: maxBubbleWidth,
                bottomGap: bottomGap,
              ),
              child: Padding(
                padding: const EdgeInsets.only(bottom: bottomGap),
                child: Align(
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
              ),
            ),
          ],
        ),
      );
    }
  }
}

class ReplyQuoteHookPainter extends CustomPainter {
  final bool quotedFromMe;
  final bool replyFromMe;
  final Color color;
  final double? maxBubbleWidth;
  final double bottomGap;

  const ReplyQuoteHookPainter({
    required this.quotedFromMe,
    required this.replyFromMe,
    required this.color,
    this.maxBubbleWidth,
    this.bottomGap = 8.0,
  });

  static bool hitTestHook(
    Offset position,
    Size size, {
    required bool quotedFromMe,
    required bool replyFromMe,
    double? quotedBubbleWidth,
    double? quotedBubbleHeight,
    double bottomGap = 8.0,
  }) {
    final bounds = buildHookPath(
      size,
      quotedFromMe: quotedFromMe,
      replyFromMe: replyFromMe,
      quotedBubbleWidth: quotedBubbleWidth,
      quotedBubbleHeight: quotedBubbleHeight,
      bottomGap: bottomGap,
    ).getBounds();
    if (bounds.width == 0 && bounds.height == 0) return false;
    return bounds.inflate(ReplyLinePainter.connectorHitPadding).contains(position);
  }

  // Vertical stem sits on the reply side (replyFromMe); cross-side hooks rise to
  // the quoted bubble's vertical center and curve toward it without overlapping.
  static Path buildHookPath(
    Size size, {
    required bool quotedFromMe,
    required bool replyFromMe,
    double? quotedBubbleWidth,
    double? quotedBubbleHeight,
    double bottomGap = 8.0,
  }) {
    final path = Path();
    const double edgeInset = 18.0;
    const double hookLen = 28.0;
    const double maxRadius = 12.0;
    const double bubbleClearance = 6.0;
    final double x = replyFromMe ? size.width - edgeInset : edgeInset;
    final double bubbleH = (quotedBubbleHeight ?? (size.height - bottomGap)).clamp(0.0, size.height);

    if (quotedFromMe == replyFromMe) {
      path.moveTo(x, bubbleH);
      path.lineTo(x, size.height);
      return path;
    }

    final double midY = bubbleH / 2.0;
    final double r = min(maxRadius, max(0.0, size.height - midY));

    if (!replyFromMe) {
      // Left-side row replying to right-side quoted bubble: stem on left, curve right.
      final double desiredEndX = x + hookLen;
      final double maxEndX =
          quotedBubbleWidth != null ? size.width - quotedBubbleWidth - bubbleClearance : size.width - edgeInset;
      final double endX = min(desiredEndX, max(x, maxEndX));
      final double effectiveR = min(r, max(0.0, endX - x));

      path.moveTo(x, size.height);
      path.lineTo(x, midY + effectiveR);
      if (effectiveR > 0) {
        path.arcToPoint(Offset(x + effectiveR, midY), clockwise: true, radius: Radius.circular(effectiveR));
      }
      if (endX > x + effectiveR) {
        path.lineTo(endX, midY);
      }
    } else {
      // Right-side (isFromMe) row replying to left-side quoted bubble: stem on right, curve left.
      final double desiredEndX = x - hookLen;
      final double minEndX = quotedBubbleWidth != null ? quotedBubbleWidth + bubbleClearance : edgeInset;
      final double endX = max(desiredEndX, min(x, minEndX));
      final double effectiveR = min(r, max(0.0, x - endX));

      path.moveTo(x, size.height);
      path.lineTo(x, midY + effectiveR);
      if (effectiveR > 0) {
        path.arcToPoint(Offset(x - effectiveR, midY), clockwise: false, radius: Radius.circular(effectiveR));
      }
      if (endX < x - effectiveR) {
        path.lineTo(endX, midY);
      }
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      buildHookPath(
        size,
        quotedFromMe: quotedFromMe,
        replyFromMe: replyFromMe,
        quotedBubbleWidth: maxBubbleWidth,
        bottomGap: bottomGap,
      ),
      paint,
    );
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(covariant ReplyQuoteHookPainter oldDelegate) =>
      oldDelegate.quotedFromMe != quotedFromMe ||
      oldDelegate.replyFromMe != replyFromMe ||
      oldDelegate.color != color ||
      oldDelegate.maxBubbleWidth != maxBubbleWidth ||
      oldDelegate.bottomGap != bottomGap;
}
