import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/helpers/ui/dialog_helpers.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/main.dart' show AppShellFrame;
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _FakeSettingsService extends SettingsService {}

final Uint8List _samplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  tearDown(() {
    hideInAppCallScreen();
  });

  testWidgets('InAppCallScreen renders badge, timer, videoView slot, mute, speaker, DTMF, and end call',
      (tester) async {
    var fakeNow = DateTime(2026, 11, 21, 12, 0, 0);
    bool? mutedState;
    String? dtmfUuid;
    String? dtmfDigit;
    String? endedUuid;

    final controller = ActiveCallController(
      now: () => fakeNow,
      onMuteChanged: (muted) => mutedState = muted,
      onSendDtmf: (uuid, digit) async {
        dtmfUuid = uuid;
        dtmfDigit = digit;
      },
      onEndCall: (uuid, _) async => endedUuid = uuid,
    );
    addTearDown(controller.dispose);

    controller.startOngoing(
      callUuid: 'call-video-1',
      callerName: 'Maya Lin',
      avatarBytes: _samplePng,
      isVideo: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(
          controller: controller,
          videoView: const ColoredBox(
            key: Key('fake_remote_video'),
            color: Colors.teal,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Maya Lin'), findsOneWidget);
    expect(find.text('FaceTime Video'), findsOneWidget);
    expect(find.text('Connected · 00:00'), findsOneWidget);
    expect(find.byKey(const Key('fake_remote_video')), findsOneWidget);

    fakeNow = fakeNow.add(const Duration(seconds: 7));
    await tester.pump(const Duration(seconds: 7));
    expect(find.text('Connected · 00:07'), findsOneWidget);

    // Mute toggle updates controller and button label
    await tester.tap(find.bySemanticsLabel('Mute mic'));
    await tester.pump();
    expect(mutedState, isTrue);
    expect(find.text('Unmute'), findsOneWidget);

    // Speaker toggle works as a graceful no-op when no platform handler is provided
    await tester.tap(find.bySemanticsLabel('Speaker'));
    await tester.pump();
    expect(find.bySemanticsLabel('Speaker'), findsOneWidget);

    // Expand DTMF keypad and send digit
    await tester.tap(find.bySemanticsLabel('Keypad'));
    await tester.pump();
    expect(find.byKey(const Key('in_app_dtmf_keypad')), findsOneWidget);

    await tester.tap(find.text('5'));
    await tester.pump();
    expect(dtmfUuid, 'call-video-1');
    expect(dtmfDigit, '5');
    expect(find.text('DTMF: 5'), findsOneWidget);

    // End call resets controller to idle
    await tester.tap(find.bySemanticsLabel('End call'));
    await tester.pump();
    expect(endedUuid, 'call-video-1');
    expect(controller.state.phase, ActiveCallPhase.idle);
  });

  testWidgets('InAppCallScreen distinguishes FaceTime Audio vs iPhone Call telephony label', (tester) async {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);

    controller.startOngoing(
      callUuid: 'ft-audio-1',
      callerName: 'Alex Rivera',
      isVideo: false,
      isTelephony: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(controller: controller),
      ),
    );
    await tester.pump();
    expect(find.text('FaceTime Audio'), findsOneWidget);
    expect(find.text('iPhone Call'), findsNothing);

    controller.startOngoing(
      callUuid: 'tel-audio-1',
      callerName: 'Jordan Vance',
      isVideo: false,
      isTelecomCall: true,
      isTelephony: true,
    );
    await tester.pump();
    expect(find.text('iPhone Call'), findsOneWidget);
    expect(find.text('FaceTime Audio'), findsNothing);
  });

  testWidgets('OngoingCallPillOverlay expands InAppCallScreen without duplicating routes and minimizes back to pill',
      (tester) async {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    late BuildContext hostContext;

    await tester.pumpWidget(
      MaterialApp(
        home: AppShellFrame(
          callController: controller,
          navigator: Scaffold(
            body: Builder(
              builder: (context) {
                hostContext = context;
                return const Center(child: Text('App Body'));
              },
            ),
          ),
        ),
      ),
    );

    controller.startOngoing(
      callUuid: 'expand-1',
      callerName: 'Sam Lee',
      isVideo: false,
      isTelephony: false,
    );
    await tester.pumpAndSettle();

    expect(find.byType(InAppCallScreen), findsNothing);
    expect(find.text('Sam Lee'), findsOneWidget);

    // Tap OngoingCallPillOverlay info area to expand InAppCallScreen
    await tester.tap(find.byKey(const Key('ongoing_call_banner_tap')));
    await tester.pumpAndSettle();
    expect(find.byType(InAppCallScreen), findsOneWidget);
    expect(find.text('FaceTime Audio'), findsOneWidget);

    // Calling openInAppCallScreen again does not push a duplicate route
    openInAppCallScreen(context: hostContext, controller: controller);
    await tester.pumpAndSettle();
    expect(find.byType(InAppCallScreen), findsOneWidget);

    // Minimize pops back to app with OngoingCallPillOverlay visible
    await tester.tap(find.byKey(const Key('in_app_call_minimize')));
    await tester.pumpAndSettle();
    expect(find.byType(InAppCallScreen), findsNothing);
    expect(activeInAppCallRoute, isNull);
    expect(find.byKey(const Key('ongoing_call_banner_tap')), findsOneWidget);
    expect(find.text('Sam Lee'), findsOneWidget);
  });

  testWidgets('InAppCallScreen defaults bind to controller.remoteVideoWidget and controller.toggleSpeaker()',
      (tester) async {
    bool? speakerToggleRequested;
    final controller = ActiveCallController(
      onToggleSpeaker: (enabled) async {
        speakerToggleRequested = enabled;
        return true;
      },
    );
    addTearDown(controller.dispose);

    controller.startOngoing(
      callUuid: 'native-vid-1',
      callerName: 'Taylor Swift',
      isVideo: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.byType(Texture), findsNothing);
    expect(find.byIcon(Icons.volume_down_rounded), findsOneWidget);

    // Setting controller.remoteVideoWidget reactively renders it when videoView is null
    controller.handleFacetimeCallState(<String, dynamic>{
      'phase': 'video-texture',
      'call_uuid': 'native-vid-1',
      'texture_id': 42,
    });
    await tester.pump();

    final texture = tester.widget<Texture>(find.byType(Texture));
    expect(texture.textureId, 42);

    // Tapping speaker button delegates to controller.toggleSpeaker() and updates reactively
    await tester.tap(find.bySemanticsLabel('Speaker'));
    await tester.pump();
    expect(speakerToggleRequested, isTrue);
    expect(controller.isSpeakerOn.value, isTrue);
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

    // Clearing texture_id <= 0 removes the Texture widget
    controller.handleFacetimeCallState(<String, dynamic>{
      'phase': 'video-texture',
      'call_uuid': 'native-vid-1',
      'texture_id': 0,
    });
    await tester.pump();
    expect(find.byType(Texture), findsNothing);
  });

  testWidgets('InAppCallScreen two-way video PiP mirrors front camera, toggles camera, flips, and opens join link',
      (tester) async {
    String? openedLink;
    final controller = ActiveCallController(
      onLaunchJoinLink: (link) async {
        openedLink = link;
        return true;
      },
    );
    addTearDown(controller.dispose);

    controller.startOngoing(
      callUuid: 'two-way-1',
      callerName: 'Maya Lin',
      isVideo: true,
      joinLink: 'https://facetime.apple.com/join#two-way',
    );
    controller.handleFacetimeCallState(<String, dynamic>{
      'phase': 'video-texture',
      'call_uuid': 'two-way-1',
      'texture_id': 11,
    });
    controller.handleFacetimeCallState(<String, dynamic>{
      'phase': 'local-video-texture',
      'call_uuid': 'two-way-1',
      'texture_id': 22,
      'camera_enabled': true,
      'can_flip_camera': true,
      'front_camera': true,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(controller: controller),
      ),
    );
    await tester.pump();

    // Body uses GoogleSans while preserving caller/platform emoji fallback
    final callerText = tester.widget<Text>(find.text('Maya Lin'));
    final resolvedStyle = DefaultTextStyle.of(tester.element(find.text('Maya Lin'))).style.merge(callerText.style);
    expect(resolvedStyle.fontFamily, kDefaultAppFontFamily);

    // Top-right Open FaceTime Link button appears and launches link
    final openLinkFinder = find.byKey(const Key('in_app_call_open_link'));
    expect(openLinkFinder, findsOneWidget);
    expect(tester.getSize(openLinkFinder).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(openLinkFinder).height, greaterThanOrEqualTo(48));
    await tester.tap(openLinkFinder);
    await tester.pump();
    expect(openedLink, 'https://facetime.apple.com/join#two-way');

    // Mirrored self-preview PiP and 48dp flip button are rendered
    final pipFinder = find.byKey(const Key('in_app_call_self_preview'));
    expect(pipFinder, findsOneWidget);
    final flipTransform = tester.widget<Transform>(
      find.descendant(of: pipFinder, matching: find.byType(Transform)).first,
    );
    expect(flipTransform.transform.storage[0], lessThan(0));

    final flipFinder = find.byKey(const Key('in_app_call_flip_camera'));
    expect(flipFinder, findsOneWidget);
    expect(tester.getSize(flipFinder).height, greaterThanOrEqualTo(48));

    // Draggable PiP updates its screen position when dragged
    final initialPipRect = tester.getRect(pipFinder);
    await tester.drag(pipFinder, const Offset(-80, -60));
    await tester.pump();
    final draggedPipRect = tester.getRect(pipFinder);
    expect(draggedPipRect.left, lessThan(initialPipRect.left));
    expect(draggedPipRect.top, lessThan(initialPipRect.top));

    // Flipping camera switches to unmirrored rear preview
    await tester.tap(flipFinder);
    await tester.pump();
    expect(controller.isFrontCamera.value, isFalse);
    final rearFlipTransform = tester.widget<Transform>(
      find.descendant(of: pipFinder, matching: find.byType(Transform)).first,
    );
    expect(rearFlipTransform.transform.storage[0], greaterThan(0));

    // Toggling camera off shows clean "Camera off" state and hides flip button
    await tester.tap(find.bySemanticsLabel('Video'));
    await tester.pump();
    expect(controller.cameraEnabled.value, isFalse);
    expect(find.text('Camera off'), findsOneWidget);
    expect(flipFinder, findsNothing);

    // Clearing controller resets local video state
    controller.clear();
    await tester.pump();
    expect(controller.localVideoWidget.value, isNull);
    expect(controller.cameraEnabled.value, isFalse);
    expect(controller.canFlipCamera.value, isFalse);
    expect(controller.isFrontCamera.value, isTrue);
  });

  testWidgets('InAppCallScreen 5-button two-way video layout has zero overflows at 320x568 @ textScale 1.3',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    controller.startOngoing(
      callUuid: 'compact-two-way',
      callerName: 'Alex Rivera',
      isVideo: true,
      joinLink: 'https://facetime.apple.com/join#compact',
    );
    controller.localVideoWidget.value = const ColoredBox(color: Colors.blueGrey);
    controller.cameraEnabled.value = true;
    controller.canFlipCamera.value = true;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.3),
          ),
          child: InAppCallScreen(
            controller: controller,
            videoView: const ColoredBox(color: Colors.black54),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('in_app_call_flip_camera')), findsOneWidget);
    expect(find.byKey(const Key('in_app_call_open_link')), findsOneWidget);
    expect(find.byKey(const Key('in_app_call_self_preview')), findsOneWidget);
  });

  testWidgets('openInAppCallScreen and showBBDialog inherit inner Theme across rootNavigator boundary (#117)',
      (tester) async {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    controller.startOngoing(
      callUuid: 'theme-117',
      callerName: 'Sam Lee',
      isVideo: false,
    );

    const innerPrimary = Color(0xFF00796B);
    late BuildContext innerContext;
    Color? dialogObservedPrimary;
    String? dialogObservedFont;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: const ColorScheme.light(primary: Color(0xFF6750A4)),
          fontFamily: 'Roboto',
        ),
        home: Theme(
          data: ThemeData(
            colorScheme: const ColorScheme.dark(primary: innerPrimary),
            fontFamily: kDefaultAppFontFamily,
          ),
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: kDefaultAppFontFamily, color: Colors.white),
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) {
                  innerContext = context;
                  return const Scaffold(body: SizedBox.shrink());
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Get.testMode = true;
    final hadSettings = GetIt.I.isRegistered<SettingsService>();
    final prevSettings = hadSettings ? GetIt.I<SettingsService>() : null;
    if (hadSettings) GetIt.I.unregister<SettingsService>();
    final fakeSettings = _FakeSettingsService()..settings = Settings();
    fakeSettings.settings.skin.value = Skins.Material;
    GetIt.I.registerSingleton<SettingsService>(fakeSettings);
    addTearDown(() {
      if (GetIt.I.isRegistered<SettingsService>()) {
        GetIt.I.unregister<SettingsService>();
      }
      if (prevSettings != null) {
        GetIt.I.registerSingleton<SettingsService>(prevSettings);
      }
    });

    // 1. showBBDialog captures inner theme via Builder inside themes.wrap
    unawaited(
      showBBDialog<void>(
        context: innerContext,
        title: 'Captured Theme',
        content: Builder(
          builder: (dialogCtx) {
            dialogObservedPrimary = Theme.of(dialogCtx).colorScheme.primary;
            dialogObservedFont = DefaultTextStyle.of(dialogCtx).style.fontFamily;
            return const Text('Body');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(dialogObservedPrimary, innerPrimary);
    expect(dialogObservedFont, kDefaultAppFontFamily);
    expect(find.text('Captured Theme'), findsOneWidget);
    Navigator.of(innerContext, rootNavigator: true).pop();
    await tester.pumpAndSettle();

    // 2. openInAppCallScreen captures inner theme on rootNavigator
    openInAppCallScreen(context: innerContext, controller: controller);
    await tester.pumpAndSettle();
    final screenCtx = tester.element(find.byType(InAppCallScreen));
    expect(Theme.of(screenCtx).colorScheme.primary, innerPrimary);
    expect(DefaultTextStyle.of(tester.element(find.text('Sam Lee'))).style.fontFamily, kDefaultAppFontFamily);
  });
}
