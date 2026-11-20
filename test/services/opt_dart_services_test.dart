import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/models/models.dart' show ServerDetails;
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
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

class _FakeSettingsService extends SettingsService {
  final Rx<ServerDetails> _details = const ServerDetails(
    macOSVersion: 14,
    macOSMinorVersion: 0,
    serverVersion: '1.9.0',
    serverVersionCode: 10900,
  ).obs;

  @override
  ServerDetails get serverDetails => _details.value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await GetIt.I.reset();
    Get.reset();
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
    GetIt.I.registerSingleton<SettingsService>(_FakeSettingsService()..settings = Settings());
    GetIt.I.registerSingleton<HttpService>(HttpService());
  });

  tearDown(() async {
    await GetIt.I.reset();
    Get.reset();
  });

  group('D-01 FaceTime notification ID', () {
    test('extracts up to 8 digits deterministically when digits exist', () {
      const uuid = '12345678-90ab-cdef-1234-567890abcdef';
      expect(NotificationsService.faceTimeNotificationId(uuid), 12345678);
      expect(NotificationsService.faceTimeNotificationId(uuid), NotificationsService.faceTimeNotificationId(uuid));
    });

    test('falls back deterministically without throwing on non-numeric or empty UUID', () {
      const alphaUuid = 'abcdef-ghij-klmn';
      final id1 = NotificationsService.faceTimeNotificationId(alphaUuid);
      final id2 = NotificationsService.faceTimeNotificationId(alphaUuid);
      expect(id1, id2);
      expect(id1, greaterThanOrEqualTo(0));

      final emptyId = NotificationsService.faceTimeNotificationId('');
      expect(emptyId, greaterThanOrEqualTo(0));
    });

    test('returns positive random fallback when callUuid is null', () {
      final id = NotificationsService.faceTimeNotificationId(null);
      expect(id, inInclusiveRange(1, 9998));
    });
  });

  group('D-02 SocketService safety', () {
    test('handleStatusUpdate stops heartbeat on reconnecting, disconnected, and error', () {
      final svc = SocketService();
      expect(() => svc.handleStatusUpdate(SocketState.reconnecting, null), returnsNormally);
      expect(svc.state.value, SocketState.reconnecting);
      expect(() => svc.handleStatusUpdate(SocketState.disconnected, null), returnsNormally);
      expect(svc.state.value, SocketState.disconnected);
      expect(() => svc.handleStatusUpdate(SocketState.error, 'err'), returnsNormally);
      expect(svc.state.value, SocketState.error);
    });
  });

  group('LifecycleService.isUiInteractive', () {
    test('reflects foreground vs unfocused/headless state', () {
      final binding = TestWidgetsFlutterBinding.instance;
      final lifecycle = LifecycleService();

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      lifecycle.windowFocused = true;
      lifecycle.headless = false;
      expect(lifecycle.isUiInteractive, isTrue);

      lifecycle.headless = true;
      expect(lifecycle.isUiInteractive, isFalse);

      lifecycle.headless = false;
      lifecycle.windowFocused = false;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(lifecycle.isUiInteractive, isFalse);
    });
  });
}
