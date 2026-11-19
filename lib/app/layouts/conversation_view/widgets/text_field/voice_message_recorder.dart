import 'dart:async';

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
  });

  final RecorderController? recorderController;

  final AudioRecorder? audioRecorder;

  final Size textFieldSize;

  final bool iOS;

  final bool samsung;

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

  @override
  Widget build(BuildContext context) {
    final waveWidth = (widget.textFieldSize.width - getWidth(widget.iOS, widget.samsung)).clamp(40.0, double.infinity);
    final waveHeight = (widget.textFieldSize.height - 15).clamp(24.0, double.infinity);
    final waveColor = widget.iOS ? context.theme.colorScheme.primary : context.theme.colorScheme.onSurfaceVariant;
    final decoration = BoxDecoration(
      border: widget.iOS
          ? const Border.fromBorderSide(BorderSide(
              color: Colors.transparent,
              width: 1,
            ))
          : null,
      borderRadius: BorderRadius.circular(widget.iOS ? 20 : 28),
      color: widget.iOS ? Colors.transparent : context.theme.colorScheme.surfaceContainerHigh,
    );

    if (kIsWeb || widget.recorderController == null) {
      final minutes = _elapsed.inMinutes;
      final seconds = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
      return Padding(
        padding: const EdgeInsets.only(left: 1),
        child: Row(
          children: [
            Container(
              width: waveWidth,
              height: waveHeight,
              padding: EdgeInsets.symmetric(vertical: 5, horizontal: widget.iOS ? 10 : 15),
              decoration: decoration,
              child: CustomPaint(
                painter: _WebWaveformPainter(
                  amplitudes: _amplitudes,
                  color: waveColor,
                ),
              ),
            ),
            Visibility(
              visible: widget.iOS,
              child: Center(
                child: Text(
                  '$minutes:$seconds',
                  style: TextStyle(color: context.theme.colorScheme.primary),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
        padding: const EdgeInsets.only(left: 1),
        child: Row(
          children: [
            AudioWaveforms(
              size: Size(waveWidth, waveHeight),
              recorderController: widget.recorderController!,
              padding: EdgeInsets.symmetric(
                  vertical: 5,
                  horizontal: widget.iOS ? 10 : 15), // need extra spacing in case of iOS for recording duration
              waveStyle: WaveStyle(
                waveColor: waveColor,
                waveCap: StrokeCap.square,
                spacing: 4.0,
                showBottom: true,
                extendWaveform: true,
                showMiddleLine: false,
              ),
              decoration: decoration,
            ),
            Visibility(
              visible: widget.iOS,
              child: Center(
                child: StreamBuilder<Duration>(
                  stream: recordingDurationStream,
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      final minutes = snapshot.data!.inMinutes;

                      final seconds = (snapshot.data!.inSeconds % 60).toString().padLeft(2, '0');

                      return Text(
                        '$minutes:$seconds',
                        style: TextStyle(color: context.theme.colorScheme.primary),
                      );
                    } else {
                      return Container();
                    }
                  },
                ),
              ),
            ),
          ],
        ));
  }

  int getWidth(bool iOS, bool samsung) {
    if (samsung) {
      // width for samsung style
      return 0;
    } else if (iOS) {
      return 105;
    }
    // for material
    return 80;
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
