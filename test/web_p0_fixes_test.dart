import 'package:bluebubbles/app/layouts/setup/pages/sync/sync_progress.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/helpers/ui/oauth_helpers.dart';
import 'package:bluebubbles/services/network/websocket_adapter.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/outputs/debug_console_output.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:logger/logger.dart';

class _FakeAuthClient implements GoogleSignInAuthorizationClient {
  List<String>? lastSilentScopes;
  List<String>? lastInteractiveScopes;
  GoogleSignInClientAuthorization? silentResult;
  GoogleSignInClientAuthorization interactiveResult = const GoogleSignInClientAuthorization(accessToken: 'web-token');

  @override
  Future<GoogleSignInClientAuthorization?> authorizationForScopes(List<String> scopes) async {
    lastSilentScopes = scopes;
    return silentResult;
  }

  @override
  Future<GoogleSignInClientAuthorization> authorizeScopes(List<String> scopes) async {
    lastInteractiveScopes = scopes;
    return interactiveResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeGoogleSignIn implements GoogleSignIn {
  final bool _supportsAuth;
  final _FakeAuthClient _authClient = _FakeAuthClient();
  int authenticateCalls = 0;
  int signOutCalls = 0;

  _FakeGoogleSignIn(this._supportsAuth);

  @override
  bool supportsAuthenticate() => _supportsAuth;

  @override
  GoogleSignInAuthorizationClient get authorizationClient => _authClient;

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }

  @override
  Future<GoogleSignInAccount> authenticate({List<String> scopeHint = const <String>[]}) async {
    authenticateCalls++;
    throw UnimplementedError('authenticate is not supported on web');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('SocketService.buildSocketOptions', () {
    test('omits httpClientAdapter and extraHeaders on web so browser transports are used', () {
      final opts = SocketService.buildSocketOptions(
        password: 'secret',
        extraHeaders: const {'ngrok-skip-browser-warning': 'true'},
        isWeb: true,
      );

      expect(opts['query'], {'guid': 'secret'});
      expect(opts['transports'], ['websocket', 'polling']);
      expect(opts['autoConnect'], isFalse);
      expect(opts['forceNew'], isTrue);
      expect(opts.containsKey('reconnection'), isFalse);
      expect(opts['reconnectionDelay'], isPositive);
      expect(opts.containsKey('httpClientAdapter'), isFalse);
      expect(opts.containsKey('extraHeaders'), isFalse);
    });

    test('includes WebsocketAdapter and extraHeaders on native platforms', () {
      final opts = SocketService.buildSocketOptions(
        password: 'secret',
        extraHeaders: const {'ngrok-skip-browser-warning': 'true'},
        isWeb: false,
      );

      expect(opts['httpClientAdapter'], isA<WebsocketAdapter>());
      expect(opts['extraHeaders'], {'ngrok-skip-browser-warning': 'true'});
    });
  });

  group('Google Sign-In initialization and web auth fallback', () {
    setUp(resetGoogleSignInInitForTest);

    test('ensureGoogleSignInInitialized runs initializer only once across calls and retries on error', () async {
      int initCount = 0;
      await Future.wait([
        ensureGoogleSignInInitialized(
          clientId: 'cid',
          initializer: ({clientId, serverClientId}) async {
            initCount++;
          },
        ),
        ensureGoogleSignInInitialized(
          clientId: 'cid',
          initializer: ({clientId, serverClientId}) async {
            initCount++;
          },
        ),
      ]);
      await ensureGoogleSignInInitialized(
        clientId: 'cid',
        initializer: ({clientId, serverClientId}) async {
          initCount++;
        },
      );
      expect(initCount, 1);

      resetGoogleSignInInitForTest();
      int retryCount = 0;
      await expectLater(
        ensureGoogleSignInInitialized(
          clientId: 'cid',
          initializer: ({clientId, serverClientId}) async {
            retryCount++;
            throw StateError('transient');
          },
        ),
        throwsStateError,
      );
      await ensureGoogleSignInInitialized(
        clientId: 'cid',
        initializer: ({clientId, serverClientId}) async {
          retryCount++;
        },
      );
      expect(retryCount, 2);
    });

    test('obtainGoogleAccessToken uses authorizationClient instead of authenticate on web', () async {
      final gsi = _FakeGoogleSignIn(false);
      final token = await obtainGoogleAccessToken(
        gsi,
        scopes: const ['https://www.googleapis.com/auth/firebase'],
      );

      expect(token, 'web-token');
      expect(gsi.authenticateCalls, 0);
      expect(gsi.signOutCalls, 0);
      expect(gsi._authClient.lastSilentScopes, contains('https://www.googleapis.com/auth/userinfo.profile'));
      expect(gsi._authClient.lastInteractiveScopes, contains('https://www.googleapis.com/auth/firebase'));
      expect(gsi._authClient.lastInteractiveScopes, contains('https://www.googleapis.com/auth/userinfo.profile'));
    });

    test('obtainGoogleAccessToken signs out first when forceAccountPicker is true on web', () async {
      final gsi = _FakeGoogleSignIn(false)
        .._authClient.silentResult = const GoogleSignInClientAuthorization(accessToken: 'stale');
      final token = await obtainGoogleAccessToken(
        gsi,
        scopes: const ['https://www.googleapis.com/auth/firebase'],
        forceAccountPicker: true,
      );

      expect(token, 'web-token');
      expect(gsi.signOutCalls, 1);
      expect(gsi._authClient.lastSilentScopes, isNull);
      expect(gsi.authenticateCalls, 0);
    });
  });

  group('Web onboarding SyncProgress & console error logging', () {
    testWidgets('SyncProgress lazily initializes fullSyncManager instead of throwing on mount', (tester) async {
      final syncService = SyncService();
      GetIt.I.registerSingleton<SyncService>(syncService);
      GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
      final setupController = Get.put(SetupViewController());
      addTearDown(() async {
        Get.delete<SetupViewController>(force: true);
        await GetIt.I.reset();
      });

      expect(SyncSvc.fullSyncManager, isNull);
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SyncProgress())));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(SyncSvc.fullSyncManager, isNotNull);
      expect(find.text('Syncing...'), findsOneWidget);
      expect(setupController.pageOfNoReturn, greaterThan(0));
    });

    test('DebugConsoleOutput respects minLevel so web release logs warnings and errors only', () {
      final captured = <String>[];
      final origDebugPrint = debugPrint;
      debugPrint = (String? msg, {int? wrapWidth}) {
        if (msg != null) captured.add(msg);
      };
      addTearDown(() => debugPrint = origDebugPrint);

      final out = DebugConsoleOutput(minLevel: Level.warning);
      out.output(OutputEvent(LogEvent(Level.info, 'info'), ['info-line']));
      out.output(OutputEvent(LogEvent(Level.warning, 'warn'), ['warn-line']));
      out.output(OutputEvent(LogEvent(Level.error, 'err'), ['err-line']));

      expect(captured, ['warn-line', 'err-line']);
    });
  });
}
