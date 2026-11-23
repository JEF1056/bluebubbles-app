import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/actions/sync_actions.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';
import 'package:bluebubbles/services/isolates/incremental_sync_isolate.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
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

class _TestSettings extends Settings {
  int saveManyCalls = 0;

  @override
  Future<Settings> saveManyAsync(List<String> keys) async {
    saveManyCalls++;
    return this;
  }
}

class _TestSettingsService extends SettingsService {
  @override
  ServerDetails get serverDetails => const ServerDetails(
        macOSVersion: 15,
        macOSMinorVersion: 0,
        serverVersion: '2.0.0',
        serverVersionCode: 20000,
      );
}

class _TestSocketService extends SocketService {
  @override
  void resumeConnection() {}

  @override
  void restartSocket() {}
}

class _TestGlobalIsolate extends GlobalIsolate {
  int stopCalls = 0;

  @override
  void stop({bool clearEventListeners = false, bool closeOutputStream = false}) {
    stopCalls++;
    super.stop(clearEventListeners: clearEventListeners, closeOutputStream: closeOutputStream);
  }
}

class _TestIncrementalSyncIsolate extends IncrementalSyncIsolate {
  int stopCalls = 0;

  @override
  void stop({bool clearEventListeners = false, bool closeOutputStream = false}) {
    stopCalls++;
    super.stop(clearEventListeners: clearEventListeners, closeOutputStream: closeOutputStream);
  }
}

class _FakeHttpService extends HttpService {
  @override
  String get origin => 'https://bb.example.com';
}

class _FakeMessageApi extends MessageApi {
  final Future<Response<dynamic>> Function({
    int offset,
    int limit,
    String? dateField,
    CancelToken? cancelToken,
  }) onQuery;

  _FakeMessageApi(super.svc, this.onQuery);

