import 'dart:async';

import 'package:bluebubbles/services/facetime/facetime_media_models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';

import 'web_webrtc_client_stub.dart'
    if (dart.library.js_interop) 'web_webrtc_client_web.dart';

class WebRtcIceServer {
  const WebRtcIceServer({
    required this.urls,
    this.username,
    this.credential,
  });

  final List<String> urls;
  final String? username;
  final String? credential;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'urls': urls.length == 1 ? urls.first : urls,
        if (username != null && username!.isNotEmpty) 'username': username,
        if (credential != null && credential!.isNotEmpty) 'credential': credential,
      };
}

class WebRtcBridgeConfig {
  const WebRtcBridgeConfig({
    required this.iceServers,
    this.videoSupported = false,
    this.videoUplinkSupported = false,
  });

  static const List<WebRtcIceServer> defaultIceServers = <WebRtcIceServer>[
    WebRtcIceServer(urls: <String>['stun:stun.l.google.com:19302']),
  ];

  final List<WebRtcIceServer> iceServers;
  final bool videoSupported;
  final bool videoUplinkSupported;

  static WebRtcBridgeConfig parse(dynamic raw) {
    dynamic payload = raw;
    if (payload is List && payload.isNotEmpty) {
      payload = payload.firstWhere((e) => e is Map, orElse: () => payload.first);
    }
    if (payload is! Map) {
      return const WebRtcBridgeConfig(iceServers: defaultIceServers, videoSupported: false);
    }

    final parsedServers = parseIceServers(payload['iceServers']);
    return WebRtcBridgeConfig(
      iceServers: parsedServers.isEmpty ? defaultIceServers : parsedServers,
      videoSupported: payload['videoSupported'] == true,
      videoUplinkSupported: payload['videoUplinkSupported'] == true,
    );
  }

  static List<WebRtcIceServer> parseIceServers(dynamic rawServers) {
    if (rawServers is! List) return defaultIceServers;
    final servers = <WebRtcIceServer>[];
    for (final entry in rawServers) {
      if (entry is! Map) continue;
      final rawUrls = entry['urls'];
      final urls = <String>[];
      if (rawUrls is String) {
        final trimmed = rawUrls.trim();
        if (trimmed.isNotEmpty) urls.add(trimmed);
      } else if (rawUrls is List) {
        for (final item in rawUrls) {
          if (item is String) {
            final trimmed = item.trim();
            if (trimmed.isNotEmpty) urls.add(trimmed);
          }
        }
      }
      if (urls.isEmpty) continue;
      final username = entry['username']?.toString().trim();
      final credential = entry['credential']?.toString().trim();
      servers.add(WebRtcIceServer(
        urls: urls,
        username: (username != null && username.isNotEmpty) ? username : null,
        credential: (credential != null && credential.isNotEmpty) ? credential : null,
      ));
    }
    return servers.isEmpty ? defaultIceServers : servers;
  }
}

class WebRtcSessionDescription {
  const WebRtcSessionDescription({required this.type, required this.sdp});

  final String type;
  final String sdp;
}

