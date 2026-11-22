import 'dart:async';
import 'dart:math' as math;

import 'package:bluebubbles/platform/shims/native_media.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:record/record.dart';

class VoiceMessageRecorder extends StatefulWidget {
  const VoiceMessageRecorder({
    super.key,
    required this.recorderController,
    required this.textFieldSize,
    required this.iOS,
    required this.samsung,
    this.audioRecorder,
    this.onCancel,
  });

  final RecorderController? recorderController;

  final AudioRecorder? audioRecorder;

  final Size textFieldSize;

  final bool iOS;

  final bool samsung;

  final VoidCallback? onCancel;

  @override
  State<VoiceMessageRecorder> createState() => _VoiceMessageRecorderState();
}

class _VoiceMessageRecorderState extends State<VoiceMessageRecorder> {
  Stream<Duration>? recordingDurationStream;
  Timer? _webTimer;
  final DateTime _startTime = DateTime.now();
  Duration _elapsed = Duration.zero;
  final List<double> _amplitudes = <double>[];
  bool _sampling = false;
  double _dragOffset = 0.0;
  bool _cancelTriggered = false;
  static const int _maxBars = 200;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _webTimer = Timer.periodic(const Duration(milliseconds: 80), (_) => _sampleWebAmplitude());
    } else {
      recordingDurationStream = widget.recorderController?.onCurrentDuration;
    }
  }

  Future<void> _sampleWebAmplitude() async {
    if (_sampling) return;
    _sampling = true;
    try {
      double normalized = 0.12;
      final recorder = widget.audioRecorder;
      if (recorder != null) {
        try {
          final amp = await recorder.getAmplitude();
          if (amp.current.isFinite) {
            normalized = ((amp.current + 50.0) / 50.0).clamp(0.08, 1.0);
          }
        } catch (_) {
          // Ignore transient amplitude read failures during start/stop transitions.
        }
      }
      if (!mounted) return;
      setState(() {
        _elapsed = DateTime.now().difference(_startTime);
        _amplitudes.add(normalized);
        if (_amplitudes.length > _maxBars) {
          _amplitudes.removeAt(0);
        }
      });
    } finally {
      _sampling = false;
    }
  }

  @override
  void dispose() {
    _webTimer?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _onDragUpdate(DragUpdateDetails details, bool isRtl) {
    if (_cancelTriggered || widget.onCancel == null) return;
    setState(() {
      _dragOffset = isRtl
          ? (_dragOffset + details.delta.dx).clamp(0.0, 80.0)
          : (_dragOffset + details.delta.dx).clamp(-80.0, 0.0);
    });
  }

  void _onDragEnd(DragEndDetails details, bool isRtl) {
    if (_cancelTriggered || widget.onCancel == null) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final pastDistance = isRtl ? _dragOffset >= 56.0 : _dragOffset <= -56.0;
    final fastSwipe = isRtl ? velocity >= 300.0 : velocity <= -300.0;
    if (pastDistance || fastSwipe) {
      _cancelTriggered = true;
      widget.onCancel?.call();
      return;
    }
    setState(() => _dragOffset = 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    final waveColor = widget.iOS ? cs.primary : cs.onSurfaceVariant;
    final timerColor = widget.iOS ? cs.primary : cs.onSurface;
    final useWebFallback = kIsWeb || widget.recorderController == null;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final double scaledSlideHint = MediaQuery.textScalerOf(context).scale(105.0).clamp(105.0, 140.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.hasBoundedWidth
            ? math.min(constraints.maxWidth, widget.textFieldSize.width)
            : widget.textFieldSize.width;
        final double maxHeight = constraints.hasBoundedHeight
            ? math.min(constraints.maxHeight, widget.textFieldSize.height)
            : widget.textFieldSize.height;
        final double maxBar = widget.iOS ? 48.0 : 56.0;
        final double barHeight = maxHeight >= 24.0 ? maxHeight.clamp(24.0, maxBar) : maxHeight;
        final double waveHeight = math.max(18.0, barHeight - 14.0);

        final bool showDot = maxWidth >= 140;
        final bool showIndicatorRing = !widget.iOS && maxWidth >= 230 && barHeight >= 38;
        final bool showWaveform = maxWidth >= 105;
        final bool showTimer = (maxWidth >= 72) && (widget.iOS || kIsWeb || !widget.samsung);
        final bool showCancel = widget.onCancel != null;
        final bool showSlideHint = showCancel && maxWidth >= (156.0 + scaledSlideHint);

        final TextStyle timerStyle = TextStyle(
          color: timerColor,
          fontSize: 16,
          letterSpacing: -0.03,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
        );

        final Widget timerText = useWebFallback
            ? Text(
                _formatDuration(_elapsed),
                maxLines: 1,
                softWrap: false,
                style: timerStyle,
              )
            : StreamBuilder<Duration>(
                initialData: Duration.zero,
                stream: recordingDurationStream,
                builder: (context, snapshot) {
                  return Text(
                    _formatDuration(snapshot.data ?? Duration.zero),
                    maxLines: 1,
                    softWrap: false,
                    style: timerStyle,
                  );
                },
              );

        final Widget timerWidget = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerEnd,
            child: timerText,
          ),
        );

        final Widget waveformWidget = Expanded(
          child: useWebFallback
              ? SizedBox(
                  height: waveHeight,
                  child: CustomPaint(
                    painter: _WebWaveformPainter(
                      amplitudes: _amplitudes,
                      color: waveColor,
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, waveConstraints) {
                    final w = waveConstraints.maxWidth;
                    if (w < 16) return const SizedBox.shrink();
                    return AudioWaveforms(
                      size: Size(w, waveHeight),
                      recorderController: widget.recorderController!,
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                      waveStyle: WaveStyle(
                        waveColor: waveColor,
                        waveCap: StrokeCap.square,
                        spacing: 4.0,
                        showBottom: true,
                        extendWaveform: true,
                        showMiddleLine: false,
                      ),
                    );
                  },
                ),
        );

        final Widget dotWidget = Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.error,
          ),
        );

        final Widget cancelBtn = IconButton(
          key: const Key('voice-record-cancel-button'),
          tooltip: 'Cancel recording',
          style: IconButton.styleFrom(
            padding: EdgeInsets.zero,
            fixedSize: Size(maxWidth < 200 ? 32 : 40, maxWidth < 200 ? 32 : 40),
            minimumSize: Size(maxWidth < 200 ? 32 : 40, maxWidth < 200 ? 32 : 40),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(
            Icons.delete_outline_rounded,
            size: maxWidth < 200 ? 19 : 22,
            color: cs.error,
          ),
          onPressed: widget.onCancel,
        );

        return SizedBox(
          width: maxWidth,
          height: barHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: showCancel && maxWidth >= 132 ? (d) => _onDragUpdate(d, isRtl) : null,
            onHorizontalDragEnd: showCancel && maxWidth >= 132 ? (d) => _onDragEnd(d, isRtl) : null,
            onHorizontalDragCancel: showCancel && maxWidth >= 132 ? () => setState(() => _dragOffset = 0.0) : null,
            child: Transform.translate(
              offset: Offset(_dragOffset, 0),
              child: Container(
                padding: EdgeInsetsDirectional.only(
                  start: maxWidth < 72 ? 4 : (widget.iOS ? 10 : 8),
                  end: maxWidth < 72 ? 4 : (widget.iOS ? 4 : 8),
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.iOS ? 20 : 28),
                  color: widget.iOS ? Colors.transparent : cs.surfaceContainerHigh,
                ),
                child: maxWidth < 72
                    ? Center(
                        child: showCancel ? cancelBtn : const SizedBox.shrink(),
                      )
                    : Row(
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
                          if (showWaveform)
                            waveformWidget
                          else if (showTimer)
                            Expanded(
                              child: Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: timerWidget,
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
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 140),
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
                                  ),
                                ],
                              ),
                            ),
                          if (showTimer && showWaveform) Flexible(child: timerWidget),
                          if (showCancel) cancelBtn,
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WebWaveformPainter extends CustomPainter {
  _WebWaveformPainter({
    required this.amplitudes,
    required this.color,
  });

  final List<double> amplitudes;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.square
      ..strokeWidth = 2.0;

    const spacing = 4.0;
    final count = (size.width / spacing).floor().clamp(1, 200);
    final midY = size.height / 2;
    for (int i = 0; i < count; i++) {
      final ampIdx = amplitudes.length - count + i;
      final amp = ampIdx >= 0 ? amplitudes[ampIdx] : 0.08;
      final halfBar = (amp * size.height * 0.45).clamp(1.5, size.height * 0.45);
      final x = i * spacing + 1.0;
      canvas.drawLine(Offset(x, midY - halfBar), Offset(x, midY + halfBar), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WebWaveformPainter oldDelegate) => true;
}
