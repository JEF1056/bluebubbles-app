import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:bluebubbles/app/components/facetime/web_ringtone_wav.dart';
import 'package:web/web.dart' as web;

const String _legacyRingtoneKey = '__legacy__';

enum _LoopToneKind { ringtone, ringback }

class _ToneAsset {
  final Uint8List Function() _buildWav;
  Uint8List? _wavBytes;
  web.AudioBuffer? _buffer;
  Future<web.AudioBuffer?>? _decodeFuture;
  String? _blobUrl;

  _ToneAsset(this._buildWav);

  Uint8List wavBytes() => _wavBytes ??= _buildWav();

  String ensureBlobUrl() {
    if (_blobUrl != null) return _blobUrl!;
    final blob = web.Blob(<JSAny>[wavBytes().toJS].toJS, web.BlobPropertyBag(type: 'audio/wav'));
    _blobUrl = web.URL.createObjectURL(blob);
    return _blobUrl!;
  }

  Future<web.AudioBuffer?> loadBuffer(web.AudioContext ctx) {
    if (_buffer != null) return Future.value(_buffer);
    return _decodeFuture ??= () async {
      try {
        final copy = Uint8List.fromList(wavBytes());
        final decoded = await ctx.decodeAudioData(copy.buffer.toJS).toDart;
        _buffer = decoded;
        return decoded;
      } catch (_) {
        _decodeFuture = null;
        return null;
      }
    }();
  }
}

final _ringtoneAsset = _ToneAsset(buildIncomingRingtoneWavBytes);
final _ringbackAsset = _ToneAsset(buildOutgoingRingbackWavBytes);
final _callEndedAsset = _ToneAsset(buildCallEndedToneWavBytes);

_ToneAsset _assetFor(_LoopToneKind kind) =>
    kind == _LoopToneKind.ringtone ? _ringtoneAsset : _ringbackAsset;

web.AudioContext? _ringAudioCtx;
web.EventListener? _unlockListener;

_LoopToneKind? _activeKind;
String? _activeRingtoneKey;
double _activeVolume = 1.0;
int _ringGeneration = 0;
bool _needsGestureRetry = false;
Timer? _ringSafetyTimer;

web.AudioBufferSourceNode? _activeSource;
web.GainNode? _activeGain;
web.HTMLAudioElement? _activeHtmlAudio;

void _removeUnlockListeners() {
  final listener = _unlockListener;
  if (listener == null) return;
  _unlockListener = null;
  web.window.removeEventListener('pointerdown', listener);
  web.window.removeEventListener('keydown', listener);
}

void _ensureUnlockListeners() {
  if (_unlockListener != null || _activeRingtoneKey == null) return;

  void onGesture(web.Event _) {
    if (_activeRingtoneKey == null) {
      _removeUnlockListeners();
      return;
    }
    try {
      final ctx = _ringAudioCtx ??= web.AudioContext();
      if (ctx.state == 'suspended') {
        ctx.resume();
      }
    } catch (_) {}

    if (_activeRingtoneKey != null && _needsGestureRetry) {
      _needsGestureRetry = false;
      final gen = _ringGeneration;
      unawaited(_beginPlayback(gen));
    }
  }

  final listener = onGesture.toJS;
  _unlockListener = listener;
  web.window.addEventListener('pointerdown', listener);
  web.window.addEventListener('keydown', listener);
}

void _teardownActiveNodes() {
  final source = _activeSource;
  _activeSource = null;
  if (source != null) {
    try {
      source.stop();
    } catch (_) {}
    try {
      source.disconnect();
    } catch (_) {}
  }

  final gain = _activeGain;
  _activeGain = null;
  if (gain != null) {
    try {
      gain.disconnect();
    } catch (_) {}
  }

  final audio = _activeHtmlAudio;
  _activeHtmlAudio = null;
  if (audio != null) {
    try {
      audio.pause();
      audio.currentTime = 0;
      audio.removeAttribute('src');
      audio.load();
    } catch (_) {}
  }
}

Future<void> _beginPlayback(int gen) async {
  final kind = _activeKind;
  if (gen != _ringGeneration || _activeRingtoneKey == null || kind == null) return;
  final asset = _assetFor(kind);

  try {
    final ctx = _ringAudioCtx ??= web.AudioContext();
    if (ctx.state == 'suspended') {
      await ctx.resume().toDart;
    }
    if (gen != _ringGeneration || _activeRingtoneKey == null) return;
    if (ctx.state == 'running') {
      final buffer = await asset.loadBuffer(ctx);
      if (gen != _ringGeneration || _activeRingtoneKey == null) return;
      if (buffer != null) {
        _teardownActiveNodes();
        final gain = ctx.createGain();
        gain.gain.value = _activeVolume;
        gain.connect(ctx.destination);

        final source = ctx.createBufferSource();
        source.buffer = buffer;
        source.loop = true;
        source.connect(gain);
        source.start();

        _activeGain = gain;
        _activeSource = source;
        _needsGestureRetry = false;
        _removeUnlockListeners();
        return;
      }
    }
  } catch (_) {}

  if (gen != _ringGeneration || _activeRingtoneKey == null) return;

  web.HTMLAudioElement? audio;
  try {
    _teardownActiveNodes();
    audio = web.HTMLAudioElement()
      ..src = asset.ensureBlobUrl()
      ..loop = true
      ..volume = _activeVolume;
    _activeHtmlAudio = audio;
    await audio.play().toDart;
    if (gen != _ringGeneration || _activeRingtoneKey == null) {
      if (gen == _ringGeneration) {
        _teardownActiveNodes();
      } else {
        try {
          audio.pause();
          audio.src = '';
          audio.remove();
        } catch (_) {}
      }
      return;
    }
    _needsGestureRetry = false;
    _removeUnlockListeners();
  } catch (_) {
    // Autoplay blocked before user gesture; retry once on the next pointerdown/keydown while ringing.
    if (gen == _ringGeneration) {
      if (_activeRingtoneKey != null) {
        _needsGestureRetry = true;
        _ensureUnlockListeners();
      }
      _teardownActiveNodes();
    } else if (audio != null) {
      try {
        audio.pause();
        audio.src = '';
        audio.remove();
      } catch (_) {}
    }
  }
}

