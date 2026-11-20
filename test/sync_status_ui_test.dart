import 'package:bluebubbles/app/components/sync_indicator.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/main.dart' show AppShellFrame;
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

class _TestSettingsService extends SettingsService {
  @override
  ServerDetails get serverDetails => const ServerDetails(
        macOSVersion: 14,
        macOSMinorVersion: 0,
        serverVersion: '1.9.0',
        serverVersionCode: 10900,
      );
}

class _TestSyncService extends SyncService {
  int retryCalls = 0;

  @override
  Future<void> retryNow() async {
    retryCalls++;
    status.value = status.value.copyWith(retrying: true, dismissed: false);
  }
}

void main() {
  late _TestSettingsService settings;
  late _TestSyncService sync;

  setUp(() {
    settings = _TestSettingsService()..settings = Settings();
    settings.settings.finishedSetup.value = true;
    settings.settings.showSyncIndicator.value = true;
    settings.settings.skin.value = Skins.Material;

    if (GetIt.I.isRegistered<SettingsService>()) {
      GetIt.I.unregister<SettingsService>();
    }
    GetIt.I.registerSingleton<SettingsService>(settings);

    sync = _TestSyncService();
    sync.onSetupStateChanged(true);

    if (GetIt.I.isRegistered<SyncService>()) {
      GetIt.I.unregister<SyncService>();
    }
    GetIt.I.registerSingleton<SyncService>(sync);

    if (GetIt.I.isRegistered<SocketService>()) {
      GetIt.I.unregister<SocketService>();
    }
    GetIt.I.registerSingleton<SocketService>(SocketService());
  });

  tearDown(() {
    sync.disposeStatusTracker();
    if (GetIt.I.isRegistered<SocketService>()) {
      GetIt.I.unregister<SocketService>();
    }
    if (GetIt.I.isRegistered<SyncService>()) {
      GetIt.I.unregister<SyncService>();
    }
    if (GetIt.I.isRegistered<SettingsService>()) {
      GetIt.I.unregister<SettingsService>();
    }
  });

  Widget wrapShell({
    required Widget body,
    Size viewport = const Size(390, 844),
    EdgeInsets viewPadding = const EdgeInsets.only(top: 24),
    ThemeData? theme,
  }) {
    return MediaQuery(
      data: MediaQueryData(size: viewport, viewPadding: viewPadding),
      child: MaterialApp(
        theme: theme ?? ThemeData.light(useMaterial3: true),
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              body,
              const GlobalSyncStatusOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  group('GlobalSyncStatusOverlay', () {
    testWidgets('renders non-blocking 2px syncing hairline on mobile and web widths', (tester) async {
      var backgroundTapped = false;
      sync.status.value = const SyncStatusSnapshot(
        kind: SyncStatusKind.syncing,
        message: 'Syncing…',
      );

      // Mobile width with safe-area top inset
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        wrapShell(
          viewport: const Size(390, 800),
          viewPadding: const EdgeInsets.only(top: 24),
          body: Align(
            alignment: Alignment.topCenter,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => backgroundTapped = true,
              child: const SizedBox(width: 240, height: 120),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      final indicatorFinder = find.byType(LinearProgressIndicator);
      expect(indicatorFinder, findsOneWidget);
      final indicatorRect = tester.getRect(indicatorFinder);
      expect(indicatorRect.height, 2.0);
      expect(indicatorRect.width, 390.0);

      // Non-blocking: tapping over the hairline passes through to underlying widget
      await tester.tapAt(indicatorRect.center);
      expect(backgroundTapped, isTrue);

      // Web/desktop width & dark theme
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        wrapShell(
          viewport: const Size(1440, 900),
          viewPadding: EdgeInsets.zero,
          theme: ThemeData.dark(useMaterial3: true),
          body: const SizedBox.expand(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(tester.getRect(find.byType(LinearProgressIndicator)).width, 1440.0);
    });

    testWidgets('AppShellFrame pushes AppBar down without double top padding when sync failed', (tester) async {
      sync.status.value = const SyncStatusSnapshot(
        kind: SyncStatusKind.failed,
        issueKey: 'sync_connection',
        message: 'Connection error',
      );

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(top: 44),
            viewPadding: EdgeInsets.only(top: 44),
          ),
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: AppShellFrame(
              navigator: Scaffold(
                appBar: AppBar(
                  key: const Key('test_app_bar'),
                  title: const Text('Messages'),
                ),
                body: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bannerRect = tester.getRect(find.byKey(const ValueKey('sync_failed:sync_connection')));
      final appBarRect = tester.getRect(find.byKey(const Key('test_app_bar')));

      // Banner absorbs the 44px top safe-area inset and sits above AppBar with zero overlap
      expect(bannerRect.top, greaterThanOrEqualTo(44.0));
      expect(appBarRect.top, greaterThanOrEqualTo(bannerRect.bottom));
      // AppBar should NOT double-pad another 44px below the banner
      expect(appBarRect.height, lessThanOrEqualTo(64.0));

      // Frosted-glass translucency: BackdropFilter + translucent tinted fill + subtle 1px hairline
      final stripFinder = find.byKey(const ValueKey('sync_failed:sync_connection'));
      expect(
        find.descendant(of: stripFinder, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      final decorated = tester.widget<DecoratedBox>(
        find.descendant(of: stripFinder, matching: find.byType(DecoratedBox)).first,
      );
      final box = decorated.decoration as BoxDecoration;
      expect(box.color!.a, inInclusiveRange(0.70, 0.80));
      expect(box.border!.bottom.width, 1.0);
      expect(box.border!.bottom.color.a, inInclusiveRange(0.14, 0.22));
    });

    testWidgets('stays hidden during unauthenticated onboarding/setup', (tester) async {
      settings.settings.finishedSetup.value = false;
      sync.status.value = const SyncStatusSnapshot(
        kind: SyncStatusKind.failed,
        issueKey: 'sync_connection',
        message: 'Connection error',
      );

      await tester.pumpWidget(wrapShell(body: const SizedBox.expand()));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Connection error'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('sticky failure stays mounted through retry cycles without unmounting', (tester) async {
      sync.status.value = const SyncStatusSnapshot(
        kind: SyncStatusKind.failed,
        issueKey: 'sync_connection',
        message: 'Connection error',
        retrying: false,
      );

      await tester.pumpWidget(wrapShell(body: const SizedBox.expand()));
      await tester.pump(const Duration(milliseconds: 250));

      final bannerFinder = find.byKey(const ValueKey('sync_failed:sync_connection'));
      expect(bannerFinder, findsOneWidget);
      final initialElement = tester.element(bannerFinder);
      expect(find.text('Connection error'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Tapping Retry calls SyncSvc.retryNow() and shows inline spinner while retrying
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(sync.retryCalls, 1);
      expect(tester.element(bannerFinder), same(initialElement));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Background retry settles back to failed without unmounting or popping the banner
      sync.status.value = const SyncStatusSnapshot(
        kind: SyncStatusKind.failed,
        issueKey: 'sync_connection',
        message: 'Connection error',
        retrying: false,
      );
      await tester.pump();
      expect(tester.element(bannerFinder), same(initialElement));
      expect(find.text('Connection error'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('dismiss suppresses re-show until resolved, then re-shows on a new post-recovery failure',
        (tester) async {
      // Establish connected baseline, then drop to error
      sync.onSocketStatusChanged(
        state: SocketState.connected,
        connectionDesired: true,
        authFailed: false,
      );
      sync.onSocketStatusChanged(
        state: SocketState.error,
        connectionDesired: true,
        authFailed: false,
      );

      await tester.pumpWidget(wrapShell(body: const SizedBox.expand()));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Connection lost'), findsOneWidget);

      // Tap × dismiss
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('Connection lost'), findsNothing);

      // Background retry cycle (reconnecting -> error) must NOT re-show dismissed episode
      sync.onSocketStatusChanged(
        state: SocketState.reconnecting,
        connectionDesired: true,
        authFailed: false,
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('Connection lost'), findsNothing);

      sync.onSocketStatusChanged(
        state: SocketState.error,
        connectionDesired: true,
        authFailed: false,
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('Connection lost'), findsNothing);

      // Sync recovers and stays connected past the 10s stability window -> episode resolves
      sync.onSocketStatusChanged(
        state: SocketState.connected,
        connectionDesired: true,
        authFailed: false,
      );
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('Connection lost'), findsNothing);

      // A new post-recovery failure MUST re-show the banner
      sync.onSocketStatusChanged(
        state: SocketState.error,
        connectionDesired: true,
        authFailed: false,
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('Connection lost'), findsOneWidget);
    });

    testWidgets('red/yellow ConnectionIndicator hairline is removed from TitleBarWrapper', (tester) async {
      SocketSvc.state.value = SocketState.error;
      await tester.pumpWidget(
        const MaterialApp(
          home: TitleBarWrapper(
            child: Scaffold(body: Text('Body')),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Body'), findsOneWidget);
      // Confirm no 1.5px hairline Container exists inside TitleBarWrapper
      final containers = tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer));
      expect(containers, isEmpty);
    });
  });
}
