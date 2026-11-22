import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/outgoing_facetime_sheet.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/facetime_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBaseApi implements BaseApi {
  @override
  final Dio dio;

  _FakeBaseApi(this.dio);

  @override
  String get origin => 'https://server.test';

  @override
  String get apiRoot => 'https://server.test/api/v1';

  @override
  String get apiRootV2 => 'https://server.test/api/v2';

  @override
  Map<String, String> get headers => const {};

  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const {}]) => Map.of(params);

  @override
  Future<Response> runApiGuarded(Future<Response> Function() func, {bool checkOrigin = true}) => func();

  @override
  Future<Response> returnSuccessOrError(Response r) async => r;
}

class _RecordedRequest {
  final String method;
  final String path;
  final Map<String, dynamic> data;

  _RecordedRequest(this.method, this.path, this.data);
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<_RecordedRequest> requests = [];
  final Map<String, dynamic> Function(RequestOptions options) responder;

  _RecordingAdapter(this.responder);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = options.data is Map ? Map<String, dynamic>.from(options.data as Map) : <String, dynamic>{};
    requests.add(_RecordedRequest(options.method, options.path, body));
    final payload = responder(options);
    return ResponseBody.fromString(
      jsonEncode({'status': 200, 'data': payload}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

class _FakePendingCallTab implements PendingCallTab {
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

void main() {
  group('FaceTimeApi session sync contract', () {
    test('sends deviceId, deviceName, displayName, and chatGuid across session endpoints', () async {
      final dio = Dio(BaseOptions(receiveTimeout: const Duration(seconds: 5)));
      final adapter = _RecordingAdapter((options) {
        if (options.path.endsWith('/facetime/sessions')) {
          return {
            'sessions': [
              {'uuid': 'call-1', 'status': 'answered', 'status_id': 1},
            ],
          };
        }
        return {
          'link': options.path.contains('/v2/')
              ? {'url': 'https://facetime.apple.com/join#v2'}
              : 'https://facetime.apple.com/join#v1',
          'call': {'call_uuid': 'call-1', 'status': 'outgoing', 'is_video': true},
          'session': {'uuid': 'call-1', 'status': 'answered', 'status_id': 1},
        };
      });
      dio.httpClientAdapter = adapter;

      final api = FaceTimeApi(
        _FakeBaseApi(dio),
        identityResolver: () => const ClientDeviceIdentity(deviceId: 'dev-android-1', deviceName: 'Android'),
      );

      final created = await api.createFaceTimeSession(displayName: 'Alice', chatGuid: 'iMessage;-;alice');
      expect(created.link, 'https://facetime.apple.com/join#v1');

      final placed = await api.placeFaceTimeCall('+15551234567', displayName: 'Alice', chatGuid: 'iMessage;-;alice');
      expect(placed.link, 'https://facetime.apple.com/join#v2');

      final answered = await api.answerFaceTime('call-1', audioOnly: true, displayName: 'Alice', chatGuid: 'iMessage;-;alice');
      expect(answered.call.callUuid, 'call-1');

      final handedOff = await api.handoffFaceTime('call-1', mode: 'video', displayName: 'Alice', chatGuid: 'iMessage;-;alice');
      expect(handedOff.link, 'https://facetime.apple.com/join#v1');

      await api.setFaceTimeMuted('call-1', true, displayName: 'Alice', chatGuid: 'iMessage;-;alice');
      await api.leaveFaceTime('call-1', displayName: 'Alice', chatGuid: 'iMessage;-;alice');
      await api.declineFaceTime('call-1', displayName: 'Alice', chatGuid: 'iMessage;-;alice');

      final sessions = await api.getFaceTimeSessions();
      expect(sessions, hasLength(1));
      expect(sessions.first['uuid'], 'call-1');

      final postRequests = adapter.requests.where((r) => r.method == 'POST').toList();
      expect(postRequests.map((r) => r.path).toList(), [
        'https://server.test/api/v1/facetime/session',
        'https://server.test/api/v2/facetime/call',
        'https://server.test/api/v1/facetime/session/call-1/answer',
        'https://server.test/api/v1/facetime/session/call-1/handoff',
        'https://server.test/api/v1/facetime/session/call-1/mute',
        'https://server.test/api/v1/facetime/session/call-1/leave',
        'https://server.test/api/v1/facetime/session/call-1/decline',
      ]);
      for (final req in postRequests) {
        expect(req.data['deviceId'], 'dev-android-1');
        expect(req.data['deviceName'], 'Android');
        expect(req.data['displayName'], 'Alice');
        expect(req.data['chatGuid'], 'iMessage;-;alice');
      }
      expect(adapter.requests.last.method, 'GET');
      expect(adapter.requests.last.path, 'https://server.test/api/v1/facetime/sessions');
    });
  });

  group('ActiveCallController cross-device sync & handoff', () {
    test('Web -> Android sync shows On Web and Android can hang up Web call', () async {
      final leftCalls = <String>[];
      final ctrl = ActiveCallController(
        deviceId: 'android-1',
        deviceName: 'Android',
        onLeaveServerCall: (uuid) async => leftCalls.add(uuid),
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(ctrl.dispose);

      ctrl.applyServerSession({
        'uuid': 'web-call-1',
        'status': 'outgoing',
        'status_id': 3,
        'display_name': 'Alice',
        'address': '+15551234567',
        'chat_guid': 'iMessage;-;+15551234567',
        'is_outgoing': true,
        'is_video': true,
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
        'started_at': 1730000000000,
      });

      expect(ctrl.state.phase, ActiveCallPhase.outgoing);
      expect(ctrl.state.isOnOtherDevice, isTrue);
      expect(ctrl.state.isHeldHere, isFalse);
      expect(ctrl.state.canTransferHere, isTrue);
      expect(ctrl.state.statusSubtitle, 'Calling · On Web');

      ctrl.applyServerSession({
        'uuid': 'web-call-1',
        'status': 'answered',
        'status_id': 1,
        'is_video': true,
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
        'answered_at': 1730000005000,
      });

      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.isOnOtherDevice, isTrue);
      expect(ctrl.state.statusSubtitle, 'On Web');
      expect(ctrl.state.chatGuid, 'iMessage;-;+15551234567');

      await ctrl.endCall();
      expect(leftCalls, ['web-call-1']);
      expect(ctrl.state.phase, ActiveCallPhase.idle);
    });

    test('Web <-> Android transfer promotes local audio, then takeover closes Telecom without server leave', () async {
      final handoffModes = <String?>[];
      final startedTelecom = <String>[];
      final endedNative = <Map<String, dynamic>>[];
      final leftCalls = <String>[];

      final androidCtrl = ActiveCallController(
        deviceId: 'android-1',
        deviceName: 'Android',
        onHandoffServerCall: (uuid, {mode}) async {
          handoffModes.add(mode);
          return PlacedFaceTimeCall(
            link: 'https://facetime.apple.com/join#handoff',
            call: FaceTimeCall(callUuid: uuid, isVideo: mode == 'video'),
          );
        },
        onStartTelecomAudio: ({
          required String callUuid,
          required String callerName,
          String? callerAddress,
          bool isTelephony = false,
        }) async {
          startedTelecom.add(callUuid);
          return true;
        },
        onEndNativeCall: (uuid, {onlyIfRinging = false}) async {
          endedNative.add({'uuid': uuid, 'onlyIfRinging': onlyIfRinging});
        },
        onLeaveServerCall: (uuid) async => leftCalls.add(uuid),
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(androidCtrl.dispose);

      androidCtrl.applyServerSession({
        'uuid': 'call-xfer-1',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Bob',
        'address': 'bob@icloud.com',
        'is_video': true,
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
      });
      expect(androidCtrl.state.canTransferHere, isTrue);

      final transferred = await androidCtrl.transferHere(audioOnly: true);
      expect(transferred, isTrue);
      expect(handoffModes, ['audio']);
      expect(startedTelecom, ['call-xfer-1']);
      expect(androidCtrl.state.isHeldHere, isTrue);
      expect(androidCtrl.state.isOnOtherDevice, isFalse);
      expect(androidCtrl.state.isTelecomCall, isTrue);
      expect(androidCtrl.state.statusSubtitle, 'FaceTime Audio');

      // Now Web takes the call back: Android stops Telecom audio locally without calling /leave
      // and keeps the call pill visible as "On Web".
      androidCtrl.applyServerSession({
        'uuid': 'call-xfer-1',
        'status': 'answered',
        'status_id': 1,
        'is_video': true,
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
      });

      expect(endedNative.last, {'uuid': 'call-xfer-1', 'onlyIfRinging': false});
      expect(leftCalls, isEmpty);
      expect(androidCtrl.state.isTelecomCall, isFalse);
      expect(androidCtrl.state.isOnOtherDevice, isTrue);
      expect(androidCtrl.state.statusSubtitle, 'On Web');

      // Server disconnect tears down the remaining UI cleanly.
      androidCtrl.applyServerSession({
        'uuid': 'call-xfer-1',
        'status': 'disconnected',
        'status_id': 6,
      });
      expect(androidCtrl.state.phase, ActiveCallPhase.idle);
    });

    test('PendingCallTab is closed when another device takes over or server disconnects', () async {
      final fakeTab = _FakePendingCallTab();
      final webCtrl = ActiveCallController(
        deviceId: 'web-1',
        deviceName: 'Web',
        onOpenPendingTab: () => fakeTab,
        onHandoffServerCall: (uuid, {mode}) async => PlacedFaceTimeCall(
          link: 'https://facetime.apple.com/join#web',
          call: FaceTimeCall(callUuid: uuid, isVideo: true),
        ),
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(webCtrl.dispose);

      webCtrl.applyServerSession({
        'uuid': 'call-tab-1',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Carol',
        'is_video': true,
        'active_device_id': 'android-1',
        'active_device_name': 'Android',
      });
      final ok = await webCtrl.transferHere(audioOnly: false);
      expect(ok, isTrue);
      expect(fakeTab.navigatedUrl, 'https://facetime.apple.com/join#web');
      expect(fakeTab.closed, isFalse);
      expect(webCtrl.state.isHeldHere, isTrue);

      // Simulate takeover by Android while Web held the call.
      webCtrl.applyServerSession({
        'uuid': 'call-tab-1',
        'status': 'answered',
        'status_id': 1,
        'is_video': false,
        'active_device_id': 'android-1',
        'active_device_name': 'Android',
      });
      expect(fakeTab.closed, isTrue);
      expect(webCtrl.state.statusSubtitle, 'On Android');
      expect(webCtrl.state.canTransferHere, isTrue);
    });

    test('remote answer dismisses incoming overlay and ringing native call', () async {
      final dismissed = <Map<String, dynamic>>[];
      final endedNative = <Map<String, dynamic>>[];
      final ctrl = ActiveCallController(
        deviceId: 'android-1',
        deviceName: 'Android',
        onDismissOverlay: (uuid, {keepCallState = false}) =>
            dismissed.add({'uuid': uuid, 'keepCallState': keepCallState}),
        onEndNativeCall: (uuid, {onlyIfRinging = false}) async =>
            endedNative.add({'uuid': uuid, 'onlyIfRinging': onlyIfRinging}),
      );
      addTearDown(ctrl.dispose);

      ctrl.startIncoming(callUuid: 'ring-1', callerName: 'Dave', isVideo: true);
      expect(ctrl.state.phase, ActiveCallPhase.incoming);

      ctrl.applyServerSession({
        'uuid': 'ring-1',
        'status': 'answered',
        'status_id': 1,
        'is_video': true,
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
      });

      expect(dismissed, [
        {'uuid': 'ring-1', 'keepCallState': true},
      ]);
      expect(endedNative, [
        {'uuid': 'ring-1', 'onlyIfRinging': true},
      ]);
      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.statusSubtitle, 'On Web');
    });

    test('mute syncs both directions (local toggle -> server and server event -> local)', () async {
      final serverMutes = <Map<String, dynamic>>[];
      final ctrl = ActiveCallController(
        deviceId: 'android-1',
        deviceName: 'Android',
        onSetServerMuted: (uuid, muted) async => serverMutes.add({'uuid': uuid, 'muted': muted}),
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(ctrl.dispose);

      ctrl.applyServerSession({
        'uuid': 'mute-1',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Eve',
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
        'is_muted': false,
      });

      ctrl.toggleMute();
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.state.isMuted, isTrue);
      expect(serverMutes, [
        {'uuid': 'mute-1', 'muted': true},
      ]);

      ctrl.applyServerSession({
        'uuid': 'mute-1',
        'status': 'answered',
        'status_id': 1,
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
        'is_muted': false,
      });
      expect(ctrl.state.isMuted, isFalse);

      ctrl.syncMutedFromNative('mute-1', true);
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.state.isMuted, isTrue);
      expect(serverMutes.last, {'uuid': 'mute-1', 'muted': true});
    });

    test('reconnect reconciliation restores active call and clears stale call when server has none', () async {
      var sessionsToReturn = <Map<String, dynamic>>[
        {
          'uuid': 'recon-1',
          'status': 'answered',
          'status_id': 1,
          'display_name': 'Frank',
          'is_video': false,
          'active_device_id': 'web-1',
          'active_device_name': 'Web',
        },
      ];
      final endedNative = <Map<String, dynamic>>[];
      final ctrl = ActiveCallController(
        deviceId: 'android-1',
        deviceName: 'Android',
        onFetchServerSessions: () async => sessionsToReturn,
        onEndNativeCall: (uuid, {onlyIfRinging = false}) async =>
            endedNative.add({'uuid': uuid, 'onlyIfRinging': onlyIfRinging}),
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(ctrl.dispose);

      await ctrl.syncFromServer();
      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.callUuid, 'recon-1');
      expect(ctrl.state.statusSubtitle, 'On Web');

      sessionsToReturn = const [];
      await ctrl.syncFromServer();
      expect(ctrl.state.phase, ActiveCallPhase.idle);
      expect(endedNative.last, {'uuid': 'recon-1', 'onlyIfRinging': false});
    });

    test('failure ended_reason or ended_error notifies error and closes attached PendingCallTab', () async {
      final errors = <Map<String, String>>[];
      final pendingTab = _FakePendingCallTab();
      final ctrl = ActiveCallController(
        deviceId: 'web-1',
        deviceName: 'Web',
        onDismissOverlay: (_, {keepCallState = false}) {},
        onShowError: (title, message) => errors.add({'title': title, 'message': message}),
      );
      addTearDown(ctrl.dispose);

      ctrl.attachPendingCallTab(pendingTab);
      ctrl.applyServerSession({
        'uuid': 'fail-1',
        'status': 'outgoing',
        'status_id': 4,
        'display_name': 'Grace',
        'is_video': true,
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
      });

      ctrl.applyServerSession({
        'uuid': 'fail-1',
        'status': 'disconnected',
        'status_id': 6,
        'ended_reason': 'no_answer',
      });

      expect(ctrl.state.phase, ActiveCallPhase.idle);
      expect(pendingTab.closed, isTrue);
      expect(ctrl.lastFailure?.callUuid, 'fail-1');
      expect(ctrl.lastFailure?.message, 'No answer.');
      expect(errors, [
        {'title': 'Call failed', 'message': 'No answer.'},
      ]);

      // ended_error overrides generic reason message when call was active
      ctrl.applyServerSession({
        'uuid': 'fail-2',
        'status': 'outgoing',
        'status_id': 4,
        'display_name': 'Grace',
        'is_video': true,
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
      });
      ctrl.applyServerSession({
        'uuid': 'fail-2',
        'status': 'disconnected',
        'status_id': 6,
        'ended_reason': 'call_failed',
        'ended_error': 'FaceTime link expired',
      });
      expect(ctrl.lastFailure?.message, 'FaceTime link expired');
      expect(errors.last, {'title': 'Call failed', 'message': 'FaceTime link expired'});

      // First-seen disconnect (never active locally) and ended_reason == 'missed' never trigger error snackbars
      final errorsBefore = errors.length;
      ctrl.applyServerSession({
        'uuid': 'first-seen-1',
        'status': 'disconnected',
        'status_id': 6,
        'ended_reason': 'call_failed',
        'ended_error': 'Stale call failure',
      });
      expect(errors.length, errorsBefore);
      expect(ctrl.lastFailure?.callUuid, 'fail-2');

      ctrl.startIncoming(callUuid: 'missed-1', callerName: 'Grace', isVideo: true);
      ctrl.applyServerSession({
        'uuid': 'missed-1',
        'status': 'disconnected',
        'status_id': 6,
        'ended_reason': 'missed',
        'ended_error': 'Ignored missed error text',
      });
      expect(ctrl.state.phase, ActiveCallPhase.idle);
      expect(errors.length, errorsBefore);
      expect(ctrl.lastFailure?.callUuid, 'fail-2');

      // Normal user_ended does not trigger error banner
      ctrl.applyServerSession({
        'uuid': 'ok-1',
        'status': 'disconnected',
        'status_id': 6,
        'ended_reason': 'user_ended',
      });
      expect(errors.length, errorsBefore);
    });

    test('observer device stays switchable on answered call even when active_device_id is null or omitted', () {
      final ctrl = ActiveCallController(
        deviceId: 'android-2',
        deviceName: 'Pixel',
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(ctrl.dispose);

      ctrl.applyServerSession({
        'uuid': 'obs-1',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Heidi',
        'is_video': true,
      });

      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.isHeldHere, isFalse);
      expect(ctrl.state.canTransferHere, isTrue);

      ctrl.applyServerSession({
        'uuid': 'obs-1',
        'status': 'answered',
        'status_id': 1,
        'active_device_id': 'web-1',
        'active_device_name': 'Web',
      });
      expect(ctrl.state.activeDeviceId, 'web-1');
      expect(ctrl.state.activeDeviceName, 'Web');

      // Subsequent update omitting active_device_id preserves it
      ctrl.applyServerSession({
        'uuid': 'obs-1',
        'status': 'answered',
        'status_id': 1,
        'is_muted': true,
      });
      expect(ctrl.state.activeDeviceId, 'web-1');
      expect(ctrl.state.activeDeviceName, 'Web');
      expect(ctrl.state.isMuted, isTrue);
    });

    test('answerCall and transferHere surface FaceTimeException via onShowError', () async {
      final errors = <String>[];
      final ctrl = ActiveCallController(
        deviceId: 'web-1',
        deviceName: 'Web',
        onAnswerServerCall: (uuid, {audioOnly = false, displayName, chatGuid}) async {
          throw const FaceTimeException('Call already ended', statusCode: 400);
        },
        onHandoffServerCall: (uuid, {mode}) async {
          throw const FaceTimeException('Handoff unavailable', statusCode: 500);
        },
        onDismissOverlay: (_, {keepCallState = false}) {},
        onShowError: (_, message) => errors.add(message),
      );
      addTearDown(ctrl.dispose);

      ctrl.applyServerSession({
        'uuid': 'err-1',
        'status': 'incoming',
        'status_id': 3,
        'display_name': 'Ivan',
      });
      final answered = await ctrl.answerCall();
      expect(answered, isFalse);
      expect(errors, ['Call already ended']);

      ctrl.applyServerSession({
        'uuid': 'err-2',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Ivan',
        'active_device_id': 'mac-1',
        'active_device_name': 'Mac',
      });
      final transferred = await ctrl.transferHere();
      expect(transferred, isFalse);
      expect(errors, ['Call already ended', 'Handoff unavailable']);
    });

    test('Web video WebRTC answerCall and transferHere notify server with video_bridge mode', () async {
      final transport = _FakeWebRtcTransport();
      final answerCalls = <Map<String, dynamic>>[];
      final handoffModes = <Map<String, dynamic>>[];

      final ctrl = ActiveCallController(
        isWebOverride: true,
        webRtcClient: WebWebRtcClient(
          transport: transport,
          adapterFactory: () => _FakeWebRtcAdapter(),
        ),
        deviceId: 'web-1',
        deviceName: 'Chrome',
        onAnswerServerCall: (uuid, {audioOnly = false, displayName, chatGuid}) async {
          answerCalls.add({'uuid': uuid, 'audioOnly': audioOnly});
          return null;
        },
        onHandoffServerCall: (uuid, {mode}) async {
          handoffModes.add({'uuid': uuid, 'mode': mode});
          return null;
        },
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(ctrl.dispose);

      ctrl.startIncoming(callUuid: 'web-vid-1', callerName: 'Alex', isVideo: true);
      expect(await ctrl.answerCall(), isTrue);
      expect(answerCalls, [
        {'uuid': 'web-vid-1', 'audioOnly': false},
      ]);
      expect(ctrl.state.isVideo, isTrue);

      ctrl.applyServerSession({
        'uuid': 'web-vid-2',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Blake',
        'is_video': true,
        'active_device_id': 'mac-1',
        'active_device_name': 'Mac',
      });
      expect(await ctrl.transferHere(audioOnly: false), isTrue);
      expect(handoffModes, [
        {'uuid': 'web-vid-2', 'mode': 'video_bridge'},
      ]);
      expect(ctrl.state.isVideo, isTrue);
      expect(ctrl.state.isHeldHere, isTrue);

      // Production answerCall path (onAnswerServerCall == null) uses _handoffServer(mode: 'video_bridge')
      // and preserves the live call if server metadata sync throws.
      final prodHandoffs = <Map<String, dynamic>>[];
      final prodErrors = <String>[];
      var throwOnHandoff = false;
      final prodCtrl = ActiveCallController(
        isWebOverride: true,
        webRtcClient: WebWebRtcClient(
          transport: transport,
          adapterFactory: () => _FakeWebRtcAdapter(),
        ),
        deviceId: 'web-2',
        deviceName: 'Chrome',
        onHandoffServerCall: (uuid, {mode}) async {
          prodHandoffs.add({'uuid': uuid, 'mode': mode});
          if (throwOnHandoff) throw const FaceTimeException('Sync timeout');
          return null;
        },
        onShowError: (_, msg) => prodErrors.add(msg),
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(prodCtrl.dispose);

      prodCtrl.startIncoming(callUuid: 'web-vid-3', callerName: 'Morgan', isVideo: true);
      expect(await prodCtrl.answerCall(), isTrue);
      expect(prodHandoffs, [
        {'uuid': 'web-vid-3', 'mode': 'video_bridge'},
      ]);
      expect(prodCtrl.state.phase, ActiveCallPhase.ongoing);

      throwOnHandoff = true;
      prodCtrl.startIncoming(callUuid: 'web-vid-4', callerName: 'Morgan', isVideo: true);
      expect(await prodCtrl.answerCall(), isTrue);
      expect(prodCtrl.state.phase, ActiveCallPhase.ongoing);
      expect(prodErrors, isEmpty);
    });

    test('Android native video answerCall and transferHere route via Telecom video_bridge without Apple join link',
        () async {
      final startedTelecom = <Map<String, dynamic>>[];
      final handoffCalls = <Map<String, dynamic>>[];
      final launchedLinks = <String>[];
      var telecomShouldStart = true;

      final ctrl = ActiveCallController(
        deviceId: 'android-1',
        deviceName: 'Pixel',
        onStartTelecomCall: ({
          required String callUuid,
          required String callerName,
          String? callerAddress,
          bool isTelephony = false,
          bool isVideo = false,
        }) async {
          startedTelecom.add({'uuid': callUuid, 'isTelephony': isTelephony, 'isVideo': isVideo});
          return telecomShouldStart;
        },
        onHandoffServerCall: (uuid, {mode}) async {
          handoffCalls.add({'uuid': uuid, 'mode': mode});
          return PlacedFaceTimeCall(
            link: 'https://facetime.apple.com/join#fallback',
            call: FaceTimeCall(callUuid: uuid, isVideo: mode == 'video' || mode == 'video_bridge'),
          );
        },
        onLaunchJoinLink: (link) async {
          launchedLinks.add(link);
          return true;
        },
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(ctrl.dispose);

      ctrl.startIncoming(callUuid: 'and-vid-1', callerName: 'Casey', isVideo: true);
      expect(await ctrl.answerCall(), isTrue);
      expect(startedTelecom.last, {'uuid': 'and-vid-1', 'isTelephony': false, 'isVideo': true});
      expect(handoffCalls.last, {'uuid': 'and-vid-1', 'mode': 'video_bridge'});
      expect(launchedLinks, isEmpty);
      expect(ctrl.state.isVideo, isTrue);
      expect(ctrl.state.isTelecomCall, isTrue);

      ctrl.applyServerSession({
        'uuid': 'and-vid-2',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Casey',
        'is_video': true,
        'active_device_id': 'mac-1',
        'active_device_name': 'Mac',
      });
      expect(await ctrl.transferHere(audioOnly: false), isTrue);
      expect(startedTelecom.last, {'uuid': 'and-vid-2', 'isTelephony': false, 'isVideo': true});
      expect(handoffCalls.last, {'uuid': 'and-vid-2', 'mode': 'video_bridge'});
      expect(launchedLinks, isEmpty);
      expect(ctrl.state.isVideo, isTrue);
      expect(ctrl.state.isTelecomCall, isTrue);
      expect(ctrl.state.isHeldHere, isTrue);

      // When Telecom fails to start on transferHere, fallback uses join-link mode 'video' and launches link.
      telecomShouldStart = false;
      ctrl.applyServerSession({
        'uuid': 'and-vid-3',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Casey',
        'is_video': true,
        'active_device_id': 'mac-1',
        'active_device_name': 'Mac',
      });
      expect(await ctrl.transferHere(audioOnly: false), isTrue);
      expect(handoffCalls.last, {'uuid': 'and-vid-3', 'mode': 'video'});
      expect(launchedLinks, ['https://facetime.apple.com/join#fallback']);
      expect(ctrl.state.isTelecomCall, isFalse);

      // Audio-only onStartTelecomAudio callback must not claim video calls.
      var audioCbCalls = 0;
      final audioOnlyCtrl = ActiveCallController(
        deviceId: 'android-2',
        deviceName: 'Pixel',
        onStartTelecomAudio: ({
          required String callUuid,
          required String callerName,
          String? callerAddress,
          bool isTelephony = false,
        }) async {
          audioCbCalls++;
          return true;
        },
        onHandoffServerCall: (uuid, {mode}) async => PlacedFaceTimeCall(
          link: 'https://facetime.apple.com/join#video-only',
          call: FaceTimeCall(callUuid: uuid, isVideo: true),
        ),
        onLaunchJoinLink: (link) async {
          launchedLinks.add(link);
          return true;
        },
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(audioOnlyCtrl.dispose);
      audioOnlyCtrl.applyServerSession({
        'uuid': 'and-vid-4',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Casey',
        'is_video': true,
        'active_device_id': 'mac-1',
        'active_device_name': 'Mac',
      });
      expect(await audioOnlyCtrl.transferHere(audioOnly: false), isTrue);
      expect(audioCbCalls, 0);
      expect(launchedLinks.last, 'https://facetime.apple.com/join#video-only');
    });

    test('notifyTelecomActive triggers handoff from idle and preserves audio mode on transferHere(audioOnly: null)',
        () async {
      final handoffs = <Map<String, dynamic>>[];
      final ctrl = ActiveCallController(
        deviceId: 'android-1',
        deviceName: 'Pixel',
        onHandoffServerCall: (uuid, {mode}) async {
          handoffs.add({'uuid': uuid, 'mode': mode});
          return PlacedFaceTimeCall(
            link: 'https://facetime.apple.com/join#xfer',
            call: FaceTimeCall(callUuid: uuid, isVideo: mode == 'video' || mode == 'video_bridge'),
          );
        },
        onLaunchJoinLink: (_) async => true,
        onDismissOverlay: (_, {keepCallState = false}) {},
      );
      addTearDown(ctrl.dispose);

      ctrl.handleFacetimeCallState({'phase': 'active', 'call_uuid': 'idle-vid-1', 'is_video': true});
      await pumpEventQueue();
      expect(handoffs, [
        {'uuid': 'idle-vid-1', 'mode': 'video_bridge'},
      ]);
      expect(ctrl.state.isVideo, isTrue);
      expect(ctrl.state.isTelecomCall, isTrue);

      ctrl.applyServerSession({
        'uuid': 'idle-vid-1',
        'status': 'disconnected',
        'status_id': 6,
        'ended_reason': 'user_ended',
      });
      ctrl.applyServerSession({
        'uuid': 'aud-xfer-1',
        'status': 'answered',
        'status_id': 1,
        'display_name': 'Dana',
        'is_video': false,
        'active_device_id': 'mac-1',
        'active_device_name': 'Mac',
      });
      expect(await ctrl.transferHere(), isTrue);
      expect(handoffs.last, {'uuid': 'aud-xfer-1', 'mode': 'audio'});
      expect(ctrl.state.isVideo, isFalse);
    });

    testWidgets('OutgoingFaceTimeSheet routes Android outbound video natively into ongoing state', (tester) async {
      final ctrl = ActiveCallController(deviceId: 'android-1', deviceName: 'Pixel');
      addTearDown(ctrl.dispose);
      final nativeCalls = <bool>[];
      var serverCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OutgoingFaceTimeSheet(
              callerName: 'Eli',
              callerAddress: 'eli@icloud.com',
              initialVideo: true,
              isAndroid: true,
              callController: ctrl,
              checkTelecomEnabled: () async => true,
              onOpenCallingAccounts: () async {},
              requestCallPermissions: () async => true,
              onPlaceNativeAudioCall: () async => false,
              onPlaceNativeCall: (isVideo) async {
                nativeCalls.add(isVideo);
                return true;
              },
              onStartServerCall: (_) async {
                serverCalls++;
                return const PlacedFaceTimeCall(call: FaceTimeCall(callUuid: 'out-1'));
              },
              onOpenJoinLink: (_) async {},
              onHangUpRingingCall: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(nativeCalls, [true]);
      expect(serverCalls, 0);
      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.isVideo, isTrue);
      expect(ctrl.state.isTelecomCall, isTrue);
    });
  });
}

class _FakeWebRtcTransport implements WebRtcSignalingTransport {
  void Function(Map<String, dynamic>)? _answerHandler;

  @override
  Future<dynamic> fetchBridgeConfig({Duration timeout = const Duration(seconds: 3)}) async => {
        'iceServers': <Map<String, dynamic>>[],
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
    scheduleMicrotask(() {
      _answerHandler?.call({
        'callUuid': callUuid,
        'type': 'answer',
        'sdp': 'v=0\r\nfake-answer-$callUuid',
        'uplinkVideo': uplinkVideo,
      });
    });
  }

  @override
  void emitIceCandidate({required String callUuid, required String candidate, String? sdpMid, int? sdpMLineIndex}) {}

  @override
  void emitMute({required String callUuid, required bool muted}) {}

  @override
  void emitCamera({required String callUuid, required bool enabled}) {}

  @override
  void emitHangup({required String callUuid}) {}

  @override
  void onAnswer(void Function(Map<String, dynamic> data) handler) => _answerHandler = handler;

  @override
  void onIceCandidate(void Function(Map<String, dynamic> data) handler) {}

  @override
  void offListeners() => _answerHandler = null;
}

class _FakeWebRtcAdapter implements WebRtcPeerAdapter {
  @override
  bool get isSupported => true;

  @override
  bool get hasLocalVideo => true;

  @override
  bool get canFlipCamera => false;

  @override
  bool get isFrontCamera => true;

  @override
  Future<void> initialize({required List<WebRtcIceServer> iceServers, required bool wantVideo}) async {}

  @override
  Future<WebRtcSessionDescription> createAndSetOffer() async =>
      const WebRtcSessionDescription(type: 'offer', sdp: 'v=0\r\nfake-offer');

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
