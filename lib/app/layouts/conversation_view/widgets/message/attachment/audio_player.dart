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

class AudioPlayer extends StatefulWidget {
  final PlatformFile file;
  final Attachment? attachment;
  final String? transcript;
  final ConversationViewController? controller;

  const AudioPlayer({
    super.key,
    required this.file,
    required this.attachment,
    this.transcript,
    this.controller,
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

  @override
  void initState() {
    super.initState();
    if (attachment != null) controller = cvController?.audioPlayers[attachment!.guid];
    initBytes();
  }

  @override
  void dispose() {
    if (attachment == null) {
      controller?.dispose();
    }
    animController.dispose();
    super.dispose();
  }

  void initBytes() async {
    if (attachment != null) controller = cvController?.audioPlayers[attachment!.guid];
    if (controller == null) {
      controller = PlayerController()
        ..addListener(() {
          maxDuration.value = controller!.maxDuration;
        });
      controller!.onPlayerStateChanged.listen((event) {
        if ((controller!.playerState == PlayerState.paused || controller!.playerState == PlayerState.stopped) &&
            animController.value > 0) {
          animController.reverse();
        }
        playerState.value = controller!.playerState;
      });
      await controller!.preparePlayer(path: file.path!);
      if (attachment != null) cvController?.audioPlayers[attachment!.guid!] = controller!;
    }
    playerState.value = controller?.playerState;
    maxDuration.value = controller?.maxDuration ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
        padding: const EdgeInsets.all(5),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () async {
                      if (controller == null) return;
                      if (playerState.value == PlayerState.playing) {
                        animController.reverse();
                        await controller!.pausePlayer();
                      } else {
                        animController.forward();
                        controller!.setFinishMode(finishMode: FinishMode.pause);
                        await controller!.startPlayer();
                      }
                    },
                    icon: AnimatedIcon(
                      icon: AnimatedIcons.play_pause,
                      progress: animController,
                    ),
                    color: context.theme.colorScheme.onSurfaceVariant,
                    visualDensity: VisualDensity.compact,
                  ),
                  Obx(() => maxDuration.value == 0
                      ? SizedBox(width: NavigationSvc.width(context) * 0.25)
                      : AudioFileWaveforms(
                          size: Size(NavigationSvc.width(context) * 0.20, 40),
                          playerController: controller!,
                          padding: EdgeInsets.zero,
                          playerWaveStyle: PlayerWaveStyle(
                              fixedWaveColor:
                                  context.theme.colorScheme.surfaceContainerHighest.oppositeLightenOrDarken(20),
                              liveWaveColor: context.theme.colorScheme.onSurfaceVariant,
                              waveCap: StrokeCap.square,
                              waveThickness: 2,
                              seekLineThickness: 2,
                              showSeekLine: false),
                        )),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Center(
                      heightFactor: 1,
                      child: Obx(() => Text(prettyDuration(Duration(milliseconds: maxDuration.value)),
                          style: context.theme.textTheme.labelLarge!)),
                    ),
                  ),
                ],
              ),
              if (widget.transcript != null) _Transcript(widget.transcript!),
            ]));
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
  final position = Duration.zero.obs;
  final duration = Duration.zero.obs;

  @override
  void initState() {
    super.initState();
    if (attachment != null) controller = cvController?.audioPlayersDesktop[attachment!.guid];
    initBytes();
  }

  @override
  void dispose() {
    if (attachment == null) {
      controller?.dispose();
    }
    animController.dispose();
    super.dispose();
  }

  void initBytes() async {
    if (attachment != null) controller = cvController?.audioPlayersDesktop[attachment!.guid];
    if (controller == null) {
      controller = Player()
        ..stream.position.listen((pos) => position.value = pos)
        ..stream.duration.listen((dur) => duration.value = dur)
        ..stream.playing.listen((playing) => isPlaying.value = playing)
        ..stream.completed.listen((bool completed) async {
          if (completed) {
            await controller!.seek(Duration.zero);
            if (Platform.isLinux) {
              await controller!.pause();
            }
            animController.reverse();
          }
        });
      await controller!.setPlaylistMode(PlaylistMode.none);
      await controller!.open(Media(file.path!), play: false);
      if (attachment != null) cvController?.audioPlayersDesktop[attachment!.guid!] = controller!;
    }
    isPlaying.value = controller?.state.playing ?? false;
    position.value = controller?.state.position ?? Duration.zero;
    duration.value = controller?.state.duration ?? Duration.zero;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
        padding: const EdgeInsets.all(5),
        child: IntrinsicWidth(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: () async {
                      if (controller == null) return;
                      if (isPlaying.value) {
                        animController.reverse();
                        await controller!.pause();
                      } else {
                        animController.forward();
                        await controller!.play();
                      }
                    },
                    icon: AnimatedIcon(
                      icon: AnimatedIcons.play_pause,
                      progress: animController,
                    ),
                    color: context.theme.colorScheme.onSurfaceVariant,
                    visualDensity: VisualDensity.compact,
                  ),
                  if (controller != null)
                    Obx(() => SizedBox(
                          height: 30,
                          child: Slider(
                            value: position.value.inSeconds.toDouble(),
                            onChanged: (double value) {
                              controller!.seek(Duration(seconds: value.toInt()));
                            },
                            min: 0,
                            max: duration.value.inSeconds.toDouble(),
                          ),
                        )),
                  Obx(() => Padding(
                        padding: const EdgeInsets.only(left: 10, right: 16),
                        child: Text("${prettyDuration(position.value)} / ${prettyDuration(duration.value)}"),
                      ))
                ],
              ),
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

  @override
  void initState() {
    super.initState();
    _controller = WebAudioController(file: widget.file, attachment: widget.attachment)
      ..addListener(_onControllerUpdate);
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    if (!_controller.isPlaying && animController.value > 0) {
      animController.reverse();
    } else if (_controller.isPlaying && animController.value == 0) {
      animController.forward();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    animController.dispose();
    super.dispose();
  }

  static const _speeds = [1.0, 1.5, 2.0];

  void _cycleSpeed() {
    final idx = _speeds.indexOf(_controller.playbackRate);
    final next = _speeds[(idx + 1) % _speeds.length];
    _controller.setPlaybackRate(next);
  }

  String _speedLabel(double rate) {
    return rate == rate.roundToDouble() ? '${rate.toInt()}x' : '${rate}x';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = context.theme.colorScheme;
    if (_controller.hasError) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton.filledTonal(
                  onPressed: _controller.togglePlayPause,
                  padding: EdgeInsets.zero,
                  icon: AnimatedIcon(
                    icon: AnimatedIcons.play_pause,
                    progress: animController,
                  ),
                  color: colors.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
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
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  "${prettyDuration(_controller.position)} / ${prettyDuration(_controller.duration)}",
                  style: context.theme.textTheme.labelMedium,
                ),
              ),
              Material(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: _cycleSpeed,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      _speedLabel(_controller.playbackRate),
                      style: context.theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (widget.transcript != null) _Transcript(widget.transcript!),
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