class WebRtcIceCandidate {
  const WebRtcIceCandidate({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
}

abstract class WebRtcSignalingTransport {
  Future<dynamic> fetchBridgeConfig({Duration timeout = const Duration(seconds: 3)});
  void emitOffer({
    required String callUuid,
    required String sdp,
    required bool video,
    bool uplinkVideo = false,
    required bool answerCall,
  });
  void emitIceCandidate({
    required String callUuid,
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  });
  void emitMute({required String callUuid, required bool muted});
  void emitCamera({required String callUuid, required bool enabled});
  void emitHangup({required String callUuid});
  void onAnswer(void Function(Map<String, dynamic> data) handler);
  void onIceCandidate(void Function(Map<String, dynamic> data) handler);
  void offListeners();
}

class SocketIoWebRtcTransport implements WebRtcSignalingTransport {
  dynamic _answerHandler;
  dynamic _iceHandler;

  @override
  Future<dynamic> fetchBridgeConfig({Duration timeout = const Duration(seconds: 3)}) {
    if (!GetIt.I.isRegistered<SocketService>()) return Future<dynamic>.value(null);
    final socket = SocketSvc.socket;
    if (socket == null) return Future<dynamic>.value(null);

    final completer = Completer<dynamic>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    try {
      socket.emitWithAck('ft-bridge-config', <String, dynamic>{}, ack: (dynamic a, [dynamic b]) {
        if (timer.isActive) timer.cancel();
        if (!completer.isCompleted) {
          final payload = (a is Map || a is List) ? a : (b ?? a);
          completer.complete(payload);
        }
      });
    } catch (_) {
      if (timer.isActive) timer.cancel();
      if (!completer.isCompleted) completer.complete(null);
    }

    return completer.future;
  }

  @override
  void emitOffer({
    required String callUuid,
    required String sdp,
    required bool video,
    bool uplinkVideo = false,
    required bool answerCall,
  }) {
    if (!GetIt.I.isRegistered<SocketService>()) return;
    SocketSvc.socket?.emit('ft-bridge-offer', <String, dynamic>{
      'callUuid': callUuid,
      'sdp': sdp,
      'type': 'offer',
      'video': video,
      'uplinkVideo': uplinkVideo,
      if (answerCall) 'answerCall': true,
    });
  }

  @override
  void emitIceCandidate({
    required String callUuid,
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) {
    if (!GetIt.I.isRegistered<SocketService>()) return;
    SocketSvc.socket?.emit('ft-bridge-ice', <String, dynamic>{
      'callUuid': callUuid,
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    });
  }

  @override
  void emitMute({required String callUuid, required bool muted}) {
    if (!GetIt.I.isRegistered<SocketService>()) return;
    SocketSvc.socket?.emit('ft-bridge-mute', <String, dynamic>{
      'callUuid': callUuid,
      'muted': muted,
    });
  }

  @override
  void emitCamera({required String callUuid, required bool enabled}) {
    if (!GetIt.I.isRegistered<SocketService>()) return;
    SocketSvc.socket?.emit('ft-bridge-camera', <String, dynamic>{
      'callUuid': callUuid,
      'enabled': enabled,
    });
  }

  @override
  void emitHangup({required String callUuid}) {
    if (!GetIt.I.isRegistered<SocketService>()) return;
    SocketSvc.socket?.emit('ft-bridge-hangup', <String, dynamic>{
      'callUuid': callUuid,
    });
  }

  @override
  void onAnswer(void Function(Map<String, dynamic> data) handler) {
    if (!GetIt.I.isRegistered<SocketService>()) return;
    final socket = SocketSvc.socket;
    if (socket == null) return;
    if (_answerHandler != null) {
      socket.off('ft-bridge-answer', _answerHandler);
    }
    _answerHandler = (dynamic raw) {
      if (raw is Map) {
        handler(Map<String, dynamic>.from(raw));
      }
    };
    socket.on('ft-bridge-answer', _answerHandler);
  }

  @override
  void onIceCandidate(void Function(Map<String, dynamic> data) handler) {
    if (!GetIt.I.isRegistered<SocketService>()) return;
    final socket = SocketSvc.socket;
    if (socket == null) return;
    if (_iceHandler != null) {
      socket.off('ft-bridge-ice', _iceHandler);
    }
    _iceHandler = (dynamic raw) {
      if (raw is Map) {
        handler(Map<String, dynamic>.from(raw));
      }
    };
    socket.on('ft-bridge-ice', _iceHandler);
  }

  @override
  void offListeners() {
    if (!GetIt.I.isRegistered<SocketService>()) return;
    final socket = SocketSvc.socket;
    if (socket == null) return;
    if (_answerHandler != null) {
      socket.off('ft-bridge-answer', _answerHandler);
      _answerHandler = null;
    }
    if (_iceHandler != null) {
      socket.off('ft-bridge-ice', _iceHandler);
      _iceHandler = null;
    }
  }
}

abstract class WebRtcPeerAdapter {
  bool get isSupported;
  bool get hasLocalVideo;
  bool get canFlipCamera;
  bool get isFrontCamera;
  Future<void> initialize({required List<WebRtcIceServer> iceServers, required bool wantVideo});
  Future<WebRtcSessionDescription> createAndSetOffer();
  Future<void> setRemoteAnswer(String sdp, String type);
  Future<void> addIceCandidate(WebRtcIceCandidate candidate);
  void setMicMuted(bool muted);
  Future<void> setCameraEnabled(bool enabled);
  Future<void> flipCamera();
  void setOnIceCandidate(void Function(WebRtcIceCandidate candidate)? callback);
  void setOnRemoteVideoWidget(void Function(Widget? widget)? callback);
  void setOnLocalVideoWidget(void Function(Widget? widget)? callback);
  void setOnConnectionStateChanged(void Function(String state)? callback);
  Future<void> close();
}

/// Extended peer adapter capabilities for audio/video processing, device selection,
/// and quality telemetry. Separated from [WebRtcPeerAdapter] so existing unit test
/// fakes implementing [WebRtcPeerAdapter] stay compatible.
abstract class WebRtcMediaPeerAdapter implements WebRtcPeerAdapter {
  bool get canSelectAudioOutput;
  Future<void> setVoiceIsolation(bool enabled);
  Future<void> setVideoProcessing({
    required FaceTimeVideoEffectType effect,
    required bool denoise,
    String? backgroundId,
    String? backgroundPath,
  });
  Future<
      ({
        List<FaceTimeAudioDevice> outputs,
        List<FaceTimeAudioDevice> inputs,
        String? activeOutputId,
        String? activeInputId,
      })> enumerateAudioDevices();
  Future<bool> selectAudioOutput(String deviceId);
  Future<bool> selectAudioInput(String deviceId);
  void setOnAudioDevicesChanged(
    void Function(
      List<FaceTimeAudioDevice> outputs,
      List<FaceTimeAudioDevice> inputs,
      String? activeOutputId,
      String? activeInputId,
    )? callback,
  );
  void setOnQualityStats(void Function(FaceTimeCallQualityStats stats)? callback);
  void setOnIceStateChanged(void Function(String state)? callback);
}

/// Manages Web browser WebRTC audio/video bridging with the BlueBubbles Mac server
/// over `ft-bridge-*` Socket.IO signaling.
class WebWebRtcClient {
  WebWebRtcClient({
    WebRtcSignalingTransport? transport,
    WebRtcPeerAdapter Function()? adapterFactory,
    this._onSendDtmf,
  })  : _transport = transport ?? SocketIoWebRtcTransport(),
        _adapterFactory = adapterFactory ?? createPlatformWebRtcPeerAdapter;

  final WebRtcSignalingTransport _transport;
  final WebRtcPeerAdapter Function() _adapterFactory;
  final Future<void> Function(String callUuid, String digit)? _onSendDtmf;

  final ValueNotifier<Widget?> remoteVideo = ValueNotifier<Widget?>(null);
  final ValueNotifier<Widget?> localVideo = ValueNotifier<Widget?>(null);
  final ValueNotifier<bool> cameraEnabled = ValueNotifier<bool>(false);
  final ValueNotifier<bool> frontCamera = ValueNotifier<bool>(true);
  final ValueNotifier<bool> canFlipCamera = ValueNotifier<bool>(false);
  final ValueNotifier<bool> voiceIsolationEnabled = ValueNotifier<bool>(true);
  final ValueNotifier<bool> videoDenoiseEnabled = ValueNotifier<bool>(false);
  final ValueNotifier<FaceTimeVideoEffectType> videoEffect =
      ValueNotifier<FaceTimeVideoEffectType>(FaceTimeVideoEffectType.none);
  final ValueNotifier<List<FaceTimeAudioDevice>> audioOutputs =
      ValueNotifier<List<FaceTimeAudioDevice>>(const <FaceTimeAudioDevice>[]);
  final ValueNotifier<List<FaceTimeAudioDevice>> audioInputs =
      ValueNotifier<List<FaceTimeAudioDevice>>(const <FaceTimeAudioDevice>[]);
  final ValueNotifier<String?> activeAudioOutputId = ValueNotifier<String?>(null);
  final ValueNotifier<String?> activeAudioInputId = ValueNotifier<String?>(null);
  final ValueNotifier<bool> canSelectAudioOutput = ValueNotifier<bool>(false);
  final ValueNotifier<FaceTimeCallQualityStats?> callQualityStats = ValueNotifier<FaceTimeCallQualityStats?>(null);
  final ValueNotifier<String> iceConnectionState = ValueNotifier<String>('new');

  void Function(Widget? widget)? onRemoteVideoChanged;
  void Function(Widget? widget)? onLocalVideoChanged;
  void Function(bool enabled)? onCameraEnabledChanged;
  void Function(bool canFlip)? onCanFlipCameraChanged;
  void Function(bool isFront)? onFrontCameraChanged;
  void Function(String state)? onConnectionStateChanged;
  void Function(
    List<FaceTimeAudioDevice> outputs,
    List<FaceTimeAudioDevice> inputs,
    String? activeOutputId,
    String? activeInputId,
  )? onAudioDevicesChanged;
  void Function(FaceTimeCallQualityStats stats)? onQualityStatsChanged;
  void Function(String state)? onIceStateChanged;

  WebRtcBridgeConfig? _cachedConfig;
  WebRtcBridgeConfig? get cachedConfig => _cachedConfig;

  WebRtcPeerAdapter? _adapter;
  WebRtcMediaPeerAdapter? get _mediaAdapter =>
      _adapter is WebRtcMediaPeerAdapter ? _adapter as WebRtcMediaPeerAdapter : null;

  String? _activeCallUuid;
  String? get activeCallUuid => _activeCallUuid;
  bool get isActive => _activeCallUuid != null;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _uplinkAccepted = false;
  bool get uplinkAccepted => _uplinkAccepted;

  String? _backgroundId;
  String? _backgroundPath;

  bool _remoteDescriptionSet = false;
  final List<WebRtcIceCandidate> _pendingRemoteIce = <WebRtcIceCandidate>[];
  Completer<void>? _answerCompleter;

  Future<WebRtcBridgeConfig> fetchBridgeConfig({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedConfig != null) {
      return _cachedConfig!;
    }
    try {
      final raw = await _transport.fetchBridgeConfig();
      final parsed = WebRtcBridgeConfig.parse(raw);
      _cachedConfig = parsed;
      return parsed;
    } catch (e, s) {
      Logger.warn('Failed to fetch ft-bridge-config; falling back to default STUN', error: e, trace: s, tag: 'WebWebRtc');
      const fallback = WebRtcBridgeConfig(iceServers: WebRtcBridgeConfig.defaultIceServers, videoSupported: false);
      _cachedConfig ??= fallback;
      return fallback;
    }
  }

  Future<void> start({
    required String callUuid,
    bool wantVideo = false,
    bool answerCall = false,
    bool initialMuted = false,
    Duration answerTimeout = const Duration(seconds: 8),
  }) async {
    if (_activeCallUuid != null) {
      await hangup(emitSignal: false);
    }

    final adapter = _adapterFactory();
    if (!adapter.isSupported) {
      throw StateError('WebRTC is not supported on this platform');
    }

    _adapter = adapter;
    _activeCallUuid = callUuid;
    _isMuted = initialMuted;
    _remoteDescriptionSet = false;
    _pendingRemoteIce.clear();
    final answerCompleter = Completer<void>();
    // Prevent unhandled zone errors if hangup() aborts before answerCompleter.future is awaited.
    answerCompleter.future.ignore();
    _answerCompleter = answerCompleter;

    final config = await fetchBridgeConfig(forceRefresh: true);
    if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) {
      throw StateError('aborted');
    }

    adapter.setOnIceCandidate((candidate) {
      if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) return;
      _transport.emitIceCandidate(
        callUuid: callUuid,
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      );
    });
    adapter.setOnRemoteVideoWidget((widget) {
      if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) return;
      _updateRemoteVideo(widget);
    });
    adapter.setOnLocalVideoWidget((widget) {
      if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) return;
      _updateLocalVideo(widget);
    });
    adapter.setOnConnectionStateChanged((state) {
      if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) return;
      onConnectionStateChanged?.call(state);
    });

    final mediaAdapter = _mediaAdapter;
    if (mediaAdapter != null) {
      canSelectAudioOutput.value = mediaAdapter.canSelectAudioOutput;
      mediaAdapter.setOnAudioDevicesChanged((outputs, inputs, activeOut, activeIn) {
        if (_activeCallUuid != callUuid || !identical(_adapter, mediaAdapter)) return;
        _updateAudioDevices(outputs, inputs, activeOut, activeIn);
      });
      mediaAdapter.setOnQualityStats((stats) {
        if (_activeCallUuid != callUuid || !identical(_adapter, mediaAdapter)) return;
        callQualityStats.value = stats;
        onQualityStatsChanged?.call(stats);
      });
      mediaAdapter.setOnIceStateChanged((state) {
        if (_activeCallUuid != callUuid || !identical(_adapter, mediaAdapter)) return;
        iceConnectionState.value = state;
        onIceStateChanged?.call(state);
      });
    }

    _transport.onAnswer((data) async {
      if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) return;
      if (data['callUuid']?.toString() != callUuid) return;
      final sdp = data['sdp']?.toString();
      if (sdp == null || sdp.isEmpty) return;
      final type = data['type']?.toString() ?? 'answer';
      try {
        await adapter.setRemoteAnswer(sdp, type);
        if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) return;
        _uplinkAccepted = data['uplinkVideo'] == true;
        _remoteDescriptionSet = true;
        final queued = List<WebRtcIceCandidate>.from(_pendingRemoteIce);
        _pendingRemoteIce.clear();
        for (final c in queued) {
          if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) return;
          await adapter.addIceCandidate(c);
        }
        if (!answerCompleter.isCompleted) answerCompleter.complete();
      } catch (e, s) {
        if (!answerCompleter.isCompleted) answerCompleter.completeError(e, s);
      }
    });

    _transport.onIceCandidate((data) async {
      if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) return;
      if (data['callUuid']?.toString() != callUuid) return;
      final candidateStr = data['candidate']?.toString();
      if (candidateStr == null || candidateStr.isEmpty) return;
      final rawIndex = data['sdpMLineIndex'];
      final candidate = WebRtcIceCandidate(
        candidate: candidateStr,
        sdpMid: data['sdpMid']?.toString(),
        sdpMLineIndex: rawIndex is int ? rawIndex : int.tryParse(rawIndex?.toString() ?? ''),
      );
      if (!_remoteDescriptionSet) {
        _pendingRemoteIce.add(candidate);
        return;
      }
      try {
        await adapter.addIceCandidate(candidate);
      } catch (_) {}
    });

    try {
      await adapter.initialize(iceServers: config.iceServers, wantVideo: wantVideo);
      if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) {
        await adapter.close();
        throw StateError('aborted');
      }
      final hasLocalVideo = wantVideo && adapter.hasLocalVideo;
      _updateCameraEnabled(hasLocalVideo);
      _updateFrontCamera(adapter.isFrontCamera);
      _updateCanFlipCamera(hasLocalVideo && adapter.canFlipCamera);

      if (mediaAdapter != null) {
        if (!voiceIsolationEnabled.value) {
          await mediaAdapter.setVoiceIsolation(false);
        }
        if (hasLocalVideo && (videoEffect.value != FaceTimeVideoEffectType.none || videoDenoiseEnabled.value)) {
          await mediaAdapter.setVideoProcessing(
            effect: videoEffect.value,
            denoise: videoDenoiseEnabled.value,
            backgroundId: _backgroundId,
            backgroundPath: _backgroundPath,
          );
        }
        await refreshAudioDevices();
      }

      if (initialMuted) {
        adapter.setMicMuted(true);
      }
      final offer = await adapter.createAndSetOffer();
      if (_activeCallUuid != callUuid || !identical(_adapter, adapter)) {
        await adapter.close();
        throw StateError('aborted');
      }

      _transport.emitOffer(
        callUuid: callUuid,
        sdp: offer.sdp,
        video: wantVideo,
        uplinkVideo: hasLocalVideo,
        answerCall: answerCall,
      );

      if (initialMuted) {
        _transport.emitMute(callUuid: callUuid, muted: true);
      }

      await answerCompleter.future.timeout(answerTimeout);
    } catch (e) {
      if (_activeCallUuid == callUuid && identical(_adapter, adapter)) {
        await hangup(emitSignal: false);
      }
      rethrow;
    }
  }

  Future<void> setMuted(bool muted) async {
    _isMuted = muted;
    _adapter?.setMicMuted(muted);
    final uuid = _activeCallUuid;
    if (GetIt.I.isRegistered<BaseLogger>()) {
      Logger.info('WebRTC setMuted($muted) for call $uuid', tag: 'WebWebRtc');
    }
    if (uuid != null) {
      _transport.emitMute(callUuid: uuid, muted: muted);
    }
  }

  Future<void> setCameraEnabled(bool enabled) async {
    final adapter = _adapter;
    if (adapter == null || !adapter.hasLocalVideo) {
      _updateCameraEnabled(false);
      return;
    }
    await adapter.setCameraEnabled(enabled);
    _updateCameraEnabled(enabled);
    final uuid = _activeCallUuid;
    if (uuid != null) {
      _transport.emitCamera(callUuid: uuid, enabled: enabled);
    }
  }

  Future<void> flipCamera() async {
    final adapter = _adapter;
    if (adapter == null || !adapter.hasLocalVideo || !adapter.canFlipCamera) {
      return;
    }
    await adapter.flipCamera();
    _updateFrontCamera(adapter.isFrontCamera);
  }

  Future<bool> setVoiceIsolation(bool enabled) async {
    voiceIsolationEnabled.value = enabled;
    final media = _mediaAdapter;
    if (media == null) return true;
    await media.setVoiceIsolation(enabled);
    return true;
  }

  Future<bool> setVideoProcessing({
    required FaceTimeVideoEffectType effect,
    required bool denoise,
    String? backgroundId,
    String? backgroundPath,
  }) async {
    videoEffect.value = effect;
    videoDenoiseEnabled.value = denoise;
    _backgroundId = backgroundId;
    _backgroundPath = backgroundPath;
    final media = _mediaAdapter;
    if (media == null) return true;
    await media.setVideoProcessing(
      effect: effect,
      denoise: denoise,
      backgroundId: backgroundId,
      backgroundPath: backgroundPath,
    );
    return true;
  }

  Future<void> refreshAudioDevices() async {
    final media = _mediaAdapter;
    if (media == null) return;
    final result = await media.enumerateAudioDevices();
    if (!identical(_adapter, media)) return;
    _updateAudioDevices(result.outputs, result.inputs, result.activeOutputId, result.activeInputId);
  }

  Future<bool> selectAudioOutput(String deviceId) async {
    final media = _mediaAdapter;
    if (media == null) return false;
    final ok = await media.selectAudioOutput(deviceId);
    if (ok) {
      await refreshAudioDevices();
    }
    return ok;
  }

  Future<bool> selectAudioInput(String deviceId) async {
    final media = _mediaAdapter;
    if (media == null) return false;
    final ok = await media.selectAudioInput(deviceId);
    if (ok) {
      await refreshAudioDevices();
    }
    return ok;
  }

  Future<void> sendDtmf(String digit) async {
    final uuid = _activeCallUuid;
    if (uuid == null || digit.isEmpty) return;
    if (_onSendDtmf != null) {
      await _onSendDtmf(uuid, digit);
      return;
    }
    if (GetIt.I.isRegistered<HttpService>()) {
      await HttpSvc.faceTime.dtmf(uuid, digit);
    }
  }

  Future<void> hangup({bool emitSignal = true}) async {
    final uuid = _activeCallUuid;
    final adapter = _adapter;
    final pendingAnswer = _answerCompleter;

    _activeCallUuid = null;
    _adapter = null;
    _answerCompleter = null;
    _remoteDescriptionSet = false;
    _pendingRemoteIce.clear();
    _isMuted = false;
    _uplinkAccepted = false;

    if (pendingAnswer != null && !pendingAnswer.isCompleted) {
      pendingAnswer.completeError(StateError('aborted'));
    }

    _transport.offListeners();
    if (emitSignal && uuid != null) {
      _transport.emitHangup(callUuid: uuid);
    }

    _updateRemoteVideo(null);
    _updateLocalVideo(null);
    _updateCameraEnabled(false);
    _updateFrontCamera(true);
    _updateCanFlipCamera(false);
    canSelectAudioOutput.value = false;
    callQualityStats.value = null;
    iceConnectionState.value = 'new';
    _updateAudioDevices(const <FaceTimeAudioDevice>[], const <FaceTimeAudioDevice>[], null, null);
    if (adapter != null) {
      try {
        await adapter.close();
      } catch (_) {}
    }
  }

  void _updateRemoteVideo(Widget? widget) {
    if (!identical(remoteVideo.value, widget)) {
      remoteVideo.value = widget;
    }
    onRemoteVideoChanged?.call(widget);
  }

  void _updateLocalVideo(Widget? widget) {
    if (!identical(localVideo.value, widget)) {
      localVideo.value = widget;
    }
    onLocalVideoChanged?.call(widget);
  }

  void _updateCameraEnabled(bool enabled) {
    if (cameraEnabled.value != enabled) {
      cameraEnabled.value = enabled;
    }
    onCameraEnabledChanged?.call(enabled);
  }

  void _updateFrontCamera(bool isFront) {
    if (frontCamera.value != isFront) {
      frontCamera.value = isFront;
    }
    onFrontCameraChanged?.call(isFront);
  }

  void _updateCanFlipCamera(bool canFlip) {
    if (canFlipCamera.value != canFlip) {
      canFlipCamera.value = canFlip;
    }
    onCanFlipCameraChanged?.call(canFlip);
  }

  void _updateAudioDevices(
    List<FaceTimeAudioDevice> outputs,
    List<FaceTimeAudioDevice> inputs,
    String? activeOut,
    String? activeIn,
  ) {
    audioOutputs.value = List<FaceTimeAudioDevice>.unmodifiable(outputs);
    audioInputs.value = List<FaceTimeAudioDevice>.unmodifiable(inputs);
    activeAudioOutputId.value = activeOut;
    activeAudioInputId.value = activeIn;
    onAudioDevicesChanged?.call(outputs, inputs, activeOut, activeIn);
  }

  void dispose() {
    unawaited(hangup(emitSignal: false));
    remoteVideo.dispose();
    localVideo.dispose();
    cameraEnabled.dispose();
    frontCamera.dispose();
    canFlipCamera.dispose();
    voiceIsolationEnabled.dispose();
    videoDenoiseEnabled.dispose();
    videoEffect.dispose();
    audioOutputs.dispose();
    audioInputs.dispose();
    activeAudioOutputId.dispose();
    activeAudioInputId.dispose();
    canSelectAudioOutput.dispose();
    callQualityStats.dispose();
    iceConnectionState.dispose();
  }
}
