import 'dart:math';

import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Paints [ReplyLinePainter] behind an [Align] child using the child's actual
/// rendered bubble width so the horizontal connector reaches the bubble edge.
class ReplyLineBox extends SingleChildRenderObjectWidget {
  final bool enabled;
  final bool isFromMe;
  final bool connectUpper;
  final bool connectLower;
  final Color color;
  final bool compactHook;

  const ReplyLineBox({
    super.key,
    required this.enabled,
    required this.isFromMe,
    required this.connectUpper,
    required this.connectLower,
    required this.color,
    this.compactHook = false,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) => RenderReplyLineBox(
        enabled: enabled,
        isFromMe: isFromMe,
        connectUpper: connectUpper,
        connectLower: connectLower,
        color: color,
        compactHook: compactHook,
      );

  @override
  void updateRenderObject(BuildContext context, RenderReplyLineBox renderObject) {
    renderObject
      ..enabled = enabled
      ..isFromMe = isFromMe
      ..connectUpper = connectUpper
      ..connectLower = connectLower
      ..color = color
      ..compactHook = compactHook;
  }
}

class RenderReplyLineBox extends RenderProxyBox {
  bool _enabled;
  bool _isFromMe;
  bool _connectUpper;
  bool _connectLower;
  Color _color;
  bool _compactHook;

  RenderReplyLineBox({
    required bool enabled,
    required bool isFromMe,
    required bool connectUpper,
    required bool connectLower,
    required Color color,
    required bool compactHook,
  })  : _enabled = enabled,
        _isFromMe = isFromMe,
        _connectUpper = connectUpper,
        _connectLower = connectLower,
        _color = color,
        _compactHook = compactHook;

  set enabled(bool v) {
    if (_enabled != v) {
      _enabled = v;
      markNeedsPaint();
    }
  }

  set isFromMe(bool v) {
    if (_isFromMe != v) {
      _isFromMe = v;
      markNeedsPaint();
    }
  }

  set connectUpper(bool v) {
    if (_connectUpper != v) {
      _connectUpper = v;
      markNeedsPaint();
    }
  }

  set connectLower(bool v) {
    if (_connectLower != v) {
      _connectLower = v;
      markNeedsPaint();
    }
  }

  set color(Color v) {
    if (_color != v) {
      _color = v;
      markNeedsPaint();
    }
  }

  set compactHook(bool v) {
    if (_compactHook != v) {
      _compactHook = v;
      markNeedsPaint();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_enabled && (_connectUpper || _connectLower) && size.width > 0 && size.height > 0) {
      double? bubbleWidth;
      if (child is RenderPositionedBox) {
        bubbleWidth = (child as RenderPositionedBox).child?.size.width;
      }
      ReplyLinePainter.paintConnector(
        canvas: context.canvas,
        offset: offset,
        size: size,
        isFromMe: _isFromMe,
        connectUpper: _connectUpper,
        connectLower: _connectLower,
        color: _color,
        bubbleWidth: bubbleWidth,
        compactHook: _compactHook,
      );
    }
    super.paint(context, offset);
  }
}

class ReplyLineDecoration extends Decoration {
  final bool isFromMe;
  final bool connectUpper;
  final bool connectLower;
  final Color color;
  final BuildContext context;

  const ReplyLineDecoration({
    required this.isFromMe,
    required this.connectUpper,
    required this.connectLower,
    required this.color,
    required this.context,
  });

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    return ReplyLinePainter(
      isFromMe: isFromMe,
      connectUpper: connectUpper,
      connectLower: connectLower,
      color: color,
      context: context,
    );
  }
}

class ReplyLinePainter extends BoxPainter {
  // Outgoing corner tuning by visual result in UI (not by method name).
  // Empirical mapping:
  // - `_addTopConnector` controls the corner that appears visually on top.
  // - `_addBottomConnector` controls the corner that appears visually on bottom.
  static const double _outgoingVisualTopRadiusFactor = 1.0;
  static const double _outgoingVisualBottomRadiusFactor = 1.4;
  static const double _incomingVisualTopRadiusFactor = 0.9;
  static const double _incomingVisualBottomRadiusFactor = 1.2;

  final bool isFromMe;
  final bool connectUpper;
  final bool connectLower;
  final Color color;
  final BuildContext context;

