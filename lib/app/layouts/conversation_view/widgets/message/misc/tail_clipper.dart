import 'dart:math';

import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';

/// Whether a part's bubble visually joins the bubbles above / below it: the Material and Samsung multi-part
/// styling, where the author-edge corners between neighbouring parts tighten. The iOS skin never connects part
/// bubbles.
///
/// One rule for every bubble shape: [TailClipper] callers (text, attachments, edits) and the media collection
/// grid's silhouette. Position is decided by [MessageState.isLeadingMessagePart] /
/// [MessageState.isTrailingMessagePart], so a collapsed collection counts as covering its whole span.
abstract final class BubbleConnect {
  /// [part] joins the bubble below it (it isn't the message's trailing part, or the newer message groups with it).
  static bool lower(MessageState state, MessagePart part) {
    if (CurrentSkin.iOS) return false;
    if (!state.isTrailingMessagePart(part)) return true;
    final newer = state.newMessage;
    return newer != null && !state.message.showTail(newer);
  }

  /// [part] joins the bubble above it (it isn't the message's leading part, or the older message groups with it).
  static bool upper(MessageState state, MessagePart part) {
    if (CurrentSkin.iOS) return false;
    if (!state.isLeadingMessagePart(part)) return true;
    final older = state.oldMessage;
    return older != null && !older.isGroupEvent && !older.showTail(state.message) && !state.message.isReply;
  }
}

class TailClipper extends CustomClipper<Path> {
  final bool isFromMe;
  final bool showTail;
  final bool connectUpper;
  final bool connectLower;

  TailClipper({
    required this.isFromMe,
    required this.showTail,
    required this.connectUpper,
    required this.connectLower,
  });

  @override
  Path getClip(Size size) {
    final path = Path();
    final skin = SettingsSvc.settings.skin.value;
    final isIOS = skin == Skins.iOS;
    final isMaterial = skin == Skins.Material;
    final double r = min(size.height / 2, isMaterial ? 20.0 : 22.0);
    final double cr = min(size.height / 2, isMaterial ? 4.0 : 5.0);
    final double start = isIOS ? (isFromMe ? 0 : 10) : 0;
    final double end = isIOS ? (isFromMe ? size.width - 10 : size.width) : size.width;
    path.moveTo(start, r);
    if (!isFromMe && showTail && isIOS) {
      path.lineTo(start, size.height - 10);
      path.arcToPoint(Offset(0, size.height), radius: const Radius.circular(10));
      // intersect slightly more than 45 deg on the arc
      path.arcToPoint(Offset(start + 6.547, size.height - 5.201), radius: const Radius.circular(20), clockwise: false);
      path.arcToPoint(Offset(start + 20, size.height), radius: const Radius.circular(20), clockwise: false);
    } else {
      if (connectLower && !isFromMe) {
        path.lineTo(start, size.height - cr);
        path.arcToPoint(Offset(start + cr, size.height), radius: Radius.circular(cr), clockwise: false);
      } else {
        path.lineTo(start, size.height - r);
        path.arcToPoint(Offset(start + r, size.height), radius: Radius.circular(r), clockwise: false);
      }
    }
    if (isFromMe && showTail && isIOS) {
      path.lineTo(end - 20, size.height);
      // intersect slightly more than 45 deg on the arc
      path.arcToPoint(Offset(end - 6.547, size.height - 5.201), radius: const Radius.circular(20), clockwise: false);
      path.arcToPoint(Offset(size.width, size.height + 1), radius: const Radius.circular(20), clockwise: false);
      path.arcToPoint(Offset(end, size.height - 10), radius: const Radius.circular(10));
    } else {
      if (connectLower && isFromMe) {
        path.lineTo(end - cr, size.height);
        path.arcToPoint(Offset(end, size.height - cr), radius: Radius.circular(cr), clockwise: false);
      } else {
        path.lineTo(end - r, size.height);
        path.arcToPoint(Offset(end, size.height - r), radius: Radius.circular(r), clockwise: false);
      }
    }
    if (connectUpper && !isIOS) {
      if (isFromMe) {
        path.lineTo(end, cr);
        path.arcToPoint(Offset(end - cr, 0), radius: Radius.circular(cr), clockwise: false);
        path.lineTo(start + r, 0);
        path.arcToPoint(Offset(start, r), radius: Radius.circular(r), clockwise: false);
      } else {
        path.lineTo(end, r);
        path.arcToPoint(Offset(end - r, 0), radius: Radius.circular(r), clockwise: false);
        path.lineTo(start + cr, 0);
        path.arcToPoint(Offset(start, cr), radius: Radius.circular(cr), clockwise: false);
      }
    } else {
      path.lineTo(end, r);
      path.arcToPoint(Offset(end - r, 0), radius: Radius.circular(r), clockwise: false);
      path.lineTo(start + r, 0);
      path.arcToPoint(Offset(start, r), radius: Radius.circular(r), clockwise: false);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant TailClipper oldClipper) {
    return showTail != oldClipper.showTail ||
        isFromMe != oldClipper.isFromMe ||
        connectUpper != oldClipper.connectUpper ||
        connectLower != oldClipper.connectLower;
  }
}

class TailPainter extends CustomPainter {
  final bool isFromMe;
  final bool showTail;
  final Color color;
  final double? width;

  TailPainter({
    required this.isFromMe,
    required this.showTail,
    required this.color,
    this.width,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    paint.color = color;
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = width ?? 3;

    final path = Path();
    final skin = SettingsSvc.settings.skin.value;
    final isIOS = skin == Skins.iOS;
    final isMaterial = skin == Skins.Material;
    final double r = min(size.height / 2, isMaterial ? 20.0 : 22.0);
    final double start = isIOS ? (isFromMe ? 0 : 10) : 0;
    final double end = isIOS ? (isFromMe ? size.width - 10 : size.width) : size.width;
    path.moveTo(start, r);
    if (!isFromMe && showTail && isIOS) {
      path.lineTo(start, size.height - 10);
      path.arcToPoint(Offset(0, size.height), radius: const Radius.circular(10));
      path.arcToPoint(Offset(start + 6.547, size.height - 5.201), radius: const Radius.circular(20), clockwise: false);
      path.arcToPoint(Offset(start + 20, size.height), radius: const Radius.circular(20), clockwise: false);
    } else {
      path.lineTo(start, size.height - r);
      path.arcToPoint(Offset(start + r, size.height), radius: Radius.circular(r), clockwise: false);
    }
    final bool isFromMeTail = isFromMe && showTail && isIOS;
    if (isFromMeTail) {
      path.lineTo(end - 20, size.height);
      path.arcToPoint(Offset(end - 6.547, size.height - 5.201), radius: const Radius.circular(20), clockwise: false);
      path.arcToPoint(Offset(size.width, size.height + 1), radius: const Radius.circular(20), clockwise: false);
      path.arcToPoint(Offset(end, size.height - 10), radius: const Radius.circular(10));
    } else {
      path.lineTo(end - r, size.height);
      path.arcToPoint(Offset(end, size.height - r), radius: Radius.circular(r), clockwise: false);
    }
    path.lineTo(end, r);
    path.arcToPoint(Offset(end - r, 0), radius: Radius.circular(r), clockwise: false);
    path.lineTo(start + r, 0);
    path.arcToPoint(Offset(start, r), radius: Radius.circular(r), clockwise: false);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant TailPainter oldDelegate) {
    return showTail != oldDelegate.showTail ||
        isFromMe != oldDelegate.isFromMe ||
        color != oldDelegate.color ||
        width != oldDelegate.width;
  }
}
