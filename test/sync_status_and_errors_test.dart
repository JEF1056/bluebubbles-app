import 'package:bluebubbles/app/components/app_notice_bar.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/main.dart' show AppShellFrame;
import 'package:bluebubbles/services/services.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _FakeSettingsService extends SettingsService {}

void main() {
  group('SyncStatusTracker state machine', () {
    test('stays idle while finishedSetup is false even on socket error and sync failure', () {
      final emitted = <SyncStatusSnapshot>[];
      final tracker = SyncStatusTracker(
        onChanged: emitted.add,
        syncDebounce: const Duration(milliseconds: 300),
        startupGrace: const Duration(seconds: 5),
      );
      addTearDown(tracker.dispose);

      tracker.onSocketState(connected: false, retrying: false, failed: true, errorMessage: 'Connection refused');
      tracker.onSyncStarted();
      tracker.onSyncFinished(success: false);

      expect(tracker.snapshot, SyncStatusSnapshot.idle);
      expect(emitted, isEmpty);
    });

    test('debounces syncing (~300ms) so fast syncs do not flash', () {
      fakeAsync((async) {
        final emitted = <SyncStatusSnapshot>[];
        final tracker = SyncStatusTracker(
          onChanged: emitted.add,
          syncDebounce: const Duration(milliseconds: 300),
          startupGrace: const Duration(seconds: 5),
        );
        addTearDown(tracker.dispose);

        tracker.setFinishedSetup(true);
        tracker.onSocketState(connected: true, retrying: false, failed: false);

        // Fast sync (< 300ms): never emits syncing.
        tracker.onSyncStarted();
        async.elapse(const Duration(milliseconds: 200));
        expect(tracker.snapshot.showSyncing, isFalse);
        tracker.onSyncFinished(success: true);
        async.elapse(const Duration(milliseconds: 200));
        expect(emitted, isEmpty);

        // Longer sync (>= 300ms): emits syncing after 300ms, then returns to idle on finish.
        tracker.onSyncStarted();
        async.elapse(const Duration(milliseconds: 299));
        expect(tracker.snapshot.showSyncing, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(tracker.snapshot.showSyncing, isTrue);
        expect(tracker.snapshot.message, 'Syncing…');

        tracker.onSyncFinished(success: true);
        expect(tracker.snapshot, SyncStatusSnapshot.idle);
      });
    });

    test('respects startup grace then latches sticky failed across reconnect cycles without flapping', () {
      fakeAsync((async) {
        final emitted = <SyncStatusSnapshot>[];
        final tracker = SyncStatusTracker(
          onChanged: emitted.add,
          syncDebounce: const Duration(milliseconds: 300),
          startupGrace: const Duration(seconds: 5),
        );
        addTearDown(tracker.dispose);

        tracker.setFinishedSetup(true);
        tracker.onSocketState(connected: false, retrying: true, failed: false);
        expect(tracker.snapshot, SyncStatusSnapshot.idle);

        // Early error within startup grace stays idle until grace expires.
        tracker.onSocketState(connected: false, retrying: false, failed: true, errorMessage: 'Connection refused');
        async.elapse(const Duration(seconds: 4));
        expect(tracker.snapshot, SyncStatusSnapshot.idle);

        // Grace expires while still failing -> latches failed.
        async.elapse(const Duration(seconds: 1));
        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.showFailed, isTrue);
        expect(tracker.snapshot.retrying, isFalse);

        // Reconnect ticks toggle retrying without ever leaving failed or flapping to idle/syncing.
        emitted.clear();
        tracker.onSocketState(connected: false, retrying: true, failed: false);
        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.retrying, isTrue);

        tracker.onSocketState(connected: false, retrying: false, failed: true, errorMessage: 'Timed out');
        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.retrying, isFalse);

        tracker.onSyncStarted();
        async.elapse(const Duration(milliseconds: 400));
        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.retrying, isTrue);

        tracker.onSyncFinished(success: false);
        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.retrying, isFalse);
        expect(emitted.every((s) => s.kind == SyncStatusKind.failed), isTrue);

        // Real connect + sync success clears the failed episode.
        tracker.onSocketState(connected: true, retrying: false, failed: false);
        // Sync failed earlier in episode, so it stays failed (retrying) until sync succeeds.
        tracker.onSyncStarted();
        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.retrying, isTrue);

        tracker.onSyncFinished(success: true);
        expect(tracker.snapshot, SyncStatusSnapshot.idle);
      });
    });

    test('dismissIssue suppresses same episode across retries until resolved or manual retryNow', () {
      fakeAsync((async) {
        final tracker = SyncStatusTracker(
          onChanged: (_) {},
          syncDebounce: const Duration(milliseconds: 300),
          startupGrace: Duration.zero,
        );
        addTearDown(tracker.dispose);

        tracker.setFinishedSetup(true);
        tracker.onSocketState(connected: true, retrying: false, failed: false);

        // Sync fails -> failed episode latches.
        tracker.onSyncStarted();
        tracker.onSyncFinished(success: false);
        expect(tracker.snapshot.showFailed, isTrue);

        // User dismisses -> showFailed becomes false.
        tracker.dismissIssue();
        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.dismissed, isTrue);
        expect(tracker.snapshot.showFailed, isFalse);

        // Subsequent socket drops and failed retries of the same episode stay dismissed.
        tracker.onSocketState(connected: false, retrying: true, failed: false);
        tracker.onSocketState(connected: false, retrying: false, failed: true, errorMessage: 'Offline');
        tracker.onSyncStarted();
        tracker.onSyncFinished(success: false);
        expect(tracker.snapshot.showFailed, isFalse);

        // Manual retry clears dismissal and marks retrying.
        tracker.prepareManualRetry();
        expect(tracker.snapshot.dismissed, isFalse);
        expect(tracker.snapshot.retrying, isTrue);
        expect(tracker.snapshot.showFailed, isTrue);

        // Dismiss again, then recover via real connect + sync success.
        tracker.dismissIssue();
        expect(tracker.snapshot.showFailed, isFalse);
        tracker.onSocketState(connected: true, retrying: false, failed: false);
        tracker.onSyncStarted();
        tracker.onSyncFinished(success: true);
        expect(tracker.snapshot, SyncStatusSnapshot.idle);

        // A NEW post-recovery failure shows again.
        tracker.onSocketState(connected: false, retrying: false, failed: true, errorMessage: 'Connection lost');
        expect(tracker.snapshot.showFailed, isTrue);
        expect(tracker.snapshot.dismissed, isFalse);
      });
    });

    test('sticky failure stays failed and keeps dismissal across brief connect-then-drop loops', () {
      fakeAsync((async) {
        final emitted = <SyncStatusSnapshot>[];
        final tracker = SyncStatusTracker(
          onChanged: emitted.add,
          syncDebounce: const Duration(milliseconds: 300),
          startupGrace: Duration.zero,
          stableConnectDuration: const Duration(seconds: 10),
        );
        addTearDown(tracker.dispose);

        tracker.setFinishedSetup(true);
        tracker.onSocketState(connected: false, retrying: false, failed: true, errorMessage: 'Connection lost');
        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.showFailed, isTrue);

        tracker.dismissIssue();
        expect(tracker.snapshot.showFailed, isFalse);

        // Connect briefly then drop within 2s -> banner clears immediately while connected,
        // dismissal stays latched across drop within 10s stability window.
        emitted.clear();
        tracker.onSocketState(connected: true, retrying: false, failed: false);
        expect(tracker.snapshot, SyncStatusSnapshot.idle);
        async.elapse(const Duration(seconds: 2));
        tracker.onSocketState(connected: false, retrying: false, failed: true, errorMessage: 'Connection lost');

        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.showFailed, isFalse);
        expect(emitted.first, SyncStatusSnapshot.idle);

        // Staying connected for >= 10s clears the latched failure and dismissal.
        tracker.onSocketState(connected: true, retrying: false, failed: false);
        expect(tracker.snapshot, SyncStatusSnapshot.idle);
        async.elapse(const Duration(seconds: 10));
        tracker.onSocketState(connected: false, retrying: false, failed: true, errorMessage: 'Connection lost');
        expect(tracker.snapshot.showFailed, isTrue);
      });
    });

    test('resume reconnect grace hides transient failure/offline until grace expires', () {
      fakeAsync((async) {
        final tracker = SyncStatusTracker(
          onChanged: (_) {},
          startupGrace: Duration.zero,
          reconnectGrace: const Duration(seconds: 6),
        );
        addTearDown(tracker.dispose);

        tracker.setFinishedSetup(true);
        tracker.onSocketState(connected: true, retrying: false, failed: false);
        tracker.beginReconnectGrace();
        tracker.setNetworkOnline(false);
        tracker.onSocketState(connected: false, retrying: true, failed: true, errorMessage: 'Offline');

        expect(tracker.snapshot, SyncStatusSnapshot.idle);
        async.elapse(const Duration(seconds: 5));
        expect(tracker.snapshot, SyncStatusSnapshot.idle);

        // If connection does not recover before 6s, failure surfaces.
        async.elapse(const Duration(seconds: 1));
        expect(tracker.snapshot.kind, SyncStatusKind.failed);
        expect(tracker.snapshot.showFailed, isTrue);
      });
    });

    test('setNetworkOnline(false) never shows Offline while socket is connected', () {
      final tracker = SyncStatusTracker(
        onChanged: (_) {},
        startupGrace: Duration.zero,
      );
      addTearDown(tracker.dispose);

      tracker.setFinishedSetup(true);
      tracker.onSocketState(connected: true, retrying: false, failed: false);
      tracker.setNetworkOnline(false);

      expect(tracker.snapshot, SyncStatusSnapshot.idle);
    });

    test('intentional background disconnect does not latch failure', () {
      final tracker = SyncStatusTracker(
        onChanged: (_) {},
        startupGrace: Duration.zero,
      );
      addTearDown(tracker.dispose);

      tracker.setFinishedSetup(true);
      tracker.onSocketState(connected: true, retrying: false, failed: false);
      tracker.setConnectionDesired(false);
      tracker.onSocketState(connected: false, retrying: false, failed: false);

      expect(tracker.snapshot, SyncStatusSnapshot.idle);
    });
  });

  group('SyncService reactive status integration', () {
    setUp(() {
      if (GetIt.I.isRegistered<SettingsService>()) GetIt.I.unregister<SettingsService>();
      if (GetIt.I.isRegistered<SyncService>()) GetIt.I.unregister<SyncService>();
      final settings = _FakeSettingsService()..settings = (Settings()..finishedSetup.value = true);
      GetIt.I.registerSingleton<SettingsService>(settings);
      GetIt.I.registerSingleton<SyncService>(SyncService());
    });

    tearDown(() async {
      if (GetIt.I.isRegistered<SyncService>()) {
        SyncSvc.disposeStatusTracker();
      }
      await GetIt.I.reset();
    });

    test('onNetworkOnlineChanged(false) latches Offline and dismissIssue hides it', () {
      SyncSvc.onNetworkOnlineChanged(false);
      expect(SyncSvc.status.value.kind, SyncStatusKind.failed);
      expect(SyncSvc.status.value.message, 'Offline');
      expect(SyncSvc.status.value.showFailed, isTrue);

      SyncSvc.dismissIssue();
      expect(SyncSvc.status.value.showFailed, isFalse);

      SyncSvc.onNetworkOnlineChanged(true);
      SyncSvc.onSocketStatusChanged(
        state: SocketState.connected,
        connectionDesired: true,
        authFailed: false,
      );
      expect(SyncSvc.status.value, SyncStatusSnapshot.idle);
    });
  });

  group('Dismissible & issue-deduped error snackbars/toasts', () {
    setUp(() {
      Get.testMode = true;
      resetErrorIssuesForTest();
      if (GetIt.I.isRegistered<SettingsService>()) {
        GetIt.I.unregister<SettingsService>();
      }
      GetIt.I.registerSingleton<SettingsService>(_FakeSettingsService()..settings = Settings());
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('PonnamKarthik/fluttertoast'), null);
      resetErrorIssuesForTest();
      Get.closeAllSnackbars();
      Get.reset();
      if (GetIt.I.isRegistered<SettingsService>()) {
        GetIt.I.unregister<SettingsService>();
      }
    });

    testWidgets('error snackbar auto-close allows repeat error, while explicit dismiss suppresses it',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox.shrink())));

        // 1. Show error -> let it auto-close -> same error can show again.
        showSnackbar('Error', 'Failed to send message', type: SnackbarType.error);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Failed to send message'), findsOneWidget);

        // While still open, duplicate pop is suppressed.
        showSnackbar('Error', 'Failed to send message', type: SnackbarType.error);
        await tester.pump();
        expect(find.text('Failed to send message'), findsOneWidget);

        // Wait for auto-close (4000ms duration + 250ms animation).
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(find.text('Failed to send message'), findsNothing);

        // Same error shows again after auto-close!
        showSnackbar('Error', 'Failed to send message', type: SnackbarType.error);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Failed to send message'), findsOneWidget);

        // 2. Explicit dismiss -> stays suppressed.
        await tester.tap(find.byKey(const Key('snackbar_dismiss_button')));
        await tester.pumpAndSettle();
        expect(find.text('Failed to send message'), findsNothing);

        showSnackbar('Error', 'Failed to send message', type: SnackbarType.error);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Failed to send message'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('web/desktop error snackbar has close button, dismisses on tap, and dedups until cleared',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox.shrink())));

        showSnackbar('Error', 'Upload failed', type: SnackbarType.error);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Upload failed'), findsOneWidget);
        expect(find.byKey(const Key('snackbar_dismiss_button')), findsOneWidget);

        // Tap the explicit × close button.
        await tester.tap(find.byKey(const Key('snackbar_dismiss_button')));
        await tester.pumpAndSettle();
        expect(find.text('Upload failed'), findsNothing);

        // Same issue (even with different casing/whitespace) does not re-show while unresolved.
        showSnackbar('  error ', 'upload   failed ', type: SnackbarType.error);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('upload   failed '), findsNothing);

        // Clearing the issue allows it to show again.
        clearErrorIssue(normalizeErrorIssueKey(title: 'Error', message: 'Upload failed'));
        showSnackbar('Error', 'Upload failed', type: SnackbarType.error);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Upload failed'), findsOneWidget);

        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('issueKey dedups distinct messages sharing the same unresolved issue', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox.shrink())));

        showSnackbar('Error', 'Contact sync error #1', type: SnackbarType.error, issueKey: 'contact_sync');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Contact sync error #1'), findsOneWidget);

        await tester.tap(find.byKey(const Key('snackbar_dismiss_button')));
        await tester.pumpAndSettle();

        showSnackbar('Error', 'Contact sync error #2', type: SnackbarType.error, issueKey: 'contact_sync');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Contact sync error #2'), findsNothing);

        clearErrorIssue('contact_sync');
        showSnackbar('Error', 'Contact sync error #2', type: SnackbarType.error, issueKey: 'contact_sync');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Contact sync error #2'), findsOneWidget);

        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('mobile native error toast is deduped without recursing until cleared', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final toastCalls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('PonnamKarthik/fluttertoast'), (call) async {
          toastCalls.add('${call.method}:${(call.arguments as Map)['msg']}');
          return true;
        });

        await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox.shrink())));
        showSnackbar('Error', 'Mobile toast error', type: SnackbarType.error, issueKey: 'mobile_err');
        showSnackbar('Error', 'Mobile toast error', type: SnackbarType.error, issueKey: 'mobile_err');
        await showToast('Mobile toast error', isError: true, issueKey: 'mobile_err');
        await tester.pump(const Duration(seconds: 5));

        expect(toastCalls, ['showToast:Mobile toast error']);

        clearErrorIssue('mobile_err');
        await showToast('Mobile toast error', isError: true, issueKey: 'mobile_err');
        await tester.pump(const Duration(seconds: 5));
        expect(toastCalls, ['showToast:Mobile toast error', 'showToast:Mobile toast error']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('non-error snackbars are not deduped and have no error close button', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox.shrink())));

        showSnackbar('Notice', 'Saved', type: SnackbarType.success);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Saved'), findsOneWidget);
        expect(find.byKey(const Key('snackbar_dismiss_button')), findsNothing);

        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        showSnackbar('Notice', 'Saved', type: SnackbarType.success);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Saved'), findsOneWidget);

        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('AppShellFrame renders error notice in top slot on mobile Android and pushes AppBar down',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = null;
      });

      await tester.pumpWidget(
        MaterialApp(
          home: AppShellFrame(
            navigator: Scaffold(
              appBar: AppBar(
                key: const Key('shell_app_bar'),
                title: const Text('Chat'),
              ),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      );

      showSnackbar('Error', 'Upload failed', type: SnackbarType.error, issueKey: 'upload_fail');
      await tester.pumpAndSettle();

      expect(find.byType(AppNoticeTopBar), findsOneWidget);
      expect(find.text('Upload failed'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppNoticeTopBar), matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      final topDecorated = tester.widget<DecoratedBox>(
        find.descendant(of: find.byType(AppNoticeTopBar), matching: find.byType(DecoratedBox)).first,
      );
      final topBox = topDecorated.decoration as BoxDecoration;
      expect(topBox.color!.a, inInclusiveRange(0.70, 0.80));
      expect(topBox.border!.bottom.color.a, inInclusiveRange(0.14, 0.22));
      final noticeRect = tester.getRect(find.byType(AppNoticeTopBar));
      final appBarRect = tester.getRect(find.byKey(const Key('shell_app_bar')));
      expect(appBarRect.top, greaterThanOrEqualTo(noticeRect.bottom));

      await tester.tap(find.byKey(const Key('snackbar_dismiss_button')));
      await tester.pumpAndSettle();
      expect(find.byType(AppNoticeTopBar), findsNothing);
    });

    testWidgets('AppShellFrame renders info/success notice at bottom-left on wide desktop (>=840px)',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = null;
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: AppShellFrame(
            navigator: Scaffold(
              appBar: AppBar(title: const Text('Messages')),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      );

      showSnackbar('Copied', 'Message copied', type: SnackbarType.success);
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byType(AppNoticeCornerToast), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppNoticeCornerToast), matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      final toastBox = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: find.byType(AppNoticeCornerToast), matching: find.byType(DecoratedBox)),
          )
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.color != null);
      expect(toastBox.color!.a, inInclusiveRange(0.68, 0.78));
      expect(toastBox.border!.top.color.a, inInclusiveRange(0.14, 0.22));
      final toastRect = tester.getRect(find.byType(AppNoticeCornerToast));
      expect(toastRect.left, lessThanOrEqualTo(24.0));
      expect(toastRect.right, lessThanOrEqualTo(400.0));
      expect(toastRect.bottom, greaterThanOrEqualTo(850.0));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });
}
