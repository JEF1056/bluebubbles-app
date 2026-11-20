import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_line_painter.dart';
import 'package:flutter/material.dart';

class VerticalReplyLine extends StatelessWidget {
  const VerticalReplyLine({
    super.key,
    required this.color,
    required this.isFromMe,
    required this.onTap,
    required this.child,
  });

  final Color color;
  final bool isFromMe;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: ReplyLineHitRegion(
              containsPoint: (pos, size) {
                final x = isFromMe ? 35.0 : size.width - 35.0;
                return (pos.dx - x).abs() <= ReplyLinePainter.connectorHitPadding;
              },
              onTap: onTap,
            ),
          ),
          CustomPaint(
            painter: _ReplyLinePainter(
              color: color,
              isFromMe: isFromMe,
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Custom painter to draw a simple vertical line for the reply thread
/// connecting through the message sender
class _ReplyLinePainter extends CustomPainter {
  final Color color;
  final bool isFromMe;

  _ReplyLinePainter({required this.color, required this.isFromMe});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    // Draw vertical line at the same position as the reply line
    // Position depends on message direction: left side if from me, right side if not
    final x = isFromMe ? 35.0 : size.width - 35;
    canvas.drawLine(
      Offset(x, -5),
      Offset(x, size.height - (!isFromMe ? 0 : 5)),
      paint,
    );
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_ReplyLinePainter oldDelegate) => oldDelegate.color != color || oldDelegate.isFromMe != isFromMe;
}
