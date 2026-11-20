import 'dart:async';
import 'dart:math';

import 'package:bluebubbles/app/state/message_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Keeps tap targets inside an ancestor [SelectionArea] clickable even when a
/// pointer click includes slight (>1px) mouse movement that would otherwise let
/// [SelectableRegion]'s [TapAndHorizontalDragGestureRecognizer] win the arena.
class SelectionSafeTap extends StatefulWidget {
  final VoidCallback? onTap;
  final HitTestBehavior behavior;
  final Widget? child;
  final Widget Function(BuildContext context, VoidCallback handleTap)? builder;

  const SelectionSafeTap({
    super.key,
    required this.onTap,
    this.behavior = HitTestBehavior.opaque,
    required Widget this.child,
  }) : builder = null;

  const SelectionSafeTap.builder({
    super.key,
    required this.onTap,
    required Widget Function(BuildContext context, VoidCallback handleTap) this.builder,
  })  : behavior = HitTestBehavior.opaque,
        child = null;

  @override
  State<SelectionSafeTap> createState() => _SelectionSafeTapState();
}

class _SelectionSafeTapState extends State<SelectionSafeTap> {
  static const double _maxFallbackSlop = 6.0;
  static const Duration _maxTapDuration = Duration(milliseconds: 450);

  int? _activePointer;
  Offset? _downPosition;
  Duration? _downTime;
  bool _handled = false;
  int _tapGeneration = 0;

  void _fireOnce() {
    if (_handled) return;
    _handled = true;
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.builder != null
        ? widget.builder!(context, _fireOnce)
        : GestureDetector(
            behavior: widget.behavior,
            onTap: _fireOnce,
            child: widget.child,
          );
    return SelectionContainer.disabled(
      child: Listener(
        behavior: widget.behavior,
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.mouse && event.buttons != kPrimaryButton) return;
          _activePointer = event.pointer;
          _downPosition = event.position;
          _downTime = event.timeStamp;
          _handled = false;
          _tapGeneration++;
        },
        onPointerUp: (event) {
          if (event.pointer != _activePointer || _handled || _downPosition == null || _downTime == null) {
            return;
          }
          final dist = (event.position - _downPosition!).distance;
          final elapsed = event.timeStamp - _downTime!;
          if (dist <= _maxFallbackSlop && elapsed <= _maxTapDuration) {
            final pointer = event.pointer;
            final gen = _tapGeneration;
            scheduleMicrotask(() {
              if (!mounted || _handled || gen != _tapGeneration || _activePointer != pointer) return;
              _fireOnce();
            });
          }
        },
        onPointerCancel: (event) {
          if (event.pointer == _activePointer) {
            _activePointer = null;
            _tapGeneration++;
          }
        },
        child: content,
      ),
    );
  }
}

/// Intercepts taps only where [containsPoint] matches the painted reply bar,
/// letting taps on empty row space pass through to parent handlers.
class ReplyLineHitRegion extends StatelessWidget {
  final bool Function(Offset position, Size size) containsPoint;
  final VoidCallback onTap;

