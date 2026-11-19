import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';

class WebVideoController extends ChangeNotifier {
  bool get isPlaying => false;
  bool get isMuted => false;
  double? get aspectRatio => null;

  Future<void> play() async {}
  Future<void> pause() async {}
  Future<void> togglePlayPause() async {}
  Future<void> setMuted(bool muted) async {}
  Future<void> seek(Duration position) async {}
  void requestFullscreen() {}
}

class WebVideoPlayer extends StatelessWidget {
  const WebVideoPlayer({
    super.key,
    this.file,
    this.attachment,
    this.srcUrl,
    this.controller,
    this.autoplay = false,
    this.muted = false,
    this.controls = true,
    this.loop = false,
    this.fit = BoxFit.cover,
    this.posterUrl,
    this.enableKeyboardShortcuts = false,
    this.onEnded,
    this.onPlayingChanged,
    this.onAspectRatioChanged,
  });

  final PlatformFile? file;
  final Attachment? attachment;
  final String? srcUrl;
  final WebVideoController? controller;
  final bool autoplay;
  final bool muted;
  final bool controls;
  final bool loop;
  final BoxFit fit;
  final String? posterUrl;
  final bool enableKeyboardShortcuts;
  final VoidCallback? onEnded;
  final ValueChanged<bool>? onPlayingChanged;
  final ValueChanged<double>? onAspectRatioChanged;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