  @override
  Future<Response> query({
    List<String> withQuery = const [],
    List<dynamic> where = const [],
    String sort = "DESC",
    int? before,
    int? after,
    String? dateField,
    String? chatGuid,
    int offset = 0,
    int limit = 100,
    bool convertAttachments = true,
    CancelToken? cancelToken,
  }) {
    return onQuery(
      offset: offset,
      limit: limit,
      dateField: dateField,
      cancelToken: cancelToken,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestSettingsService settings;
  late _TestSettings testSettings;
  late _TestSocketService socket;
  late SyncService sync;

  setUp(() {
    if (GetIt.I.isRegistered<BaseLogger>()) GetIt.I.unregister<BaseLogger>();
    GetIt.I.registerSingleton<BaseLogger>(_NoopLogger());

    if (GetIt.I.isRegistered<GlobalIsolate>()) GetIt.I.unregister<GlobalIsolate>();
    GetIt.I.registerSingleton<GlobalIsolate>(_TestGlobalIsolate());

    testSettings = _TestSettings();
    settings = _TestSettingsService()..settings = testSettings;
    settings.settings.finishedSetup.value = true;
    settings.settings.showIncrementalSync.value = false;
    settings.settings.syncContactsAutomatically.value = false;
    settings.settings.lastIncrementalSync.value = 1000;
    settings.settings.lastIncrementalSyncRowId.value = 10;

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

  group('L2-1 & L2-2 stall timeout reset on incrementalSyncPageComplete', () {
    test('GlobalIsolate resets 2m performIncrementalSync timeout on page progress and times out when stalled', () {
      fakeAsync((async) {
        final isolate = _TestGlobalIsolate();
        Object? error;
        final future = isolate
            .sendWithTimeoutForTest<List<int>>(
              IsolateRequestType.performIncrementalSync,
              customTimeout: const Duration(minutes: 2),
            )
            .catchError((Object e) {
          error = e;
          return <int>[];
        });
        unawaited(future);

        // Steady page progress every 60s for 4 minutes (> 2m) must not time out.
        for (var i = 0; i < 4; i++) {
          async.elapse(const Duration(seconds: 60));
          expect(error, isNull);
          isolate.handleMessageForTest(
            IsolateEventMessage(
              type: IsolateEvent.incrementalSyncPageComplete,
              data: const <String, dynamic>{},
            ).toMap(),
          );
        }
        expect(isolate.stopCalls, 0);

        // Stop emitting page progress: 119s is still alive, 120s times out.
        async.elapse(const Duration(seconds: 119));
        expect(error, isNull);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(error, isNotNull);
        expect(error.toString(), contains('Request timeout'));
        expect(isolate.stopCalls, 0);
      });
    });

    test('IncrementalSyncIsolate keeps alive past 5m with page progress and stops only when hung', () {
      fakeAsync((async) {
        final isolate = _TestIncrementalSyncIsolate();
        Object? error;
        final future = isolate
            .sendWithTimeoutForTest<List<int>>(IsolateRequestType.performIncrementalSync)
            .catchError((Object e) {
          error = e;
          return <int>[];
        });
        unawaited(future);

        // Emit page progress every 3 minutes for 9 minutes (> 5m taskTimeout).
        for (var i = 0; i < 3; i++) {
          async.elapse(const Duration(minutes: 3));
          expect(error, isNull);
          expect(isolate.stopCalls, 0);
          isolate.handleMessageForTest(
            IsolateEventMessage(
              type: IsolateEvent.incrementalSyncPageComplete,
              data: const <String, dynamic>{},
            ).toMap(),
          );
        }

        // Now stall for 5 minutes -> times out and recycles IncrementalSyncIsolate.
        async.elapse(const Duration(minutes: 4, seconds: 59));
        expect(error, isNull);
        expect(isolate.stopCalls, 0);

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(error, isNotNull);
        expect(isolate.stopCalls, 1);
      });
    });

    test('incrementalSyncPageComplete does not reset non-sync request timeouts', () {
      fakeAsync((async) {
        final isolate = _TestGlobalIsolate();
        Object? error;
        unawaited(
          isolate
              .sendWithTimeoutForTest<Map<String, dynamic>>(
                IsolateRequestType.bulkSyncData,
                customTimeout: const Duration(seconds: 30),
              )
              .catchError((Object e) {
            error = e;
            return <String, dynamic>{};
          }),
        );

        async.elapse(const Duration(seconds: 20));
        isolate.handleMessageForTest(
          IsolateEventMessage(
            type: IsolateEvent.incrementalSyncPageComplete,
            data: const <String, dynamic>{},
          ).toMap(),
        );

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(error, isNotNull);
      });
    });
  });

  group('L2-1 single-flight cancellation in IncrementalSyncManager and SyncActions', () {
    test('IncrementalSyncManager aborts before next page and never writes markers when shouldCancel turns true',
        () async {
      final http = _FakeHttpService();
      var queryCalls = 0;
      var cancelled = false;
      http.message = _FakeMessageApi(http, ({
        int offset = 0,
        int limit = 100,
        String? dateField,
        CancelToken? cancelToken,
      }) async {
        queryCalls++;
        cancelled = true;
        return Response(
          requestOptions: RequestOptions(path: '/api/v1/message/query'),
          statusCode: 200,
          data: {
            'metadata': {'total': 50},
            'data': <dynamic>[],
          },
        );
      });
      if (GetIt.I.isRegistered<HttpService>()) GetIt.I.unregister<HttpService>();
      GetIt.I.registerSingleton<HttpService>(http);

      final manager = IncrementalSyncManager(
        startTimestamp: 1000,
        startRowId: 10,
        saveMarker: true,
        shouldCancel: () => cancelled,
      );

      await expectLater(manager.start(), throwsA(contains('cancelled')));
      expect(queryCalls, 1);
      expect(manager.status.value, SyncStatus.COMPLETED_ERROR);
      expect(testSettings.saveManyCalls, 0);
      expect(settings.settings.lastIncrementalSync.value, 1000);
      expect(settings.settings.lastIncrementalSyncRowId.value, 10);
    });

    test('SyncActions.performIncrementalSync cancels superseded run via generation and CancelToken', () async {
      final http = _FakeHttpService();
      final firstQueryStarted = Completer<void>();
      final releaseFirstQuery = Completer<void>();
      CancelToken? firstToken;
      CancelToken? secondToken;
      var queryCalls = 0;

      http.message = _FakeMessageApi(http, ({
        int offset = 0,
        int limit = 100,
        String? dateField,
        CancelToken? cancelToken,
      }) async {
        queryCalls++;
        if (queryCalls == 1) {
          firstToken = cancelToken;
          firstQueryStarted.complete();
          await releaseFirstQuery.future;
          return Response(
            requestOptions: RequestOptions(path: '/api/v1/message/query'),
            statusCode: 200,
            data: {
              'metadata': {'total': 0},
              'data': <dynamic>[],
            },
          );
        }
        secondToken ??= cancelToken;
        return Response(
          requestOptions: RequestOptions(path: '/api/v1/message/query'),
          statusCode: 200,
          data: {
            'metadata': {'total': 0},
            'data': <dynamic>[],
          },
        );
      });
      if (GetIt.I.isRegistered<HttpService>()) GetIt.I.unregister<HttpService>();
      GetIt.I.registerSingleton<HttpService>(http);

      final firstRun = SyncActions.performIncrementalSync({});
      await firstQueryStarted.future;
      expect(firstToken, isNotNull);
      expect(firstToken!.isCancelled, isFalse);

      // Start superseding run -> immediately cancels first run's CancelToken.
      final secondRun = SyncActions.performIncrementalSync({});
      expect(firstToken!.isCancelled, isTrue);

      releaseFirstQuery.complete();

      await expectLater(firstRun, throwsA(anything));
      await expectLater(secondRun, completes);
      expect(secondToken, isNotNull);
      expect(secondToken!.isCancelled, isFalse);
      expect(testSettings.saveManyCalls, 1);
    });
  });

  group('L2-2 bounded auto-retry in SyncService', () {
    test('caps automatic failure retries at 10 and resets on retryNow, reconnect, online, and resume', () {
      fakeAsync((async) {
        var attempts = 0;
        var shouldFail = true;
        sync.incrementalSyncRunner = ({bool useGlobalIsolate = false}) async {
          attempts++;
          if (shouldFail) {
            throw Exception('deterministic failure');
          }
          return <Message>[];
        };

        // Initial attempt (1) + 10 auto-retries = 11 total attempts over 2+5+15+30 + 6*60 = 412s.
        unawaited(sync.startIncrementalSync());
        async.flushMicrotasks();
        expect(attempts, 1);

        async.elapse(const Duration(seconds: 412));
        async.flushMicrotasks();
        expect(attempts, 11);

        // No further automatic retries after hitting the cap.
        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(attempts, 11);

        // Manual retryNow resets the retry budget.
        unawaited(sync.retryNow());
        async.flushMicrotasks();
        expect(attempts, 12);
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(attempts, 13);

        // Exhaust again to test resume reset.
        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(attempts, 22);

        // Resume resets _failureRetryAttempt.
        sync.onResumeReconnectGrace();
        unawaited(sync.startIncrementalSync());
        async.flushMicrotasks();
        expect(attempts, 23);
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(attempts, 24);

        // Network offline -> online resets and recovers.
        shouldFail = false;
        sync.onNetworkOnlineChanged(false);
        sync.onNetworkOnlineChanged(true);
        async.flushMicrotasks();
        expect(attempts, 25);
        expect(sync.status.value.kind, SyncStatusKind.idle);
      });
    });
  });
}