void _startLoopTone(_LoopToneKind kind, {String? callUuid, double volume = 1.0}) {
  final clampedVol = volume.clamp(0.0, 1.0);
  if (clampedVol <= 0) {
    _stopLoopTone(kind, callUuid: callUuid);
    return;
  }

  final key = (callUuid != null && callUuid.isNotEmpty) ? callUuid : _legacyRingtoneKey;
  _activeVolume = clampedVol;

  if (_activeKind == kind && _activeRingtoneKey == key) {
    final gain = _activeGain;
    if (gain != null) {
      try {
        gain.gain.value = clampedVol;
      } catch (_) {}
    }
    final audio = _activeHtmlAudio;
    if (audio != null) {
      try {
        audio.volume = clampedVol;
      } catch (_) {}
    }
    return;
  }

  _ringSafetyTimer?.cancel();
  _teardownActiveNodes();
  _ringGeneration++;
  _activeKind = kind;
  _activeRingtoneKey = key;
  _needsGestureRetry = false;
  _ensureUnlockListeners();

  final timeout = (kind == _LoopToneKind.ringtone && key == _legacyRingtoneKey)
      ? const Duration(seconds: 30)
      : const Duration(minutes: 2);
  _ringSafetyTimer = Timer(timeout, () {
    _stopLoopTone(kind, callUuid: callUuid);
  });

  unawaited(_beginPlayback(_ringGeneration));
}

void _stopLoopTone(_LoopToneKind kind, {String? callUuid}) {
  if (_activeRingtoneKey == null) {
    _removeUnlockListeners();
    return;
  }
  if (_activeKind != kind) return;
  if (callUuid != null &&
      callUuid.isNotEmpty &&
      _activeRingtoneKey != callUuid &&
      _activeRingtoneKey != _legacyRingtoneKey) {
    return;
  }
  _ringSafetyTimer?.cancel();
  _ringSafetyTimer = null;
  _ringGeneration++;
  _activeKind = null;
  _activeRingtoneKey = null;
  _needsGestureRetry = false;
  _removeUnlockListeners();
  _teardownActiveNodes();
  final ctx = _ringAudioCtx;
  if (ctx != null && ctx.state == 'running') {
    try {
      unawaited(ctx.suspend().toDart.then((_) {}, onError: (_) {}));
    } catch (_) {}
  }
}

void startWebFaceTimeRingtone({
  String? callUuid,
  double volume = 1.0,
}) =>
    _startLoopTone(_LoopToneKind.ringtone, callUuid: callUuid, volume: volume);

void stopWebFaceTimeRingtone({String? callUuid}) =>
    _stopLoopTone(_LoopToneKind.ringtone, callUuid: callUuid);

void startWebFaceTimeRingback({
  String? callUuid,
  double volume = 1.0,
}) =>
    _startLoopTone(_LoopToneKind.ringback, callUuid: callUuid, volume: volume);

void stopWebFaceTimeRingback({String? callUuid}) =>
    _stopLoopTone(_LoopToneKind.ringback, callUuid: callUuid);

void playWebFaceTimeCallEndedTone({double volume = 1.0}) {
  final clampedVol = volume.clamp(0.0, 1.0);
  if (clampedVol <= 0) return;
  unawaited(_playCallEndedOneShot(clampedVol));
}

Future<void> _playCallEndedOneShot(double volume) async {
  try {
    final ctx = _ringAudioCtx ??= web.AudioContext();
    if (ctx.state == 'suspended') {
      await ctx.resume().toDart;
    }
    if (ctx.state == 'running') {
      final buffer = await _callEndedAsset.loadBuffer(ctx);
      if (buffer != null) {
        final gain = ctx.createGain();
        gain.gain.value = volume;
        gain.connect(ctx.destination);

        final source = ctx.createBufferSource();
        source.buffer = buffer;
        source.loop = false;
        source.connect(gain);
        source.onended = ((web.Event _) {
          try {
            source.disconnect();
          } catch (_) {}
          try {
            gain.disconnect();
          } catch (_) {}
          if (_activeRingtoneKey == null && ctx.state == 'running') {
            try {
              unawaited(ctx.suspend().toDart.then((_) {}, onError: (_) {}));
            } catch (_) {}
          }
        }).toJS;
        source.start();
        return;
      }
    }
  } catch (_) {}

  // Fallback to one-shot HTMLAudioElement without arming gesture retry listeners.
  web.HTMLAudioElement? audio;
  try {
    audio = web.HTMLAudioElement()
      ..src = _callEndedAsset.ensureBlobUrl()
      ..loop = false
      ..volume = volume;
    void cleanup(web.Event _) {
      try {
        audio?.pause();
        audio?.removeAttribute('src');
        audio?.load();
        audio?.remove();
      } catch (_) {}
    }
    audio.onended = cleanup.toJS;
    await audio.play().toDart;
  } catch (_) {
    try {
      audio?.pause();
      audio?.removeAttribute('src');
      audio?.load();
      audio?.remove();
    } catch (_) {}
  }
}
