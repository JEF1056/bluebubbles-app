import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/method_channel_service.dart';
import 'package:bluebubbles/services/backend/notifications/notifications_service.dart';
import 'package:bluebubbles/services/network/method_channel_actions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _TestMethodChannelService extends MethodChannelService {
  _TestMethodChannelService() {
    channel = const MethodChannel('com.bluebubbles.messaging');
    actions = MethodChannelActions(this);
  }

  @override
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) =>
      channel.invokeMethod(method, arguments);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final recordedMethodCalls = <MethodCall>[];

  setUp(() {
    recordedMethodCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.bluebubbles.messaging'),
      (call) async {
        recordedMethodCalls.add(call);
        return true;
      },
    );

    if (!GetIt.I.isRegistered<MethodChannelService>()) {
      GetIt.I.registerSingleton<MethodChannelService>(_TestMethodChannelService());
    }
    if (!GetIt.I.isRegistered<NotificationsService>()) {
      GetIt.I.registerSingleton<NotificationsService>(NotificationsService());
    }
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    hideInAppCallScreen();
    faceTimeOverlays.clear();
    faceTimeIncomingActions.clear();
    ActiveCallController.instance.clear();
  });

  test('repeated showFaceTimeOverlay for an already-tracked uuid does not call endFaceTimeCall or clear controller', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const callUuid = 'ft-lifecycle-dup-1';

    // First incoming overlay arrival
    await showFaceTimeOverlay(
      callUuid,
      'Alice Original',
      null,
      false,
      callerAddress: '+15551111111',
    );

    expect(ActiveCallController.instance.state.phase, ActiveCallPhase.incoming);
    expect(ActiveCallController.instance.state.callUuid, callUuid);
    expect(ActiveCallController.instance.state.callerName, 'Alice Original');
    expect(ActiveCallController.instance.state.callerAddress, '+15551111111');
    expect(faceTimeOverlays.containsKey(callUuid), isTrue);
    expect(faceTimeIncomingActions.containsKey(callUuid), isTrue);

    // Track dummy route object in overlays to verify route is kept
    final dummyRoute = MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink());
    faceTimeOverlays[callUuid] = dummyRoute;

    recordedMethodCalls.clear();

    // Repeated incoming event arrives for the exact same uuid
    await showFaceTimeOverlay(
      callUuid,
      'Alice Updated',
      null,
      false,
      callerAddress: '+15552222222',
    );

    // Must NOT call endFaceTimeCall natively
    final endCallInvocations = recordedMethodCalls.where((c) => c.method == 'end-facetime-call');
    expect(endCallInvocations, isEmpty);

    // Controller must remain active and updated in place
    expect(ActiveCallController.instance.state.phase, ActiveCallPhase.incoming);
    expect(ActiveCallController.instance.state.callUuid, callUuid);
    expect(ActiveCallController.instance.state.callerName, 'Alice Updated');
    expect(ActiveCallController.instance.state.callerAddress, '+15552222222');

    // Action and route must be updated in place without discarding route
    expect(faceTimeIncomingActions[callUuid]?.callerName, 'Alice Updated');
    expect(faceTimeIncomingActions[callUuid]?.callerAddress, '+15552222222');
    expect(identical(faceTimeOverlays[callUuid], dummyRoute), isTrue);
  });

  test('clearFaceTimeNotification and hideFaceTimeOverlay respect endNative and keepCallState', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final notificationsService = NotificationsSvc;

    // 1. clearFaceTimeNotification with default endNative: false does NOT call endFaceTimeCall
    recordedMethodCalls.clear();
    await notificationsService.clearFaceTimeNotification('uuid-dismiss-1');
    expect(recordedMethodCalls.where((c) => c.method == 'end-facetime-call'), isEmpty);
    expect(recordedMethodCalls.where((c) => c.method == 'delete-notification'), hasLength(1));

    // 2. clearFaceTimeNotification with endNative: true calls endFaceTimeCall
    recordedMethodCalls.clear();
    await notificationsService.clearFaceTimeNotification('uuid-decline-1', endNative: true);
    expect(recordedMethodCalls.where((c) => c.method == 'end-facetime-call'), hasLength(1));
    expect(recordedMethodCalls.firstWhere((c) => c.method == 'end-facetime-call').arguments['call_uuid'], 'uuid-decline-1');

    // 3. hideFaceTimeOverlay with keepCallState: true never calls endFaceTimeCall and preserves controller
    ActiveCallController.instance.startOngoing(callUuid: 'uuid-ongoing-1', callerName: 'Bob', isVideo: true);
    recordedMethodCalls.clear();
    hideFaceTimeOverlay('uuid-ongoing-1', keepCallState: true, endNative: true);
    expect(recordedMethodCalls.where((c) => c.method == 'end-facetime-call'), isEmpty);
    expect(ActiveCallController.instance.state.callUuid, 'uuid-ongoing-1');
    expect(ActiveCallController.instance.state.phase, ActiveCallPhase.ongoing);

    // 4. hideFaceTimeOverlay default does not end native call
    recordedMethodCalls.clear();
    hideFaceTimeOverlay('uuid-ongoing-1');
    expect(recordedMethodCalls.where((c) => c.method == 'end-facetime-call'), isEmpty);
  });

  testWidgets('openInAppCallScreen removes tracked incoming route for the uuid before pushing InAppCallScreen',
      (tester) async {
    const callUuid = 'uuid-inapp-replace-1';

    await tester.pumpWidget(
      const GetMaterialApp(
        home: Scaffold(body: Text('Home')),
      ),
    );
    await tester.pump();

    final controller = ActiveCallController.instance;
    controller.startIncoming(callUuid: callUuid, callerName: 'Charlie', isVideo: true);

    openIncomingFaceTimeScreen(callUuid, context: tester.element(find.text('Home')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(IncomingFaceTimeScreen), findsOneWidget);
    expect(faceTimeOverlays[callUuid], isNotNull);
    final incomingRoute = faceTimeOverlays[callUuid]!;

    // Move controller to ongoing and call openInAppCallScreen
    controller.startOngoing(callUuid: callUuid, callerName: 'Charlie', isVideo: true);
    openInAppCallScreen(context: tester.element(find.byType(IncomingFaceTimeScreen)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Incoming route removed from overlays and disposed
    expect(faceTimeOverlays.containsKey(callUuid), isFalse);
    expect(incomingRoute.isActive, isFalse);
    expect(find.byType(IncomingFaceTimeScreen), findsNothing);
    expect(find.byType(InAppCallScreen), findsOneWidget);

    hideInAppCallScreen();
    controller.clear();
    await tester.pump();
  });

  testWidgets('openIncomingFaceTimeScreen does nothing unless phase == incoming and no active InAppCallScreen',
      (tester) async {
    const callUuid = 'uuid-incoming-guard-1';

    await tester.pumpWidget(
      const GetMaterialApp(
        home: Scaffold(body: Text('Home')),
      ),
    );
    await tester.pump();
    final homeContext = tester.element(find.text('Home'));

    final controller = ActiveCallController.instance;

    // 1. When phase is ongoing, openIncomingFaceTimeScreen does nothing
    controller.startOngoing(callUuid: callUuid, callerName: 'David', isVideo: true);
    openIncomingFaceTimeScreen(callUuid, context: homeContext);
    await tester.pump();
    expect(find.byType(IncomingFaceTimeScreen), findsNothing);

    // 2. When InAppCallScreen is active, openIncomingFaceTimeScreen does nothing
    openInAppCallScreen(context: homeContext);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(InAppCallScreen), findsOneWidget);

    controller.startIncoming(callUuid: callUuid, callerName: 'David', isVideo: true);
    openIncomingFaceTimeScreen(callUuid, context: homeContext);
    await tester.pump();
    expect(find.byType(IncomingFaceTimeScreen), findsNothing);

    hideInAppCallScreen();
    controller.clear();
    await tester.pump();
  });
}