  const ReplyLineHitRegion({
    super.key,
    required this.containsPoint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _ConnectorHitRegion(
      containsPoint: containsPoint,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SelectionSafeTap(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _ConnectorHitRegion extends SingleChildRenderObjectWidget {
  final bool Function(Offset position, Size size) containsPoint;

  const _ConnectorHitRegion({
    required this.containsPoint,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderConnectorHitRegion(containsPoint);

  @override
  void updateRenderObject(BuildContext context, _RenderConnectorHitRegion renderObject) {
    renderObject.containsPoint = containsPoint;
  }
}

class _RenderConnectorHitRegion extends RenderProxyBox {
  bool Function(Offset position, Size size) containsPoint;

  _RenderConnectorHitRegion(this.containsPoint);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position) || !containsPoint(position, size)) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}

/// Marks the actual bubble subtree inside [ReplyLineBox] so [RenderReplyLineBox]
/// measures only the bubble width, excluding sibling hover action bars.
class ReplyBubbleBounds extends SingleChildRenderObjectWidget {
  const ReplyBubbleBounds({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => RenderReplyBubbleBounds();
}

class RenderReplyBubbleBounds extends RenderProxyBox {
  Size? measuredSize;

  @override
  void performLayout() {
    super.performLayout();
    measuredSize = size;
  }
}

class _BubbleWidthSlot {
  double? width;
}

/// Paints [ReplyLinePainter] behind an [Align] child using the child's actual
/// rendered bubble width so the horizontal connector reaches the bubble edge.
class ReplyLineBox extends StatefulWidget {
  final bool enabled;
  final bool isFromMe;
  final bool connectUpper;
  final bool connectLower;
  final Color color;
  final bool compactHook;
  final double? fallbackMaxWidth;
  final VoidCallback? onTapLine;
  final Widget child;

  const ReplyLineBox({
    super.key,
    required this.enabled,
    required this.isFromMe,
    required this.connectUpper,
    required this.connectLower,
    required this.color,
    this.compactHook = false,
    this.fallbackMaxWidth,
    this.onTapLine,
    required this.child,
  });

  @override
  State<ReplyLineBox> createState() => _ReplyLineBoxState();
}

class _ReplyLineBoxState extends State<ReplyLineBox> {
  final _BubbleWidthSlot _bubbleWidthSlot = _BubbleWidthSlot();

  @override
  Widget build(BuildContext context) {
    final canTap = widget.enabled && (widget.connectUpper || widget.connectLower) && widget.onTapLine != null;
    // Keep the 2-slot Stack stable so toggling canTap never remounts child state (e.g. media players).
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        canTap
            ? Positioned.fill(
                child: ReplyLineHitRegion(
                  containsPoint: (pos, size) => ReplyLinePainter.hitTestConnector(
                    pos,
                    size,
                    isFromMe: widget.isFromMe,
                    connectUpper: widget.connectUpper,
                    connectLower: widget.connectLower,
                    compactHook: widget.compactHook,
                    bubbleWidth: _bubbleWidthSlot.width,
                    fallbackMaxWidth: widget.fallbackMaxWidth,
                  ),
                  onTap: widget.onTapLine!,
                ),
              )
            : const SizedBox.shrink(),
        _ReplyLinePaintBox(
          enabled: widget.enabled,
          isFromMe: widget.isFromMe,
          connectUpper: widget.connectUpper,
          connectLower: widget.connectLower,
          color: widget.color,
          compactHook: widget.compactHook,
          fallbackMaxWidth: widget.fallbackMaxWidth,
          bubbleWidthSlot: _bubbleWidthSlot,
          child: widget.child,
        ),
      ],
    );
  }
}

class _ReplyLinePaintBox extends SingleChildRenderObjectWidget {
  final bool enabled;
  final bool isFromMe;
  final bool connectUpper;
  final bool connectLower;
  final Color color;
  final bool compactHook;
  final double? fallbackMaxWidth;
  final _BubbleWidthSlot bubbleWidthSlot;

  const _ReplyLinePaintBox({
    required this.enabled,
    required this.isFromMe,
    required this.connectUpper,
    required this.connectLower,
    required this.color,
    required this.compactHook,
    this.fallbackMaxWidth,
    required this.bubbleWidthSlot,
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
        fallbackMaxWidth: fallbackMaxWidth,
        bubbleWidthSlot: bubbleWidthSlot,
      );

  @override
  void updateRenderObject(BuildContext context, RenderReplyLineBox renderObject) {
    renderObject
      ..enabled = enabled
      ..isFromMe = isFromMe
      ..connectUpper = connectUpper
      ..connectLower = connectLower
      ..color = color
      ..compactHook = compactHook
      ..fallbackMaxWidth = fallbackMaxWidth
      ..bubbleWidthSlot = bubbleWidthSlot;
  }
}

class RenderReplyLineBox extends RenderProxyBox {
  bool _enabled;
  bool _isFromMe;
  bool _connectUpper;
  bool _connectLower;
  Color _color;
  bool _compactHook;
  double? _fallbackMaxWidth;
  _BubbleWidthSlot? _bubbleWidthSlot;

  RenderReplyLineBox({
    required bool enabled,
    required bool isFromMe,
    required bool connectUpper,
    required bool connectLower,
    required Color color,
    required bool compactHook,
    double? fallbackMaxWidth,
    _BubbleWidthSlot? bubbleWidthSlot,
  })  : _enabled = enabled,
        _isFromMe = isFromMe,
        _connectUpper = connectUpper,
        _connectLower = connectLower,
        _color = color,
        _compactHook = compactHook,
        _fallbackMaxWidth = fallbackMaxWidth,
        _bubbleWidthSlot = bubbleWidthSlot;

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

  set fallbackMaxWidth(double? v) {
    if (_fallbackMaxWidth != v) {
      _fallbackMaxWidth = v;
      markNeedsPaint();
    }
  }

  set bubbleWidthSlot(_BubbleWidthSlot? v) {
    if (!identical(_bubbleWidthSlot, v)) {
      _bubbleWidthSlot = v;
      _bubbleWidthSlot?.width = _measureBubbleWidth();
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

  double? _measureBubbleWidth({bool allowGrandchildFallback = false}) {
    final bounds = _findBubbleBounds(child);
    if (bounds != null) {
      return bounds.measuredSize?.width;
    }
    if (allowGrandchildFallback && child is RenderPositionedBox) {
      final inner = (child as RenderPositionedBox).child;
      if (inner != null && inner.hasSize) {
        return inner.size.width;
      }
    }
    return null;
  }

  @override
  void performLayout() {
    super.performLayout();
    _bubbleWidthSlot?.width = _measureBubbleWidth();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final bubbleWidth = _measureBubbleWidth(allowGrandchildFallback: true);
    _bubbleWidthSlot?.width = bubbleWidth;
    if (_enabled && (_connectUpper || _connectLower) && size.width > 0 && size.height > 0) {
      ReplyLinePainter.paintConnector(
        canvas: context.canvas,
        offset: offset,
        size: size,
        isFromMe: _isFromMe,
        connectUpper: _connectUpper,
        connectLower: _connectLower,
        color: _color,
        bubbleWidth: bubbleWidth,
        fallbackMaxWidth: _fallbackMaxWidth,
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
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) => false;

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
      fallbackMaxWidth: MessageState.maxBubbleWidth(context),
    );
  }

  static const double connectorHitPadding = 20.0;

  static double compactHookTipX(
    Offset offset,
    Size size, {
    required bool isFromMe,
    double? bubbleWidth,
    double? fallbackMaxWidth,
  }) {
    const double edgeInset = 18.0;
    const double defaultHookLen = 28.0;
    final double r = min(14.0, size.height / 2);
    final double verticalX = isFromMe ? offset.dx + edgeInset : offset.dx + size.width - edgeInset;
    final double turnEndX = isFromMe ? verticalX + r : verticalX - r;
    final double rawTargetX;
    if (bubbleWidth != null) {
      rawTargetX = isFromMe ? offset.dx + size.width - bubbleWidth - 8.0 : offset.dx + bubbleWidth + 8.0;
    } else if (fallbackMaxWidth != null) {
      rawTargetX = isFromMe ? offset.dx + size.width - fallbackMaxWidth - 8.0 : offset.dx + fallbackMaxWidth + 8.0;
    } else {
      rawTargetX = isFromMe ? verticalX + defaultHookLen : verticalX - defaultHookLen;
    }
    return isFromMe ? max(turnEndX, rawTargetX) : min(turnEndX, rawTargetX);
  }

  static bool hitTestCompactHook(
    Offset position,
    Size size, {
    required bool isFromMe,
    required bool connectUpper,
    double? bubbleWidth,
    double? fallbackMaxWidth,
  }) {
    if (!connectUpper || size.width <= 0 || size.height <= 0) return false;
    const double pad = connectorHitPadding;
    const double edgeInset = 18.0;
    final double midY = size.height / 2;
    final double verticalX = isFromMe ? edgeInset : size.width - edgeInset;
    final double tipX = compactHookTipX(
      Offset.zero,
      size,
      isFromMe: isFromMe,
      bubbleWidth: bubbleWidth,
      fallbackMaxWidth: fallbackMaxWidth,
    );
    final verticalRect = Rect.fromLTRB(
      max(0.0, verticalX - pad),
      0.0,
      min(size.width, verticalX + pad),
      min(size.height, midY + pad),
    );
    if (verticalRect.contains(position)) return true;

    final horizontalRect = Rect.fromLTRB(
      max(0.0, min(verticalX, tipX) - pad),
      max(0.0, midY - pad),
      min(size.width, max(verticalX, tipX) + pad),
      min(size.height, midY + pad),
    );
    return horizontalRect.contains(position);
  }

  static bool hitTestConnector(
    Offset position,
    Size size, {
    required bool isFromMe,
    required bool connectUpper,
    required bool connectLower,
    required bool compactHook,
    double? bubbleWidth,
    double? fallbackMaxWidth,
  }) {
    if ((!connectUpper && !connectLower) || size.width <= 0 || size.height <= 0) {
      return false;
    }
    const double pad = connectorHitPadding;
    final double midY = size.height / 2;

    if (compactHook) {
      return hitTestCompactHook(
        position,
        size,
        isFromMe: isFromMe,
        connectUpper: connectUpper,
        bubbleWidth: bubbleWidth,
        fallbackMaxWidth: fallbackMaxWidth,
      );
    }

    final double verticalX = isFromMe ? 35.0 : size.width - 35.0;
    final double topY = connectUpper ? 0.0 : max(0.0, midY - pad);
    final double bottomY = connectLower ? size.height : min(size.height, midY + pad);
    if (Rect.fromLTRB(
      max(0.0, verticalX - pad),
      topY,
      min(size.width, verticalX + pad),
      bottomY,
    ).contains(position)) {
      return true;
    }

    // Horizontal arm reaches to the bubble edge at midY; the bubble sits in front in the Stack.
    return Rect.fromLTRB(
      isFromMe ? max(0.0, verticalX - pad) : 0.0,
      max(0.0, midY - pad),
      isFromMe ? size.width : min(size.width, verticalX + pad),
      min(size.height, midY + pad),
    ).contains(position);
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
      // Material L-hook on the opposite-sender margin reaching 8dp from the reply bubble edge.
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      const double edgeInset = 18.0;
      final double r = min(14.0, size.height / 2);
      final double midY = offset.dy + size.height / 2;
      final double verticalX = isFromMe ? offset.dx + edgeInset : offset.dx + size.width - edgeInset;
      final double tipX = compactHookTipX(
        offset,
        size,
        isFromMe: isFromMe,
        bubbleWidth: bubbleWidth,
        fallbackMaxWidth: fallbackMaxWidth,
      );
      if (connectUpper) {
        path.moveTo(verticalX, offset.dy - 4.0);
        path.lineTo(verticalX, midY - r);
        if (isFromMe) {
          final double turnEndX = verticalX + r;
          path.arcToPoint(Offset(turnEndX, midY), clockwise: false, radius: Radius.circular(r));
          if (tipX > turnEndX) {
            path.lineTo(tipX, midY);
          }
        } else {
          final double turnEndX = verticalX - r;
          path.arcToPoint(Offset(turnEndX, midY), clockwise: true, radius: Radius.circular(r));
          if (tipX < turnEndX) {
            path.lineTo(tipX, midY);
          }
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
