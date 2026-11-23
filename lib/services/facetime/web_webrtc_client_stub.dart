import 'package:bluebubbles/services/facetime/facetime_media_models.dart';
import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:flutter/widgets.dart';

class _StubWebRtcPeerAdapter implements WebRtcMediaPeerAdapter {
  @override
  bool get isSupported => false;

  @override
  bool get hasLocalVideo => false;

  @override
  bool get canFlipCamera => false;

  @override
  bool get isFrontCamera => true;

  @override
  bool get canSelectAudioOutput => false;

  @override
  Future<void> initialize({required List<WebRtcIceServer> iceServers, required bool wantVideo}) async {
    throw UnsupportedError('WebWebRtcClient is only supported on Flutter Web');
  }

  @override
  Future<WebRtcSessionDescription> createAndSetOffer() async {
    throw UnsupportedError('WebWebRtcClient is only supported on Flutter Web');
  }

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
      })> enumerateAudioDevices() async {
    return (
      outputs: const <FaceTimeAudioDevice>[],
      inputs: const <FaceTimeAudioDevice>[],
      activeOutputId: null,
      activeInputId: null,
    );
  }

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
  void setOnConnectionStateChanged(void Function(String state)? callback) {}

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
  void setOnIceStateChanged(void Function(String state)? callback) {}

  @override
  Future<void> close() async {}
}

WebRtcPeerAdapter createPlatformWebRtcPeerAdapter() => _StubWebRtcPeerAdapter();
