import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/app/components/facetime/ongoing_call_pill.dart';
import 'package:bluebubbles/app/components/facetime/outgoing_facetime_sheet.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _loadTestFonts() async {
  const flutterRoot = '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts';
  final robotoLoader = FontLoader('Roboto');
  for (final file in [
    '$flutterRoot/Roboto-Regular.ttf',
    '$flutterRoot/Roboto-Medium.ttf',
    '$flutterRoot/Roboto-Bold.ttf',
    '$flutterRoot/Roboto-Light.ttf',
  ]) {
    final f = File(file);
    if (f.existsSync()) {
      robotoLoader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
  }
  await robotoLoader.load();

  final iconsFile = File('$flutterRoot/MaterialIcons-Regular.otf');
  if (iconsFile.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons');
    iconsLoader.addFont(Future.value(ByteData.sublistView(iconsFile.readAsBytesSync())));
    await iconsLoader.load();
  }
}

void main() {
  final screenshotDir = Platform.environment['FACETIME_SCREENSHOT_DIR'];

  setUpAll(() async {
    await _loadTestFonts();
    if (screenshotDir != null && screenshotDir.isNotEmpty) {
      Directory(screenshotDir).createSync(recursive: true);
    }
  });

  final viewports = <String, Size>{
    'desktop_1280x800': const Size(1280, 800),
    'mobile_390x844': const Size(390, 844),
  };

  Future<void> capture(WidgetTester tester, String name) async {
    if (screenshotDir == null || screenshotDir.isEmpty) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('visual_capture_root')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data != null) {
        await File('$screenshotDir/$name.png').writeAsBytes(data.buffer.asUint8List());
      }
    });
  }

  Widget wrapRoot(
    Widget child, {
    Brightness brightness = Brightness.dark,
    bool disableAnimations = true,
  }) {
    return RepaintBoundary(
      key: const Key('visual_capture_root'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'Roboto',
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF147EFB),
            brightness: brightness,
          ),
        ),
        home: Builder(
          builder: (ctx) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(disableAnimations: disableAnimations),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget mockChatBackdrop() {
    return Scaffold(
      appBar: AppBar(title: const Text('Maya Lin')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Align(
            alignment: Alignment.centerLeft,
            child: Card(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text('Hey, are you free for a quick call?'),
              ),
            ),
          ),
          SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Card(
              color: Color(0xFF147EFB),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text('Yes! Calling you now.', style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  for (final entry in viewports.entries) {
    final vpName = entry.key;
    final size = entry.value;

    testWidgets('FaceTime visual E2E suite ($vpName)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final baseNow = DateTime(2026, 11, 21, 12, 5, 0);

      // 1. InAppCallScreen - Audio
      final audioCtrl = ActiveCallController(now: () => baseNow);
      addTearDown(audioCtrl.dispose);
      audioCtrl.startOngoing(
        callUuid: 'vis-audio',
        callerName: 'Maya Lin',
        isVideo: false,
        connectedAt: baseNow.subtract(const Duration(minutes: 2, seconds: 14)),
      );
      await tester.pumpWidget(wrapRoot(InAppCallScreen(controller: audioCtrl)));
      await tester.pumpAndSettle();
      expect(find.text('Maya Lin'), findsOneWidget);
      expect(find.text('Connected · 02:14'), findsOneWidget);
      await capture(tester, '${vpName}_01_inapp_audio');

      // 2. InAppCallScreen - Video
      final videoCtrl = ActiveCallController(now: () => baseNow);
      addTearDown(videoCtrl.dispose);
      videoCtrl.startOngoing(
        callUuid: 'vis-video',
        callerName: 'Alex Rivera',
        isVideo: true,
        connectedAt: baseNow.subtract(const Duration(minutes: 1, seconds: 8)),
      );
      await tester.pumpWidget(
        wrapRoot(
          InAppCallScreen(
            controller: videoCtrl,
            videoView: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF0E2A38), Color(0xFF1A4B5C), Color(0xFF0A1924)],
                ),
              ),
              child: Center(
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                  ),
                  child: const Icon(Icons.person_rounded, size: 72, color: Colors.white70),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alex Rivera'), findsOneWidget);
      await capture(tester, '${vpName}_02_inapp_video');

      // 3. InAppCallScreen - iPhone Call
      final phoneCtrl = ActiveCallController(now: () => baseNow);
      addTearDown(phoneCtrl.dispose);
      phoneCtrl.startOngoing(
        callUuid: 'vis-phone',
        callerName: 'Jordan Vance',
        callerAddress: '+1 (415) 555-0192',
        isVideo: false,
        isTelecomCall: true,
        isTelephony: true,
        connectedAt: baseNow.subtract(const Duration(seconds: 42)),
      );
      await tester.pumpWidget(wrapRoot(InAppCallScreen(controller: phoneCtrl)));
      await tester.pumpAndSettle();
      expect(find.text('Jordan Vance'), findsOneWidget);
      expect(find.text('+1 (415) 555-0192'), findsOneWidget);
      await capture(tester, '${vpName}_03_inapp_iphone_call');

      // 4. InAppCallScreen - Muted + Speaker
      final mutedCtrl = ActiveCallController(
        now: () => baseNow,
        onToggleSpeaker: (_) async => true,
      );
      addTearDown(mutedCtrl.dispose);
      mutedCtrl.startOngoing(
        callUuid: 'vis-muted',
        callerName: 'Maya Lin',
        isVideo: false,
        connectedAt: baseNow.subtract(const Duration(minutes: 4, seconds: 5)),
      );
      mutedCtrl.toggleMute();
      await mutedCtrl.toggleSpeaker();
      await tester.pumpWidget(wrapRoot(InAppCallScreen(controller: mutedCtrl)));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Unmute'), findsOneWidget);
      await capture(tester, '${vpName}_04_inapp_muted');

      // 5. InAppCallScreen - DTMF keypad open
      final dtmfCtrl = ActiveCallController(
        now: () => baseNow,
        onSendDtmf: (_, _) async {},
      );
      addTearDown(dtmfCtrl.dispose);
      dtmfCtrl.startOngoing(
        callUuid: 'vis-dtmf',
        callerName: 'Bank Support',
        callerAddress: '+1 (800) 555-0100',
        isVideo: false,
        isTelecomCall: true,
        isTelephony: true,
        connectedAt: baseNow.subtract(const Duration(seconds: 19)),
      );
      await tester.pumpWidget(wrapRoot(InAppCallScreen(controller: dtmfCtrl)));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Keypad'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5'));
      await tester.pumpAndSettle();
      expect(find.text('DTMF: 5'), findsOneWidget);
      await capture(tester, '${vpName}_05_inapp_dtmf_open');

      // 6. IncomingFaceTimeScreen
      await tester.pumpWidget(
        wrapRoot(
          IncomingFaceTimeScreen(
            callUuid: 'vis-incoming',
            callerName: 'Maya Lin',
            isAudio: false,
            onAnswerVideo: () {},
            onAnswerAudio: () {},
            onDecline: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Incoming FaceTime Video'), findsOneWidget);
      await capture(tester, '${vpName}_06_incoming_facetime');

      // 7. OutgoingFaceTimeSheet (with Telecom setup banner)
      late BuildContext sheetHostCtx;
      await tester.pumpWidget(
        wrapRoot(
          Stack(
            children: [
              mockChatBackdrop(),
              Builder(
                builder: (ctx) {
                  sheetHostCtx = ctx;
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(
        showModalBottomSheet<void>(
          context: sheetHostCtx,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => OutgoingFaceTimeSheet(
            callerName: 'Samira Patel',
            callerAddress: '+1 (415) 555-0144',
            isAndroid: true,
            checkTelecomEnabled: () async => false,
            onOpenCallingAccounts: () async {},
            requestCallPermissions: () async => true,
            onPlaceNativeAudioCall: () async => true,
            onStartServerCall: (_) async => const PlacedFaceTimeCall(
              link: 'https://facetime.apple.com/join#mock',
              call: FaceTimeCall(callUuid: 'vis-out'),
            ),
            onOpenJoinLink: (_) async {},
            onHangUpRingingCall: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Start video call'), findsOneWidget);
      await capture(tester, '${vpName}_07_outgoing_sheet');
      Navigator.of(sheetHostCtx, rootNavigator: true).pop();
      await tester.pumpAndSettle();

      // 8. OngoingCallPillOverlay inside AppShellFrame (4-action audio call + keypad overlay)
      final pillCtrl = ActiveCallController(
        now: () => baseNow,
        onReturnToCall: (_, _) async {},
        onEndCall: (_, _) async {},
        onSendDtmf: (_, _) async {},
      );
      addTearDown(pillCtrl.dispose);
      pillCtrl.startOngoing(
        callUuid: 'vis-pill',
        callerName: 'Maya Lin',
        isVideo: false,
        joinLink: 'https://facetime.apple.com/join#live',
        connectedAt: baseNow.subtract(const Duration(minutes: 1, seconds: 25)),
      );
      Widget pillShell(ActiveCallController ctrl) {
        return Column(
          children: [
            SafeArea(
              bottom: false,
              child: OngoingCallPillOverlay(controller: ctrl),
            ),
            Expanded(child: mockChatBackdrop()),
          ],
        );
      }

      await tester.pumpWidget(wrapRoot(pillShell(pillCtrl)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ongoing_call_banner_tap')), findsOneWidget);
      await capture(tester, '${vpName}_08_ongoing_pill');

      // 9. OngoingCallPillOverlay with DTMF keypad overlay open
      await tester.tap(find.bySemanticsLabel('Keypad'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('keypad_outside_dismiss')), findsOneWidget);
      final btnRect = tester.getRect(find.bySemanticsLabel('Keypad'));
      final key1Rect = tester.getRect(find.text('1'));
      expect(key1Rect.left, greaterThan(size.width * 0.3));
      expect(key1Rect.top, greaterThan(btnRect.bottom));
      await capture(tester, '${vpName}_09_ongoing_pill_keypad');

      // 10. Light Mode OngoingCallPillOverlay (with reduced motion active too)
      await tester.pumpWidget(
        wrapRoot(
          pillShell(pillCtrl),
          brightness: Brightness.light,
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, '${vpName}_10_ongoing_pill_light');
    });
  }

  testWidgets('InAppCallScreen DTMF keypad fits short landscape viewport without overflow', (tester) async {
    tester.view.physicalSize = const Size(800, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final baseNow = DateTime(2026, 11, 21, 12, 5, 0);
    final ctrl = ActiveCallController(
      now: () => baseNow,
      onSendDtmf: (_, _) async {},
    );
    addTearDown(ctrl.dispose);
    ctrl.startOngoing(
      callUuid: 'vis-landscape',
      callerName: 'Bank Support',
      isVideo: false,
      isTelecomCall: true,
      isTelephony: true,
      connectedAt: baseNow.subtract(const Duration(seconds: 12)),
    );
    await tester.pumpWidget(wrapRoot(InAppCallScreen(controller: ctrl)));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Keypad'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('in_app_dtmf_keypad')), findsOneWidget);
  });

  testWidgets('InAppCallScreen two-way video with PiP, Flip, and Open Link fits compact & landscape viewports',
      (tester) async {
    for (final size in const [Size(320, 568), Size(800, 420)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final baseNow = DateTime(2026, 11, 21, 12, 5, 0);
      final ctrl = ActiveCallController(now: () => baseNow);
      addTearDown(ctrl.dispose);
      ctrl.startOngoing(
        callUuid: 'vis-two-way-${size.width.toInt()}',
        callerName: 'Alex Rivera',
        isVideo: true,
        joinLink: 'https://facetime.apple.com/join#visual',
        connectedAt: baseNow.subtract(const Duration(seconds: 34)),
      );
      ctrl.localVideoWidget.value = const ColoredBox(color: Color(0xFF284B63));
      ctrl.cameraEnabled.value = true;
      ctrl.canFlipCamera.value = true;

      await tester.pumpWidget(
        wrapRoot(
          MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: size.width <= 320 ? const TextScaler.linear(1.3) : TextScaler.noScaling,
            ),
            child: InAppCallScreen(
              controller: ctrl,
              videoView: const ColoredBox(color: Color(0xFF0E2A38)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('in_app_call_self_preview')), findsOneWidget);
      expect(find.byKey(const Key('in_app_call_flip_camera')), findsOneWidget);
      expect(find.byKey(const Key('in_app_call_open_link')), findsOneWidget);
    }
  });
}
