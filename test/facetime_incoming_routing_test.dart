import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _SilentLogger extends BaseLogger {
  @override
  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void error(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

class _FakeLifecycleService extends LifecycleService {
  bool foregroundValue = true;

  @override
  bool get isForeground => foregroundValue;
}

class _FaceTimeNotifCall {
  final String? callUuid;
  final String caller;
  final Uint8List? chatIcon;
  final bool isAudio;
  final String? callerAddress;
  final bool isTelephony;

  _FaceTimeNotifCall({
    required this.callUuid,
    required this.caller,
    required this.chatIcon,
    required this.isAudio,
    required this.callerAddress,
    required this.isTelephony,
  });
}

class _MissedFaceTimeNotifCall {
  final String? callUuid;
  final String caller;
  final bool isAudio;
  final bool isTelephony;
  final String? callerAddress;

  _MissedFaceTimeNotifCall({
    required this.callUuid,
    required this.caller,
    required this.isAudio,
    required this.isTelephony,
    required this.callerAddress,
  });
}

class _FakeNotificationsService extends NotificationsService {
  bool telecomResult = false;
  final List<_FaceTimeNotifCall> calls = [];
  final List<_MissedFaceTimeNotifCall> missedCalls = [];
  final List<String> clearedUuids = [];

  @override
  Future<bool> createIncomingFaceTimeNotification(
    String? callUuid,
    String caller,
    Uint8List? chatIcon,
    bool isAudio, {
    String? callerAddress,
    bool isTelephony = false,
  }) async {
    calls.add(_FaceTimeNotifCall(
      callUuid: callUuid,
      caller: caller,
      chatIcon: chatIcon,
      isAudio: isAudio,
      callerAddress: callerAddress,
      isTelephony: isTelephony,
    ));
    return telecomResult;
  }

  @override
  Future<void> clearFaceTimeNotification(String callUuid, {bool onlyIfRinging = false}) async {
    clearedUuids.add(callUuid);
  }

  @override
  Future<void> createMissedFaceTimeNotification(
    String? callUuid,
    String caller, {
    bool isAudio = false,
    bool isTelephony = false,
    String? callerAddress,
  }) async {
    missedCalls.add(_MissedFaceTimeNotifCall(
      callUuid: callUuid,
      caller: caller,
      isAudio: isAudio,
      isTelephony: isTelephony,
      callerAddress: callerAddress,
    ));
  }
}

class _FakeContactServiceV2 extends ContactServiceV2 {
  final Map<String, ContactV2> contactsByAddress;

  _FakeContactServiceV2(this.contactsByAddress);

  @override
  ContactV2? findContactForAddressSync(String address) => contactsByAddress[address];

  @override
  Future<ContactV2?> getContact(String address) async => contactsByAddress[address];

  @override
  Future<Uint8List?> getContactAvatar(String nativeContactId) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLifecycleService lifecycle;
  late _FakeNotificationsService notifications;

  setUp(() async {
    await GetIt.I.reset();
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
    lifecycle = _FakeLifecycleService();
    notifications = _FakeNotificationsService();
    GetIt.I.registerSingleton<LifecycleService>(lifecycle);
    GetIt.I.registerSingleton<NotificationsService>(notifications);
    GetIt.I.registerSingleton<ContactServiceV2>(
      _FakeContactServiceV2({
        '+15551234567': ContactV2(
          nativeContactId: 'c1',
          displayName: 'Maya Lin',
          addresses: const ['+15551234567'],
        ),
      }),
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    ActiveCallController.instance.clear();
    faceTimeOverlays.clear();
    faceTimeIncomingActions.clear();
    Get.reset();
    await GetIt.I.reset();
  });

  test('handleIncomingFaceTimeCall notifies and shows overlay for Android video call when in foreground', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    lifecycle.foregroundValue = true;
    notifications.telecomResult = false;

    await ActionHandler().handleIncomingFaceTimeCall({
      'uuid': 'ft-video-1',
      'is_video': true,
      'handle': {'address': '+15551234567'},
      'address': '+15551234567',
    });

    expect(notifications.calls, hasLength(1));
    expect(notifications.calls.single.callUuid, 'ft-video-1');
    expect(notifications.calls.single.caller, 'Maya Lin');
    expect(notifications.calls.single.isAudio, isFalse);
    expect(notifications.calls.single.callerAddress, '+15551234567');

    expect(faceTimeOverlays.containsKey('ft-video-1'), isTrue);
    expect(ActiveCallController.instance.state.phase, ActiveCallPhase.incoming);
    expect(ActiveCallController.instance.state.isVideo, isTrue);
    expect(ActiveCallController.instance.state.callerName, 'Maya Lin');
  });

  test('handleIncomingFaceTimeCall skips overlay on Android when handledByTelecom or backgrounded', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    lifecycle.foregroundValue = true;
    notifications.telecomResult = true;

    await ActionHandler().handleIncomingFaceTimeCall({
      'uuid': 'ft-audio-1',
      'is_video': false,
      'handle': {'address': '+15551234567'},
      'address': '+15551234567',
    });

    expect(notifications.calls, hasLength(1));
    expect(faceTimeOverlays, isEmpty);

    notifications.telecomResult = false;
    lifecycle.foregroundValue = false;

    await ActionHandler().handleIncomingFaceTimeCall({
      'uuid': 'ft-video-bg',
      'is_video': true,
      'handle': {'address': '+15551234567'},
      'address': '+15551234567',
    });

    expect(notifications.calls, hasLength(2));
    expect(notifications.calls.last.callUuid, 'ft-video-bg');
    expect(notifications.calls.last.isAudio, isFalse);
    expect(faceTimeOverlays, isEmpty);
  });

  test('legacy incoming-facetime parses uuid, is_video, address and shows overlay in foreground on Web/Desktop',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    lifecycle.foregroundValue = true;

    await ActionHandler().handleEvent(
      'incoming-facetime',
      {
        'caller': '+15551234567',
        'address': '+15551234567',
        'uuid': 'legacy-uuid-1',
        'is_video': false,
        'timestamp': 1700000000000,
      },
      'DartSocket',
    );

    expect(notifications.calls, isEmpty);
    expect(faceTimeOverlays.containsKey('legacy-uuid-1'), isTrue);
    expect(ActiveCallController.instance.state.phase, ActiveCallPhase.incoming);
    expect(ActiveCallController.instance.state.callUuid, 'legacy-uuid-1');
    expect(ActiveCallController.instance.state.callerName, 'Maya Lin');
    expect(ActiveCallController.instance.state.callerAddress, '+15551234567');
    expect(ActiveCallController.instance.state.isVideo, isFalse);
  });

  test('legacy incoming-facetime without uuid still shows foreground overlay on Web/Desktop and notifies on Android',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    lifecycle.foregroundValue = true;

    await ActionHandler().handleIncomingFaceTimeCallLegacy({
      'caller': '+15559990000',
      'timestamp': 1700000000000,
    });

    expect(faceTimeOverlays, hasLength(1));
    expect(ActiveCallController.instance.state.callerName, '+15559990000');
    expect(ActiveCallController.instance.state.isVideo, isTrue);

    faceTimeOverlays.clear();
    ActiveCallController.instance.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    lifecycle.foregroundValue = false;

    await ActionHandler().handleIncomingFaceTimeCallLegacy({
      'caller': '+15551234567',
      'address': '+15551234567',
      'uuid': 'legacy-android-1',
      'is_video': false,
      'timestamp': 1700000000000,
    });

    expect(notifications.calls, hasLength(1));
    expect(notifications.calls.single.callUuid, 'legacy-android-1');
    expect(notifications.calls.single.caller, 'Maya Lin');
    expect(notifications.calls.single.isAudio, isTrue);
    expect(notifications.calls.single.callerAddress, '+15551234567');
    expect(faceTimeOverlays, isEmpty);
  });

  test('missed status_id=6 posts exactly one missed-FaceTime notification with deterministic ID', () async {
    final handler = ActionHandler();
    await handler.handleFaceTimeStatusChange({
      'uuid': 'missed-ft-1',
      'status_id': 6,
      'is_outgoing': false,
      'is_video': false,
      'ended_reason': 'missed',
      'handle': {'address': '+15551234567'},
    });
    // Second delivery (e.g. FCM + socket) for the same uuid is deduped.
    await handler.handleFaceTimeStatusChange({
      'uuid': 'missed-ft-1',
      'status_id': 6,
      'is_outgoing': false,
      'is_video': false,
      'ended_reason': 'missed',
      'handle': {'address': '+15551234567'},
    });

    expect(notifications.missedCalls, hasLength(1));
    expect(notifications.missedCalls.single.callUuid, 'missed-ft-1');
    expect(notifications.missedCalls.single.caller, 'Maya Lin');
    expect(notifications.missedCalls.single.isAudio, isTrue);
    expect(
      NotificationsService.missedFaceTimeNotificationId('missed-ft-1'),
      equals(NotificationsService.missedFaceTimeNotificationId('missed-ft-1')),
    );

    // Outgoing or non-missed status 6 does not post a missed notification.
    await handler.handleFaceTimeStatusChange({
      'uuid': 'outgoing-ft-1',
      'status_id': 6,
      'is_outgoing': true,
      'ended_reason': 'missed',
      'handle': {'address': '+15551234567'},
    });
    await handler.handleFaceTimeStatusChange({
      'uuid': 'ended-ft-1',
      'status_id': 6,
      'is_outgoing': false,
      'ended_reason': 'remote_ended',
      'handle': {'address': '+15551234567'},
    });
    expect(notifications.missedCalls, hasLength(1));
  });
}
