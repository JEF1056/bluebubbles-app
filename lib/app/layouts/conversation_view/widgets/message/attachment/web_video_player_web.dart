import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/web_video_player.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mime_type/mime_type.dart';
import 'package:web/web.dart' as web;

class WebVideoController extends ChangeNotifier {
  web.HTMLVideoElement? _video;
  bool _isPlaying = false;
  bool _isMuted = false;
  double? _aspectRatio;

  bool get isPlaying => _isPlaying;
  bool get isMuted => _isMuted;
  double? get aspectRatio => _aspectRatio;

  void _attach(web.HTMLVideoElement video) {
    _video = video;
    _isMuted = video.muted;
    _isPlaying = !video.paused && !video.ended;
  }

  void _detach(web.HTMLVideoElement video) {
    if (identical(_video, video)) {
      _video = null;
    }
  }

  void _updateState({bool? isPlaying, bool? isMuted, double? aspectRatio}) {
    var changed = false;
    if (isPlaying != null && _isPlaying != isPlaying) {
      _isPlaying = isPlaying;
      changed = true;
    }
    if (isMuted != null && _isMuted != isMuted) {
      _isMuted = isMuted;
      changed = true;
    }
    if (aspectRatio != null && _aspectRatio != aspectRatio) {
      _aspectRatio = aspectRatio;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> play() async {
    final v = _video;
    if (v == null) return;
    try {
      await v.play().toDart;
    } catch (_) {}
  }

  Future<void> pause() async {
    _video?.pause();
  }

  Future<void> togglePlayPause() async {
    final v = _video;
    if (v == null) return;
    if (v.paused || v.ended) {
      await play();
    } else {
      await pause();
    }
  }

  Future<void> setMuted(bool muted) async {
    final v = _video;
    if (v != null) v.muted = muted;
    _updateState(isMuted: muted);
  }

  Future<void> seek(Duration position) async {
    final v = _video;
    if (v != null) {
      v.currentTime = position.inMilliseconds / 1000.0;
    }
  }

  void requestFullscreen() {
    try {
      _video?.requestFullscreen();
    } catch (_) {}
  }
}

class WebVideoPlayer extends StatefulWidget {
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
  State<WebVideoPlayer> createState() => _WebVideoPlayerState();
}

class _WebVideoPlayerState extends State<WebVideoPlayer> {
  static int _nextViewId = 0;

  late final String _viewType;
  late final web.HTMLVideoElement _video;
  late WebVideoController _controller;
  late bool _ownsController;

  String? _resolvedUrl;
  bool _isObjectUrl = false;
  final List<StreamSubscription<web.Event>> _subs = [];

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? WebVideoController();
    _viewType = 'bb-web-video-${_nextViewId++}';

    _video = web.HTMLVideoElement()
      ..controls = widget.controls
      ..autoplay = widget.autoplay
      ..muted = widget.muted
      ..loop = widget.loop
      ..playsInline = true
      ..preload = 'metadata';

    _video.setAttribute('playsinline', 'true');
    _video.setAttribute('webkit-playsinline', 'true');

    _video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = widget.fit == BoxFit.cover ? 'cover' : 'contain'
      ..backgroundColor = 'transparent';
    if (!widget.controls) {
      _video.style.pointerEvents = 'none';
    }
    if (widget.posterUrl != null && widget.posterUrl!.isNotEmpty) {
      _video.poster = widget.posterUrl!;
    }

    _resolveSource();
    if (_resolvedUrl != null && _resolvedUrl!.isNotEmpty) {
      _video.src = _resolvedUrl!;
    }

    _controller._attach(_video);
    _attachListeners();

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _video);
  }

  void _resolveSource() {
    if (widget.srcUrl != null && widget.srcUrl!.isNotEmpty) {
      _resolvedUrl = widget.srcUrl;
      _isObjectUrl = false;
      return;
    }

    final bytes = widget.file?.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      final mimeType = widget.attachment?.mimeType ??
          (widget.file?.name != null ? mime(widget.file!.name) : null) ??
          'video/mp4';
      final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
      _resolvedUrl = web.URL.createObjectURL(blob);
      _isObjectUrl = true;
      return;
    }

