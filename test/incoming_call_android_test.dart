import 'dart:async';

import 'package:bluebubbles/app/components/app_notice_bar.dart';
import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/backend/action_handler.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/intents_service.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/method_channel_service.dart';
import 'package:bluebubbles/services/backend/lifecycle/lifecycle_service.dart';
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
import 'package:receive_intent/receive_intent.dart' as receive_intent;

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
    hideInAppCallScreen();
    AppNoticeController.instance.resetForTest();
    ActiveCallController.instance.clear();
    faceTimeOverlays.clear();
    faceTimeIncomingActions.clear();
    await GetIt.I.reset();
    Get.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.bluebubbles.messaging'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null);
  });

  testWidgets('IncomingFaceTimeScreen hides video actions and labels Phone Call for telephony',
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

    expect(find.text('Phone Call'), findsOneWidget);
    expect(find.text('Incoming Phone Call'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Answer with audio'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Decline'));
    await tester.pump();
    expect(declined, isTrue);

    await tester.tap(find.bySemanticsLabel('Accept'));
    await tester.pump();
    expect(answeredAudio, isTrue);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Connecting audio…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
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

    final smallAvatar = Uint8List(512);
    await actions.markFaceTimeCallActive(
      callUuid: 'out-2',
      isOutgoing: true,
      callerName: 'Alice, Bob',
      callerAddress: '+15551112222',
      callerAvatar: smallAvatar,
      isVideo: true,
      isGroup: true,
      isTelephony: false,
    );
    final args2 = Map<String, dynamic>.from(recorded[2].arguments as Map);
    expect(args2['call_uuid'], 'out-2');
    expect(args2['callerName'], 'Alice, Bob');
    expect(args2['callerAddress'], '+15551112222');
    expect(args2['callerAvatar'], smallAvatar);
    expect(args2['isVideo'], isTrue);
    expect(args2['isGroup'], isTrue);
    expect(args2['isTelephony'], isFalse);

    final oversizeAvatar = Uint8List(100 * 1024 + 1);
    await actions.markFaceTimeCallActive(
      callUuid: 'out-3',
      isOutgoing: false,
      callerName: 'Carol',
      callerAvatar: oversizeAvatar,
    );
    final args3 = Map<String, dynamic>.from(recorded[3].arguments as Map);
    expect(args3.containsKey('callerAvatar'), isFalse);
    expect(args3['callerName'], 'Carol');
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
      onAnswerServerCall: (uuid, {audioOnly = false, mode, displayName, chatGuid}) async {
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
    expect(telecomCalls.last, {'callUuid': 'ft-cold-audio', 'callerName': 'FaceTime Audio', 'isTelephony': false});
    expect(recorded.map((m) => m.method), isNot(contains('open-calling-accounts')));
    expect(ctrl.state.phase, ActiveCallPhase.ongoing);
    expect(ctrl.state.isVideo, isFalse);
  });

  testWidgets('Android audio, telephony, and video answerCall() opens InAppCallScreen immediately before handoff completes',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      late BuildContext rootContext;
      await tester.pumpWidget(
        GetMaterialApp(
          key: UniqueKey(),
          home: Builder(
            builder: (context) {
              rootContext = context;
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );
      await tester.pump();

      Completer<PlacedFaceTimeCall?>? pendingHandoff;
      final ctrl = ActiveCallController(
        onStartTelecomCall: ({
          required callUuid,
          required callerName,
          callerAddress,
          isTelephony = false,
          isVideo = false,
        }) async =>
            true,
        onHandoffServerCall: (uuid, {mode}) => pendingHandoff!.future,
        onDismissOverlay: (uuid, {keepCallState = false}) {
          hideFaceTimeOverlay(uuid, keepCallState: keepCallState);
        },
      );
      addTearDown(ctrl.dispose);

      // 1. FaceTime Audio pickup opens InAppCallScreen immediately before _handoffServer completes.
      pendingHandoff = Completer<PlacedFaceTimeCall?>();
      ctrl.startIncoming(callUuid: 'pickup-audio-1', callerName: 'Alice', isVideo: false);
      final audioFuture = ctrl.answerCall(audioOnly: true, context: rootContext);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.isVideo, isFalse);
      expect(find.byType(InAppCallScreen), findsOneWidget);
      pendingHandoff.complete(null);
      expect(await audioFuture, isTrue);

      hideInAppCallScreen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // 2. Telephony pickup opens InAppCallScreen immediately before _handoffServer completes.
      pendingHandoff = Completer<PlacedFaceTimeCall?>();
      ctrl.startIncoming(callUuid: 'pickup-tel-1', callerName: 'Mom', isVideo: false, isTelephony: true);
      final telFuture = ctrl.answerCall(audioOnly: true, context: rootContext);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.isTelephony, isTrue);
      expect(find.byType(InAppCallScreen), findsOneWidget);
      pendingHandoff.complete(null);
      expect(await telFuture, isTrue);

      hideInAppCallScreen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // 3. Video pickup also opens InAppCallScreen immediately before _handoffServer completes.
      pendingHandoff = Completer<PlacedFaceTimeCall?>();
      ctrl.startIncoming(callUuid: 'pickup-vid-1', callerName: 'Dan', isVideo: true);
      final vidFuture = ctrl.answerCall(audioOnly: false, context: rootContext);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.isVideo, isTrue);
      expect(find.byType(InAppCallScreen), findsOneWidget);
      pendingHandoff.complete(null);
      expect(await vidFuture, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('IntentsService.handleIntent opens InAppCallScreen for openCall without regressing ongoing state',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      if (!StartupTasks.uiReady.isCompleted) StartupTasks.uiReady.complete();
      GetIt.I.registerSingleton<LifecycleService>(LifecycleService());

      await tester.pumpWidget(
        GetMaterialApp(
          key: UniqueKey(),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pump();

      final ctrl = ActiveCallController();
      addTearDown(ctrl.dispose);
      final intents = IntentsService()..callControllerOverride = ctrl;

      // 1. Existing ongoing call tapped via OpenCall (even without openCall extra) stays ongoing and opens InAppCallScreen.
      ctrl.startOngoing(
        callUuid: 'ongoing-open-1',
        callerName: 'Alice',
        isVideo: false,
        isTelecomCall: true,
      );
      await intents.handleIntent(
        const receive_intent.Intent(
          isNull: false,
          extra: {'callUuid': 'ongoing-open-1'},
        ),
        isInitialIntent: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.callerName, 'Alice');
      expect(faceTimeOverlays, isEmpty);
      expect(find.byType(InAppCallScreen), findsOneWidget);

      hideInAppCallScreen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // 2. Cold-start openCall=true from idle hydrates ongoing state with caller metadata and opens InAppCallScreen.
      ctrl.clear();
      await intents.handleIntent(
        const receive_intent.Intent(
          isNull: false,
          extra: {
            'callUuid': 'cold-open-1',
            'openCall': true,
            'audioOnly': true,
            'isTelephony': true,
            'caller': 'Mom',
          },
        ),
        isInitialIntent: true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.callUuid, 'cold-open-1');
      expect(ctrl.state.callerName, 'Mom');
      expect(ctrl.state.isTelephony, isTrue);
      expect(ctrl.state.isVideo, isFalse);
      expect(ctrl.state.isTelecomCall, isTrue);
      expect(faceTimeOverlays, isEmpty);
      expect(find.byType(InAppCallScreen), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('IntentsService.handleIntent with OpenSummary (answer=false) pushes IncomingFaceTimeScreen',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      if (!StartupTasks.uiReady.isCompleted) StartupTasks.uiReady.complete();
      GetIt.I.registerSingleton<LifecycleService>(LifecycleService());

      await tester.pumpWidget(
        GetMaterialApp(
          key: UniqueKey(),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pump();

      final ctrl = ActiveCallController();
      addTearDown(ctrl.dispose);
      final intents = IntentsService()..callControllerOverride = ctrl;

      await intents.handleIntent(
        const receive_intent.Intent(
          isNull: false,
          extra: {
            'callUuid': 'summary-1',
            'answer': false,
            'audioOnly': false,
            'caller': 'Elena',
          },
        ),
        isInitialIntent: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(ctrl.state.phase, ActiveCallPhase.incoming);
      expect(ctrl.state.callerName, 'Elena');
      expect(faceTimeOverlays['summary-1'], isNotNull);
      expect(find.byType(IncomingFaceTimeScreen), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('IntentsService.handleIntent with answer=true preserves caller extra on cold start and opens InAppCallScreen',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      if (!StartupTasks.uiReady.isCompleted) StartupTasks.uiReady.complete();
      GetIt.I.registerSingleton<LifecycleService>(LifecycleService());

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.bluebubbles.messaging'),
        (call) async {
          if (call.method == 'is-telecom-enabled') return true;
          return true;
        },
      );
      final svc = _TestMethodChannelService();
      svc.actions = MethodChannelActions(svc);
      GetIt.I.registerSingleton<MethodChannelService>(svc);

      await tester.pumpWidget(
        GetMaterialApp(
          key: UniqueKey(),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pump();

      final ctrl = ActiveCallController(
        onStartTelecomCall: ({
          required callUuid,
          required callerName,
          callerAddress,
          isTelephony = false,
          isVideo = false,
        }) async =>
            true,
        onHandoffServerCall: (uuid, {mode}) async => null,
        onDismissOverlay: (uuid, {keepCallState = false}) {
          hideFaceTimeOverlay(uuid, keepCallState: keepCallState);
        },
      );
      addTearDown(ctrl.dispose);
      final intents = IntentsService()..callControllerOverride = ctrl;

      await intents.handleIntent(
        const receive_intent.Intent(
          isNull: false,
          extra: {
            'callUuid': 'cold-ans-1',
            'answer': true,
            'audioOnly': true,
            'isTelephony': false,
            'caller': 'Maya Lin',
          },
        ),
        isInitialIntent: true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.callUuid, 'cold-ans-1');
      expect(ctrl.state.callerName, 'Maya Lin');
      expect(ctrl.state.isVideo, isFalse);
      expect(find.byType(InAppCallScreen), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('ActiveCallController.notifyTelecomActive dismisses incoming overlay and opens InAppCallScreen (including post-frame retry)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final ctrl = ActiveCallController(
        onHandoffServerCall: (uuid, {mode}) async => null,
      );
      addTearDown(ctrl.dispose);

      // 1. Active widget tree with IncomingFaceTimeScreen open -> notifyTelecomActive dismisses it and opens InAppCallScreen.
      await tester.pumpWidget(
        GetMaterialApp(
          key: UniqueKey(),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pump();

      await showFaceTimeOverlay('telecom-active-1', 'Noah', null, true, controller: ctrl);
      openIncomingFaceTimeScreen('telecom-active-1', context: Get.context, controller: ctrl);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(IncomingFaceTimeScreen), findsOneWidget);
      expect(faceTimeOverlays['telecom-active-1'], isNotNull);

      ctrl.handleFacetimeCallState({
        'phase': 'active',
        'call_uuid': 'telecom-active-1',
        'is_video': false,
        'caller_name': 'Noah',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.callerName, 'Noah');
      expect(faceTimeOverlays.containsKey('telecom-active-1'), isFalse);
      expect(find.byType(IncomingFaceTimeScreen), findsNothing);
      expect(find.byType(InAppCallScreen), findsOneWidget);

      // 2. Post-frame retry when Navigator is not yet mounted at the moment notifyTelecomActive fires.
      hideInAppCallScreen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      ctrl.clear();
      Get.reset();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      ctrl.handleFacetimeCallState({
        'phase': 'active',
        'call_uuid': 'telecom-retry-1',
        'is_video': true,
        'caller_name': 'Zoe',
      });
      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(ctrl.state.callerName, 'Zoe');
      expect(ctrl.state.isVideo, isTrue);

      await tester.pumpWidget(
        GetMaterialApp(
          key: UniqueKey(),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(InAppCallScreen), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('IntentsService.handleIntent dedupes duplicate OpenSummary and replaces incoming screen on openCall',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      if (!StartupTasks.uiReady.isCompleted) StartupTasks.uiReady.complete();
      GetIt.I.registerSingleton<LifecycleService>(LifecycleService());

      await tester.pumpWidget(
        GetMaterialApp(
          key: UniqueKey(),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pump();

      final ctrl = ActiveCallController();
      addTearDown(ctrl.dispose);
      final intents = IntentsService()..callControllerOverride = ctrl;

      await intents.handleIntent(
        const receive_intent.Intent(
          isNull: false,
          extra: {
            'callUuid': 'dup-summary-1',
            'answer': false,
            'audioOnly': false,
            'caller': 'Elena',
          },
        ),
        isInitialIntent: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(ctrl.state.phase, ActiveCallPhase.incoming);
      final firstRoute = faceTimeOverlays['dup-summary-1'];
      final firstActions = faceTimeIncomingActions['dup-summary-1'];
      expect(firstRoute, isNotNull);
      expect(find.byType(IncomingFaceTimeScreen), findsOneWidget);

      // Second OpenSummary for the same uuid keeps state == incoming and does not recreate overlay/route.
      await intents.handleIntent(
        const receive_intent.Intent(
          isNull: false,
          extra: {
            'callUuid': 'dup-summary-1',
            'answer': false,
            'audioOnly': false,
            'caller': 'Elena',
          },
        ),
        isInitialIntent: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(ctrl.state.phase, ActiveCallPhase.incoming);
      expect(identical(faceTimeOverlays['dup-summary-1'], firstRoute), isTrue);
      expect(identical(faceTimeIncomingActions['dup-summary-1'], firstActions), isTrue);
      expect(find.byType(IncomingFaceTimeScreen), findsOneWidget);

      // openCall removes the incoming screen and opens a single InAppCallScreen without stacking.
      await intents.handleIntent(
        const receive_intent.Intent(
          isNull: false,
          extra: {
            'callUuid': 'dup-summary-1',
            'openCall': true,
            'caller': 'Elena',
          },
        ),
        isInitialIntent: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(ctrl.state.phase, ActiveCallPhase.ongoing);
      expect(faceTimeOverlays.containsKey('dup-summary-1'), isFalse);
      expect(find.byType(IncomingFaceTimeScreen), findsNothing);
      expect(find.byType(InAppCallScreen), findsOneWidget);

      // Repeated openCall does not stack a second InAppCallScreen.
      await intents.handleIntent(
        const receive_intent.Intent(
          isNull: false,
          extra: {
            'callUuid': 'dup-summary-1',
            'openCall': true,
            'caller': 'Elena',
          },
        ),
        isInitialIntent: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byType(InAppCallScreen), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
