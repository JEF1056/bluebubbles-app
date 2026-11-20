import 'dart:math';

import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_line_painter.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
      final leftPad = (showAvatar || alwaysShowAvatars)
          ? BubbleConnect.incomingAvatarIndent(isIOS: false, avatarScale: avatarScale)
          : 0.0;
      const double bottomGap = 8.0;
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

      const quoteRadius = BorderRadius.only(
        topLeft: Radius.circular(20),
        topRight: Radius.circular(20),
        bottomLeft: Radius.circular(4),
        bottomRight: Radius.circular(4),
      );

      return Padding(
        padding: EdgeInsets.only(left: leftPad, bottom: 2),
        child: _MaterialReplyQuoteHookSection(
          quotedFromMe: quotedFromMe,
          replyFromMe: replyFromMe,
          hookColor: hookColor,
          bottomGap: bottomGap,
          onTapHook: openReplyThread,
          child: Padding(
            padding: const EdgeInsets.only(bottom: bottomGap),
            child: Align(
              alignment: quotedFromMe ? Alignment.centerRight : Alignment.centerLeft,
              child: ReplyBubbleBounds(
                child: ClipRRect(
                  borderRadius: quoteRadius,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: quoteRadius,
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
        ),
      );
    }
  }
}

class _QuotedBubbleSizeSlot {
  Size? size;
}

class _MaterialReplyQuoteHookSection extends StatefulWidget {
  final bool quotedFromMe;
  final bool replyFromMe;
  final Color hookColor;
  final double bottomGap;
  final VoidCallback onTapHook;
  final Widget child;

  const _MaterialReplyQuoteHookSection({
    required this.quotedFromMe,
    required this.replyFromMe,
    required this.hookColor,
    required this.bottomGap,
    required this.onTapHook,
    required this.child,
  });

  @override
  State<_MaterialReplyQuoteHookSection> createState() => _MaterialReplyQuoteHookSectionState();
}

class _MaterialReplyQuoteHookSectionState extends State<_MaterialReplyQuoteHookSection> {
  final _QuotedBubbleSizeSlot _quotedSizeSlot = _QuotedBubbleSizeSlot();

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: ReplyLineHitRegion(
            containsPoint: (pos, size) => ReplyQuoteHookPainter.hitTestHook(
              pos,
              size,
              quotedFromMe: widget.quotedFromMe,
              replyFromMe: widget.replyFromMe,
              quotedBubbleWidth: _quotedSizeSlot.size?.width,
              quotedBubbleHeight: _quotedSizeSlot.size?.height,
              bottomGap: widget.bottomGap,
            ),
            onTap: widget.onTapHook,
          ),
        ),
        _ReplyQuoteHookBox(
          quotedFromMe: widget.quotedFromMe,
          replyFromMe: widget.replyFromMe,
          color: widget.hookColor,
          bottomGap: widget.bottomGap,
          quotedSizeSlot: _quotedSizeSlot,
          child: widget.child,
        ),
      ],
    );
  }
}

class _ReplyQuoteHookBox extends SingleChildRenderObjectWidget {
  final bool quotedFromMe;
  final bool replyFromMe;
  final Color color;
  final double bottomGap;
  final _QuotedBubbleSizeSlot quotedSizeSlot;

