import 'dart:async';
import 'dart:math' as math;

import 'package:universal_io/io.dart';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/web_audio_player.dart';
import 'package:bluebubbles/platform/shims/native_media.dart';
import 'package:bluebubbles/helpers/helpers.dart';
// it does actually export (Web only)
// ignore: undefined_hidden_name
import 'package:bluebubbles/database/models.dart' hide PlayerState;
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';

@visibleForTesting
const List<double> audioPlaybackSpeeds = [1.0, 1.5, 2.0];

@visibleForTesting
double nextAudioPlaybackSpeed(double current) {
  final idx = audioPlaybackSpeeds.indexOf(current);
  return audioPlaybackSpeeds[(idx + 1) % audioPlaybackSpeeds.length];
}

@visibleForTesting
String formatAudioPlaybackSpeed(double rate) {
  return rate == rate.roundToDouble() ? '${rate.toInt()}x' : '${rate}x';
}

class AudioSpeedChip extends StatelessWidget {
  const AudioSpeedChip({
    super.key,
    required this.rate,
    required this.onTap,
  });

  final double rate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colorScheme;
    final label = formatAudioPlaybackSpeed(rate);
    return ActionChip(
      key: const Key('audio-speed-chip'),
      tooltip: 'Playback speed $label',
      onPressed: onTap,
      label: Text(
        label,
        style: context.theme.textTheme.labelSmall?.copyWith(
          color: colors.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
      backgroundColor: colors.secondaryContainer,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
  }
}

class AudioPlayer extends StatefulWidget {
  final PlatformFile file;
  final Attachment? attachment;
  final String? transcript;
  final ConversationViewController? controller;
  final bool compact;
  final Listenable? playPauseSignal;

  const AudioPlayer({
    super.key,
    required this.file,
    required this.attachment,
    this.transcript,
    this.controller,
    this.compact = false,
    this.playPauseSignal,
  });

  @override
  State<StatefulWidget> createState() => _createState();

  State<StatefulWidget> _createState() {
    if (kIsWeb) return _WebAudioPlayerState();
    if (kIsDesktop) return _DesktopAudioPlayerState();
    return _AudioPlayerState();
  }
}

class _AudioPlayerState extends State<AudioPlayer> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  Attachment? get attachment => widget.attachment;

  PlatformFile get file => widget.file;

  ConversationViewController? get cvController => widget.controller;

  PlayerController? controller;
  late final animController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 400), animationBehavior: AnimationBehavior.preserve);
  final playerState = Rx<PlayerState?>(null);
  final maxDuration = 0.obs;
  final currentPosition = 0.obs;
  final playbackRate = 1.0.obs;
  final hasError = false.obs;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<int>? _currentDurationSub;
  VoidCallback? _controllerListener;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    widget.playPauseSignal?.addListener(_handlePlayPauseSignal);
    if (attachment?.guid != null) controller = cvController?.audioPlayers[attachment!.guid];
    initBytes();
  }

  @override
  void didUpdateWidget(covariant AudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playPauseSignal != widget.playPauseSignal) {
      oldWidget.playPauseSignal?.removeListener(_handlePlayPauseSignal);
      widget.playPauseSignal?.addListener(_handlePlayPauseSignal);
    }
  }

  @override
  void dispose() {
    widget.playPauseSignal?.removeListener(_handlePlayPauseSignal);
    _playerStateSub?.cancel();
    _playerStateSub = null;
    _currentDurationSub?.cancel();
    _currentDurationSub = null;
    if (_controllerListener != null) {
      controller?.removeListener(_controllerListener!);
      _controllerListener = null;
    }
    if (_ownsController) {
      controller?.dispose();
    }
    animController.dispose();
    super.dispose();
  }

  void _handlePlayPauseSignal() {
    unawaited(_togglePlayPause());
  }

  Future<void> _togglePlayPause() async {
    if (controller == null) return;
    if (playerState.value == PlayerState.playing) {
      animController.reverse();
      await controller!.pausePlayer();
    } else {
      animController.forward();
      controller!.setFinishMode(finishMode: FinishMode.pause);
      await controller!.startPlayer();
    }
  }

  Future<void> _cycleSpeed() async {
    final next = nextAudioPlaybackSpeed(playbackRate.value);
    playbackRate.value = next;
    if (controller != null && !kIsWeb) {
      try {
        await (controller as dynamic).setRate(next);
      } catch (_) {}
    }
  }

  void initBytes() async {
    if (attachment?.guid != null) controller = cvController?.audioPlayers[attachment!.guid];
    if (controller == null) {
      final created = PlayerController();
      try {
        if (file.path == null || file.path!.isEmpty) {
          throw StateError('Audio file path is missing');
        }
        await created.preparePlayer(path: file.path!);
      } catch (_) {
        created.dispose();
        if (mounted) hasError.value = true;
        return;
      }
      final cached = cvController != null && attachment?.guid != null;
      if (!mounted) {
        created.dispose();
        return;
      }
      controller = created;
      _ownsController = !cached;
      if (cached) cvController!.audioPlayers[attachment!.guid!] = created;
    }
    final active = controller;
    if (active == null || !mounted) return;
    void listener() {
      if (!mounted) return;
      maxDuration.value = active.maxDuration;
    }
    active.addListener(listener);
    _controllerListener = listener;
    _playerStateSub = active.onPlayerStateChanged.listen((event) {
      if (!mounted) return;
      if ((active.playerState == PlayerState.paused || active.playerState == PlayerState.stopped) &&
          animController.value > 0) {
        animController.reverse();
      } else if (active.playerState == PlayerState.playing && animController.value < 1) {
        animController.forward();
      }
      playerState.value = active.playerState;
    });
    _currentDurationSub = active.onCurrentDurationChanged.listen((ms) {
      if (!mounted) return;
      currentPosition.value = ms;
    });
    playerState.value = active.playerState;
    maxDuration.value = active.maxDuration;
    animController.value = active.playerState == PlayerState.playing ? 1 : 0;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = context.theme.colorScheme;
    return Obx(() {
      if (hasError.value) {
        return Padding(
          padding: widget.compact ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 20, color: colors.error),
              const SizedBox(width: 8),
              Text('Audio unavailable', style: context.theme.textTheme.bodyMedium?.copyWith(color: colors.error)),
            ],
          ),
        );
      }

      final isPlaying = playerState.value == PlayerState.playing;
      final remainingMs = math.max(0, maxDuration.value - currentPosition.value);
      final remaining = Duration(milliseconds: remainingMs);
      final active = playerState.value == PlayerState.playing || playerState.value == PlayerState.paused;

      final waveform = LayoutBuilder(
        builder: (context, waveConstraints) {
          final maxW = waveConstraints.maxWidth.isFinite
              ? waveConstraints.maxWidth
              : NavigationSvc.width(context) * 0.22;
          final targetW = widget.compact
              ? maxW.clamp(40.0, 160.0)
              : math.min(maxW, NavigationSvc.width(context) * 0.22).clamp(40.0, 220.0);
          if (maxDuration.value == 0 || controller == null) {
            return SizedBox(width: targetW, height: 36);
          }
          return AudioFileWaveforms(
            size: Size(targetW, 36),
            playerController: controller!,
            padding: EdgeInsets.zero,
            playerWaveStyle: PlayerWaveStyle(
                fixedWaveColor: colors.surfaceContainerHighest.oppositeLightenOrDarken(20),
                liveWaveColor: colors.primary,
                waveCap: StrokeCap.square,
                waveThickness: 2,
                seekLineThickness: 2,
                showSeekLine: false),
          );
        },
      );

      return Padding(
          padding: widget.compact ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: widget.compact ? MainAxisSize.max : MainAxisSize.min,
                  children: [
                    IconButton.filledTonal(
                      key: const Key('audio-play-pause-button'),
                      tooltip: isPlaying ? 'Pause' : 'Play',
                      onPressed: _togglePlayPause,
                      style: IconButton.styleFrom(
                        fixedSize: const Size(40, 40),
                        minimumSize: const Size(40, 40),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      icon: AnimatedIcon(
                        icon: AnimatedIcons.play_pause,
                        progress: animController,
                      ),
                      color: colors.onSecondaryContainer,
                    ),
                    const SizedBox(width: 6),
                    if (widget.compact) Expanded(child: waveform) else Flexible(child: waveform),
                    const SizedBox(width: 6),
                    Text(
                      prettyDuration(remaining),
                      style: context.theme.textTheme.labelMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (!widget.compact && active)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: AudioSpeedChip(
                          rate: playbackRate.value,
                          onTap: _cycleSpeed,
                        ),
                      ),
                  ],
                ),
                if (widget.transcript != null && !widget.compact) _Transcript(widget.transcript!),
              ]));
    });
  }

  @override
  bool get wantKeepAlive => true;
}

