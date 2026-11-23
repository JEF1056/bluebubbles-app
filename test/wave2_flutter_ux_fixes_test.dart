import 'package:bluebubbles/app/components/app_notice_bar.dart';
import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/call_controls.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/app/components/facetime/ongoing_call_pill.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart' show SnackbarType;
import 'package:bluebubbles/main.dart' show AppShellFrame;
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

void main() {
  setUp(() async {
    Get.testMode = true;
    Get.reset();
    await GetIt.I.reset();
    AppNoticeController.instance.resetForTest();
    faceTimeOverlays.clear();
    faceTimeIncomingActions.clear();
    hideInAppCallScreen();
  });

  tearDown(() async {
    AppNoticeController.instance.resetForTest();
    faceTimeOverlays.clear();
    faceTimeIncomingActions.clear();
    hideInAppCallScreen();
    await GetIt.I.reset();
    Get.reset();
  });

  group('L2-UX-P0-1: AppShellFrame provides an Overlay in GetMaterialApp.builder', () {
    testWidgets('shell Tooltips (call bar, AppNoticeTopBar, sync strip) and OngoingCallPill Keypad OverlayPortal work',
        (tester) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      String? sentUuid;
      String? sentDigit;
      final controller = ActiveCallController(
        onSendDtmf: (uuid, digit) async {
          sentUuid = uuid;
          sentDigit = digit;
        },
      );
      addTearDown(controller.dispose);
      final semantics = tester.ensureSemantics();
      try {

        await tester.pumpWidget(
          GetMaterialApp(
            navigatorKey: NavigationSvc.key,
            builder: (context, child) => AppShellFrame(
              callController: controller,
              syncStatusOverride: const SyncStatusSnapshot(
                kind: SyncStatusKind.failed,
                issueKey: 'sync-err',
                message: 'Server unreachable',
              ),
              showSyncIndicatorOverride: true,
              navigator: child ?? const SizedBox.shrink(),
            ),
            home: const Scaffold(body: Center(child: Text('Home'))),
          ),
        );

        controller.startOngoing(
          callUuid: 'builder-ov-1',
          callerName: 'Bank Line',
          isVideo: false,
          isTelecomCall: true,
          isTelephony: true,
        );
        AppNoticeController.instance.show(
          title: 'Error',
          message: 'Check server connection',
          type: SnackbarType.error,
          durationMs: 10000,
        );
        await tester.pumpAndSettle();

        expect(find.byType(OngoingCallPillOverlay), findsOneWidget);
        expect(find.byKey(const ValueKey('call_bar_ongoing')), findsOneWidget);
        expect(find.byType(FaceTimeDockButton), findsWidgets);
        expect(find.bySemanticsLabel('Mute mic'), findsOneWidget);

        // Long-pressing tooltips inside call bar, sync banner, and AppNoticeTopBar must not throw.
        await tester.longPress(find.bySemanticsLabel('Mute mic'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final dismissTooltips = find.byTooltip('Dismiss');
        expect(dismissTooltips, findsNWidgets(2));
        await tester.longPress(dismissTooltips.first);
        await tester.pumpAndSettle();
        await tester.longPress(dismissTooltips.last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Tapping Keypad on OngoingCallPillOverlay inside GetMaterialApp.builder opens OverlayPortal.
        await tester.tap(find.bySemanticsLabel('Keypad'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('keypad_outside_dismiss')), findsOneWidget);

        await tester.tap(find.text('5'));
        await tester.pumpAndSettle();
        expect(sentUuid, 'builder-ov-1');
        expect(sentDigit, '5');

        await tester.tap(find.byKey(const Key('keypad_outside_dismiss')));
        await tester.pumpAndSettle();
      } finally {
        semantics.dispose();
        AppNoticeController.instance.resetForTest();
      }
    });
  });

  group('L2-UX-P0-2: FaceTime navigation resolves root Navigator from builder-slot contexts', () {
    testWidgets('tapping ongoing/incoming shell banners, answerCall, and join-link fallback sheet succeed from builder',
        (tester) async {
      final controller = ActiveCallController(
        onStartTelecomCall: ({
          required callUuid,
          required callerName,
          callerAddress,
          isTelephony = false,
          isVideo = false,
        }) async =>
            true,
        onAnswerServerCall: (
          uuid, {
          mode,
          audioOnly = false,
          displayName,
          chatGuid,
        }) async =>
            null,
      );
      addTearDown(controller.dispose);
      late BuildContext shellBuilderContext;
      late BuildContext innerNavigatorContext;

      await tester.pumpWidget(
        GetMaterialApp(
          navigatorKey: NavigationSvc.key,
          builder: (context, child) {
            shellBuilderContext = context;
            return AppShellFrame(
              callController: controller,
              navigator: child ?? const SizedBox.shrink(),
            );
          },
          home: Scaffold(
            body: Builder(
              builder: (context) {
                innerNavigatorContext = context;
                return const Center(child: Text('Root Home'));
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Confirm shellBuilderContext really sits above any Navigator.
      expect(Navigator.maybeOf(shellBuilderContext, rootNavigator: true), isNull);

      // Inner navigator context is preserved verbatim; builder-slot context resolves into root Navigator.
      expect(resolveFaceTimeNavigatorContext(innerNavigatorContext), same(innerNavigatorContext));
      final resolved = resolveFaceTimeNavigatorContext(shellBuilderContext);
      expect(resolved, isNotNull);
      expect(Navigator.maybeOf(resolved!, rootNavigator: true), isNotNull);

      // Show a root-navigator modal bottom sheet using the resolved context (same path as openFaceTimeJoinLink).
      showModalBottomSheet<void>(
        context: resolved,
        useRootNavigator: true,
        builder: (_) => const SizedBox(height: 80, child: Center(child: Text('Join Sheet OK'))),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Join Sheet OK'), findsOneWidget);
      Navigator.of(resolved, rootNavigator: true).pop();
      await tester.pumpAndSettle();

      // 1. Tapping incoming Continuity banner in builder opens IncomingFaceTimeScreen.
      controller.startIncoming(
        callUuid: 'builder-in-1',
        callerName: 'Taylor',
        isVideo: true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('incoming_call_banner_tap')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);
      expect(find.byType(IncomingFaceTimeScreen), findsOneWidget);
      hideFaceTimeOverlay('builder-in-1');
      await tester.pumpAndSettle();

      // 2. answerCall with builder-slot context opens InAppCallScreen via _openInAppCallScreenIfPossible.
      await controller.answerCall(audioOnly: false, context: shellBuilderContext);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(InAppCallScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('in_app_call_minimize')));
      await tester.pumpAndSettle();
      expect(find.byType(InAppCallScreen), findsNothing);

      // 3. Tapping ongoing call bar in builder opens InAppCallScreen.
      await tester.tap(find.byKey(const Key('ongoing_call_banner_tap')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(InAppCallScreen), findsOneWidget);

      hideInAppCallScreen();
      controller.clear();
      await tester.pumpAndSettle();
    });
  });

  group('L2-UX-P1-1: Keypad availability is independent of width across full screen and pill', () {
    testWidgets('FaceTime audio call keeps Keypad available at compact (<600) and wide (>=600) widths',
        (tester) async {
      String? sentDigit;
      final controller = ActiveCallController(
        onSendDtmf: (_, digit) async => sentDigit = digit,
      );
      addTearDown(controller.dispose);
      controller.startOngoing(
        callUuid: 'ft-audio-unified',
        callerName: 'Alex Rivera',
        isVideo: false,
        isTelephony: false,
      );

      // Minimized pill shows Keypad at compact width.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OngoingCallPillOverlay(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Keypad'), findsOneWidget);

      // Compact InAppCallScreen (<600) places Keypad in More tray instead of primary phone sheet.
      await tester.pumpWidget(
        MaterialApp(home: InAppCallScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Keypad'), findsNothing);
      await tester.tap(find.byKey(const Key('in_app_call_more_tray')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Keypad'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Keypad'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('in_app_dtmf_keypad')), findsOneWidget);
      await tester.tap(find.text('5'));
      await tester.pumpAndSettle();
      expect(sentDigit, '5');

      // Wide InAppCallScreen (>=600) places Keypad directly in the primary dock.
      tester.view.physicalSize = const Size(900, 800);
      await tester.pumpWidget(
        MaterialApp(home: InAppCallScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Keypad'), findsOneWidget);
      expect(MediaQuery.sizeOf(tester.element(find.byType(InAppCallScreen))).width,
          greaterThanOrEqualTo(FaceTimeDims.compactBreak));
    });

    testWidgets('Compact FaceTime video call keeps Keypad in More tray and omits Keypad when callUuid missing',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final controller = ActiveCallController();
      addTearDown(controller.dispose);
      controller.startOngoing(
        callUuid: 'ft-video-compact',
        callerName: 'Maya Lin',
        isVideo: true,
        isTelephony: false,
      );

      await tester.pumpWidget(
        MaterialApp(home: InAppCallScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('in_app_call_more_tray')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Keypad'), findsOneWidget);

      // Dismiss bottom sheet, then clear callUuid -> canShowKeypad becomes false across both surfaces.
      Navigator.of(tester.element(find.text('Keypad'))).pop();
      await tester.pumpAndSettle();

      controller.startOngoing(
        callUuid: null,
        callerName: 'No UUID Call',
        isVideo: false,
        isTelephony: true,
      );
      expect(controller.state.canShowKeypad, isFalse);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Keypad'), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OngoingCallPillOverlay(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Keypad'), findsNothing);
    });
  });
}
