import 'dart:math';
import 'package:flutter/material.dart';

/// Controls which side the reaction bubble's "tail" arcs point toward.
enum ReactionTailDirection { left, right }

/// Outward vs inward tail (inward used on stack cards).
enum ReactionTailType { standard, inside }

class ReactionClipper extends CustomClipper<Path> {
  final ReactionTailDirection tailDirection;
  final ReactionTailType tailType;

  ReactionClipper({
    required this.tailDirection,
    this.tailType = ReactionTailType.standard,
  });

  @override
  Path getClip(Size size) {
    final square = size.width;
    final path = Path();
    if (tailDirection == ReactionTailDirection.right) {
      path.addArc(Rect.fromLTWH(0, 0, square * 0.8, square * 0.8), 0, 2 * pi);
      if (tailType == ReactionTailType.inside) {
        path.addArc(Rect.fromLTWH(0, square * 0.55, square * 0.3, square * 0.3), 0, 2 * pi);
        path.addArc(Rect.fromLTWH(square * 0.157, square * 0.879, square * 0.175, square * 0.175), 0, 2 * pi);
      } else {
        path.addArc(Rect.fromLTWH(square * 0.55, square * 0.55, square * 0.3, square * 0.3), 0, 2 * pi);
        path.addArc(Rect.fromLTWH(square * 0.825, square * 0.825, square * 0.175, square * 0.175), 0, 2 * pi);
      }
    } else if (tailDirection == ReactionTailDirection.left) {
      path.addArc(Rect.fromLTWH(square * 0.2, 0, square * 0.8, square * 0.8), 0, 2 * pi);
      if (tailType == ReactionTailType.inside) {
        path.addArc(Rect.fromLTWH(square * 0.7, square * 0.55, square * 0.3, square * 0.3), 0, 2 * pi);
        path.addArc(Rect.fromLTWH(square * 0.668, square * 0.879, square * 0.175, square * 0.175), 0, 2 * pi);
      } else {
        path.addArc(Rect.fromLTWH(square * 0.2, square * 0.55, square * 0.3, square * 0.3), 0, 2 * pi);
        path.addArc(Rect.fromLTWH(0, square * 0.825, square * 0.175, square * 0.175), 0, 2 * pi);
      }
    }
    return path;
  }

  @override
  bool shouldReclip(covariant ReactionClipper oldClipper) {
    return oldClipper.tailDirection != tailDirection || oldClipper.tailType != tailType;
  }
}

class ReactionBorderClipper extends CustomClipper<Path> {
  final ReactionTailDirection tailDirection;
  final ReactionTailType tailType;

  ReactionBorderClipper({
    required this.tailDirection,
    this.tailType = ReactionTailType.standard,
  });

  @override
  Path getClip(Size size) {
    final square = size.width - 2;
    final path = Path();
    if (tailDirection == ReactionTailDirection.right) {
      path.addArc(Rect.fromLTWH(0, 0, square * 0.8 + 3, square * 0.8 + 3), 0, 2 * pi);
      if (tailType == ReactionTailType.inside) {
        path.addArc(Rect.fromLTWH(0, square * 0.55, square * 0.3 + 3, square * 0.3 + 3), 0, 2 * pi);
        path.addArc(
            Rect.fromLTWH(square * 0.157 + 0.5, square * 0.879 + 0.5, square * 0.175 + 2.5, square * 0.175 + 2.5),
            0,
            2 * pi);
      } else {
        path.addArc(Rect.fromLTWH(square * 0.55, square * 0.55, square * 0.3 + 3, square * 0.3 + 3), 0, 2 * pi);
        path.addArc(Rect.fromLTWH(square * 0.825 + 0.5, square * 0.825 + 0.5, square * 0.175 + 2.5, square * 0.175 + 2.5),
            0, 2 * pi);
      }
    } else if (tailDirection == ReactionTailDirection.left) {
      if (tailType == ReactionTailType.inside) {
        path.addArc(Rect.fromLTWH(square * 0.2, 0, square * 0.8 + 3, square * 0.8 + 3), 0, 2 * pi);
        path.addArc(Rect.fromLTWH(square * 0.7, square * 0.55, square * 0.3 + 3, square * 0.3 + 3), 0, 2 * pi);
        path.addArc(
            Rect.fromLTWH(square * 0.668 + 0.5, square * 0.879 + 0.5, square * 0.175 + 2.5, square * 0.175 + 2.5),
            0,
            2 * pi);
      } else {
        path.addArc(Rect.fromLTWH(size.width - (square * 0.8 + 3), 0, square * 0.8 + 3, square * 0.8 + 3), 0, 2 * pi);
        path.addArc(
            Rect.fromLTWH(size.width - (square * 0.8 + 3), square * 0.55, square * 0.3 + 3, square * 0.3 + 3), 0, 2 * pi);
        path.addArc(Rect.fromLTWH(0, square * 0.825 + 1, square * 0.175 + 1.5, square * 0.175 + 1.5), 0, 2 * pi);
      }
    }
    return path;
  }

