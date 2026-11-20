import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/services/backend/action_handler.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/method_channel_service.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/facetime_api.dart';
import 'package:bluebubbles/services/network/method_channel_actions.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;

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

  tearDown(() {
    ActiveCallController.instance.clear();
    faceTimeOverlays.clear();
    Get.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.bluebubbles.messaging'), null);
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
}
