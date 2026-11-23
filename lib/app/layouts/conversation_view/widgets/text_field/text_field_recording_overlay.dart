import 'dart:async';
import 'dart:math' as math;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/audio_player.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/voice_message_recorder.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/platform/shims/native_media.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:record/record.dart';

/// Animated overlay shown on top of the text field while audio is recording or previewing.
///
/// Internally wraps an [Obx] subscribed to [controller.showRecording] and
/// [voicePreviewFor(controller)] so only this subtree rebuilds on recording state changes.
class TextFieldRecordingOverlay extends StatefulWidget {
  const TextFieldRecordingOverlay({
    super.key,
    required this.controller,
    this.recorderController,
    this.audioRecorder,
  });

  final ConversationViewController controller;
  final RecorderController? recorderController;
  final AudioRecorder? audioRecorder;

  @override
  State<TextFieldRecordingOverlay> createState() => _TextFieldRecordingOverlayState();
}

class _TextFieldRecordingOverlayState extends State<TextFieldRecordingOverlay> {
  final ValueNotifier<int> _playPauseSignal = ValueNotifier<int>(0);
  final FocusNode _shortcutFocusNode = FocusNode(debugLabel: 'voice-recording-overlay');
  bool _wasRecording = false;
  bool _hadPreview = false;

  @override
  void dispose() {
    _playPauseSignal.dispose();
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  void _ensureShortcutFocus(bool isRecording, bool hasPreview) {
    if (!(kIsWeb || kIsDesktop)) return;
    if (isRecording && (!_wasRecording || (hasPreview && !_hadPreview))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.controller.showRecording.value && !_shortcutFocusNode.hasFocus) {
          _shortcutFocusNode.requestFocus();
        }
      });
    }
    _wasRecording = isRecording;
    _hadPreview = hasPreview;
  }

  void _cancelRecording() {
    final preview = voicePreviewFor(widget.controller).value;
    if (preview != null) {
      preview.onDiscard();
      return;
    }
    widget.controller.showRecording.value = false;
    if (kIsWeb || kIsDesktop) {
      unawaited(widget.audioRecorder?.cancel().catchError((_) {}));
    } else {
      unawaited(widget.recorderController?.stop().catchError((_) => null));
    }
  }

  @override
  Widget build(BuildContext context) {
    final previewRx = voicePreviewFor(widget.controller);
    return Obx(() {
      final isRecording = widget.controller.showRecording.value;
      final preview = previewRx.value;
      _ensureShortcutFocus(isRecording, preview != null);
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
              : CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    const SingleActivator(LogicalKeyboardKey.escape): _cancelRecording,
                    if (preview != null) ...{
                      const SingleActivator(LogicalKeyboardKey.space): () => _playPauseSignal.value++,
                      const SingleActivator(LogicalKeyboardKey.enter): () => unawaited(preview.onSend()),
                    },
                  },
                  child: Focus(
                    focusNode: _shortcutFocusNode,
                    autofocus: true,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // Reserve the right 48px on iOS during active recording so the inline
                        // Stop button inside TextFieldComponent's suffixIcon remains unobstructed.
                        final double rightReserve = (iOS && preview == null) ? 48.0 : 0.0;
                        final double availableWidth =
                            math.max(0.0, constraints.maxWidth - rightReserve);
                        final double availableHeight = constraints.maxHeight;
                        final double overlayHeight = iOS
                            ? availableHeight.clamp(0.0, 48.0)
                            : availableHeight;

                        final Widget bar = AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: kIsDesktop
                              ? _DesktopRecordingBar(
                                  key: ValueKey(preview != null ? 'desktop-preview' : 'desktop-record'),
                                  iOS: iOS,
                                  audioRecorder: widget.audioRecorder,
                                  onCancel: _cancelRecording,
                                  preview: preview,
                                  playPauseSignal: _playPauseSignal,
                                )
                              : VoiceMessageRecorder(
                                  key: ValueKey(preview != null ? 'mobile-preview' : 'mobile-record'),
                                  recorderController: widget.recorderController,
                                  audioRecorder: widget.audioRecorder,
                                  textFieldSize: Size(availableWidth, overlayHeight),
                                  iOS: iOS,
                                  samsung: samsung,
                                  onCancel: _cancelRecording,
                                  preview: preview,
                                  playPauseSignal: _playPauseSignal,
                                ),
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
                                    borderRadius: preview == null
                                        ? const BorderRadius.horizontal(left: Radius.circular(19))
                                        : BorderRadius.circular(20),
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
                ),
        ),
      );
    });
  }
}

class _DesktopRecordingBar extends StatefulWidget {
  const _DesktopRecordingBar({
    super.key,
    required this.iOS,
    required this.onCancel,
    this.audioRecorder,
    this.preview,
    this.playPauseSignal,
  });

  final bool iOS;
  final AudioRecorder? audioRecorder;
  final VoidCallback onCancel;
  final VoicePreviewData? preview;
  final Listenable? playPauseSignal;

