import 'dart:async';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePendingTab implements PendingCallTab {
  bool closed = false;
  String? navigatedUrl;

  @override
  bool get isOpen => !closed;

  @override
  bool navigate(String url) {
    navigatedUrl = url;
    return true;
  }

  @override
  void close() {
    closed = true;
  }
}

class _FakeSignalingTransport implements WebRtcSignalingTransport {
  dynamic configResponse = <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[
      <String, dynamic>{'urls': 'stun:stun.l.google.com:19302'},
      <String, dynamic>{
        'urls': <String>['turn:turn.example.com:3478', 'turns:turn.example.com:5349'],
        'username': 'u1',
        'credential': 'p1',
      },
    ],
    'videoSupported': true,
  };
  bool autoRespondAnswer = true;
  final List<Map<String, dynamic>> offers = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> iceCandidates = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> mutes = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> cameras = <Map<String, dynamic>>[];
  final List<String> hangups = <String>[];
  bool listenersCleared = false;

  void Function(Map<String, dynamic>)? _answerHandler;
  void Function(Map<String, dynamic>)? _iceHandler;

  @override
  Future<dynamic> fetchBridgeConfig({Duration timeout = const Duration(seconds: 3)}) async => configResponse;

  @override
  void emitOffer({
    required String callUuid,
    required String sdp,
    required bool video,
    bool uplinkVideo = false,
    required bool answerCall,
  }) {
    offers.add(<String, dynamic>{
      'callUuid': callUuid,
      'sdp': sdp,
      'video': video,
      'uplinkVideo': uplinkVideo,
      'answerCall': answerCall,
    });
    if (autoRespondAnswer && _answerHandler != null) {
      scheduleMicrotask(() {
        _answerHandler?.call(<String, dynamic>{
          'callUuid': callUuid,
          'type': 'answer',
          'sdp': 'v=0\r\nfake-answer-$callUuid',
          'uplinkVideo': uplinkVideo,
        });
      });
    }
  }

  @override
  void emitIceCandidate({
    required String callUuid,
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) {
    iceCandidates.add(<String, dynamic>{
      'callUuid': callUuid,
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    });
  }

  @override
  void emitMute({required String callUuid, required bool muted}) {
    mutes.add(<String, dynamic>{'callUuid': callUuid, 'muted': muted});
  }

  @override
  void emitCamera({required String callUuid, required bool enabled}) {
    cameras.add(<String, dynamic>{'callUuid': callUuid, 'enabled': enabled});
  }

  @override
  void emitHangup({required String callUuid}) {
    hangups.add(callUuid);
  }

  @override
  void onAnswer(void Function(Map<String, dynamic> data) handler) {
    listenersCleared = false;
    _answerHandler = handler;
  }

  @override
  void onIceCandidate(void Function(Map<String, dynamic> data) handler) {
    listenersCleared = false;
    _iceHandler = handler;
  }

  void pushServerIce({
    required String callUuid,
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) {
    _iceHandler?.call(<String, dynamic>{
      'callUuid': callUuid,
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    });
  }

  @override
  void offListeners() {
    listenersCleared = true;
    _answerHandler = null;
    _iceHandler = null;
  }
}

class _FakePeerAdapter implements WebRtcPeerAdapter {
  _FakePeerAdapter({
    this.simulateVideoCaptureSuccess = true,
    this.canFlip = false,
  });

  final bool simulateVideoCaptureSuccess;
  final bool canFlip;
  List<WebRtcIceServer>? initializedIceServers;
  bool? initializedWantVideo;
  String? remoteAnswerSdp;
  final List<WebRtcIceCandidate> addedIce = <WebRtcIceCandidate>[];
  bool muted = false;
  bool closed = false;
  bool _hasLocalVideo = false;
  bool _isFrontCamera = true;
  bool cameraEnabled = false;
  int flipCount = 0;

  void Function(WebRtcIceCandidate candidate)? _onIce;
  void Function(Widget? widget)? _onVideo;
  void Function(Widget? widget)? _onLocalVideo;
  void Function(String state)? _onConnState;

  @override
  bool get isSupported => true;

  @override
  bool get hasLocalVideo => _hasLocalVideo;

  @override
  bool get canFlipCamera => canFlip;

  @override
  bool get isFrontCamera => _isFrontCamera;

  @override
  Future<void> initialize({required List<WebRtcIceServer> iceServers, required bool wantVideo}) async {
    initializedIceServers = iceServers;
    initializedWantVideo = wantVideo;
    _hasLocalVideo = wantVideo && simulateVideoCaptureSuccess;
    cameraEnabled = _hasLocalVideo;
    if (_hasLocalVideo) {
      _onLocalVideo?.call(const SizedBox(key: Key('fake-local-video')));
    }
  }

  @override
  Future<WebRtcSessionDescription> createAndSetOffer() async {
    return const WebRtcSessionDescription(type: 'offer', sdp: 'v=0\r\nfake-offer');
  }

  @override
  Future<void> setRemoteAnswer(String sdp, String type) async {
    remoteAnswerSdp = sdp;
  }

  @override
  Future<void> addIceCandidate(WebRtcIceCandidate candidate) async {
    addedIce.add(candidate);
  }

  @override
  void setMicMuted(bool muted) {
    this.muted = muted;
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    if (!_hasLocalVideo) return;
    cameraEnabled = enabled;
  }

  @override
  Future<void> flipCamera() async {
    if (!_hasLocalVideo || !canFlip) return;
    _isFrontCamera = !_isFrontCamera;
    flipCount++;
  }

  @override
  void setOnIceCandidate(void Function(WebRtcIceCandidate candidate)? callback) {
    _onIce = callback;
  }

  @override
  void setOnRemoteVideoWidget(void Function(Widget? widget)? callback) {
    _onVideo = callback;
  }

  @override
  void setOnLocalVideoWidget(void Function(Widget? widget)? callback) {
    _onLocalVideo = callback;
  }

  @override
  void setOnConnectionStateChanged(void Function(String state)? callback) {
    _onConnState = callback;
  }

  void simulateLocalIce(String candidate) {
    _onIce?.call(WebRtcIceCandidate(candidate: candidate, sdpMid: '0', sdpMLineIndex: 0));
  }

  void simulateRemoteVideo(Widget? widget) {
    _onVideo?.call(widget);
  }

  void simulateLocalVideo(Widget? widget) {
    _onLocalVideo?.call(widget);
  }

  void simulateConnectionState(String state) {
    _onConnState?.call(state);
  }

  @override
  Future<void> close() async {
    closed = true;
    _onVideo?.call(null);
    _onLocalVideo?.call(null);
  }
}

void main() {
  group('WebRtcBridgeConfig parsing', () {
    test('parses STUN/TURN servers and videoSupported flag', () {
      final config = WebRtcBridgeConfig.parse(<String, dynamic>{
        'iceServers': <Map<String, dynamic>>[
          <String, dynamic>{'urls': 'stun:stun.example.org:3478'},
          <String, dynamic>{
            'urls': <String>['turn:a.example.org:3478', 'turns:a.example.org:5349'],
            'username': 'alice',
            'credential': 'secret',
          },
        ],
        'videoSupported': true,
        'videoUplinkSupported': true,
      });

      expect(config.videoSupported, isTrue);
      expect(config.videoUplinkSupported, isTrue);
      expect(config.iceServers.length, 2);
      expect(config.iceServers[0].urls, <String>['stun:stun.example.org:3478']);
      expect(config.iceServers[1].urls, <String>['turn:a.example.org:3478', 'turns:a.example.org:5349']);
      expect(config.iceServers[1].username, 'alice');
      expect(config.iceServers[1].credential, 'secret');
    });

    test('falls back to default Google STUN when payload is null or invalid', () {
      final fromNull = WebRtcBridgeConfig.parse(null);
      expect(fromNull.videoSupported, isFalse);
      expect(fromNull.iceServers.single.urls, <String>['stun:stun.l.google.com:19302']);

      final fromEmpty = WebRtcBridgeConfig.parse(<String, dynamic>{
        'iceServers': <Map<String, dynamic>>[
          <String, dynamic>{'urls': '   '},
        ],
      });
      expect(fromEmpty.iceServers.single.urls, <String>['stun:stun.l.google.com:19302']);
    });

    test('unwraps list-wrapped Socket.IO ack payloads', () {
      final config = WebRtcBridgeConfig.parse(<dynamic>[
        <String, dynamic>{
          'iceServers': <Map<String, dynamic>>[
            <String, dynamic>{'urls': 'stun:wrapped.example.org:3478'},
          ],
          'videoSupported': true,
        },
      ]);
      expect(config.videoSupported, isTrue);
      expect(config.iceServers.single.urls, <String>['stun:wrapped.example.org:3478']);
    });
  });

  group('WebWebRtcClient signaling and media lifecycle', () {
    test('negotiates offer/answer, buffers pre-answer ICE, handles video, mute, dtmf, hangup', () async {
      final transport = _FakeSignalingTransport()..autoRespondAnswer = false;
      final adapter = _FakePeerAdapter();
      final dtmfSent = <String>[];
      final client = WebWebRtcClient(
        transport: transport,
        adapterFactory: () => adapter,
        onSendDtmf: (uuid, digit) async => dtmfSent.add('$uuid:$digit'),
      );

      final startFuture = client.start(
        callUuid: 'call-1',
        wantVideo: true,
        answerCall: true,
      );

      // Wait until offer is emitted so listeners are attached before answer arrives
      await pumpEventQueue();
      expect(transport.offers.length, 1);
      expect(transport.offers.single['video'], isTrue);
      expect(transport.offers.single['answerCall'], isTrue);
      expect(adapter.initializedWantVideo, isTrue);
      expect(adapter.initializedIceServers?.length, 2);

      // Push remote ICE before answer arrives -> must buffer until setRemoteAnswer
      transport.pushServerIce(
        callUuid: 'call-1',
        candidate: 'candidate:1 1 UDP 2122252543 192.0.2.1 5000 typ host',
        sdpMid: '0',
        sdpMLineIndex: 0,
      );
      expect(adapter.addedIce, isEmpty);

      // Push answer -> should flush buffered ICE
      transport._answerHandler?.call(<String, dynamic>{
        'callUuid': 'call-1',
        'type': 'answer',
        'sdp': 'v=0\r\nremote-answer',
      });
      await startFuture;

      expect(adapter.remoteAnswerSdp, 'v=0\r\nremote-answer');
      expect(adapter.addedIce.length, 1);

      // Local ICE candidate -> emitted to transport
      adapter.simulateLocalIce('candidate:local-1');
      expect(transport.iceCandidates.single['candidate'], 'candidate:local-1');

      // Remote video widget arrival -> updates notifier
      const videoPlaceholder = SizedBox(key: Key('remote-video'));
      adapter.simulateRemoteVideo(videoPlaceholder);
      expect(client.remoteVideo.value, same(videoPlaceholder));

      // Mute & DTMF
      await client.setMuted(true);
      expect(adapter.muted, isTrue);
      expect(transport.mutes.single, <String, dynamic>{'callUuid': 'call-1', 'muted': true});

      await client.sendDtmf('7');
      expect(dtmfSent, <String>['call-1:7']);

      // Hangup clears state, emits ft-bridge-hangup, closes adapter
      await client.hangup();
      expect(transport.hangups, <String>['call-1']);
      expect(transport.listenersCleared, isTrue);
      expect(adapter.closed, isTrue);
      expect(client.isActive, isFalse);
      expect(client.remoteVideo.value, isNull);
      expect(client.localVideo.value, isNull);
      expect(client.cameraEnabled.value, isFalse);
      expect(client.canFlipCamera.value, isFalse);
    });

    test('manages local video, camera toggle/flip, and audio-only fallback when camera unavailable', () async {
      final transport = _FakeSignalingTransport();
      final adapter = _FakePeerAdapter(simulateVideoCaptureSuccess: true, canFlip: true);
      final localWidgets = <Widget?>[];
      final client = WebWebRtcClient(
        transport: transport,
        adapterFactory: () => adapter,
      )..onLocalVideoChanged = localWidgets.add;
      addTearDown(client.dispose);

      await client.start(callUuid: 'vid-up-1', wantVideo: true, answerCall: false);

      expect(transport.offers.single['video'], isTrue);
      expect(transport.offers.single['uplinkVideo'], isTrue);
      expect(client.uplinkAccepted, isTrue);
      expect(client.cameraEnabled.value, isTrue);
      expect(client.frontCamera.value, isTrue);
      expect(client.canFlipCamera.value, isTrue);
      expect(client.localVideo.value, isNotNull);
      expect(localWidgets.last, isNotNull);

      await client.setCameraEnabled(false);
      expect(adapter.cameraEnabled, isFalse);
      expect(client.cameraEnabled.value, isFalse);
      expect(transport.cameras.single, <String, dynamic>{'callUuid': 'vid-up-1', 'enabled': false});

      await client.setCameraEnabled(true);
      expect(adapter.cameraEnabled, isTrue);
      expect(client.cameraEnabled.value, isTrue);
      expect(transport.cameras.last, <String, dynamic>{'callUuid': 'vid-up-1', 'enabled': true});

      await client.flipCamera();
      expect(adapter.flipCount, 1);
      expect(client.frontCamera.value, isFalse);

      await client.hangup();
      expect(client.localVideo.value, isNull);
      expect(client.cameraEnabled.value, isFalse);
      expect(client.canFlipCamera.value, isFalse);
      expect(client.frontCamera.value, isTrue);
      expect(client.uplinkAccepted, isFalse);

      // Audio-only fallback when camera capture fails
      final fallbackTransport = _FakeSignalingTransport();
      final fallbackAdapter = _FakePeerAdapter(simulateVideoCaptureSuccess: false, canFlip: false);
      final fallbackClient = WebWebRtcClient(
        transport: fallbackTransport,
        adapterFactory: () => fallbackAdapter,
      );
      addTearDown(fallbackClient.dispose);

      await fallbackClient.start(callUuid: 'vid-fallback-1', wantVideo: true, answerCall: true);
      expect(fallbackTransport.offers.single['video'], isTrue);
      expect(fallbackTransport.offers.single['uplinkVideo'], isFalse);
      expect(fallbackClient.cameraEnabled.value, isFalse);
      expect(fallbackClient.canFlipCamera.value, isFalse);
      expect(fallbackClient.localVideo.value, isNull);

      await fallbackClient.setCameraEnabled(true);
      expect(fallbackClient.cameraEnabled.value, isFalse);
      expect(fallbackTransport.cameras, isEmpty);
    });
  });

  group('ActiveCallController Web routing', () {
    test('routes incoming FaceTime Audio and iPhone Cellular through WebWebRtcClient without web link', () async {
      final transport = _FakeSignalingTransport();
      final adapter = _FakePeerAdapter();
      final client = WebWebRtcClient(
        transport: transport,
        adapterFactory: () => adapter,
      );
      final answerCalls = <bool>[];
      final launchedLinks = <String>[];

      final controller = ActiveCallController(
        isWebOverride: true,
        webRtcClient: client,
        deviceId: 'web-1',
        deviceName: 'Chrome',
        onOpenPendingTab: () => _FakePendingTab(),
        onLaunchJoinLink: (link) async {
          launchedLinks.add(link);
          return true;
        },
        onAnswerServerCall: (uuid, {bool audioOnly = false, String? displayName, String? chatGuid}) async {
          answerCalls.add(audioOnly);
          return null;
        },
      );
      addTearDown(controller.dispose);

      // 1) Incoming iPhone Cellular (isTelephony: true)
      controller.startIncoming(
        callUuid: 'tel-1',
        callerName: 'Mom',
        isVideo: false,
        isTelephony: true,
      );
      final okTel = await controller.answerCall();
      expect(okTel, isTrue);
      expect(controller.state.phase, ActiveCallPhase.ongoing);
      expect(controller.state.isTelephony, isTrue);
      expect(controller.state.isVideo, isFalse);
      expect(transport.offers.single['callUuid'], 'tel-1');
      expect(transport.offers.single['video'], isFalse);
      expect(transport.offers.single['answerCall'], isTrue);
      expect(answerCalls, <bool>[true]);
      expect(launchedLinks, isEmpty);

      // toggleSpeaker on Web is a graceful no-op
      expect(await controller.toggleSpeaker(), isFalse);
      expect(controller.isSpeakerOn.value, isFalse);

      await controller.endCall();
      expect(transport.hangups, <String>['tel-1']);
    });

    test('routes incoming FaceTime Video via WebWebRtcClient when videoSupported, falls back to link otherwise', () async {
      // Case A: videoSupported == true -> uses WebRTC video and updates remoteVideoWidget
      final transport = _FakeSignalingTransport();
      final adapter = _FakePeerAdapter();
      final client = WebWebRtcClient(
        transport: transport,
        adapterFactory: () => adapter,
      );
      final pendingTab = _FakePendingTab();
      final launchedLinks = <String>[];

      final controller = ActiveCallController(
        isWebOverride: true,
        webRtcClient: client,
        deviceId: 'web-1',
        deviceName: 'Chrome',
        onOpenPendingTab: () => pendingTab,
        onLaunchJoinLink: (link) async {
          launchedLinks.add(link);
          return true;
        },
      );
      addTearDown(controller.dispose);

      controller.startIncoming(callUuid: 'vid-1', callerName: 'Alex', isVideo: true);
      final ok = await controller.answerCall();
      expect(ok, isTrue);
      expect(pendingTab.closed, isTrue);
      expect(launchedLinks, isEmpty);
      expect(transport.offers.single['video'], isTrue);
      expect(controller.state.isVideo, isTrue);

      const remoteView = SizedBox(key: Key('vid-view'));
      adapter.simulateRemoteVideo(remoteView);
      expect(controller.remoteVideoWidget.value, same(remoteView));

      // Remote takeover from another device closes WebRTC locally without ft-bridge-hangup
      controller.applyServerSession(<String, dynamic>{
        'call_uuid': 'vid-1',
        'status': 'answered',
        'active_device_id': 'android-2',
        'active_device_name': 'Pixel',
      });
      await pumpEventQueue();
      expect(transport.hangups, isEmpty);
      expect(controller.isWebRtcActive, isFalse);
      expect(controller.remoteVideoWidget.value, isNull);

      // Case B: videoSupported == false -> falls back to facetime.apple.com join link
      transport.configResponse = <String, dynamic>{
        'iceServers': <Map<String, dynamic>>[],
        'videoSupported': false,
      };
      final fallbackTab = _FakePendingTab();
      final controllerFallback = ActiveCallController(
        isWebOverride: true,
        webRtcClient: WebWebRtcClient(
          transport: transport,
          adapterFactory: () => _FakePeerAdapter(),
        ),
        onOpenPendingTab: () => fallbackTab,
        onAnswerServerCall: (uuid, {bool audioOnly = false, String? displayName, String? chatGuid}) async {
          return PlacedFaceTimeCall(
            call: FaceTimeCall(callUuid: uuid),
            link: 'https://facetime.apple.com/join#abc',
          );
        },
      );
      addTearDown(controllerFallback.dispose);

      controllerFallback.startIncoming(callUuid: 'vid-2', callerName: 'Sam', isVideo: true);
      final okFallback = await controllerFallback.answerCall();
      expect(okFallback, isTrue);
      expect(fallbackTab.navigatedUrl, 'https://facetime.apple.com/join#abc');
    });

    test('supports outgoing WebRTC calls, mute, transferHere, and Android speaker DI', () async {
      final transport = _FakeSignalingTransport();
      final adapter = _FakePeerAdapter();
      final controller = ActiveCallController(
        isWebOverride: true,
        webRtcClient: WebWebRtcClient(
          transport: transport,
          adapterFactory: () => adapter,
        ),
        deviceId: 'web-1',
        deviceName: 'Chrome',
        onToggleSpeaker: (enabled) async => true,
        onHandoffServerCall: (uuid, {String? mode}) async => null,
      );
      addTearDown(controller.dispose);

      const placedCall = PlacedFaceTimeCall(
        call: FaceTimeCall(callUuid: 'out-1'),
      );
      final placedOk = await controller.startWebOutgoingCall(
        address: '+15551234567',
        callerName: 'Jamie',
        video: false,
        isTelephony: true,
        onPlaceServerCall: (_) async => placedCall,
      );
      expect(placedOk, isTrue);
      expect(controller.state.phase, ActiveCallPhase.outgoing);
      expect(controller.state.callUuid, 'out-1');
      expect(controller.state.isTelephony, isTrue);
      expect(transport.offers.single['answerCall'], isFalse);

      controller.toggleMute();
      await pumpEventQueue();
      expect(controller.state.isMuted, isTrue);
      expect(adapter.muted, isTrue);
      expect(transport.mutes.single['muted'], isTrue);

      // Speaker callback toggles state when supported
      expect(await controller.toggleSpeaker(), isTrue);
      expect(controller.isSpeakerOn.value, isTrue);

      await controller.endCall();
      expect(controller.isSpeakerOn.value, isFalse);
      expect(transport.hangups, <String>['out-1']);

      // transferHere for telephony on Web uses WebRTC audio
      controller.applyServerSession(<String, dynamic>{
        'call_uuid': 'xfer-1',
        'status': 'answered',
        'is_telephony': true,
        'active_device_id': 'mac-1',
        'active_device_name': 'Mac',
      });
      final xferOk = await controller.transferHere();
      expect(xferOk, isTrue);
      expect(controller.state.isHeldHere, isTrue);
      expect(transport.offers.last['callUuid'], 'xfer-1');
      expect(transport.offers.last['video'], isFalse);
    });
  });

  group('ActiveCallController Android facetime-call-state video-texture', () {
    test('sets Texture(textureId:) on video-texture and clears on <= 0 or idle/ended', () {
      final controller = ActiveCallController();
      addTearDown(controller.dispose);

      // Ignored while idle
      controller.handleFacetimeCallState(<String, dynamic>{
        'phase': 'video-texture',
        'call_uuid': 'and-vid-1',
        'texture_id': 9,
      });
      expect(controller.remoteVideoWidget.value, isNull);

      controller.startOngoing(
        callUuid: 'and-vid-1',
        callerName: 'Casey',
        isVideo: true,
        isTelecomCall: true,
      );

      // Mismatched call_uuid is ignored
      controller.handleFacetimeCallState(<String, dynamic>{
        'phase': 'video-texture',
        'call_uuid': 'other-call',
        'texture_id': 99,
      });
      expect(controller.remoteVideoWidget.value, isNull);

      // Valid video-texture sets Texture widget
      controller.handleFacetimeCallState(<String, dynamic>{
        'phase': 'video-texture',
        'call_uuid': 'and-vid-1',
        'texture_id': 7,
      });
      expect(controller.remoteVideoWidget.value, isA<Texture>());
      expect((controller.remoteVideoWidget.value as Texture).textureId, 7);

      // texture_id <= 0 clears remoteVideoWidget
      controller.handleFacetimeCallState(<String, dynamic>{
        'phase': 'video-texture',
        'call_uuid': 'and-vid-1',
        'texture_id': -1,
      });
      expect(controller.remoteVideoWidget.value, isNull);

      // Set again then clear via ended event
      controller.handleFacetimeCallState(<String, dynamic>{
        'phase': 'video-texture',
        'call_uuid': 'and-vid-1',
        'texture_id': 11,
      });
      expect((controller.remoteVideoWidget.value as Texture).textureId, 11);

      controller.handleFacetimeCallState(<String, dynamic>{
        'phase': 'ended',
        'call_uuid': 'and-vid-1',
      });
      expect(controller.state.phase, ActiveCallPhase.idle);
      expect(controller.remoteVideoWidget.value, isNull);
    });

    test('hangup() aborts in-flight start() with StateError and cancelled answerCall() stays idle', () async {
      final transport = _FakeSignalingTransport()..autoRespondAnswer = false;
      final adapter = _FakePeerAdapter();
      final client = WebWebRtcClient(
        transport: transport,
        adapterFactory: () => adapter,
      );
      final errors = <String>[];
      final launchedLinks = <String>[];

      final controller = ActiveCallController(
        isWebOverride: true,
        webRtcClient: client,
        deviceId: 'web-1',
        deviceName: 'Chrome',
        onOpenPendingTab: () => _FakePendingTab(),
        onLaunchJoinLink: (link) async {
          launchedLinks.add(link);
          return true;
        },
        onShowError: (title, message) => errors.add('$title: $message'),
      );
      addTearDown(controller.dispose);

      // Direct client.start() cancellation throws StateError('aborted').
      final startFuture = client.start(
        callUuid: 'abort-1',
        wantVideo: false,
        answerCall: true,
      );
      final expectation = expectLater(startFuture, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      await client.hangup(emitSignal: false);
      await expectation;

      // Cancelling an incoming call mid-answerCall via declineCall() does not fall back or error.
      controller.startIncoming(
        callUuid: 'abort-2',
        callerName: 'Sam',
        isVideo: true,
      );
      final answerFuture = controller.answerCall(audioOnly: true);
      await Future<void>.delayed(Duration.zero);
      await controller.declineCall();
      expect(await answerFuture, isFalse);
      expect(controller.state.phase, ActiveCallPhase.idle);
      expect(launchedLinks, isEmpty);
      expect(errors, isEmpty);

      // Cancelling via endCall() mid-answerCall() emits ft-bridge-hangup, returns false,
      // leaves state idle, and suppresses fallback join-link launch and errors.
      final linkClient = WebWebRtcClient(
        transport: transport,
        adapterFactory: () => _FakePeerAdapter(),
      );
      final linkController = ActiveCallController(
        isWebOverride: true,
        webRtcClient: linkClient,
        deviceId: 'web-1',
        deviceName: 'Chrome',
        onOpenPendingTab: () => _FakePendingTab(),
        onLaunchJoinLink: (link) async {
          launchedLinks.add(link);
          return true;
        },
        onAnswerServerCall: (uuid, {bool audioOnly = false, String? displayName, String? chatGuid}) async {
          return PlacedFaceTimeCall(
            link: 'https://facetime.apple.com/join#fallback',
            call: FaceTimeCall(callUuid: uuid),
          );
        },
        onShowError: (title, message) => errors.add('$title: $message'),
      );
      addTearDown(linkController.dispose);

      linkController.startIncoming(
        callUuid: 'abort-3',
        callerName: 'Taylor',
        isVideo: true,
      );
      final videoAnswerFuture = linkController.answerCall();
      await Future<void>.delayed(Duration.zero);
      await linkController.endCall();
      expect(await videoAnswerFuture, isFalse);
      expect(linkController.state.phase, ActiveCallPhase.idle);
      expect(transport.hangups, contains('abort-3'));
      expect(launchedLinks, isEmpty);
      expect(errors, isEmpty);
    });
  });

  group('facetime_call.dart continuity visibility', () {
    test('enables iPhone Cellular option on Web and Android, hides on Desktop', () {
      expect(
        canContinuityCall(
          hasPhone: true,
          isDesktop: false,
          isWeb: true,
          isAndroid: false,
          supportsFaceTimeCalls: true,
          enablePrivateAPI: true,
        ),
        isTrue,
      );
      expect(
        canContinuityCall(
          hasPhone: true,
          isDesktop: false,
          isWeb: false,
          isAndroid: true,
          supportsFaceTimeCalls: true,
          enablePrivateAPI: true,
        ),
        isTrue,
      );
      expect(
        canContinuityCall(
          hasPhone: true,
          isDesktop: true,
          isWeb: false,
          isAndroid: false,
          supportsFaceTimeCalls: true,
          enablePrivateAPI: true,
        ),
        isFalse,
      );
      expect(
        canContinuityCall(
          hasPhone: false,
          isDesktop: false,
          isWeb: true,
          isAndroid: false,
          supportsFaceTimeCalls: true,
          enablePrivateAPI: true,
        ),
        isFalse,
      );
    });
  });
}
