import 'dart:async';
import 'dart:js_interop';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/web_audio_player.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:mime_type/mime_type.dart';
import 'package:web/web.dart' as web;

class WebAudioController extends ChangeNotifier {
  WebAudioController({
    required PlatformFile file,
    Attachment? attachment,
  }) {
    _init(file, attachment);
  }

  late final web.HTMLAudioElement _audio;
  final List<StreamSubscription<web.Event>> _subs = [];
  String? _resolvedUrl;
  bool _isObjectUrl = false;
  bool _disposed = false;

  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _hasError = false;
  double _playbackRate = 1.0;

  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get hasError => _hasError;
  double get playbackRate => _playbackRate;

  void _init(PlatformFile file, Attachment? attachment) {
    _audio = web.HTMLAudioElement()..preload = 'metadata';

    final caf = isCafAudio(
      mimeType: attachment?.mimeType,
      fileName: file.name,
      transferName: attachment?.transferName,
    );

    final guid = attachment?.guid;
    // Browsers cannot decode raw CAF bytes; stream with ?format=m4a when a server GUID exists.
    if (caf && guid != null && guid.isNotEmpty && HttpSvc.origin.isNotEmpty) {
      _resolvedUrl = buildWebAudioStreamUrl(
        apiRoot: HttpSvc.apiRoot,
        guid: guid,
        authGuid: SettingsSvc.settings.guidAuthKey.value,
        isCaf: true,
      );
      _isObjectUrl = false;
    } else if (file.bytes != null && file.bytes!.isNotEmpty) {
      final mimeType = attachment?.mimeType ?? mime(file.name) ?? 'audio/mp4';
      final blob = web.Blob(<JSAny>[file.bytes!.toJS].toJS, web.BlobPropertyBag(type: mimeType));
      _resolvedUrl = web.URL.createObjectURL(blob);
      _isObjectUrl = true;
    } else if (guid != null && guid.isNotEmpty && HttpSvc.origin.isNotEmpty) {
      _resolvedUrl = buildWebAudioStreamUrl(
        apiRoot: HttpSvc.apiRoot,
        guid: guid,
        authGuid: SettingsSvc.settings.guidAuthKey.value,
        isCaf: caf,
      );
      _isObjectUrl = false;
    } else if (file.path != null && file.path!.isNotEmpty) {
      _resolvedUrl = file.path;
      _isObjectUrl = false;
    }

    if (_resolvedUrl != null && _resolvedUrl!.isNotEmpty) {
      _audio.src = _resolvedUrl!;
    }

    _subs.add(web.EventStreamProviders.loadedMetadataEvent.forTarget(_audio).listen((_) {
      _syncDuration();
    }));
    _subs.add(web.EventStreamProviders.durationChangeEvent.forTarget(_audio).listen((_) {
      _syncDuration();
    }));
    _subs.add(web.EventStreamProviders.timeUpdateEvent.forTarget(_audio).listen((_) {
      final secs = _audio.currentTime;
      if (secs.isFinite && secs >= 0) {
        _position = Duration(milliseconds: (secs * 1000).round());
        _notify();
      }
    }));
    _subs.add(web.EventStreamProviders.playEvent.forTarget(_audio).listen((_) {
      _isPlaying = true;
      _notify();
    }));
    _subs.add(web.EventStreamProviders.pauseEvent.forTarget(_audio).listen((_) {
      _isPlaying = false;
      _notify();
    }));
    _subs.add(web.EventStreamProviders.endedEvent.forTarget(_audio).listen((_) {
      _isPlaying = false;
      _position = Duration.zero;
      _audio.currentTime = 0;
      _notify();
    }));
    _subs.add(web.EventStreamProviders.errorEvent.forTarget(_audio).listen((_) {
      _hasError = true;
      _isPlaying = false;
      _notify();
    }));
  }

