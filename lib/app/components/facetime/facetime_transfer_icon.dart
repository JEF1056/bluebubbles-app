import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:flutter/material.dart';

/// Bespoke Pixel Watch silhouette with a directional transfer arrow into the watch face.
class WatchTransferIcon extends StatelessWidget {
  const WatchTransferIcon({
    super.key,
    this.size = 22.0,
    this.color = FaceTimePalette.onCanvas,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _WatchTransferPainter(color: color),
      ),
    );
  }
}

class _WatchTransferPainter extends CustomPainter {
  const _WatchTransferPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final scale = s / 24.0;
    final strokeWidth = (2.0 * scale).clamp(1.3, 8.0);

    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Pixel Watch silhouette shifted slightly right on the 24x24 optical grid.
    final cx = 14.0 * scale;
    final cy = 12.0 * scale;
    final r = 5.6 * scale;

    // Top and bottom Pixel Watch band attachments rising cleanly from the bezel.
    final bandHalfW = 2.8 * scale;
    final bandJoinDy = 4.85 * scale; // sqrt(5.6^2 - 2.8^2)
    final topBand = Path()
      ..moveTo(cx - bandHalfW, cy - bandJoinDy)
      ..lineTo(cx - 2.4 * scale, 3.2 * scale)
      ..quadraticBezierTo(cx - 2.4 * scale, 2.8 * scale, cx - 1.8 * scale, 2.8 * scale)
      ..lineTo(cx + 1.8 * scale, 2.8 * scale)
      ..quadraticBezierTo(cx + 2.4 * scale, 2.8 * scale, cx + 2.4 * scale, 3.2 * scale)
      ..lineTo(cx + bandHalfW, cy - bandJoinDy);
    canvas.drawPath(topBand, strokePaint);

    final bottomBand = Path()
      ..moveTo(cx - bandHalfW, cy + bandJoinDy)
      ..lineTo(cx - 2.4 * scale, 20.8 * scale)
      ..quadraticBezierTo(cx - 2.4 * scale, 21.2 * scale, cx - 1.8 * scale, 21.2 * scale)
      ..lineTo(cx + 1.8 * scale, 21.2 * scale)
      ..quadraticBezierTo(cx + 2.4 * scale, 21.2 * scale, cx + 2.4 * scale, 20.8 * scale)
      ..lineTo(cx + bandHalfW, cy + bandJoinDy);
    canvas.drawPath(bottomBand, strokePaint);

    // Clean crown pip on the right bezel with subtle separation.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx + r + 1.8 * scale, cy),
          width: 1.5 * scale,
          height: 3.2 * scale,
        ),
        Radius.circular(0.75 * scale),
      ),
      fillPaint,
    );

    // Open circular watch bezel with generous left cutout (±52° around 180°).
    // Start at 232° (4.049 rad), sweep 256° (4.468 rad) to 128°.
    const startAngle = 4.049;
    const sweepAngle = 4.468;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      startAngle,
      sweepAngle,
      false,
      strokePaint,
    );

    // Left-to-right handoff arrow entering cleanly through the negative-space cutout.
    final arrowStartX = 2.2 * scale;
    final arrowTipX = 13.8 * scale;
    canvas.drawLine(
      Offset(arrowStartX, cy),
      Offset(arrowTipX, cy),
      strokePaint,
    );

    final headPath = Path()
      ..moveTo(arrowTipX - 2.6 * scale, cy - 2.5 * scale)
      ..lineTo(arrowTipX, cy)
      ..lineTo(arrowTipX - 2.6 * scale, cy + 2.5 * scale);
    canvas.drawPath(headPath, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _WatchTransferPainter oldDelegate) => oldDelegate.color != color;
}
