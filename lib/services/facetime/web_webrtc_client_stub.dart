import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:flutter/widgets.dart';

class _StubWebRtcPeerAdapter implements WebRtcPeerAdapter {
  @override
  bool get isSupported => false;

  @override
  bool get hasLocalVideo => false;

  @override
  bool get canFlipCamera => false;

  @override
  bool get isFrontCamera => true;

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
  void setOnIceCandidate(void Function(WebRtcIceCandidate candidate)? callback) {}

  @override
  void setOnRemoteVideoWidget(void Function(Widget? widget)? callback) {}

  @override
  void setOnLocalVideoWidget(void Function(Widget? widget)? callback) {}

  @override
  void setOnConnectionStateChanged(void Function(String state)? callback) {}

  @override
  Future<void> close() async {}
}

WebRtcPeerAdapter createPlatformWebRtcPeerAdapter() => _StubWebRtcPeerAdapter();