class _DesktopAudioPlayerState extends State<AudioPlayer>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  Attachment? get attachment => widget.attachment;

  PlatformFile get file => widget.file;

  ConversationViewController? get cvController => widget.controller;

  Player? controller;
  late final animController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 400), animationBehavior: AnimationBehavior.preserve);
  final isPlaying = false.obs;
  final hasStarted = false.obs;
  final hasError = false.obs;
  final position = Duration.zero.obs;
  final duration = Duration.zero.obs;
  final playbackRate = 1.0.obs;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    widget.playPauseSignal?.addListener(_handlePlayPauseSignal);
    if (attachment?.guid != null) controller = cvController?.audioPlayersDesktop[attachment!.guid];
    initBytes();
  }

  @override
  void didUpdateWidget(covariant AudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playPauseSignal != widget.playPauseSignal) {
      oldWidget.playPauseSignal?.removeListener(_handlePlayPauseSignal);
      widget.playPauseSignal?.addListener(_handlePlayPauseSignal);
    }
  }

  @override
  void dispose() {
    widget.playPauseSignal?.removeListener(_handlePlayPauseSignal);
    _positionSub?.cancel();
    _positionSub = null;
    _durationSub?.cancel();
    _durationSub = null;
    _playingSub?.cancel();
    _playingSub = null;
    _completedSub?.cancel();
    _completedSub = null;
    if (_ownsController) {
      controller?.dispose();
    }
    animController.dispose();
    super.dispose();
  }

  void _handlePlayPauseSignal() {
    unawaited(_togglePlayPause());
  }

  Future<void> _togglePlayPause() async {
    if (controller == null) return;
    if (isPlaying.value) {
      animController.reverse();
      await controller!.pause();
    } else {
      hasStarted.value = true;
      animController.forward();
      await controller!.play();
    }
  }

  Future<void> _cycleSpeed() async {
    final next = nextAudioPlaybackSpeed(playbackRate.value);
    playbackRate.value = next;
    try {
      await controller?.setRate(next);
    } catch (_) {}
  }

  void initBytes() async {
    if (attachment?.guid != null) controller = cvController?.audioPlayersDesktop[attachment!.guid];
    if (controller == null) {
      final Player created;
      try {
        created = Player();
      } catch (_) {
        if (mounted) hasError.value = true;
        return;
      }
      try {
        if (file.path == null || file.path!.isEmpty) {
          throw StateError('Audio file path is missing');
        }
        await created.setPlaylistMode(PlaylistMode.none);
        await created.open(Media(file.path!), play: false);
      } catch (_) {
        await created.dispose();
        if (mounted) hasError.value = true;
        return;
      }
      final cached = cvController != null && attachment?.guid != null;
      if (!mounted) {
        await created.dispose();
        return;
      }
      controller = created;
      _ownsController = !cached;
      if (cached) cvController!.audioPlayersDesktop[attachment!.guid!] = created;
    }
    final active = controller;
    if (active == null || !mounted) return;
    _positionSub = active.stream.position.listen((pos) {
      if (!mounted) return;
      position.value = pos;
    });
    _durationSub = active.stream.duration.listen((dur) {
      if (!mounted) return;
      duration.value = dur;
    });
    _playingSub = active.stream.playing.listen((playing) {
      if (!mounted) return;
      isPlaying.value = playing;
      if (playing) {
        hasStarted.value = true;
        if (animController.value < 1) animController.forward();
      } else if (animController.value > 0) {
        animController.reverse();
      }
    });
    _completedSub = active.stream.completed.listen((bool completed) async {
      if (completed) {
        if (mounted) hasStarted.value = false;
        await active.seek(Duration.zero);
        if (Platform.isLinux) {
          await active.pause();
        }
        if (!mounted) return;
        animController.reverse();
      }
    });
    isPlaying.value = active.state.playing;
    position.value = active.state.position;
    duration.value = active.state.duration;
    animController.value = active.state.playing ? 1 : 0;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = context.theme.colorScheme;
    final row = Row(
      mainAxisSize: widget.compact ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Obx(() => IconButton.filledTonal(
              key: const Key('audio-play-pause-button'),
              tooltip: isPlaying.value ? 'Pause' : 'Play',
              onPressed: _togglePlayPause,
              style: IconButton.styleFrom(
                fixedSize: const Size(40, 40),
                minimumSize: const Size(40, 40),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
              icon: AnimatedIcon(
                icon: AnimatedIcons.play_pause,
                progress: animController,
              ),
              color: colors.onSecondaryContainer,
            )),
        const SizedBox(width: 4),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.compact ? double.infinity : 160),
            child: Obx(() {
              final maxSec = duration.value.inSeconds.toDouble();
              final posSec = position.value.inSeconds.toDouble().clamp(0.0, maxSec > 0 ? maxSec : 0.0);
              return SizedBox(
                height: 30,
                child: Slider(
                  value: posSec,
                  onChanged: controller != null && maxSec > 0
                      ? (double value) => controller!.seek(Duration(seconds: value.toInt()))
                      : null,
                  min: 0,
                  max: maxSec > 0 ? maxSec : 1.0,
                ),
              );
            }),
          ),
        ),
        Obx(() {
          final remainingMs = math.max(0, duration.value.inMilliseconds - position.value.inMilliseconds);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              prettyDuration(Duration(milliseconds: remainingMs)),
              style: context.theme.textTheme.labelMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          );
        }),
        if (!widget.compact)
          Obx(() {
            if (!isPlaying.value && !hasStarted.value) return const SizedBox.shrink();
            return AudioSpeedChip(
              rate: playbackRate.value,
              onTap: _cycleSpeed,
            );
          }),
      ],
    );

    return Padding(
        padding: widget.compact ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: widget.compact
            ? row
            : IntrinsicWidth(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      row,
                      if (widget.transcript != null) _NoIntrinsicWidth(child: _Transcript(widget.transcript!)),
                    ])));
  }

  @override
  bool get wantKeepAlive => true;
}

