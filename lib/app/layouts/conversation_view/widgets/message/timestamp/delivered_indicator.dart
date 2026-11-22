import 'dart:async';

import 'package:bluebubbles/app/components/m3e/m3e_motion.dart';
import 'package:bluebubbles/app/components/wallpaper/wallpaper_contrast.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/relative_timestamp_ticker.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class DeliveredIndicator extends StatefulWidget {
  const DeliveredIndicator({
    super.key,
    required this.forceShow,
  });

  final bool forceShow;

  @override
  State<StatefulWidget> createState() => _DeliveredIndicatorState();
}

class _DeliveredIndicatorState extends State<DeliveredIndicator> with ThemeHelpers {
  late MessageState controller;
  late final bool _isGroup;
  Message get message => controller.message;
  bool get showAvatar => _isGroup;

  // Debounced shadow of isSending. Goes true immediately when sending starts,
  // but stays true for at least _sendingMinDisplayMs after sending ends so the
  // "Sending..." label outlives the send animation (~650 ms total).
  bool _isSendingDisplayed = false;
  Timer? _sendingTimer;
  Worker? _isSendingWorker;
  late final RelativeTimestampTicker _ticker;
  static const int _sendingMinDisplayMs = 700;

  @override
  void initState() {
    super.initState();
    controller = MessageStateScope.readStateOnce(context);
    final fallbackChat = ChatStateScope.maybeReadChatOnce(context);
    _isGroup = controller.cvController?.chat.isGroup ?? fallbackChat?.isGroup ?? false;
    _isSendingDisplayed = controller.isSending.value;
    _isSendingWorker = ever(controller.isSending, _onIsSendingChange);
    _ticker = RelativeTimestampTicker(onTick: () {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ticker.setVisible(TickerMode.valuesOf(context).enabled);
  }

  void _onIsSendingChange(bool newVal) {
    if (newVal) {
      _sendingTimer?.cancel();
      if (mounted) setState(() => _isSendingDisplayed = true);
    } else if (_isSendingDisplayed) {
      _sendingTimer = Timer(const Duration(milliseconds: _sendingMinDisplayMs), () {
        if (mounted) setState(() => _isSendingDisplayed = false);
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _isSendingWorker?.dispose();
    _sendingTimer?.cancel();
    super.dispose();
  }

  bool get _isEdited => controller.parts.any((p) => p.isEdited);

  bool get shouldShow {
    if (controller.audioWasKept.value != null) return true;
    if (message.isGroupEvent) return false;
    if (widget.forceShow || _isSendingDisplayed) return true;
    if (controller.isFullyUnsent || (controller.parts.lastOrNull?.isUnsent ?? false)) return false;
    if (_isEdited) return true;

    // Visibility for "last read / delivered / sent / received" is computed by
    // MessagesService._recomputeDeliveredIndicators and stored reactively on
    // the MessageState — each tier is independent.
    return controller.showReadIndicator.value ||
        controller.showDeliveredIndicator.value ||
        controller.showSentIndicator.value ||
        controller.showReceivedIndicator.value;
  }

  List<InlineSpan> buildTwoPiece(String action, String? date) {
    final material = !iOS && !samsung;
    final hasBackground = ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false;
    final fallbackColor = material ? context.theme.colorScheme.onSurfaceVariant : context.theme.colorScheme.outline;
    final baseStyle = WallpaperContrast.unbubbledStyle(
      material ? context.theme.textTheme.bodySmall! : context.theme.textTheme.labelSmall!,
      hasWallpaper: hasBackground,
      fallbackColor: fallbackColor,
    );
    final hasDate = date != null && date.isNotEmpty;
    return [
      TextSpan(
        text: action,
        style: baseStyle.copyWith(fontWeight: material ? FontWeight.w500 : FontWeight.w600),
      ),
      if (hasDate)
        TextSpan(
          text: " · $date",
          style: baseStyle.copyWith(fontWeight: FontWeight.normal),
        ),
    ];
  }

  ({
    IconData? icon,
    _GMsgStatusKind? gmsgKind,
    Color? iconColor,
    String? semanticLabel,
    List<InlineSpan> spans,
    DateTime? timestamp,
  }) _resolveStatus({required bool material, required bool hasBackground}) {
    final dateRead = controller.dateRead.value ?? message.dateRead;
    final dateDelivered = controller.dateDelivered.value ?? message.dateDelivered;
    final dateCreated = controller.dateCreated.value ?? message.dateCreated;
    final wasDeliveredQuietly = controller.wasDeliveredQuietly.value;
    final didNotifyRecipient = controller.didNotifyRecipient.value;
    ({
      IconData? icon,
      _GMsgStatusKind? gmsgKind,
      Color? iconColor,
      String? semanticLabel,
      List<InlineSpan> spans,
      DateTime? timestamp,
    }) status(
      String label,
      DateTime? timestamp, {
      IconData? icon,
      _GMsgStatusKind? gmsgKind,
      Color? iconColor,
      String? semanticLabel,
    }) =>
        (
          icon: icon,
          gmsgKind: gmsgKind,
          iconColor: iconColor,
          semanticLabel: semanticLabel ?? label,
          spans: buildTwoPiece(label, timestamp == null ? null : buildDate(timestamp)),
          timestamp: timestamp,
        );

    if (controller.audioWasKept.value != null) {
      return status("Kept", controller.audioWasKept.value!, icon: Icons.check_circle_outline);
    }
    if (_isEdited) {
      return status("Edited", widget.forceShow ? dateCreated : null);
    }
    if (!(message.isFromMe ?? false)) {
      return status("Received", dateCreated);
    }
    if (material && _isSendingDisplayed) {
      return status("Sending...", null, icon: Icons.schedule, semanticLabel: 'Sending');
    }
    if (dateRead != null) {
      return status(
        "Read",
        dateRead,
        gmsgKind: _GMsgStatusKind.read,
        iconColor: hasBackground ? Colors.white.withValues(alpha: 0.92) : context.theme.colorScheme.primary,
      );
    }
    if (dateDelivered != null) {
      return status(
        "Delivered${wasDeliveredQuietly && !didNotifyRecipient ? " Quietly" : ""}",
        dateDelivered,
        gmsgKind: _GMsgStatusKind.delivered,
        semanticLabel: 'Delivered',
      );
    }
    if (message.isDelivered) {
      return status("Delivered", dateCreated, gmsgKind: _GMsgStatusKind.delivered);
    }
    if (!material && _isSendingDisplayed && !(controller.cvController?.chat.isGroup ?? _isGroup) && !iOS) {
      return status("Sending...", null, semanticLabel: 'Sending');
    }
    if (controller.showSentIndicator.value || widget.forceShow) {
      return status("Sent", dateCreated, gmsgKind: _GMsgStatusKind.sent);
    }
    return (icon: null, gmsgKind: null, iconColor: null, semanticLabel: null, spans: const [], timestamp: null);
  }

  ({
    IconData? icon,
    _GMsgStatusKind? gmsgKind,
    Color? iconColor,
    String? semanticLabel,
    List<InlineSpan> spans,
    DateTime? timestamp,
  }) _materialStatus(bool hasBackground) => _resolveStatus(material: true, hasBackground: hasBackground);

  @override
  Widget build(BuildContext context) {
    final material = !iOS && !samsung;
    final hasBackground = ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false;
    final mutedColor = hasBackground
        ? Colors.white.withValues(alpha: 0.86)
        : context.theme.colorScheme.onSurfaceVariant;
    final indentLeft =
        (showAvatar || (!material && SettingsSvc.settings.alwaysShowAvatars.value)) && !(message.isFromMe ?? false)
            ? BubbleConnect.incomingAvatarIndent(
                isIOS: iOS,
                avatarScale: SettingsSvc.settings.avatarScale.value,
              )
            : 0.0;
    return AnimatedSize(
      curve: material ? M3EMotion.spatialFast.curve : Curves.easeInOut,
      alignment: Alignment.bottomCenter,
      duration: material ? M3EMotion.spatialFast.duration : const Duration(milliseconds: 250),
      child: Obx(() {
        // Observe the fields that affect both shouldShow and getText.
        // isSending is handled via the debounced _isSendingDisplayed + setState,
        // not subscribed here, so the "Sending..." label outlives the animation.
        controller.showReadIndicator.value;
        controller.showDeliveredIndicator.value;
        controller.showSentIndicator.value;
        controller.showReceivedIndicator.value;
        controller.audioWasKept.value;
        controller.dateDelivered.value;
        controller.dateRead.value;
        controller.dateCreated.value;
        controller.dateEdited.value;
        controller.parts.length;
        final isRelative = SettingsSvc.settings.skin.value != Skins.iOS;
        if (!shouldShow) {
          _ticker.sync(null, isRelative: false);
          return const SizedBox.shrink();
        }

        Widget wrapEditedTap(Widget child) {
          if (!_isEdited) return child;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => controller.showEdits.toggle(),
              child: child,
            ),
          );
        }

        if (material) {
          final status = _materialStatus(hasBackground);
          _ticker.sync(status.timestamp, isRelative: isRelative);
          final hasIcon = status.icon != null || status.gmsgKind != null;
          if (!hasIcon && status.spans.isEmpty) {
            return const SizedBox.shrink();
          }
          return wrapEditedTap(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4).add(EdgeInsets.only(top: 2, bottom: 2, left: indentLeft)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (status.gmsgKind != null)
                  Semantics(
                    label: status.semanticLabel,
                    child: CustomPaint(
                      size: Size(status.gmsgKind == _GMsgStatusKind.sent ? 12 : 18, 12),
                      painter: _GMsgStatusPainter(
                        kind: status.gmsgKind!,
                        color: status.iconColor ?? mutedColor,
                        checkColor: hasBackground ? Colors.black87 : context.theme.colorScheme.onPrimary,
                      ),
                    ),
                  )
                else if (status.icon != null)
                  Icon(
                    status.icon,
                    size: 14,
                    color: status.iconColor ?? mutedColor,
                    shadows: hasBackground ? WallpaperContrast.unbubbledTextShadows : null,
                    semanticLabel: status.semanticLabel,
                  ),
                AnimatedSize(
                  duration: M3EMotion.spatialFast.duration,
                  curve: M3EMotion.spatialFast.curve,
                  alignment: AlignmentDirectional.centerStart,
                  child: AnimatedSwitcher(
                    duration: M3EMotion.effectsFast.duration,
                    switchInCurve: M3EMotion.effectsFast.curve,
                    switchOutCurve: M3EMotion.effectsFast.curve,
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      alignment: AlignmentDirectional.centerStart,
                      children: [
                        ...previousChildren,
                        ?currentChild,
                      ],
                    ),
                    child: status.spans.isEmpty
                        ? const SizedBox.shrink()
                        : Padding(
                            key: ValueKey(status.semanticLabel),
                            padding: EdgeInsets.only(left: hasIcon ? 4 : 0),
                            child: Text.rich(TextSpan(children: status.spans)),
                          ),
                  ),
                ),
              ],
            ),
          ));
        }

        final status = _resolveStatus(material: false, hasBackground: hasBackground);
        _ticker.sync(status.timestamp, isRelative: isRelative);
        final spans = status.spans;
        return spans.isNotEmpty
            ? wrapEditedTap(Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15).add(EdgeInsets.only(top: 2, bottom: 2, left: indentLeft)),
                child: Text.rich(TextSpan(
                  children: spans,
                )),
              ))
            : const SizedBox.shrink();
      }),
    );
  }
}

