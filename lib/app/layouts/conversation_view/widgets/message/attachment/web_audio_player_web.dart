import 'dart:async';
import 'dart:js_interop';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/web_audio_player.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
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

  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get hasError => _hasError;

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
        ctx.resume();
      }
    } catch (_) {}
  }).toJS;

  // Synchronous DOM listeners run inside the browser user-gesture turn (required by Safari).
  web.window.addEventListener('pointerdown', jsUnlock);
  web.window.addEventListener('keydown', jsUnlock);
}

Future<void> playWebChime({
  required bool isSend,
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
    final ctx = _sharedAudioCtx ??= web.AudioContext();
    if (ctx.state != 'running') {
      // Never await ctx.resume() before first gesture — it hangs and stalls callers.
      if (ctx.state == 'suspended') ctx.resume();
      return;
    }
    final now = ctx.currentTime;
    final gain = ctx.createGain();
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(clampedVol * 0.2, now + 0.015);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.22);
    gain.connect(ctx.destination);

    final osc = ctx.createOscillator();
    osc.type = 'sine';
    // Subtle ascending two-tone for receive, crisp single-tone for send.
    osc.frequency.setValueAtTime(isSend ? 660.0 : 587.33, now);
    if (!isSend) {
      osc.frequency.setValueAtTime(880.0, now + 0.08);
    }
    osc.connect(gain);
    osc.start(now);
    osc.stop(now + 0.24);
  } catch (_) {}
}