  @override
  bool shouldReclip(covariant ReactionBorderClipper oldClipper) {
    return oldClipper.tailDirection != tailDirection || oldClipper.tailType != tailType;
  }
}

/// Google Messages reaction badge silhouette (APK `ewso.java#L13-32` / `ewsm.java#L317-340`).
///
/// Single reactions render as a full circle/pill (`r = H / 2`). Multi-reactions (`hasCount: true`)
/// fuse the main `H × H` circle with a top-end count lobe (`r = H / 4`, expanding horizontally into
/// a stadium pill for 2+ digit counts) so one continuous `surface` cutout stroke and drop shadow
/// frame the entire badge cleanly.
class MaterialReactionBadgeShape extends ShapeBorder {
  const MaterialReactionBadgeShape({
    this.hasCount = false,
    this.countExtraWidth = 0.0,
    this.side = BorderSide.none,
  });

  final bool hasCount;

  /// Extra horizontal width beyond the base badge height `H` (8dp for single-digit counts per `ewsm.c#L340`).
  final double countExtraWidth;
  final BorderSide side;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  Path _buildPath(Rect rect, TextDirection? textDirection) {
    final h = rect.height;
    if (h <= 0 || rect.width <= 0) return Path();
    if (!hasCount || rect.width <= h + 0.5) {
      return Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(h / 2)));
    }

    final isRtl = textDirection == TextDirection.rtl;
    final earH = h / 2;
    final earR = h / 4;
    // Base ear is an exact H/2 circle (`ewso.java#L30`) for 8dp extra width; stretches into a stadium for 2+ digits.
    final earW = max(earH, earH + (countExtraWidth - 8.0).clamp(0.0, 32.0));

    final mainRect = isRtl
        ? Rect.fromLTWH(rect.right - h, rect.top, h, h)
        : Rect.fromLTWH(rect.left, rect.top, h, h);
    final earRect = isRtl
        ? Rect.fromLTWH(rect.left, rect.top, earW, earH)
        : Rect.fromLTWH(rect.right - earW, rect.top, earW, earH);

    final mainPath = Path()..addOval(mainRect);
    final earPath = Path()..addRRect(RRect.fromRectAndRadius(earRect, Radius.circular(earR)));
    return Path.combine(PathOperation.union, mainPath, earPath);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _buildPath(rect.deflate(side.width), textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _buildPath(rect, textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side == BorderSide.none || side.width <= 0) return;
    final strokeRect = rect.deflate(side.width / 2);
    final path = _buildPath(strokeRect, textDirection);
    final paint = Paint()
      ..color = side.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = side.width
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    canvas.drawPath(path, paint);
  }

  @override
  ShapeBorder scale(double t) => MaterialReactionBadgeShape(
        hasCount: hasCount,
        countExtraWidth: countExtraWidth * t,
        side: side.scale(t),
      );

  @override
  bool operator ==(Object other) =>
      other is MaterialReactionBadgeShape &&
      other.hasCount == hasCount &&
      other.countExtraWidth == countExtraWidth &&
      other.side == side;

  @override
  int get hashCode => Object.hash(hasCount, countExtraWidth, side);
}