enum _GMsgStatusKind { sent, delivered, read }

class _GMsgStatusPainter extends CustomPainter {
  const _GMsgStatusPainter({
    required this.kind,
    required this.color,
    required this.checkColor,
  });

  final _GMsgStatusKind kind;
  final Color color;
  final Color checkColor;

  void _drawCheck(Canvas canvas, Offset center, double radius, Paint paint) {
    final p = Path()
      ..moveTo(center.dx - radius * 0.44, center.dy + radius * 0.04)
      ..lineTo(center.dx - radius * 0.10, center.dy + radius * 0.36)
      ..lineTo(center.dx + radius * 0.46, center.dy - radius * 0.30);
    canvas.drawPath(p, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    const r = 4.6;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (kind == _GMsgStatusKind.sent) {
      final c = Offset(size.width / 2, cy);
      canvas.drawCircle(c, r, stroke);
      _drawCheck(canvas, c, r, stroke);
      return;
    }

    final isRead = kind == _GMsgStatusKind.read;
    final circlePaint = isRead ? (Paint()..color = color..style = PaintingStyle.fill) : stroke;
    final checkPaint = isRead
        ? (Paint()
          ..color = checkColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round)
        : stroke;
    for (final c in [Offset(5.5, cy), Offset(12.0, cy)]) {
      canvas.drawCircle(c, r, circlePaint);
      _drawCheck(canvas, c, r, checkPaint);
    }
  }

  @override
  bool shouldRepaint(_GMsgStatusPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color || oldDelegate.checkColor != checkColor;
}