class _WebAudioPlayerState extends State<AudioPlayer>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  late final WebAudioController _controller;
  late final animController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 400), animationBehavior: AnimationBehavior.preserve);
  bool _hasStarted = false;

  @override
  void initState() {
    super.initState();
    widget.playPauseSignal?.addListener(_handlePlayPauseSignal);
    _controller = WebAudioController(file: widget.file, attachment: widget.attachment)
      ..addListener(_onControllerUpdate);
  }

  @override
  void didUpdateWidget(covariant AudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playPauseSignal != widget.playPauseSignal) {
      oldWidget.playPauseSignal?.removeListener(_handlePlayPauseSignal);
      widget.playPauseSignal?.addListener(_handlePlayPauseSignal);
    }
  }

  void _handlePlayPauseSignal() {
    unawaited(_controller.togglePlayPause());
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    if (_controller.isPlaying) {
      _hasStarted = true;
    } else if (_controller.position == Duration.zero) {
      _hasStarted = false;
    }
    if (!_controller.isPlaying && animController.value > 0) {
      animController.reverse();
    } else if (_controller.isPlaying && animController.value == 0) {
      animController.forward();
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.playPauseSignal?.removeListener(_handlePlayPauseSignal);
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    animController.dispose();
    super.dispose();
  }

  void _cycleSpeed() {
    final next = nextAudioPlaybackSpeed(_controller.playbackRate);
    _controller.setPlaybackRate(next);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = context.theme.colorScheme;
    if (_controller.hasError) {
      return Padding(
        padding: widget.compact ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 20, color: colors.error),
            const SizedBox(width: 8),
            Text('Audio unavailable', style: context.theme.textTheme.bodyMedium?.copyWith(color: colors.error)),
          ],
        ),
      );
    }

    final maxSec = _controller.duration.inSeconds.toDouble();
    final posSec = _controller.position.inSeconds.toDouble().clamp(0.0, maxSec > 0 ? maxSec : 0.0);
    final remainingMs = math.max(0, _controller.duration.inMilliseconds - _controller.position.inMilliseconds);

    return Padding(
      padding: widget.compact ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisSize: widget.compact ? MainAxisSize.max : MainAxisSize.min,
            children: [
              IconButton.filledTonal(
                key: const Key('audio-play-pause-button'),
                tooltip: _controller.isPlaying ? 'Pause' : 'Play',
                onPressed: _controller.togglePlayPause,
                style: IconButton.styleFrom(
                  fixedSize: const Size(40, 40),
                  minimumSize: const Size(40, 40),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                icon: AnimatedIcon(
                  icon: AnimatedIcons.play_pause,
                  progress: animController,
                ),
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: widget.compact ? double.infinity : 160),
                  child: SizedBox(
                    height: 30,
                    child: Slider(
                      value: posSec,
                      onChanged: maxSec > 0
                          ? (double value) => _controller.seek(Duration(seconds: value.toInt()))
                          : null,
                      min: 0,
                      max: maxSec > 0 ? maxSec : 1.0,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  prettyDuration(Duration(milliseconds: remainingMs)),
                  style: context.theme.textTheme.labelMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (!widget.compact && (_controller.isPlaying || _hasStarted))
                AudioSpeedChip(
                  rate: _controller.playbackRate,
                  onTap: _cycleSpeed,
                ),
            ],
          ),
          if (widget.transcript != null && !widget.compact) _Transcript(widget.transcript!),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

/// Reports no intrinsic width, so an [IntrinsicWidth] parent sizes to its other children and this one wraps
/// to fit them. Also keeps the transcript's scroll view out of intrinsic queries, which it doesn't support.
class _NoIntrinsicWidth extends SingleChildRenderObjectWidget {
  const _NoIntrinsicWidth({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderNoIntrinsicWidth();
}

class _RenderNoIntrinsicWidth extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;
}

/// A voice note's transcript. Long ones scroll inside a capped height instead of stretching the bubble.
class _Transcript extends StatefulWidget {
  const _Transcript(this.text);
  final String text;

  static const double maxHeight = 150;

  @override
  State<_Transcript> createState() => _TranscriptState();
}

class _TranscriptState extends State<_Transcript> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5, left: 10, right: 10, bottom: 5),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _Transcript.maxHeight),
        // Scrollbar insets its track by MediaQuery padding, which here is the conversation view's, not this box's
        child: MediaQuery.removePadding(
          context: context,
          removeLeft: true,
          removeTop: true,
          removeRight: true,
          removeBottom: true,
          child: Scrollbar(
            controller: _scrollController,
            child: SingleChildScrollView(
              controller: _scrollController,
              child: Text(widget.text, style: context.theme.textTheme.bodySmall),
            ),
          ),
        ),
      ),
    );
  }
}