  const _ReplyQuoteHookBox({
    required this.quotedFromMe,
    required this.replyFromMe,
    required this.color,
    required this.bottomGap,
    required this.quotedSizeSlot,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderReplyQuoteHookBox(
        quotedFromMe: quotedFromMe,
        replyFromMe: replyFromMe,
        color: color,
        bottomGap: bottomGap,
        quotedSizeSlot: quotedSizeSlot,
      );

  @override
  void updateRenderObject(BuildContext context, _RenderReplyQuoteHookBox renderObject) {
    renderObject
      ..quotedFromMe = quotedFromMe
      ..replyFromMe = replyFromMe
      ..color = color
      ..bottomGap = bottomGap
      ..quotedSizeSlot = quotedSizeSlot;
  }
}

class _RenderReplyQuoteHookBox extends RenderProxyBox {
  bool _quotedFromMe;
  bool _replyFromMe;
  Color _color;
  double _bottomGap;
  _QuotedBubbleSizeSlot? _quotedSizeSlot;

  _RenderReplyQuoteHookBox({
    required bool quotedFromMe,
    required bool replyFromMe,
    required Color color,
    required double bottomGap,
    _QuotedBubbleSizeSlot? quotedSizeSlot,
  })  : _quotedFromMe = quotedFromMe,
        _replyFromMe = replyFromMe,
        _color = color,
        _bottomGap = bottomGap,
        _quotedSizeSlot = quotedSizeSlot;

  set quotedFromMe(bool v) {
    if (_quotedFromMe != v) {
      _quotedFromMe = v;
      markNeedsPaint();
    }
  }

  set replyFromMe(bool v) {
    if (_replyFromMe != v) {
      _replyFromMe = v;
      markNeedsPaint();
    }
  }

  set color(Color v) {
    if (_color != v) {
      _color = v;
      markNeedsPaint();
    }
  }

  set bottomGap(double v) {
    if (_bottomGap != v) {
      _bottomGap = v;
      markNeedsPaint();
    }
  }

  set quotedSizeSlot(_QuotedBubbleSizeSlot? v) {
    if (!identical(_quotedSizeSlot, v)) {
      _quotedSizeSlot = v;
      _quotedSizeSlot?.size = _measureQuotedBubbleSize();
    }
  }

  static RenderReplyBubbleBounds? _findBubbleBounds(RenderObject? root) {
    if (root == null) return null;
    if (root is RenderReplyBubbleBounds) return root;
    RenderReplyBubbleBounds? found;
    root.visitChildren((child) {
      found ??= _findBubbleBounds(child);
    });
    return found;
  }

  Size? _measureQuotedBubbleSize() {
    return _findBubbleBounds(child)?.measuredSize;
  }

  @override
  void performLayout() {
    super.performLayout();
    _quotedSizeSlot?.size = _measureQuotedBubbleSize();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final quotedSize = _measureQuotedBubbleSize();
    _quotedSizeSlot?.size = quotedSize;
    if (size.width > 0 && size.height > 0) {
      final paint = Paint()
        ..color = _color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: _quotedFromMe,
        replyFromMe: _replyFromMe,
        quotedBubbleWidth: quotedSize?.width,
        quotedBubbleHeight: quotedSize?.height,
        bottomGap: _bottomGap,
      );
      final canvas = context.canvas;
      canvas.save();
      canvas.translate(offset.dx, offset.dy);
      canvas.drawPath(path, paint);
      canvas.restore();
    }
    super.paint(context, offset);
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

  static ({double x, double bubbleH, double midY, double endX}) _computeGeometry(
    Size size, {
    required bool quotedFromMe,
    required bool replyFromMe,
    double? quotedBubbleWidth,
    double? quotedBubbleHeight,
    double bottomGap = 8.0,
  }) {
    const double edgeInset = 18.0;
    const double defaultHookLen = 28.0;
    const double bubbleClearance = 4.0;
    final double x = replyFromMe ? size.width - edgeInset : edgeInset;
    final double bubbleH = (quotedBubbleHeight ?? (size.height - bottomGap)).clamp(0.0, size.height);
    final double midY = bubbleH / 2.0;

    final double endX;
    if (quotedFromMe == replyFromMe) {
      endX = x;
    } else if (!replyFromMe) {
      final double target = quotedBubbleWidth != null
          ? size.width - quotedBubbleWidth - bubbleClearance
          : min(x + defaultHookLen, size.width - edgeInset);
      endX = max(x, target);
    } else {
      final double target = quotedBubbleWidth != null
          ? quotedBubbleWidth + bubbleClearance
          : max(x - defaultHookLen, edgeInset);
      endX = min(x, target);
    }
    return (x: x, bubbleH: bubbleH, midY: midY, endX: endX);
  }

  static bool hitTestHook(
    Offset position,
    Size size, {
    required bool quotedFromMe,
    required bool replyFromMe,
    double? quotedBubbleWidth,
    double? quotedBubbleHeight,
    double bottomGap = 8.0,
  }) {
    if (size.width <= 0 || size.height <= 0) return false;
    const double pad = ReplyLinePainter.connectorHitPadding;
    final g = _computeGeometry(
      size,
      quotedFromMe: quotedFromMe,
      replyFromMe: replyFromMe,
      quotedBubbleWidth: quotedBubbleWidth,
      quotedBubbleHeight: quotedBubbleHeight,
      bottomGap: bottomGap,
    );
    if (quotedFromMe == replyFromMe) {
      return Rect.fromLTRB(
        max(0.0, g.x - pad),
        max(0.0, g.bubbleH - pad),
        min(size.width, g.x + pad),
        size.height,
      ).contains(position);
    }
    final verticalRect = Rect.fromLTRB(
      max(0.0, g.x - pad),
      max(0.0, g.midY - pad),
      min(size.width, g.x + pad),
      size.height,
    );
    if (verticalRect.contains(position)) return true;
    final horizontalRect = Rect.fromLTRB(
      max(0.0, min(g.x, g.endX) - pad),
      max(0.0, g.midY - pad),
      min(size.width, max(g.x, g.endX) + pad),
      min(size.height, g.midY + pad),
    );
    return horizontalRect.contains(position);
  }

  // Vertical stem sits on the reply side (replyFromMe) and extends +4px past size.height
  // so there is zero gap to the reply bubble below; cross-side hooks rise to the quoted
  // bubble's vertical center and reach quotedBubbleEdge ± 4px without reversing past the arc.
  static Path buildHookPath(
    Size size, {
    required bool quotedFromMe,
    required bool replyFromMe,
    double? quotedBubbleWidth,
    double? quotedBubbleHeight,
    double bottomGap = 8.0,
  }) {
    final path = Path();
    const double maxRadius = 12.0;
    const double bottomOverhang = 4.0;
    final g = _computeGeometry(
      size,
      quotedFromMe: quotedFromMe,
      replyFromMe: replyFromMe,
      quotedBubbleWidth: quotedBubbleWidth,
      quotedBubbleHeight: quotedBubbleHeight,
      bottomGap: bottomGap,
    );
    final double stemBottom = size.height + bottomOverhang;

    if (quotedFromMe == replyFromMe) {
      path.moveTo(g.x, g.bubbleH);
      path.lineTo(g.x, stemBottom);
      return path;
    }

    final double r = min(maxRadius, max(0.0, size.height - g.midY));

    if (!replyFromMe) {
      final double effectiveR = min(r, max(0.0, g.endX - g.x));
      path.moveTo(g.x, stemBottom);
      path.lineTo(g.x, g.midY + effectiveR);
      if (effectiveR > 0) {
        path.arcToPoint(Offset(g.x + effectiveR, g.midY), clockwise: true, radius: Radius.circular(effectiveR));
      }
      if (g.endX > g.x + effectiveR) {
        path.lineTo(g.endX, g.midY);
      }
    } else {
      final double effectiveR = min(r, max(0.0, g.x - g.endX));
      path.moveTo(g.x, stemBottom);
      path.lineTo(g.x, g.midY + effectiveR);
      if (effectiveR > 0) {
        path.arcToPoint(Offset(g.x - effectiveR, g.midY), clockwise: false, radius: Radius.circular(effectiveR));
      }
      if (g.endX < g.x - effectiveR) {
        path.lineTo(g.endX, g.midY);
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