  const ReplyLinePainter({
    required this.isFromMe,
    required this.connectUpper,
    required this.connectLower,
    required this.color,
    required this.context,
  });

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    paintConnector(
      canvas: canvas,
      offset: offset,
      size: configuration.size!,
      isFromMe: isFromMe,
      connectUpper: connectUpper,
      connectLower: connectLower,
      color: color,
      fallbackMaxWidth: NavigationSvc.width(context) * MessageState.maxBubbleSizeFactor,
    );
  }

  static void paintConnector({
    required Canvas canvas,
    required Offset offset,
    required Size size,
    required bool isFromMe,
    required bool connectUpper,
    required bool connectLower,
    required Color color,
    double? bubbleWidth,
    double? fallbackMaxWidth,
    bool compactHook = false,
  }) {
    if (compactHook) {
      // Short iOS-style L-hook on the opposite-sender margin (never stretches across the wallpaper).
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      const double edgeInset = 18.0;
      const double hookLen = 28.0;
      final double r = min(14.0, size.height / 2);
      final double midY = offset.dy + size.height / 2;
      final double verticalX = isFromMe ? offset.dx + edgeInset : offset.dx + size.width - edgeInset;
      if (connectUpper) {
        path.moveTo(verticalX, offset.dy - 4.0);
        path.lineTo(verticalX, midY - r);
        if (isFromMe) {
          path.arcToPoint(Offset(verticalX + r, midY), clockwise: false, radius: Radius.circular(r));
          path.lineTo(verticalX + hookLen, midY);
        } else {
          path.arcToPoint(Offset(verticalX - r, midY), clockwise: true, radius: Radius.circular(r));
          path.lineTo(verticalX - hookLen, midY);
        }
      }
      canvas.drawPath(path, paint);
      return;
    }

    final localOffset = offset + Offset(isFromMe ? 35 : 0, 0);
    final midY = localOffset.dy + size.height / 2;
    final radius = min(size.height / 2, 22.0);
    final verticalX = isFromMe ? localOffset.dx : localOffset.dx + size.width - 35;

    // Aim horizontal tip cleanly 8dp from the actual bubble edge when known.
    final double horizontalTarget;
    if (bubbleWidth != null) {
      horizontalTarget = isFromMe
          ? offset.dx + size.width - bubbleWidth - 8
          : offset.dx + bubbleWidth + 8;
    } else {
      final maxW = fallbackMaxWidth ?? (size.width * MessageState.maxBubbleSizeFactor);
      horizontalTarget = isFromMe
          ? localOffset.dx + size.width - maxW - 30
          : localOffset.dx + maxW - 35;
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();

    // Bridge the small vertical gap between stacked reply rows.
    const double verticalOverlap = 6.0;

    if (connectUpper) {
      final effectiveRadius =
          isFromMe ? radius * _outgoingVisualBottomRadiusFactor : radius * _incomingVisualBottomRadiusFactor;
      final clampedRadius = min(effectiveRadius, size.height / 2);
      final verticalEndY = midY - clampedRadius;

      path.moveTo(verticalX, localOffset.dy - verticalOverlap);
      path.lineTo(verticalX, verticalEndY);
      if (isFromMe) {
        final turnEndX = verticalX + clampedRadius;
        path.arcToPoint(Offset(turnEndX, midY), clockwise: false, radius: Radius.circular(clampedRadius));
        if (horizontalTarget > turnEndX) {
          path.lineTo(horizontalTarget, midY);
        }
      } else {
        final turnEndX = verticalX - clampedRadius;
        path.arcToPoint(Offset(turnEndX, midY), clockwise: true, radius: Radius.circular(clampedRadius));
        if (horizontalTarget < turnEndX) {
          path.lineTo(horizontalTarget, midY);
        }
      }
    }

    if (connectLower) {
      final effectiveRadius =
          isFromMe ? radius * _outgoingVisualTopRadiusFactor : radius * _incomingVisualTopRadiusFactor;
      final clampedRadius = min(effectiveRadius, size.height / 2);
      final verticalEndY = midY + clampedRadius;

      path.moveTo(verticalX, localOffset.dy + size.height + verticalOverlap);
      path.lineTo(verticalX, verticalEndY);
      if (isFromMe) {
        final turnEndX = verticalX + clampedRadius;
        path.arcToPoint(Offset(turnEndX, midY), clockwise: true, radius: Radius.circular(clampedRadius));
        if (horizontalTarget > turnEndX) {
          path.lineTo(horizontalTarget, midY);
        }
      } else {
        final turnEndX = verticalX - clampedRadius;
        path.arcToPoint(Offset(turnEndX, midY), clockwise: false, radius: Radius.circular(clampedRadius));
        if (horizontalTarget < turnEndX) {
          path.lineTo(horizontalTarget, midY);
        }
      }
    }

    canvas.drawPath(path, paint);
  }
}