    final guid = widget.attachment?.guid;
    if (guid != null && guid.isNotEmpty && HttpSvc.origin.isNotEmpty) {
      _resolvedUrl = buildWebAttachmentStreamUrl(
        apiRoot: HttpSvc.apiRoot,
        guid: guid,
        authGuid: SettingsSvc.settings.guidAuthKey.value,
      );
      _isObjectUrl = false;
      return;
    }

    final path = widget.file?.path;
    if (path != null && path.isNotEmpty) {
      _resolvedUrl = path;
      _isObjectUrl = false;
    }
  }

  void _attachListeners() {
    _subs.add(web.EventStreamProviders.loadedMetadataEvent.forTarget(_video).listen((_) {
      final w = _video.videoWidth;
      final h = _video.videoHeight;
      if (w > 0 && h > 0) {
        final ratio = w / h;
        _controller._updateState(aspectRatio: ratio);
        widget.onAspectRatioChanged?.call(ratio);
      }
    }));

    _subs.add(web.EventStreamProviders.playEvent.forTarget(_video).listen((_) {
      _controller._updateState(isPlaying: true);
      widget.onPlayingChanged?.call(true);
    }));

    _subs.add(web.EventStreamProviders.pauseEvent.forTarget(_video).listen((_) {
      _controller._updateState(isPlaying: false);
      widget.onPlayingChanged?.call(false);
    }));

    _subs.add(web.EventStreamProviders.endedEvent.forTarget(_video).listen((_) {
      _controller._updateState(isPlaying: false);
      widget.onPlayingChanged?.call(false);
      widget.onEnded?.call();
    }));

    _subs.add(web.EventStreamProviders.volumeChangeEvent.forTarget(_video).listen((_) {
      _controller._updateState(isMuted: _video.muted);
    }));
  }

  @override
  void didUpdateWidget(covariant WebVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller._detach(_video);
      if (_ownsController) {
        _controller.dispose();
      }
      _ownsController = widget.controller == null;
      _controller = widget.controller ?? WebVideoController();
      _controller._attach(_video);
    }
    if (oldWidget.muted != widget.muted) {
      _video.muted = widget.muted;
      _controller._updateState(isMuted: widget.muted);
    }
    if (oldWidget.loop != widget.loop) {
      _video.loop = widget.loop;
    }
    if (oldWidget.posterUrl != widget.posterUrl) {
      _video.poster = widget.posterUrl ?? '';
    }
    if (oldWidget.controls != widget.controls) {
      _video.controls = widget.controls;
      _video.style.pointerEvents = widget.controls ? 'auto' : 'none';
    }
    if (oldWidget.fit != widget.fit) {
      _video.style.objectFit = widget.fit == BoxFit.cover ? 'cover' : 'contain';
    }
    if (oldWidget.srcUrl != widget.srcUrl ||
        oldWidget.file?.bytes != widget.file?.bytes ||
        oldWidget.file?.path != widget.file?.path ||
        oldWidget.attachment?.guid != widget.attachment?.guid) {
      if (_isObjectUrl && _resolvedUrl != null) {
        web.URL.revokeObjectURL(_resolvedUrl!);
      }
      _resolvedUrl = null;
      _isObjectUrl = false;
      _resolveSource();
      _video.src = _resolvedUrl ?? '';
      _video.load();
    }
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _video.pause();
    _video.removeAttribute('src');
    _video.load();
    if (_isObjectUrl && _resolvedUrl != null) {
      web.URL.revokeObjectURL(_resolvedUrl!);
      _resolvedUrl = null;
    }
    _controller._detach(_video);
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  bool _isVideoFocused() {
    try {
      return web.document.activeElement == _video || _video.matches(':focus-within');
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = HtmlElementView(viewType: _viewType);
    if (!widget.enableKeyboardShortcuts) return view;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () {
          // Native <video controls> handles Space itself when focused; skip to avoid double-toggling.
          if (widget.controls && _isVideoFocused()) return;
          _controller.togglePlayPause();
        },
      },
      child: Focus(
        autofocus: true,
        child: view,
      ),
    );
  }
}
