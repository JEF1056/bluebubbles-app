import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/services/facetime/facetime_media_models.dart';
import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeReconnectSignalingTransport implements WebRtcSignalingTransport {
  void Function(Map<String, dynamic> data)? answerHandler;

  @override
  Future<dynamic> fetchBridgeConfig({Duration timeout = const Duration(seconds: 3)}) async => {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
        'videoSupported': true,
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
  void onIceCandidate(void Function(Map<String, dynamic> data) handler) {}

  @override
  void offListeners() {
    answerHandler = null;
  }
}

class _FakeReconnectPeerAdapter implements WebRtcMediaPeerAdapter {
  void Function(String state)? onConnectionStateChanged;
  void Function(String state)? onIceStateChanged;

  @override
  bool get isSupported => true;

  @override
  bool get hasLocalVideo => true;

  @override
  bool get canFlipCamera => false;

  @override
  bool get isFrontCamera => true;

  @override
  bool get canSelectAudioOutput => false;

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
  Future<void> setVoiceIsolation(bool enabled) async {}

  @override
  Future<void> setVideoProcessing({
    required FaceTimeVideoEffectType effect,
    required bool denoise,
    String? backgroundId,
    String? backgroundPath,
  }) async {}

  @override
  Future<
      ({
        List<FaceTimeAudioDevice> outputs,
        List<FaceTimeAudioDevice> inputs,
        String? activeOutputId,
        String? activeInputId,
      })> enumerateAudioDevices() async => (
        outputs: const <FaceTimeAudioDevice>[],
        inputs: const <FaceTimeAudioDevice>[],
        activeOutputId: null,
        activeInputId: null,
      );

  @override
  Future<bool> selectAudioOutput(String deviceId) async => false;

  @override
  Future<bool> selectAudioInput(String deviceId) async => false;

  @override
  void setOnIceCandidate(void Function(WebRtcIceCandidate candidate)? callback) {}

  @override
  void setOnRemoteVideoWidget(void Function(Widget? widget)? callback) {}

  @override
  void setOnLocalVideoWidget(void Function(Widget? widget)? callback) {}

  @override
  void setOnConnectionStateChanged(void Function(String state)? callback) {
    onConnectionStateChanged = callback;
  }

  @override
  void setOnAudioDevicesChanged(
    void Function(
      List<FaceTimeAudioDevice> outputs,
      List<FaceTimeAudioDevice> inputs,
      String? activeOutputId,
      String? activeInputId,
    )? callback,
  ) {}

  @override
  void setOnQualityStats(void Function(FaceTimeCallQualityStats stats)? callback) {}

  @override
  void setOnIceStateChanged(void Function(String state)? callback) {
    onIceStateChanged = callback;
  }

  @override
  Future<void> close() async {
    onConnectionStateChanged = null;
    onIceStateChanged = null;
  }
}

void main() {
  group('ActiveCallController isReconnecting', () {
    test('tracks WebRTC disconnected, connected, and failed transitions', () async {
      final transport = _FakeReconnectSignalingTransport();
      final adapter = _FakeReconnectPeerAdapter();
      var endCallInvocations = 0;

      final controller = ActiveCallController(
        webRtcClient: WebWebRtcClient(
          transport: transport,
          adapterFactory: () => adapter,
        ),
        isWebOverride: true,
        onAnswerServerCall: (uuid, {audioOnly = false, mode, displayName, chatGuid}) async => null,
        onLeaveServerCall: (_) async {},
        onEndCall: (_, _) async {
          endCallInvocations++;
        },
      );
      addTearDown(controller.dispose);

      expect(controller.isReconnecting.value, isFalse);

      controller.startIncoming(
        callUuid: 'call-reconn-web',
        callerName: 'Alice',
        isVideo: true,
      );
      expect(await controller.answerCall(), isTrue);
      expect(controller.isReconnecting.value, isFalse);

      adapter.onIceStateChanged?.call('disconnected');
      expect(controller.isReconnecting.value, isTrue);

      adapter.onIceStateChanged?.call('connected');
      expect(controller.isReconnecting.value, isFalse);

      adapter.onConnectionStateChanged?.call('disconnected');
      expect(controller.isReconnecting.value, isTrue);

      adapter.onConnectionStateChanged?.call('failed');
      await Future<void>.delayed(Duration.zero);
      expect(controller.isReconnecting.value, isFalse);
      expect(controller.state.phase, ActiveCallPhase.idle);
      expect(endCallInvocations, 1);
    });

    test('handles Android ice-state events and ignores stale UUIDs', () {
      final controller = ActiveCallController(isWebOverride: false);
      addTearDown(controller.dispose);

      controller.startOngoing(
        callUuid: 'call-reconn-android',
        callerName: 'Bob',
        isVideo: true,
        isTelecomCall: true,
      );

      controller.handleFacetimeCallState({
        'phase': 'ice-state',
        'call_uuid': 'wrong-uuid',
        'state': 'disconnected',
      });
      expect(controller.isReconnecting.value, isFalse);

      controller.handleFacetimeCallState({
        'phase': 'ice-state',
        'call_uuid': 'call-reconn-android',
        'state': 'disconnected',
      });
      expect(controller.isReconnecting.value, isTrue);

      controller.handleFacetimeCallState({
        'phase': 'ice-state',
        'call_uuid': 'call-reconn-android',
        'state': 'connected',
      });
      expect(controller.isReconnecting.value, isFalse);

      controller.handleFacetimeCallState({
        'phase': 'ice-state',
        'call_uuid': 'call-reconn-android',
        'state': 'reconnecting',
      });
      expect(controller.isReconnecting.value, isTrue);

      controller.clear();
      expect(controller.isReconnecting.value, isFalse);
    });
  });
}
