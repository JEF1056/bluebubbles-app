import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:bluebubbles/app/components/facetime/web_ringtone_wav.dart';
import 'package:web/web.dart' as web;

const String _legacyRingtoneKey = '__legacy__';

web.AudioContext? _ringAudioCtx;
web.AudioBuffer? _ringBuffer;
Future<web.AudioBuffer?>? _ringDecodeFuture;
String? _ringBlobUrl;
web.EventListener? _unlockListener;

String? _activeRingtoneKey;
double _activeVolume = 1.0;
int _ringGeneration = 0;
bool _needsGestureRetry = false;
Timer? _ringSafetyTimer;

web.AudioBufferSourceNode? _activeSource;
web.GainNode? _activeGain;
web.HTMLAudioElement? _activeHtmlAudio;

Uint8List? _cachedWavBytes;
Uint8List _wavBytes() => _cachedWavBytes ??= buildIncomingRingtoneWavBytes();

String _ensureBlobUrl() {
  if (_ringBlobUrl != null) return _ringBlobUrl!;
  final blob = web.Blob(<JSAny>[_wavBytes().toJS].toJS, web.BlobPropertyBag(type: 'audio/wav'));
  _ringBlobUrl = web.URL.createObjectURL(blob);
  return _ringBlobUrl!;
}

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

Future<web.AudioBuffer?> _loadRingBuffer(web.AudioContext ctx) {
  if (_ringBuffer != null) return Future.value(_ringBuffer);
  return _ringDecodeFuture ??= () async {
    try {
      final copy = Uint8List.fromList(_wavBytes());
      final decoded = await ctx.decodeAudioData(copy.buffer.toJS).toDart;
      _ringBuffer = decoded;
      return decoded;
    } catch (_) {
      _ringDecodeFuture = null;
      return null;
    }
  }();
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
  if (gen != _ringGeneration || _activeRingtoneKey == null) return;

  try {
    final ctx = _ringAudioCtx ??= web.AudioContext();
    if (ctx.state == 'suspended') {
      await ctx.resume().toDart;
    }
    if (gen != _ringGeneration || _activeRingtoneKey == null) return;
    if (ctx.state == 'running') {
      final buffer = await _loadRingBuffer(ctx);
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

  try {
    _teardownActiveNodes();
    final audio = web.HTMLAudioElement()
      ..src = _ensureBlobUrl()
      ..loop = true
      ..volume = _activeVolume;
    _activeHtmlAudio = audio;
    await audio.play().toDart;
    if (gen != _ringGeneration || _activeRingtoneKey == null) {
      _teardownActiveNodes();
      return;
    }
    _needsGestureRetry = false;
    _removeUnlockListeners();
  } catch (_) {
    // Autoplay blocked before user gesture; retry once on the next pointerdown/keydown while ringing.
    if (gen == _ringGeneration && _activeRingtoneKey != null) {
      _needsGestureRetry = true;
      _ensureUnlockListeners();
    }
    _teardownActiveNodes();
  }
}

void startWebFaceTimeRingtone({
  String? callUuid,
  double volume = 1.0,
}) {
  final clampedVol = volume.clamp(0.0, 1.0);
  if (clampedVol <= 0) {
    stopWebFaceTimeRingtone(callUuid: callUuid);
    return;
  }

  final key = (callUuid != null && callUuid.isNotEmpty) ? callUuid : _legacyRingtoneKey;
  _activeVolume = clampedVol;

  if (_activeRingtoneKey == key) {
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
  _activeRingtoneKey = key;
  _needsGestureRetry = false;
  _ensureUnlockListeners();

  final timeout = key == _legacyRingtoneKey ? const Duration(seconds: 30) : const Duration(minutes: 2);
  _ringSafetyTimer = Timer(timeout, () {
    stopWebFaceTimeRingtone(callUuid: callUuid);
  });

  unawaited(_beginPlayback(_ringGeneration));
}

void stopWebFaceTimeRingtone({String? callUuid}) {
  if (_activeRingtoneKey == null) {
    _removeUnlockListeners();
    return;
  }
  if (callUuid != null &&
      callUuid.isNotEmpty &&
      _activeRingtoneKey != callUuid &&
      _activeRingtoneKey != _legacyRingtoneKey) {
    return;
  }
  _ringSafetyTimer?.cancel();
  _ringSafetyTimer = null;
  _ringGeneration++;
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
