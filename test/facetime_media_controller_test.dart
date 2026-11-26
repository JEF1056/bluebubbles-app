import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/services/facetime/facetime_media_models.dart';
import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeMediaSignalingTransport implements WebRtcSignalingTransport {
  void Function(Map<String, dynamic> data)? answerHandler;
  void Function(Map<String, dynamic> data)? iceHandler;

  @override
  Future<dynamic> fetchBridgeConfig({Duration timeout = const Duration(seconds: 3)}) async => {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
        'videoSupported': true,
        'videoUplinkSupported': true,
      };

  @override
  void emitOffer({
    required String callUuid,
    required String sdp,
    required bool video,
    bool uplinkVideo = false,
    required bool answerCall,
  }) {
    Future<void>.microtask(() {
      answerHandler?.call({
        'callUuid': callUuid,
        'type': 'answer',
        'sdp': 'v=0\r\na=fake-answer\r\n',
        'uplinkVideo': uplinkVideo,
      });
    });
  }

  @override
  void emitIceCandidate({
    required String callUuid,
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) {}

  @override
  void emitMute({required String callUuid, required bool muted}) {}

  @override
  void emitCamera({required String callUuid, required bool enabled}) {}

  @override
  void emitHangup({required String callUuid}) {}

  @override
  void onAnswer(void Function(Map<String, dynamic> data) handler) {
    answerHandler = handler;
  }

  @override
  void onIceCandidate(void Function(Map<String, dynamic> data) handler) {
    iceHandler = handler;
  }

  @override
  void offListeners() {
    answerHandler = null;
    iceHandler = null;
  }
}

class _FakeMediaPeerAdapter implements WebRtcMediaPeerAdapter {
  bool? lastVoiceIsolation;
  FaceTimeVideoEffectType? lastEffect;
  bool? lastDenoise;
  String? lastBgId;
  String? lastBgPath;
  String? selectedOut = 'out-default';
  String? selectedIn = 'in-default';

  List<FaceTimeAudioDevice> outputs = const [
    FaceTimeAudioDevice(
      id: 'out-default',
      label: 'Default Speaker',
      kind: FaceTimeAudioDeviceKind.speaker,
      isInput: false,
      isActive: true,
    ),
    FaceTimeAudioDevice(
      id: 'out-bt',
      label: 'AirPods Pro',
      kind: FaceTimeAudioDeviceKind.bluetooth,
      isInput: false,
    ),
  ];

  List<FaceTimeAudioDevice> inputs = const [
    FaceTimeAudioDevice(
      id: 'in-default',
      label: 'Built-in Mic',
      kind: FaceTimeAudioDeviceKind.builtinMic,
      isInput: true,
      isActive: true,
    ),
    FaceTimeAudioDevice(
      id: 'in-usb',
      label: 'USB Studio Mic',
      kind: FaceTimeAudioDeviceKind.usb,
      isInput: true,
    ),
  ];

  void Function(
    List<FaceTimeAudioDevice> outputs,
    List<FaceTimeAudioDevice> inputs,
    String? activeOutputId,
    String? activeInputId,
  )? _onDevicesChanged;
  void Function(FaceTimeCallQualityStats stats)? _onQualityStats;
  void Function(String state)? _onIceStateChanged;
  void Function(String state)? _onConnectionStateChanged;

  @override
  bool get isSupported => true;

  @override
  bool get hasLocalVideo => true;

  @override
  bool get canFlipCamera => true;

  @override
  bool get isFrontCamera => true;

  @override
  bool get canSelectAudioOutput => true;

  @override
  Future<void> initialize({required List<WebRtcIceServer> iceServers, required bool wantVideo}) async {}

  @override
  Future<WebRtcSessionDescription> createAndSetOffer() async =>
      const WebRtcSessionDescription(type: 'offer', sdp: 'v=0\r\na=fake-offer\r\n');

  @override
  Future<void> setRemoteAnswer(String sdp, String type) async {}

  @override
  Future<void> addIceCandidate(WebRtcIceCandidate candidate) async {}

  @override
  void setMicMuted(bool muted) {}

  @override
  Future<void> setCameraEnabled(bool enabled) async {}

  @override
  Future<void> flipCamera() async {}

  @override
  Future<void> setVoiceIsolation(bool enabled) async {
    lastVoiceIsolation = enabled;
  }

  @override
  Future<void> setVideoProcessing({
    required FaceTimeVideoEffectType effect,
    required bool denoise,
    String? backgroundId,
    String? backgroundPath,
  }) async {
    lastEffect = effect;
    lastDenoise = denoise;
    lastBgId = backgroundId;
    lastBgPath = backgroundPath;
  }

  @override
  Future<
      ({
        List<FaceTimeAudioDevice> outputs,
        List<FaceTimeAudioDevice> inputs,
        String? activeOutputId,
        String? activeInputId,
      })> enumerateAudioDevices() async {
    return (
      outputs: outputs.map((d) => d.copyWith(isActive: d.id == selectedOut)).toList(),
      inputs: inputs.map((d) => d.copyWith(isActive: d.id == selectedIn)).toList(),
      activeOutputId: selectedOut,
      activeInputId: selectedIn,
    );
  }

  @override
  Future<bool> selectAudioOutput(String deviceId) async {
    selectedOut = deviceId;
    return true;
  }

  @override
  Future<bool> selectAudioInput(String deviceId) async {
    selectedIn = deviceId;
    return true;
  }

  void emitQualityStats(FaceTimeCallQualityStats stats) => _onQualityStats?.call(stats);

  void emitIceState(String state) => _onIceStateChanged?.call(state);

  void emitConnectionState(String state) => _onConnectionStateChanged?.call(state);

  void emitDevicesChanged() {
    _onDevicesChanged?.call(outputs, inputs, selectedOut, selectedIn);
  }

  @override
  void setOnIceCandidate(void Function(WebRtcIceCandidate candidate)? callback) {}

  @override
  void setOnRemoteVideoWidget(void Function(Widget? widget)? callback) {}

  @override
  void setOnLocalVideoWidget(void Function(Widget? widget)? callback) {}

  @override
  void setOnConnectionStateChanged(void Function(String state)? callback) {
    _onConnectionStateChanged = callback;
  }

  @override
  void setOnAudioDevicesChanged(
    void Function(
      List<FaceTimeAudioDevice> outputs,
      List<FaceTimeAudioDevice> inputs,
      String? activeOutputId,
      String? activeInputId,
    )? callback,
  ) {
    _onDevicesChanged = callback;
  }

  @override
  void setOnQualityStats(void Function(FaceTimeCallQualityStats stats)? callback) {
    _onQualityStats = callback;
  }

  @override
  void setOnIceStateChanged(void Function(String state)? callback) {
    _onIceStateChanged = callback;
  }

  @override
  Future<void> close() async {
    _onConnectionStateChanged = null;
    _onIceStateChanged = null;
    _onQualityStats = null;
    _onDevicesChanged = null;
  }
}

void main() {
  group('AdaptiveQualityLadder', () {
    test('starts at 1080p rung 4 and drops immediately on severe loss or high RTT', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final ladder = AdaptiveQualityLadder(now: () => now);

      expect(ladder.rungIndex, 4);
      expect(ladder.currentRung.maxHeight, 1080);

      // Immediate drop on >10% packet loss
      final drop1 = ladder.evaluate(
        availableBitrateKbps: 3500,
        packetLossPct: 12.0,
        rttMs: 40,
        timestamp: now,
      );
      expect(drop1.rungIndex, 3);
      expect(drop1.maxFramerate, 30);
      expect(drop1.scaleResolutionDownBy, 1.5);
      expect(drop1.changed, isTrue);

      // Immediate drop on RTT > 400ms
      now = now.add(const Duration(seconds: 2));
      final drop2 = ladder.evaluate(
        availableBitrateKbps: 2000,
        packetLossPct: 0.0,
        rttMs: 450,
        timestamp: now,
      );
      expect(drop2.rungIndex, 2);
      expect(drop2.scaleResolutionDownBy, 2.0);
    });

    test('requires 2s sustained low BWE before dropping and 6s + cooldown before stepping up', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final ladder = AdaptiveQualityLadder(now: () => now);

      // Low BWE at t=0s should not drop immediately.
      final d0 = ladder.evaluate(
        availableBitrateKbps: 1000,
        packetLossPct: 0.0,
        rttMs: 30,
        timestamp: now,
      );
      expect(d0.rungIndex, 4);

      // Sustained low BWE at t=2s drops to rung 3.
      now = now.add(const Duration(seconds: 2));
      final d2 = ladder.evaluate(
        availableBitrateKbps: 1000,
        packetLossPct: 0.0,
        rttMs: 30,
        timestamp: now,
      );
      expect(d2.rungIndex, 3);

      // High BWE during 8s cooldown must not step back up yet.
      now = now.add(const Duration(seconds: 7));
      final duringCooldown = ladder.evaluate(
        availableBitrateKbps: 5000,
        packetLossPct: 0.0,
        rttMs: 25,
        timestamp: now,
      );
      expect(duringCooldown.rungIndex, 3);

      // After 8s cooldown starts 6s sustained high window (t=8s -> t=14s).
      now = now.add(const Duration(seconds: 2)); // t=9s post-drop
      final startUp = ladder.evaluate(
        availableBitrateKbps: 5000,
        packetLossPct: 0.0,
        rttMs: 25,
        timestamp: now,
      );
      expect(startUp.rungIndex, 3);

      now = now.add(const Duration(seconds: 6));
      final steppedUp = ladder.evaluate(
        availableBitrateKbps: 5000,
        packetLossPct: 0.0,
        rttMs: 25,
        timestamp: now,
      );
      expect(steppedUp.rungIndex, 4);
      expect(steppedUp.changed, isTrue);
    });
  });

  group('FaceTimeMediaModels', () {
    test('parses audio device payloads and exposes background presets', () {
      final outDev = FaceTimeAudioDevice.fromJson({
        'id': 'bt-1',
        'label': 'AirPods Max',
        'kind': 'bluetooth',
        'is_input': false,
        'is_active': true,
      });
      expect(outDev.id, 'bt-1');
      expect(outDev.kind, FaceTimeAudioDeviceKind.bluetooth);
      expect(outDev.isInput, isFalse);
      expect(outDev.isActive, isTrue);

      expect(FaceTimeBackgroundPreset.presets.length, greaterThanOrEqualTo(4));
      for (final preset in FaceTimeBackgroundPreset.presets) {
        expect(preset.previewColors, isNotEmpty);
      }
    });
  });

  group('WebWebRtcClient & ActiveCallController media controls', () {
    test('propagates device changes, quality stats, and ice/connection state on WebWebRtcClient', () async {
      final transport = _FakeMediaSignalingTransport();
      final adapter = _FakeMediaPeerAdapter();
      final client = WebWebRtcClient(
        transport: transport,
        adapterFactory: () => adapter,
      );
      addTearDown(client.dispose);

      String? lastIce;
      String? lastConn;
      int deviceChanges = 0;
      client.onIceStateChanged = (s) => lastIce = s;
      client.onConnectionStateChanged = (s) => lastConn = s;
      client.onAudioDevicesChanged = (_, _, _, _) => deviceChanges++;

      await client.start(callUuid: 'call-media-1', wantVideo: true);
      final initialEvents = deviceChanges;
      adapter.emitDevicesChanged();
      adapter.emitIceState('disconnected');
      adapter.emitConnectionState('connected');

      expect(initialEvents, 1);
      expect(deviceChanges, 2);
      expect(lastIce, 'disconnected');
      expect(client.iceConnectionState.value, 'disconnected');
      expect(lastConn, 'connected');

      await client.hangup();
      expect(client.iceConnectionState.value, 'new');
      expect(client.callQualityStats.value, isNull);
    });

    test('drives WebRtcMediaPeerAdapter end-to-end through ActiveCallController', () async {
      final transport = _FakeMediaSignalingTransport();
      final adapter = _FakeMediaPeerAdapter();
      final client = WebWebRtcClient(
        transport: transport,
        adapterFactory: () => adapter,
      );
      final controller = ActiveCallController(
        webRtcClient: client,
        isWebOverride: true,
        deviceId: 'web-1',
        deviceName: 'Web Browser',
        onAnswerServerCall: (uuid, {audioOnly = false, mode, displayName, chatGuid}) async => null,
        onLeaveServerCall: (_) async {},
      );
      addTearDown(controller.dispose);

      controller.startIncoming(
        callUuid: 'call-media-2',
        callerName: 'Bob',
        isVideo: true,
      );

      final answered = await controller.answerCall();
      expect(answered, isTrue);
      expect(controller.isWebRtcActive, isTrue);
      expect(controller.canSelectAudioOutput.value, isTrue);
      expect(controller.audioOutputs.length, 2);
      expect(controller.audioInputs.length, 2);
      expect(controller.activeAudioOutputId.value, 'out-default');
      expect(controller.activeAudioInputId.value, 'in-default');

      // Voice isolation toggle
      expect(await controller.setVoiceIsolation(false), isTrue);
      expect(controller.voiceIsolationEnabled.value, isFalse);
      expect(adapter.lastVoiceIsolation, isFalse);

      // Video denoise + effects (default ON, toggling to false then true)
      expect(controller.videoDenoiseEnabled.value, isTrue);
      expect(await controller.setVideoDenoise(false), isTrue);
      expect(controller.videoDenoiseEnabled.value, isFalse);
      expect(adapter.lastDenoise, isFalse);
      expect(await controller.setVideoDenoise(true), isTrue);
      expect(controller.videoDenoiseEnabled.value, isTrue);
      expect(adapter.lastDenoise, isTrue);

      expect(
        await controller.setVideoEffect(
          FaceTimeVideoEffectType.virtualBackground,
          backgroundId: 'studio_warm',
        ),
        isTrue,
      );
      expect(controller.videoEffect.value, FaceTimeVideoEffectType.virtualBackground);
      expect(controller.virtualBackgroundId.value, 'studio_warm');
      expect(adapter.lastEffect, FaceTimeVideoEffectType.virtualBackground);
      expect(adapter.lastBgId, 'studio_warm');

      // Device selection
      expect(await controller.selectAudioOutput('out-bt'), isTrue);
      expect(controller.activeAudioOutputId.value, 'out-bt');
      expect(controller.isSpeakerOn.value, isFalse);

      expect(await controller.selectAudioInput('in-usb'), isTrue);
      expect(controller.activeAudioInputId.value, 'in-usb');

      // Stats callback
      const sampleStats = FaceTimeCallQualityStats(
        sendWidth: 1920,
        sendHeight: 1080,
        sendFps: 30,
        sendBitrateKbps: 3200,
        recvWidth: 1280,
        recvHeight: 720,
        recvFps: 30,
        recvBitrateKbps: 1800,
        packetLossPct: 0.2,
        rttMs: 24,
      );
      adapter.emitQualityStats(sampleStats);
      expect(controller.callQualityStats.value, sampleStats);

      await controller.endCall();
      expect(controller.callQualityStats.value, isNull);
      expect(controller.audioOutputs, isEmpty);
      expect(controller.videoEffect.value, FaceTimeVideoEffectType.none);
      expect(controller.videoDenoiseEnabled.value, isTrue);
    });

    test('handles Android audio-devices state events in handleFacetimeCallState', () async {
      final controller = ActiveCallController(isWebOverride: false);
      addTearDown(controller.dispose);

      controller.startOngoing(
        callUuid: 'call-android-1',
        callerName: 'Carol',
        isVideo: true,
        isTelecomCall: true,
      );

      controller.handleFacetimeCallState({
        'phase': 'audio-devices',
        'call_uuid': 'call-android-1',
        'active_output_id': 'speaker',
        'active_input_id': 'builtin',
        'outputs': [
          {'id': 'earpiece', 'label': 'Earpiece', 'kind': 'earpiece', 'is_active': false},
          {'id': 'speaker', 'label': 'Speakerphone', 'kind': 'speaker', 'is_active': true},
        ],
        'inputs': [
          {'id': 'builtin', 'label': 'Phone Mic', 'kind': 'builtinMic', 'is_active': true},
        ],
      });

      expect(controller.audioOutputs.length, 2);
      expect(controller.audioInputs.length, 1);
      expect(controller.activeAudioOutputId.value, 'speaker');
      expect(controller.activeAudioInputId.value, 'builtin');
      expect(controller.canSelectAudioOutput.value, isTrue);
      expect(controller.isSpeakerOn.value, isTrue);
    });
  });
}
