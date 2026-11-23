import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

class _NoopLogger extends BaseLogger {
  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void error(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

class _TestSettingsService extends SettingsService {
  @override
  ServerDetails get serverDetails => const ServerDetails(
        macOSVersion: 14,
        macOSMinorVersion: 0,
        serverVersion: '1.9.12',
        serverVersionCode: 10912,
      );
}

class _TestSocketService extends SocketService {
  int resumeCalls = 0;
  int restartCalls = 0;

  @override
  void resumeConnection() {
    resumeCalls++;
  }

  @override
  void restartSocket() {
    restartCalls++;
  }
}

class _FakeGlobalIsolate extends GlobalIsolate {
  @override
  Future<T> send<T>(IsolateRequestType type, {dynamic input, Duration? customTimeout}) async {
    return <int>[] as T;
  }
}

class _TestHttpService extends HttpService {
  String testOrigin = 'https://bb.jessfan.com';

  @override
  String get origin => testOrigin;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestSettingsService settings;
  late _TestSocketService socket;
  late SyncService sync;

  setUp(() {
    if (GetIt.I.isRegistered<BaseLogger>()) GetIt.I.unregister<BaseLogger>();
    GetIt.I.registerSingleton<BaseLogger>(_NoopLogger());
    if (GetIt.I.isRegistered<GlobalIsolate>()) GetIt.I.unregister<GlobalIsolate>();
    GetIt.I.registerSingleton<GlobalIsolate>(_FakeGlobalIsolate());

    settings = _TestSettingsService()..settings = Settings();
    settings.settings.finishedSetup.value = true;
    settings.settings.showIncrementalSync.value = false;
    settings.settings.syncContactsAutomatically.value = false;

    if (GetIt.I.isRegistered<SettingsService>()) GetIt.I.unregister<SettingsService>();
    GetIt.I.registerSingleton<SettingsService>(settings);

    socket = _TestSocketService();
    socket.state.value = SocketState.connected;
    if (GetIt.I.isRegistered<SocketService>()) GetIt.I.unregister<SocketService>();
    GetIt.I.registerSingleton<SocketService>(socket);

    sync = SyncService();
    sync.onSetupStateChanged(true);
    sync.onSocketStatusChanged(
      state: SocketState.connected,
      connectionDesired: true,
      authFailed: false,
    );
    if (GetIt.I.isRegistered<SyncService>()) GetIt.I.unregister<SyncService>();
    GetIt.I.registerSingleton<SyncService>(sync);
  });

  tearDown(() {
    sync.disposeStatusTracker();
    if (GetIt.I.isRegistered<SyncService>()) GetIt.I.unregister<SyncService>();
    if (GetIt.I.isRegistered<SocketService>()) GetIt.I.unregister<SocketService>();
    if (GetIt.I.isRegistered<SettingsService>()) GetIt.I.unregister<SettingsService>();
    if (GetIt.I.isRegistered<HttpService>()) GetIt.I.unregister<HttpService>();
    if (GetIt.I.isRegistered<GlobalIsolate>()) GetIt.I.unregister<GlobalIsolate>();
    if (GetIt.I.isRegistered<BaseLogger>()) GetIt.I.unregister<BaseLogger>();
  });

  group('SyncStatusTracker retry spinner state', () {
    test('clears retrying when sync fails while socket is already connected', () {
      SyncStatusSnapshot latest = SyncStatusSnapshot.idle;
      final tracker = SyncStatusTracker(
        onChanged: (next) => latest = next,
        startupGrace: Duration.zero,
        syncDebounce: Duration.zero,
      );
      addTearDown(tracker.dispose);

      tracker.setFinishedSetup(true);
      tracker.onSocketState(connected: true, retrying: false, failed: false);
      tracker.onSyncStarted();
      tracker.onSyncFinished(success: false);

      expect(latest.kind, SyncStatusKind.failed);
      expect(latest.message, 'Sync failed');

      tracker.prepareManualRetry();
      expect(latest.retrying, isTrue);

      tracker.onSyncStarted();
      tracker.onSyncFinished(success: false);
      expect(latest.kind, SyncStatusKind.failed);
      expect(latest.retrying, isFalse);

      tracker.onSyncStarted();
      tracker.onSyncFinished(success: true);
      expect(latest.kind, SyncStatusKind.idle);
      expect(latest.retrying, isFalse);
    });

    test('clears manual retrying on failed sync while socket is disconnected and auto-unblocks on stall timeout', () {
      fakeAsync((async) {
        SyncStatusSnapshot latest = SyncStatusSnapshot.idle;
        final tracker = SyncStatusTracker(
          onChanged: (next) => latest = next,
          startupGrace: Duration.zero,
          syncDebounce: Duration.zero,
          manualRetryTimeout: const Duration(seconds: 15),
        );
        addTearDown(tracker.dispose);

        tracker.setFinishedSetup(true);
        tracker.onSocketState(connected: false, retrying: false, failed: true, errorMessage: 'Connection lost');
        expect(latest.kind, SyncStatusKind.failed);
        expect(latest.retrying, isFalse);

        // Manual retry followed by failed HTTP fallback sync while socket stays disconnected must unblock Retry.
        tracker.prepareManualRetry();
        expect(latest.retrying, isTrue);
        tracker.onSyncStarted();
        tracker.onSyncFinished(success: false);
        expect(latest.kind, SyncStatusKind.failed);
        expect(latest.retrying, isFalse);

        // If socket/isolate stalls without calling onSyncFinished, bounded timeout auto-unblocks Retry.
        tracker.prepareManualRetry();
        tracker.onSocketState(connected: false, retrying: true, failed: false);
        expect(latest.retrying, isTrue);
        async.elapse(const Duration(seconds: 14));
        expect(latest.retrying, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(latest.kind, SyncStatusKind.failed);
        expect(latest.retrying, isFalse);
      });
    });
  });

  group('SyncService automatic and manual recovery', () {
    test('auto-retries failed sync while socket remains connected and clears Sync failed', () {
      fakeAsync((async) {
        var attempts = 0;
        sync.incrementalSyncRunner = ({bool useGlobalIsolate = false}) async {
          attempts++;
          if (attempts == 1) {
            throw Exception('transient 502');
          }
          return <Message>[];
        };

        unawaited(sync.startIncrementalSync());
        async.flushMicrotasks();

        expect(attempts, 1);
        expect(sync.status.value.kind, SyncStatusKind.failed);
        expect(sync.status.value.message, 'Sync failed');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(attempts, 2);
        expect(sync.status.value.kind, SyncStatusKind.idle);
      });
    });

    test('continues periodic retries with 60s capped backoff past attempt 4 and recovers when server returns', () {
      fakeAsync((async) {
        var attempts = 0;
        var shouldFail = true;
        sync.incrementalSyncRunner = ({bool useGlobalIsolate = false}) async {
          attempts++;
          if (shouldFail) {
            throw Exception('still down');
          }
          return <Message>[];
        };

        unawaited(sync.startIncrementalSync());
        async.flushMicrotasks();
        expect(attempts, 1);

        // 2s + 5s + 15s + 30s = 52s for the first 4 retries (5 attempts total).
        async.elapse(const Duration(seconds: 52));
        async.flushMicrotasks();
        expect(attempts, 5);
        expect(sync.status.value.kind, SyncStatusKind.failed);
        expect(sync.status.value.retrying, isFalse);

        // Attempt 6 runs after 60s capped backoff (at 112s), attempt 7 at 172s.
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(attempts, 6);

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(attempts, 7);
        expect(sync.status.value.kind, SyncStatusKind.failed);

        // Server recovers before attempt 8 -> clears Sync failed and stops periodic retries.
        shouldFail = false;
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(attempts, 8);
        expect(sync.status.value.kind, SyncStatusKind.idle);
        expect(sync.status.value.retrying, isFalse);

        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();
        expect(attempts, 8);
      });
    });

    test('retryNow restarts socket once (not resumeConnection) and falls back to HTTP sync after 5s when disconnected',
        () {
      fakeAsync((async) {
        var attempts = 0;
        var shouldFail = true;
        sync.incrementalSyncRunner = ({bool useGlobalIsolate = false}) async {
          attempts++;
          if (shouldFail) throw Exception('server unavailable');
          return <Message>[];
        };

        // Initial sync fails, then socket disconnects.
        unawaited(sync.startIncrementalSync());
        async.flushMicrotasks();
        expect(attempts, 1);
        expect(sync.status.value.kind, SyncStatusKind.failed);

        socket.state.value = SocketState.disconnected;
        sync.onSocketStatusChanged(
          state: SocketState.disconnected,
          connectionDesired: true,
          authFailed: false,
        );

        // Manual retry while disconnected: single restartSocket(), no resumeConnection(), HTTP fallback at 5s.
        unawaited(sync.retryNow());
        async.flushMicrotasks();
        expect(socket.restartCalls, 1);
        expect(socket.resumeCalls, 0);
        expect(sync.status.value.retrying, isTrue);
        expect(attempts, 1);

        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        expect(attempts, 1);

        // HTTP fallback fires at 5s; if it fails, retrying unblocks so user can retry again.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(attempts, 2);
        expect(sync.status.value.kind, SyncStatusKind.failed);
        expect(sync.status.value.message, 'Sync failed');
        expect(sync.status.value.retrying, isFalse);

        // Second manual retry succeeds via 5s HTTP fallback while socket remains disconnected.
        shouldFail = false;
        unawaited(sync.retryNow());
        async.flushMicrotasks();
        expect(socket.restartCalls, 2);
        expect(socket.resumeCalls, 0);
        expect(sync.status.value.retrying, isTrue);

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(attempts, 3);
        expect(sync.status.value.retrying, isFalse);
        expect(sync.status.value.message, isNot('Sync failed'));
      });
    });

    test('retryNow cancels 5s HTTP fallback if socket connects within window', () {
      fakeAsync((async) {
        var attempts = 0;
        sync.incrementalSyncRunner = ({bool useGlobalIsolate = false}) async {
          attempts++;
          return <Message>[];
        };

        socket.state.value = SocketState.disconnected;
        sync.onSocketStatusChanged(
          state: SocketState.disconnected,
          connectionDesired: true,
          authFailed: false,
        );

        unawaited(sync.retryNow());
        async.flushMicrotasks();
        expect(socket.restartCalls, 1);
        expect(attempts, 0);

        // Socket connects at 2s -> triggers immediate recovery sync and cancels 5s fallback.
        async.elapse(const Duration(seconds: 2));
        socket.state.value = SocketState.connected;
        sync.onSocketStatusChanged(
          state: SocketState.connected,
          connectionDesired: true,
          authFailed: false,
        );
        async.flushMicrotasks();
        expect(attempts, 1);
        expect(sync.status.value, SyncStatusSnapshot.idle);

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(attempts, 1);
      });
    });

    test('retryNow while sync is in flight runs follow-up immediately instead of waiting 30s cooldown', () {
      fakeAsync((async) {
        var attempts = 0;
        final firstSync = Completer<List<Message>>();
        sync.incrementalSyncRunner = ({bool useGlobalIsolate = false}) {
          attempts++;
          if (attempts == 1) return firstSync.future;
          return Future.value(<Message>[]);
        };

        unawaited(sync.startIncrementalSync());
        async.flushMicrotasks();
        expect(attempts, 1);
        expect(sync.isIncrementalSyncing.value, isTrue);

        unawaited(sync.retryNow());
        async.flushMicrotasks();
        expect(attempts, 1);

        firstSync.completeError(Exception('502 during server swap'));
        async.flushMicrotasks();

        // Immediate follow-up runs on Timer.zero, not 30s cooldown.
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(attempts, 2);
        expect(sync.status.value.kind, SyncStatusKind.idle);
        expect(sync.status.value.retrying, isFalse);
      });
    });

    test('socket reconnect recovers failed sync even when catchUp is false (Android pushes)', () {
      fakeAsync((async) {
        var attempts = 0;
        var shouldFail = true;
        sync.onSocketStatusChanged(
          state: SocketState.reconnecting,
          connectionDesired: true,
          authFailed: false,
        );
        sync.incrementalSyncRunner = ({bool useGlobalIsolate = false}) async {
          attempts++;
          if (shouldFail) throw Exception('server offline');
          return <Message>[];
        };

        unawaited(sync.startIncrementalSync());
        async.flushMicrotasks();
        expect(sync.status.value.kind, SyncStatusKind.failed);

        // Server comes back and socket reconnects; Android NetworkTasks passes catchUp: false.
        shouldFail = false;
        sync.onSocketStatusChanged(
          state: SocketState.connected,
          connectionDesired: true,
          authFailed: false,
        );
        unawaited(sync.startIncrementalSync(catchUp: false));
        async.flushMicrotasks();

        expect(attempts, greaterThanOrEqualTo(2));
        expect(sync.status.value.kind, SyncStatusKind.idle);
      });
    });

    test('pauses failure retries while offline and triggers recovery immediately when online', () {
      fakeAsync((async) {
        var attempts = 0;
        var shouldFail = true;
        sync.incrementalSyncRunner = ({bool useGlobalIsolate = false}) async {
          attempts++;
          if (shouldFail) throw Exception('network blip');
          return <Message>[];
        };

        unawaited(sync.startIncrementalSync());
        async.flushMicrotasks();
        expect(attempts, 1);
        expect(sync.status.value.kind, SyncStatusKind.failed);

        sync.onNetworkOnlineChanged(false);
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(attempts, 1);

        shouldFail = false;
        sync.onNetworkOnlineChanged(true);
        async.flushMicrotasks();

        expect(attempts, 2);
        expect(sync.status.value.kind, SyncStatusKind.idle);
      });
    });

    test('manual isIncrementalSyncing toggle clears syncing status instead of sticking', () {
      fakeAsync((async) {
        sync.isIncrementalSyncing.value = true;
        async.elapse(const Duration(milliseconds: 350));
        expect(sync.status.value.kind, SyncStatusKind.syncing);

        sync.isIncrementalSyncing.value = false;
        async.flushMicrotasks();
        expect(sync.status.value.kind, SyncStatusKind.idle);
      });
    });
  });

  group('HttpService.runApiGuarded Cloudflare tunnel retries', () {
    test('retries 502 and 503 once for HTTPS server origins', () async {
      final http = _TestHttpService();
      if (GetIt.I.isRegistered<HttpService>()) GetIt.I.unregister<HttpService>();
      GetIt.I.registerSingleton<HttpService>(http);

      var calls = 0;
      final res502 = await http.runApiGuarded(() async {
        calls++;
        if (calls == 1) {
          throw Response(requestOptions: RequestOptions(path: '/api/v1/message/query'), statusCode: 502);
        }
        return Response(requestOptions: RequestOptions(path: '/api/v1/message/query'), statusCode: 200);
      });
      expect(calls, 2);
      expect(res502.statusCode, 200);

      calls = 0;
      final res503 = await http.runApiGuarded(() async {
        calls++;
        if (calls == 1) {
          throw DioException(
            requestOptions: RequestOptions(path: '/api/v1/chat/query'),
            response: Response(requestOptions: RequestOptions(path: '/api/v1/chat/query'), statusCode: 503),
          );
        }
        return Response(requestOptions: RequestOptions(path: '/api/v1/chat/query'), statusCode: 200);
      });
      expect(calls, 2);
      expect(res503.statusCode, 200);
    });
  });
}