  @override
  State<_DesktopRecordingBar> createState() => _DesktopRecordingBarState();
}

class _DesktopRecordingBarState extends State<_DesktopRecordingBar> {
  DateTime? _segmentStart = DateTime.now();
  Duration _accumulated = Duration.zero;
  Duration _elapsed = Duration.zero;
  bool _isPaused = false;
  Timer? _timer;
  double _dragOffset = 0.0;
  bool _cancelTriggered = false;

  @override
  void initState() {
    super.initState();
    if (widget.preview == null) {
      _startTimer();
    }
  }

  @override
  void didUpdateWidget(covariant _DesktopRecordingBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview == null && widget.preview != null) {
      _timer?.cancel();
      _timer = null;
    } else if (oldWidget.preview != null && widget.preview == null && !_isPaused) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || _isPaused) return;
      setState(() {
        _elapsed = _accumulated + (_segmentStart != null ? DateTime.now().difference(_segmentStart!) : Duration.zero);
      });
    });
  }

  Future<void> _togglePauseResume() async {
    final nextPaused = !_isPaused;
    if (nextPaused) {
      if (_segmentStart != null) {
        _accumulated += DateTime.now().difference(_segmentStart!);
        _segmentStart = null;
      }
      _timer?.cancel();
      try {
        await widget.audioRecorder?.pause();
      } catch (_) {}
    } else {
      _segmentStart = DateTime.now();
      if (widget.preview == null) {
        _startTimer();
      }
      try {
        await widget.audioRecorder?.resume();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _isPaused = nextPaused;
      _elapsed = _accumulated;
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

        if (widget.preview != null) {
          final preview = widget.preview!;
          final compactButtons = w < 220;
          final btnSize = compactButtons ? 32.0 : 40.0;
          return Padding(
            key: const ValueKey('voice-preview-bar'),
            padding: EdgeInsetsDirectional.only(start: widget.iOS ? 6 : 8, end: widget.iOS ? 6 : 8),
            child: Row(
              children: [
                IconButton(
                  key: const Key('voice-preview-delete-button'),
                  tooltip: 'Delete recording',
                  style: IconButton.styleFrom(
                    padding: EdgeInsets.zero,
                    fixedSize: Size(btnSize, btnSize),
                    minimumSize: Size(btnSize, btnSize),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  icon: Icon(Icons.delete_outline, size: compactButtons ? 19 : 22, color: cs.error),
                  onPressed: preview.onDiscard,
                ),
                Expanded(
                  child: AudioPlayer(
                    key: Key('AudioMessage-${preview.path}'),
                    file: preview.file,
                    attachment: null,
                    compact: true,
                    playPauseSignal: widget.playPauseSignal,
                  ),
                ),
                IconButton(
                  key: const Key('voice-preview-restart-button'),
                  tooltip: 'Restart recording',
                  style: IconButton.styleFrom(
                    padding: EdgeInsets.zero,
                    fixedSize: Size(btnSize, btnSize),
                    minimumSize: Size(btnSize, btnSize),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  icon: Icon(Icons.refresh, size: compactButtons ? 19 : 22, color: cs.onSurfaceVariant),
                  onPressed: preview.onRestart,
                ),
                const SizedBox(width: 4),
                IconButton.filled(
                  key: const Key('voice-preview-send-button'),
                  tooltip: 'Send voice message',
                  style: IconButton.styleFrom(
                    padding: EdgeInsets.zero,
                    fixedSize: Size(btnSize, btnSize),
                    minimumSize: Size(btnSize, btnSize),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  icon: Icon(Icons.send_rounded, size: compactButtons ? 18 : 20),
                  onPressed: preview.onSend,
                ),
              ],
            ),
          );
        }

        final pauseButton = IconButton(
          key: const Key('voice-record-pause-button'),
          tooltip: _isPaused ? 'Resume recording' : 'Pause recording',
          style: IconButton.styleFrom(
            padding: EdgeInsets.zero,
            fixedSize: Size(w < 200 ? 32 : 40, w < 200 ? 32 : 40),
            minimumSize: Size(w < 200 ? 32 : 40, w < 200 ? 32 : 40),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(
            _isPaused ? Icons.mic_rounded : Icons.pause_rounded,
            size: w < 200 ? 19 : 22,
            color: _isPaused ? cs.primary : cs.onSurfaceVariant,
          ),
          onPressed: _togglePauseResume,
        );

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
        final showPause = w >= 120;
        final showDot = w >= 132;
        final showIndicatorRing = !widget.iOS && w >= 240 && h >= 40;
        final showLabel = w >= 188;
        final showSlideHint = w >= 380;

        final Widget dotWidget = Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isPaused ? cs.onSurfaceVariant : cs.error,
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
                          color: (_isPaused ? cs.onSurfaceVariant : cs.error).withValues(alpha: 0.14),
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
                        _isPaused ? 'Paused' : 'Recording',
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
                  if (showPause) pauseButton,
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