  void _syncDuration() {
    final secs = _audio.duration;
    if (secs.isFinite && secs > 0) {
      _duration = Duration(milliseconds: (secs * 1000).round());
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> play() async {
    if (_disposed) return;
    try {
      await _audio.play().toDart;
    } catch (_) {}
  }

  Future<void> pause() async {
    if (_disposed) return;
    _audio.pause();
  }

  Future<void> togglePlayPause() async {
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration position) async {
    if (_disposed) return;
    final secs = position.inMilliseconds / 1000.0;
    _audio.currentTime = secs;
    _position = position;
    _notify();
  }

  void setPlaybackRate(double rate) {
    if (_disposed) return;
    _playbackRate = rate;
    _audio.playbackRate = rate;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _audio.pause();
    _audio.removeAttribute('src');
    _audio.load();
    if (_isObjectUrl && _resolvedUrl != null) {
      web.URL.revokeObjectURL(_resolvedUrl!);
      _resolvedUrl = null;
    }
    super.dispose();
  }
}

web.AudioContext? _sharedAudioCtx;
bool _unlockListenersInstalled = false;
int _activeWebSoundCount = 0;
Timer? _suspendSharedCtxTimer;
final Map<String, Future<web.AudioBuffer?>> _decodedBuffers = <String, Future<web.AudioBuffer?>>{};
final Map<String, Future<String?>> _assetBlobUrls = <String, Future<String?>>{};

void _scheduleSharedCtxSuspend() {
  _suspendSharedCtxTimer?.cancel();
  _suspendSharedCtxTimer = Timer(const Duration(milliseconds: 300), () {
    if (_activeWebSoundCount > 0) return;
    final ctx = _sharedAudioCtx;
    if (ctx != null && ctx.state == 'running') {
      try {
        unawaited(ctx.suspend().toDart.then((_) {}, onError: (_) {}));
      } catch (_) {}
    }
  });
}

void _ensureAudioUnlock() {
  if (_unlockListenersInstalled) return;
  _unlockListenersInstalled = true;

  late final web.EventListener jsUnlock;
  jsUnlock = ((web.Event _) {
    web.window.removeEventListener('pointerdown', jsUnlock);
    web.window.removeEventListener('keydown', jsUnlock);
    try {
      final ctx = _sharedAudioCtx ??= web.AudioContext();
      if (ctx.state == 'suspended') {
        unawaited(ctx.resume().toDart.then((_) {
          if (_activeWebSoundCount == 0) _scheduleSharedCtxSuspend();
        }, onError: (_) {}));
      } else if (_activeWebSoundCount == 0) {
        _scheduleSharedCtxSuspend();
      }
    } catch (_) {}
  }).toJS;

  // Synchronous DOM listeners run inside the browser user-gesture turn (required by Safari).
  web.window.addEventListener('pointerdown', jsUnlock);
  web.window.addEventListener('keydown', jsUnlock);
}

Future<web.AudioBuffer?> _loadDecodedBuffer(web.AudioContext ctx, String assetPath) {
  return _decodedBuffers[assetPath] ??= () async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      // Copy into a standalone JSArrayBuffer so decodeAudioData detaches only this buffer.
      final copy = Uint8List.fromList(bytes);
      return await ctx.decodeAudioData(copy.buffer.toJS).toDart;
    } catch (_) {
      _decodedBuffers.remove(assetPath);
      return null;
    }
  }();
}

Future<String?> _loadAssetBlobUrl(String assetPath) {
  return _assetBlobUrls[assetPath] ??= () async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: 'audio/wav'));
      return web.URL.createObjectURL(blob);
    } catch (_) {
      _assetBlobUrls.remove(assetPath);
      return null;
    }
  }();
}

Future<void> playWebSoundAsset(
  String assetPath, {
  double volume = 1.0,
  String? customUrl,
}) async {
  final clampedVol = volume.clamp(0.0, 1.0);
  if (clampedVol <= 0) return;

  _ensureAudioUnlock();

  if (customUrl != null &&
      (customUrl.startsWith('http://') ||
          customUrl.startsWith('https://') ||
          customUrl.startsWith('blob:') ||
          customUrl.startsWith('data:'))) {
    try {
      final audio = web.HTMLAudioElement()
        ..src = customUrl
        ..volume = clampedVol;
      await audio.play().toDart;
      return;
    } catch (_) {}
  }

  try {
    _suspendSharedCtxTimer?.cancel();
    final ctx = _sharedAudioCtx ??= web.AudioContext();
    if (ctx.state == 'suspended') {
      await ctx.resume().toDart;
    }
    if (ctx.state == 'running') {
      final buffer = await _loadDecodedBuffer(ctx, assetPath);
      if (buffer != null) {
        final gain = ctx.createGain();
        gain.gain.value = clampedVol;
        gain.connect(ctx.destination);

        final source = ctx.createBufferSource();
        source.buffer = buffer;
        source.connect(gain);

        _activeWebSoundCount++;
        var finished = false;
        Timer? fallbackTimer;
        late final web.EventListener onEnded;
        void finishSound() {
          if (finished) return;
          finished = true;
          fallbackTimer?.cancel();
          try {
            source.removeEventListener('ended', onEnded);
          } catch (_) {}
          try {
            source.disconnect();
          } catch (_) {}
          try {
            gain.disconnect();
          } catch (_) {}
          if (_activeWebSoundCount > 0) _activeWebSoundCount--;
          if (_activeWebSoundCount == 0) _scheduleSharedCtxSuspend();
        }

        onEnded = ((web.Event _) => finishSound()).toJS;
        source.addEventListener('ended', onEnded);
        final durationMs = (buffer.duration * 1000).ceil().clamp(250, 10000);
        fallbackTimer = Timer(Duration(milliseconds: durationMs + 500), finishSound);

        try {
          source.start();
        } catch (_) {
          finishSound();
          rethrow;
        }
        return;
      }
    }
    if (_activeWebSoundCount == 0) _scheduleSharedCtxSuspend();
  } catch (_) {
    if (_activeWebSoundCount == 0) _scheduleSharedCtxSuspend();
  }

  try {
    final blobUrl = await _loadAssetBlobUrl(assetPath);
    if (blobUrl != null) {
      final audio = web.HTMLAudioElement()
        ..src = blobUrl
        ..volume = clampedVol;
      await audio.play().toDart;
    }
  } catch (_) {}
}

Future<void> playWebChime({
  required bool isSend,
  double volume = 1.0,
  String? customUrl,
}) {
  return playWebSoundAsset(
    isSend ? 'assets/sounds/message_sent.wav' : 'assets/sounds/message_incoming.wav',
    volume: volume,
    customUrl: customUrl,
  );
}
