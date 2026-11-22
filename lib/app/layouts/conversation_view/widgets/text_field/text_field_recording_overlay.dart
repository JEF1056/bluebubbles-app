import 'dart:async';
import 'dart:math' as math;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/voice_message_recorder.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/platform/shims/native_media.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:record/record.dart';

/// Animated overlay shown on top of the text field while audio is recording.
///
/// Internally wraps an [Obx] subscribed to [controller.showRecording] so that
/// only this subtree rebuilds on recording state changes.
class TextFieldRecordingOverlay extends StatelessWidget {
  const TextFieldRecordingOverlay({
    super.key,
    required this.controller,
    this.recorderController,
    this.audioRecorder,
  });

  final ConversationViewController controller;
  final RecorderController? recorderController;
  final AudioRecorder? audioRecorder;

  void _cancelRecording() {
    controller.showRecording.value = false;
    if (kIsWeb || kIsDesktop) {
      unawaited(audioRecorder?.cancel().catchError((_) {}));
    } else {
      unawaited(recorderController?.stop().catchError((_) => null));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final isRecording = controller.showRecording.value;
      final bool iOS = SettingsSvc.settings.skin.value == Skins.iOS;
      final bool material = SettingsSvc.settings.skin.value == Skins.Material;
      final bool samsung = SettingsSvc.settings.skin.value == Skins.Samsung;

      return IgnorePointer(
        ignoring: !isRecording,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: isRecording ? 1.0 : 0.0,
          child: !isRecording
              ? const SizedBox.shrink()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // Reserve the right 48px on iOS so the inline Stop button inside
                    // TextFieldComponent's suffixIcon (minWidth: 48) remains unobstructed.
                    final double rightReserve = iOS ? 48.0 : 0.0;
                    final double availableWidth =
                        math.max(0.0, constraints.maxWidth - rightReserve);
                    final double availableHeight = constraints.maxHeight;
                    final double overlayHeight = iOS
                        ? availableHeight.clamp(0.0, 48.0)
                        : availableHeight;

                    final Widget bar = kIsDesktop
                        ? _DesktopRecordingBar(
                            iOS: iOS,
                            onCancel: _cancelRecording,
                          )
                        : VoiceMessageRecorder(
                            recorderController: recorderController,
                            audioRecorder: audioRecorder,
                            textFieldSize: Size(availableWidth, overlayHeight),
                            iOS: iOS,
                            samsung: samsung,
                            onCancel: _cancelRecording,
                          );

                    if (iOS) {
                      return Align(
                        alignment: Alignment.bottomLeft,
                        child: SizedBox(
                          width: constraints.maxWidth,
                          height: overlayHeight,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(1, 1, rightReserve, 1),
                            child: Container(
                              decoration: BoxDecoration(
                                color: context.theme.colorScheme.surface,
                                borderRadius: const BorderRadius.horizontal(
                                  left: Radius.circular(19),
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: bar,
                            ),
                          ),
                        ),
                      );
                    }

                    final radius = BorderRadius.circular(kIsWeb && material ? 26 : 28);
                    return Container(
                      width: availableWidth,
                      height: overlayHeight,
                      decoration: BoxDecoration(
                        color: context.theme.colorScheme.surfaceContainerHigh,
                        borderRadius: radius,
                        border: Border.all(
                          color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
                          width: 1,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: bar,
                    );
                  },
                ),
        ),
      );
    });
  }
}

class _DesktopRecordingBar extends StatefulWidget {
  const _DesktopRecordingBar({
    required this.iOS,
    required this.onCancel,
  });

  final bool iOS;
  final VoidCallback onCancel;

  @override
  State<_DesktopRecordingBar> createState() => _DesktopRecordingBarState();
}

class _DesktopRecordingBarState extends State<_DesktopRecordingBar> {
  final DateTime _startTime = DateTime.now();
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  double _dragOffset = 0.0;
  bool _cancelTriggered = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      setState(() {
        _elapsed = DateTime.now().difference(_startTime);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details, bool isRtl) {
    if (_cancelTriggered) return;
    setState(() {
      _dragOffset = isRtl
          ? (_dragOffset + details.delta.dx).clamp(0.0, 80.0)
          : (_dragOffset + details.delta.dx).clamp(-80.0, 0.0);
    });
  }

  void _onDragEnd(DragEndDetails details, bool isRtl) {
    if (_cancelTriggered) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final pastDistance = isRtl ? _dragOffset >= 56.0 : _dragOffset <= -56.0;
    final fastSwipe = isRtl ? velocity >= 300.0 : velocity <= -300.0;
    if (pastDistance || fastSwipe) {
      _cancelTriggered = true;
      widget.onCancel();
      return;
    }
    setState(() => _dragOffset = 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    final fg = widget.iOS ? cs.primary : cs.onSurface;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.hasBoundedHeight ? constraints.maxHeight : 48.0;
        final cancelButton = IconButton(
          key: const Key('voice-record-cancel-button'),
          tooltip: 'Cancel recording',
          style: IconButton.styleFrom(
            padding: EdgeInsets.zero,
            fixedSize: Size(w < 200 ? 32 : 40, w < 200 ? 32 : 40),
            minimumSize: Size(w < 200 ? 32 : 40, w < 200 ? 32 : 40),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(
            Icons.delete_outline_rounded,
            size: w < 200 ? 19 : 22,
            color: cs.error,
          ),
          onPressed: widget.onCancel,
        );

        if (w < 72) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(child: cancelButton),
          );
        }

        final showTimer = w >= 104;
        final showDot = w >= 132;
        final showIndicatorRing = !widget.iOS && w >= 240 && h >= 40;
        final showLabel = w >= 188;
        final showSlideHint = w >= 340;

        final Widget dotWidget = Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.error,
          ),
        );

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: showDot ? (d) => _onDragUpdate(d, isRtl) : null,
          onHorizontalDragEnd: showDot ? (d) => _onDragEnd(d, isRtl) : null,
          onHorizontalDragCancel: showDot ? () => setState(() => _dragOffset = 0.0) : null,
          child: Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: Padding(
              padding: EdgeInsetsDirectional.only(start: widget.iOS ? 10 : 8, end: widget.iOS ? 4 : 8),
              child: Row(
                children: [
                  if (showDot) ...[
                    if (showIndicatorRing)
                      Container(
                        width: 35,
                        height: 35,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: cs.error.withValues(alpha: 0.14),
                        ),
                        child: Center(child: dotWidget),
                      )
                    else
                      dotWidget,
                    const SizedBox(width: 8),
                  ],
                  if (showLabel)
                    Expanded(
                      child: Text(
                        'Recording',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.theme.textTheme.bodyMedium?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (showSlideHint)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 165),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isRtl ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
                            size: 25,
                            color: cs.onSurfaceVariant,
                          ),
                          Flexible(
                            child: Text(
                              'Slide to cancel',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 16,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (showTimer)
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerEnd,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            prettyDuration(_elapsed),
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              color: fg,
                              fontSize: 16,
                              letterSpacing: -0.03,
                              fontWeight: FontWeight.w500,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                    ),
                  cancelButton,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
