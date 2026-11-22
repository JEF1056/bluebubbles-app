import 'package:bluebubbles/app/components/app_notice_bar.dart';
import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/backend/action_handler.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/intents_service.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/method_channel_service.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/facetime_api.dart';
import 'package:bluebubbles/services/network/method_channel_actions.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';

class _TestMethodChannelService extends MethodChannelService {
  _TestMethodChannelService() {
    channel = const MethodChannel('com.bluebubbles.messaging');
  }

  @override
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) =>
      channel.invokeMethod(method, arguments);
}

class _FakeBaseApi implements BaseApi {
  _FakeBaseApi(this.dio);

  @override
  final Dio dio;

  @override
  String get apiRoot => '/api/v1';

  @override
  String get apiRootV2 => '/api/v2';

  @override
  Map<String, String> get headers => const {};

  @override
  String get origin => 'https://example.test';

  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const {}]) => Map.of(params);

  @override
  Future<Response> returnSuccessOrError(Response r) async => r;

  @override
  Future<Response> runApiGuarded(Future<Response> Function() func, {bool checkOrigin = true}) => func();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    AppNoticeController.instance.resetForTest();
    ActiveCallController.instance.clear();
    faceTimeOverlays.clear();
    await GetIt.I.reset();
    Get.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.bluebubbles.messaging'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null);
  });

  testWidgets('IncomingFaceTimeScreen hides video actions and labels iPhone Call for telephony',
      (tester) async {
    var answeredAudio = false;
    var declined = false;

    await tester.pumpWidget(
      MaterialApp(
        home: IncomingFaceTimeScreen(
          callUuid: 'cell-1',
          callerName: '+15551234567',
          isTelephony: true,
          onAnswerAudio: () => answeredAudio = true,
          onDecline: () => declined = true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('iPhone Call'), findsOneWidget);
    expect(find.text('Incoming iPhone Call'), findsOneWidget);
    expect(find.text('Answer Audio'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Answer Video'), findsNothing);
    expect(find.text('Audio Only'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Decline'));
    await tester.pump();
    expect(declined, isTrue);

    await tester.tap(find.bySemanticsLabel('Answer Audio'));
    await tester.pump();
    expect(answeredAudio, isTrue);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Connecting audio…'), findsOneWidget);
  });

  test('ActiveCallController propagates isTelephony and forces audio-only', () {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);

    controller.startIncoming(
      callUuid: 'cell-2',
      callerName: 'iPhone call',
      callerAddress: '+15550001111',
      isVideo: true,
      isTelephony: true,
    );
    expect(controller.state.isTelephony, isTrue);
    expect(controller.state.isVideo, isFalse);

    controller.setConnecting(callUuid: 'cell-2');
    expect(controller.state.isTelephony, isTrue);
    expect(controller.state.isVideo, isFalse);

    controller.startOngoing(
      callUuid: 'cell-2',
      callerName: 'iPhone call',
      isVideo: false,
      isTelecomCall: true,
      isTelephony: true,
    );
    expect(controller.state.isTelephony, isTrue);
    expect(controller.state.isTelecomCall, isTrue);
  });

  testWidgets('ActionHandler status_id=1 dismisses incoming overlay while preserving ongoing call state',
      (tester) async {
    late BuildContext rootContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            rootContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await showFaceTimeOverlay(
      'call-ans-1',
      'Maya',
      null,
      true,
      isTelephony: true,
      context: rootContext,
    );
    await tester.pump();
    expect(faceTimeOverlays.containsKey('call-ans-1'), isTrue);

    ActiveCallController.instance.startOngoing(
      callUuid: 'call-ans-1',
      callerName: 'Maya',
      isVideo: false,
      isTelecomCall: true,
      isTelephony: true,
    );

    final handler = ActionHandler();
    await handler.handleFaceTimeStatusChange({'status_id': 1, 'uuid': 'call-ans-1'});
    await tester.pumpAndSettle();

    expect(faceTimeOverlays.containsKey('call-ans-1'), isFalse);
    expect(ActiveCallController.instance.state.phase, ActiveCallPhase.ongoing);
    expect(ActiveCallController.instance.state.callUuid, 'call-ans-1');

    await handler.handleFaceTimeStatusChange({'status_id': 6, 'uuid': 'call-ans-1'});
    expect(ActiveCallController.instance.state.phase, ActiveCallPhase.idle);
  });

  test('MethodChannelActions sends is_telephony, only_if_ringing, and answer-facetime-audio', () async {
    final recorded = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.bluebubbles.messaging'),
      (call) async {
        recorded.add(call);
        return true;
      },
    );

    final svc = _TestMethodChannelService();
    final actions = MethodChannelActions(svc);
    svc.actions = actions;

    expect(
      await actions.createIncomingFaceTimeNotification(
        channelId: 'facetime',
        notificationId: 42,
        title: 'Mom',
        body: 'Incoming iPhone Call',
        callerAvatar: Uint8List(0),
        caller: 'Mom',
        callUuid: 'cell-3',
        isVideo: false,
        callerAddress: '+15551234567',
        isTelephony: true,
      ),
      isTrue,
    );
    expect(recorded.last.method, 'create-incoming-facetime-notification');
    expect(recorded.last.arguments['is_telephony'], isTrue);
    expect(recorded.last.arguments['is_video'], isFalse);

    expect(await actions.endFaceTimeCall(callUuid: 'cell-3', onlyIfRinging: true), isTrue);
    expect(recorded.last.method, 'end-facetime-call');
    expect(recorded.last.arguments, {'call_uuid': 'cell-3', 'only_if_ringing': true});

    expect(
      await actions.answerFaceTimeAudio(
        callUuid: 'cell-3',
        callerName: 'Mom',
        callerAddress: '+15551234567',
        isTelephony: true,
      ),
      isTrue,
    );
    expect(recorded.last.method, 'answer-facetime-audio');
    expect(recorded.last.arguments, {
      'call_uuid': 'cell-3',
      'caller_name': 'Mom',
      'caller_address': '+15551234567',
      'is_telephony': true,
    });
  });

  test('FaceTimeApi.dtmf validates digits and posts normalized payload', () async {
    RequestOptions? captured;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(Response(requestOptions: options, statusCode: 200, data: {'status': 200}));
        },
      ),
    );
    final api = FaceTimeApi(_FakeBaseApi(dio));

    await expectLater(api.dtmf('call-1', 'E'), throwsArgumentError);
    await expectLater(api.dtmf('call-1', '12'), throwsArgumentError);
    await expectLater(api.dtmf('', '1'), throwsArgumentError);

    final resp = await api.dtmf('call-1', 'a');
    expect(resp.statusCode, 200);
    expect(captured?.method, 'POST');
    expect(captured?.path, '/api/v1/facetime/dtmf');
    expect(captured?.data, {'callUuid': 'call-1', 'digit': 'A'});
  });

  test('ActionHandler status_id=1 marks outgoing Telecom call connected and preserves pill', () async {
    ActiveCallController.instance.startOngoing(
      callerName: 'Outgoing Audio',
      isVideo: false,
      isTelecomCall: true,
    );
    ActiveCallController.instance.bindCallUuid('out-audio-1', isTelephony: true);
    final initialConnectedAt = ActiveCallController.instance.state.connectedAt!;

    await ActionHandler().handleFaceTimeStatusChange({
      'uuid': 'out-audio-1',
      'status_id': 1,
      'is_outgoing': true,
      'is_telephony': true,
    });

    expect(ActiveCallController.instance.state.phase, ActiveCallPhase.ongoing);
    expect(ActiveCallController.instance.state.callUuid, 'out-audio-1');
    expect(ActiveCallController.instance.state.isTelephony, isTrue);
    expect(ActiveCallController.instance.state.connectedAt, isNotNull);
    expect(ActiveCallController.instance.state.connectedAt!.isBefore(initialConnectedAt), isFalse);
  });

  test('MethodChannelActions sends mark-facetime-call-active and set-facetime-muted', () async {
    final recorded = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.bluebubbles.messaging'),
      (call) async {
        recorded.add(call);
        return true;
      },
    );
    final svc = _TestMethodChannelService();
    final actions = MethodChannelActions(svc);
    svc.actions = actions;

    expect(await actions.markFaceTimeCallActive(callUuid: 'out-1', isOutgoing: true), isTrue);
    expect(await actions.setFaceTimeMuted(callUuid: 'out-1', muted: true), isTrue);

    expect(recorded.map((m) => m.method).toList(), [
      'mark-facetime-call-active',
      'set-facetime-muted',
    ]);
    expect(recorded[0].arguments, {'call_uuid': 'out-1', 'is_outgoing': true});
    expect(recorded[1].arguments, {'call_uuid': 'out-1', 'muted': true});
  });

  test('IntentsService.answerFaceTime routes Android non-telephony FaceTime Audio through ActiveCallController',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AppNoticeController.instance.registerHost();

    final recorded = <MethodCall>[];
    var telecomEnabled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.bluebubbles.messaging'),
      (call) async {
        recorded.add(call);
        if (call.method == 'is-telecom-enabled') return telecomEnabled;
        return true;
      },
    );
    final svc = _TestMethodChannelService();
    svc.actions = MethodChannelActions(svc);
    GetIt.I.registerSingleton<MethodChannelService>(svc);

    final telecomCalls = <Map<String, Object?>>[];
    var serverAnswerCalls = 0;
    var launchedLinks = 0;
    final ctrl = ActiveCallController(
      onStartTelecomAudio: ({
        required callUuid,
        required callerName,
        callerAddress,
        isTelephony = false,
      }) async {
        telecomCalls.add({
          'callUuid': callUuid,
          'callerName': callerName,
          'isTelephony': isTelephony,
        });
        return telecomEnabled;
      },
      onAnswerServerCall: (uuid, {audioOnly = false, displayName, chatGuid}) async {
        serverAnswerCalls++;
        return PlacedFaceTimeCall(
          link: 'https://facetime.apple.com/join#$uuid',
          call: FaceTimeCall(callUuid: uuid, isVideo: !audioOnly),
        );
      },
      onLaunchJoinLink: (_) async {
        launchedLinks++;
        return true;
      },
      onDismissOverlay: (_, {keepCallState = false}) {},
    );
    addTearDown(ctrl.dispose);

    final intents = IntentsService()..callControllerOverride = ctrl;

    // 1. Incoming FaceTime Video answered audio-only with Telecom enabled -> Telecom, no web link.
    // Note: ActiveCallController invokes onAnswerServerCall as the test hook for server handoff when routed.
    ctrl.startIncoming(callUuid: 'ft-audio-1', callerName: 'Alice', isVideo: true);
    await intents.answerFaceTime('ft-audio-1', audioOnly: true);
    expect(telecomCalls, [
      {'callUuid': 'ft-audio-1', 'callerName': 'Alice', 'isTelephony': false},
    ]);
    expect(serverAnswerCalls, 1);
    expect(launchedLinks, 0);
    expect(ctrl.state.phase, ActiveCallPhase.ongoing);
    expect(ctrl.state.isTelecomCall, isTrue);

    // 2. Incoming non-telephony FaceTime Audio (!wasVideo) answered without explicit audioOnly -> Telecom.
    ctrl.startIncoming(callUuid: 'ft-audio-2', callerName: 'Bob', isVideo: false);
    await intents.answerFaceTime('ft-audio-2');
    expect(telecomCalls.last, {'callUuid': 'ft-audio-2', 'callerName': 'Bob', 'isTelephony': false});
    expect(serverAnswerCalls, 2);
    expect(launchedLinks, 0);

    // 3. Telecom disabled -> opens Calling Accounts + snackbar, never falls back to web link.
    telecomEnabled = false;
    recorded.clear();
    ctrl.startIncoming(callUuid: 'ft-audio-3', callerName: 'Carol', isVideo: false);
    await intents.answerFaceTime('ft-audio-3', audioOnly: true);
    expect(recorded.map((m) => m.method), contains('open-calling-accounts'));
    expect(AppNoticeController.instance.current.value?.title, 'Enable Calling Accounts');
    expect(serverAnswerCalls, 2);
    expect(launchedLinks, 0);

    // 4. Incoming FaceTime Video answered as video -> delegates to ActiveCallController.answerCall, no Calling Accounts.
    recorded.clear();
    ctrl.startIncoming(callUuid: 'ft-video-1', callerName: 'Dan', isVideo: true);
    await intents.answerFaceTime('ft-video-1');
    expect(recorded.map((m) => m.method), isNot(contains('open-calling-accounts')));
    expect(serverAnswerCalls, 3);
    expect(launchedLinks, 1);
    expect(ctrl.state.phase, ActiveCallPhase.ongoing);
    expect(ctrl.state.isVideo, isTrue);
    expect(ctrl.state.joinLink, 'https://facetime.apple.com/join#ft-video-1');

    // 5. Cold-start audio intent (no prior state) answers as audio via Telecom without opening Calling Accounts.
    telecomEnabled = true;
    recorded.clear();
    ctrl.clear();
    await intents.answerFaceTime('ft-cold-audio', audioOnly: true);
    expect(telecomCalls.last, {'callUuid': 'ft-cold-audio', 'callerName': 'FaceTime Call', 'isTelephony': false});
    expect(recorded.map((m) => m.method), isNot(contains('open-calling-accounts')));
    expect(ctrl.state.phase, ActiveCallPhase.ongoing);
    expect(ctrl.state.isVideo, isFalse);
  });
}
