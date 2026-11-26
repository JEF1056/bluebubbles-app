import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/call_controls.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/app/components/facetime/ongoing_call_pill.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/helpers/ui/dialog_helpers.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/main.dart' show AppShellFrame;
import 'package:bluebubbles/services/facetime/facetime_media_models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('InAppCallScreen renders header pill, timer, videoView slot, mute, speaker, DTMF, and end call',
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

    expect(find.byType(FaceTimeHeaderPill), findsOneWidget);
    expect(find.byType(FaceTimeControlDock), findsOneWidget);
    expect(find.text('Maya Lin'), findsOneWidget);
    expect(find.text('Connected · 00:00'), findsOneWidget);
    expect(find.byKey(const Key('fake_remote_video')), findsOneWidget);

    fakeNow = fakeNow.add(const Duration(seconds: 7));
    await tester.pump(const Duration(seconds: 7));
    expect(find.text('Connected · 00:07'), findsOneWidget);

    // Chrome auto-hid after 4s; tap video stage to reveal controls
    await tester.tap(find.byKey(const Key('fake_remote_video')));
    await tester.pumpAndSettle();

    // Mute toggle updates controller and semantics label
    await tester.tap(find.bySemanticsLabel('Mute'));
    await tester.pump();
    expect(mutedState, isTrue);
    expect(find.bySemanticsLabel('Unmute'), findsOneWidget);

    // Speaker toggle works as a graceful no-op when no platform handler is provided
    await tester.tap(find.bySemanticsLabel('Speaker'));
    await tester.pump();
    expect(find.bySemanticsLabel('Speaker'), findsOneWidget);

    // Expand DTMF keypad via More tray and send digit
    await tester.tap(find.byKey(const Key('in_app_call_more_tray')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Keypad'));
    await tester.pumpAndSettle();
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

  testWidgets('InAppCallScreen compact audio shows Keypad only for telephony calls', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: InAppCallScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.bySemanticsLabel('Keypad'), findsNothing);

    controller.startOngoing(
      callUuid: 'tel-audio-1',
      callerName: 'Jordan Vance',
      isVideo: false,
      isTelecomCall: true,
      isTelephony: true,
    );
    await tester.pump();
    expect(find.text('Jordan Vance'), findsOneWidget);
    expect(find.bySemanticsLabel('Keypad'), findsOneWidget);
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
    expect(find.descendant(of: find.byType(InAppCallScreen), matching: find.text('Sam Lee')), findsOneWidget);

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

  testWidgets('InAppCallScreen two-way video PiP mirrors front camera, snaps 3:4, toggles camera, flips, and opens join link',
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

    // Mirrored 3:4 self-preview PiP and 48dp flip button are rendered
    final pipFinder = find.byKey(const Key('in_app_call_self_preview'));
    expect(pipFinder, findsOneWidget);
    final pipSize = tester.getSize(pipFinder);
    expect(pipSize.height / pipSize.width, closeTo(4 / 3, 0.02));
    final flipTransform = tester.widget<Transform>(
      find.descendant(of: pipFinder, matching: find.byType(Transform)).first,
    );
    expect(flipTransform.transform.storage[0], lessThan(0));

    final flipFinder = find.byKey(const Key('in_app_call_flip_camera'));
    expect(flipFinder, findsOneWidget);
    expect(tester.getSize(flipFinder).height, greaterThanOrEqualTo(48));

    // Draggable PiP snaps to top-left corner when dragged across screen
    final initialPipRect = tester.getRect(pipFinder);
    await tester.drag(pipFinder, const Offset(-550, -350));
    await tester.pumpAndSettle();
    final snappedPipRect = tester.getRect(pipFinder);
    expect(snappedPipRect.left, lessThan(initialPipRect.left));
    expect(snappedPipRect.top, lessThan(initialPipRect.top));

    // Flipping camera switches to unmirrored rear preview
    await tester.tap(flipFinder);
    await tester.pump();
    expect(controller.isFrontCamera.value, isFalse);
    final rearFlipTransform = tester.widget<Transform>(
      find.descendant(of: pipFinder, matching: find.byType(Transform)).first,
    );
    expect(rearFlipTransform.transform.storage[0], greaterThan(0));

    // Toggling camera off shows icon-only "Camera off" semantics (no caption text) and keeps flip button disabled without resizing dock
    final dockFinder = find.byType(FaceTimeControlDock);
    final dockWidthBefore = tester.getSize(dockFinder).width;
    await tester.tap(find.bySemanticsLabel('Turn off camera'));
    await tester.pump();
    expect(controller.cameraEnabled.value, isFalse);
    expect(find.bySemanticsLabel('Camera off'), findsOneWidget);
    expect(find.text('Camera off'), findsNothing);
    expect(flipFinder, findsOneWidget);
    expect(tester.widget<FaceTimeDockButton>(flipFinder).enabled, isFalse);
    expect(tester.getSize(dockFinder).width, dockWidthBefore);
    await tester.tap(flipFinder);
    await tester.pump();
    expect(controller.isFrontCamera.value, isFalse);

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

  testWidgets('InAppCallScreen auto-hides chrome after 4s on ongoing video and respects accessibleNavigation',
      (tester) async {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    controller.startOngoing(
      callUuid: 'autohide-1',
      callerName: 'Maya Lin',
      isVideo: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(
          controller: controller,
          videoView: const ColoredBox(key: Key('stage_video'), color: Colors.teal),
        ),
      ),
    );
    await tester.pump();

    AnimatedOpacity dockOpacity() => tester.widget<AnimatedOpacity>(
          find.ancestor(of: find.byType(FaceTimeControlDock), matching: find.byType(AnimatedOpacity)),
        );

    expect(dockOpacity().opacity, 1.0);

    // Advance past 4s autoHide
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(dockOpacity().opacity, 0.0);

    // Tap stage to bring chrome back
    await tester.tap(find.byKey(const Key('stage_video')));
    await tester.pumpAndSettle();
    expect(dockOpacity().opacity, 1.0);

    // accessibleNavigation pins chrome
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(accessibleNavigation: true),
          child: InAppCallScreen(
            controller: controller,
            videoView: const ColoredBox(key: Key('stage_video'), color: Colors.teal),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(dockOpacity().opacity, 1.0);
  });

  testWidgets('InAppCallScreen shows reconnecting chip and dims remote video to 40%', (tester) async {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    controller.startOngoing(
      callUuid: 'reconnect-1',
      callerName: 'Maya Lin',
      isVideo: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(
          controller: controller,
          videoView: const ColoredBox(key: Key('reconnect_video'), color: Colors.teal),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Reconnecting…'), findsNothing);

    controller.isReconnecting.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Reconnecting…'), findsAtLeastNWidgets(1));
    final videoOpacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: find.byKey(const Key('reconnect_video')), matching: find.byType(AnimatedOpacity)),
    );
    expect(videoOpacity.opacity, 0.40);
  });

  testWidgets('InAppCallScreen expanded (>=840) layout frames 16:9 stage and handles Ctrl+D / Ctrl+E shortcuts',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    bool? mutedState;
    final controller = ActiveCallController(
      onMuteChanged: (m) => mutedState = m,
    );
    addTearDown(controller.dispose);
    controller.startOngoing(
      callUuid: 'web-expanded-1',
      callerName: 'Elena Rostova',
      isVideo: true,
    );
    controller.cameraEnabled.value = true;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1280, 900)),
          child: InAppCallScreen(
            controller: controller,
            videoView: const ColoredBox(color: Colors.indigo),
          ),
        ),
      ),
    );
    await tester.pump();

    // 16:9 AspectRatio stage & dock below stage (not FaceTimeHeaderPill)
    expect(find.byType(AspectRatio), findsOneWidget);
    expect(find.byType(FaceTimeHeaderPill), findsNothing);
    expect(find.byType(FaceTimeControlDock), findsOneWidget);

    // Ctrl+D toggles mute
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(mutedState, isTrue);

    // Ctrl+E toggles camera
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.cameraEnabled.value, isFalse);
  });

  testWidgets('InAppCallScreen opens Audio & microphone sheet and Video effects sheet', (tester) async {
    bool? voiceIsolationSet;
    String? selectedOutput;
    String? selectedInput;
    FaceTimeVideoEffectType? selectedEffect;
    bool? denoiseSet;
    String? selectedBgId;

    final controller = ActiveCallController(
      onSetVoiceIsolation: (enabled) async {
        voiceIsolationSet = enabled;
        return true;
      },
      onSelectAudioOutput: (id) async {
        selectedOutput = id;
        return true;
      },
      onSelectAudioInput: (id) async {
        selectedInput = id;
        return true;
      },
      onSetVideoProcessing: (effect, denoise, bgId, _) async {
        selectedEffect = effect;
        denoiseSet = denoise;
        selectedBgId = bgId;
        return true;
      },
    );
    addTearDown(controller.dispose);

    controller.startOngoing(
      callUuid: 'media-sheets-1',
      callerName: 'Maya Lin',
      isVideo: true,
    );
    controller.canSelectAudioOutput.value = true;
    controller.audioOutputs.assignAll(const [
      FaceTimeAudioDevice(id: 'out-1', label: 'Speakerphone', kind: FaceTimeAudioDeviceKind.speaker, isInput: false, isActive: true),
      FaceTimeAudioDevice(id: 'out-2', label: 'AirPods Pro', kind: FaceTimeAudioDeviceKind.bluetooth, isInput: false),
    ]);
    controller.activeAudioOutputId.value = 'out-1';
    controller.audioInputs.assignAll(const [
      FaceTimeAudioDevice(id: 'in-1', label: 'Built-in Mic', kind: FaceTimeAudioDeviceKind.builtinMic, isInput: true, isActive: true),
      FaceTimeAudioDevice(id: 'in-2', label: 'USB Mic', kind: FaceTimeAudioDeviceKind.usb, isInput: true),
    ]);
    controller.activeAudioInputId.value = 'in-1';

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(
          controller: controller,
          videoView: const ColoredBox(color: Colors.teal),
        ),
      ),
    );
    await tester.pump();

    // Open Audio & microphone sheet
    await tester.tap(find.bySemanticsLabel('Audio & microphone'));
    await tester.pumpAndSettle();
    expect(find.text('Audio & microphone'), findsOneWidget);
    expect(find.text('Voice Isolation'), findsOneWidget);

    await tester.tap(find.byKey(const Key('in_app_call_voice_isolation_toggle')));
    await tester.pump();
    expect(voiceIsolationSet, isFalse);

    await tester.tap(find.text('AirPods Pro'));
    await tester.pump();
    expect(selectedOutput, 'out-2');

    await tester.tap(find.text('USB Mic'));
    await tester.pump();
    expect(selectedInput, 'in-2');

    // Dismiss audio sheet
    Navigator.of(tester.element(find.text('Audio & microphone'))).pop();
    await tester.pumpAndSettle();

    // Open Video effects sheet
    await tester.tap(find.byKey(const Key('in_app_call_video_effects')));
    await tester.pumpAndSettle();
    expect(find.text('Video effects'), findsOneWidget);
    expect(find.text('Studio Video Enhancement'), findsOneWidget);

    // Initial default is ON; tap toggles to false
    await tester.tap(find.byKey(const Key('in_app_call_video_denoise_toggle')));
    await tester.pump();
    expect(denoiseSet, isFalse);

    // Tap again toggles back to true
    await tester.tap(find.byKey(const Key('in_app_call_video_denoise_toggle')));
    await tester.pump();
    expect(denoiseSet, isTrue);

    await tester.tap(find.text('Warm Studio'));
    await tester.pump();
    expect(selectedEffect, FaceTimeVideoEffectType.virtualBackground);
    expect(selectedBgId, 'studio_warm');
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

  testWidgets('InAppCallScreen opens cleanly on outgoing phase and opens Audio sheet when only inputs exist',
      (tester) async {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    controller.audioInputs.assignAll([
      const FaceTimeAudioDevice(
        id: 'mic1',
        label: 'Built-in Mic',
        kind: FaceTimeAudioDeviceKind.builtinMic,
        isInput: true,
        isActive: true,
      ),
    ]);
    controller.canSelectAudioOutput.value = false;
    controller.startOutgoing(
      callUuid: 'outgoing-1',
      callerName: 'Dana Park',
      isVideo: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(controller: controller),
      ),
    );
    await tester.pump();
    expect(find.text('Dana Park'), findsOneWidget);
    expect(find.bySemanticsLabel('Audio & microphone'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Audio & microphone'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Built-in Mic'), findsOneWidget);
  });

  testWidgets('InAppCallScreen pops open bottom sheet and itself when call goes idle', (tester) async {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    controller.audioInputs.assignAll([
      const FaceTimeAudioDevice(
        id: 'mic1',
        label: 'Built-in Mic',
        kind: FaceTimeAudioDeviceKind.builtinMic,
        isInput: true,
        isActive: true,
      ),
    ]);
    controller.canSelectAudioOutput.value = false;
    controller.startOngoing(
      callUuid: 'outgoing-pop-1',
      callerName: 'Dana Park',
      isVideo: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => InAppCallScreen(controller: controller)),
                );
              },
              child: const Text('Open Call'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Call'));
    await tester.pumpAndSettle();
    expect(find.byType(InAppCallScreen), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Audio & microphone'));
    await tester.pumpAndSettle();
    expect(find.text('Built-in Mic'), findsOneWidget);

    await controller.endCall();
    await tester.pumpAndSettle();

    expect(find.text('Built-in Mic'), findsNothing);
    expect(find.byType(InAppCallScreen), findsNothing);
    expect(find.text('Open Call'), findsOneWidget);
  });

  testWidgets('InAppCallScreen, OngoingCallPill, and IncomingFaceTimeScreen render group contact cards and callKindLabel',
      (tester) async {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    controller.startIncoming(
      callUuid: 'group-in-1',
      callerName: 'Alice, Bob, Charlie',
      callerAddress: '+15551112222',
      isVideo: true,
      isGroup: true,
      participants: const ['+15551112222', '+15553334444', 'charlie@example.com'],
      participantDetails: [
        CallParticipant(address: '+15551112222', displayName: 'Alice', avatarBytes: _samplePng),
        const CallParticipant(address: '+15553334444', displayName: 'Bob'),
        const CallParticipant(address: 'charlie@example.com', displayName: 'Charlie'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: IncomingFaceTimeScreen(
          callUuid: 'group-in-1',
          callerName: 'Alice, Bob, Charlie',
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Group FaceTime Video'), findsOneWidget);
    expect(find.text('Incoming Group FaceTime Video'), findsOneWidget);
    expect(find.text('Alice, Bob, Charlie'), findsOneWidget);
    expect(find.byType(FaceTimeGroupedAvatar), findsOneWidget);
    expect(find.byType(FaceTimeParticipantChips), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.text('FaceTime Call'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OngoingCallPillOverlay(controller: controller),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Alice, Bob, Charlie'), findsOneWidget);
    expect(find.text('Incoming Group FaceTime Video'), findsOneWidget);
    expect(find.byType(FaceTimeGroupedAvatar), findsOneWidget);

    controller.startOngoing(
      callUuid: 'group-in-1',
      callerName: 'Alice, Bob, Charlie',
      callerAddress: '+15551112222',
      isVideo: true,
      isGroup: true,
      participants: const ['+15551112222', '+15553334444', 'charlie@example.com'],
      participantDetails: [
        CallParticipant(address: '+15551112222', displayName: 'Alice', avatarBytes: _samplePng),
        const CallParticipant(address: '+15553334444', displayName: 'Bob'),
        const CallParticipant(address: 'charlie@example.com', displayName: 'Charlie'),
      ],
    );
    controller.remoteVideoWidget.value = const SizedBox.expand(child: ColoredBox(color: Colors.black));
    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(controller: controller),
      ),
    );
    await tester.pump();
    expect(find.text('Alice, Bob, Charlie'), findsOneWidget);
    expect(find.text('Group FaceTime Video'), findsOneWidget);
    expect(find.text('Connected · 00:00'), findsOneWidget);
    expect(find.byType(FaceTimeGroupedAvatar), findsOneWidget);
    expect(find.text('FaceTime Call'), findsNothing);
  });

  testWidgets('InAppCallScreen keeps outgoing video on ringing screen despite early remoteVideoWidget and shows bottom-right PiP once ongoing',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final controller = ActiveCallController();
    addTearDown(controller.dispose);

    controller.startOutgoing(
      callUuid: 'out-early-vid-1',
      callerName: 'Maya Lin',
      isVideo: true,
    );
    controller.handleFacetimeCallState(<String, dynamic>{
      'phase': 'local-video-texture',
      'call_uuid': 'out-early-vid-1',
      'texture_id': 22,
      'width': 0,
      'height': 0,
      'camera_enabled': true,
      'can_flip_camera': true,
      'front_camera': true,
    });
    controller.remoteVideoWidget.value = const ColoredBox(
      key: Key('early_remote_video'),
      color: Colors.teal,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: InAppCallScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();

    // Outgoing phase must stay on pre-connect ringing screen and not display early remote video
    expect(find.byKey(const Key('early_remote_video')), findsNothing);
    expect(find.text('Maya Lin'), findsOneWidget);
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.byType(FaceTimeHeaderPill), findsNothing);
    expect(find.byKey(const Key('in_app_call_self_preview')), findsNothing);

    // Transitioning to ongoing reveals remote video and bottom-right 3:4 self-preview PiP even with 0x0 metadata
    controller.notifyTelecomActive('out-early-vid-1', isVideo: true);
    await tester.pump();

    expect(find.byKey(const Key('early_remote_video')), findsOneWidget);
    expect(find.text('Calling…'), findsNothing);
    expect(find.byType(FaceTimeHeaderPill), findsOneWidget);

    final pipFinder = find.byKey(const Key('in_app_call_self_preview'));
    expect(pipFinder, findsOneWidget);
    final pipRect = tester.getRect(pipFinder);
    expect(pipRect.width, greaterThan(0));
    expect(pipRect.height / pipRect.width, closeTo(4 / 3, 0.02));
    expect(pipRect.left, greaterThan(200));
    expect(pipRect.top, greaterThan(400));

    // Dock width stays invariant when toggling camera off and flip button remains rendered with enabled: false
    final dockFinder = find.byType(FaceTimeControlDock);
    final flipFinder = find.byKey(const Key('in_app_call_flip_camera'));
    final initialDockWidth = tester.getSize(dockFinder).width;
    expect(tester.widget<FaceTimeDockButton>(flipFinder).enabled, isTrue);

    await tester.tap(find.bySemanticsLabel('Turn off camera'));
    await tester.pump();
    expect(flipFinder, findsOneWidget);
    expect(tester.widget<FaceTimeDockButton>(flipFinder).enabled, isFalse);
    expect(tester.getSize(dockFinder).width, initialDockWidth);
  });

  testWidgets('Audio/Phone M3E view renders FaceTimePhoneControlSheet, tonal kind badge, and More tray',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    bool? voiceIsolationSet;
    final controller = ActiveCallController(
      wearWatchConnected: true,
      onCheckWearWatchConnected: () async => true,
      onSetVoiceIsolation: (enabled) async {
        voiceIsolationSet = enabled;
        return true;
      },
    );
    addTearDown(controller.dispose);

    controller.startOngoing(
      callUuid: 'phone-m3e-1',
      callerName: 'Jordan Vance',
      isVideo: false,
      isTelecomCall: true,
      isTelephony: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: InAppCallScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(FaceTimePhoneControlSheet), findsOneWidget);
    expect(find.text('Phone Call'), findsOneWidget);
    expect(find.byKey(const Key('in_app_call_more_tray')), findsOneWidget);

    await tester.tap(find.byKey(const Key('in_app_call_more_tray')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('in_app_call_voice_isolation_toggle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('in_app_call_voice_isolation_toggle')));
    await tester.pump();
    expect(voiceIsolationSet, isFalse);
  });

  testWidgets('Meet Self-View PiP expands on double-tap and collapses to 48dp pill', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    controller.startOngoing(
      callUuid: 'pip-collapse-1',
      callerName: 'Maya Lin',
      isVideo: true,
    );
    controller.localVideoWidget.value = const ColoredBox(color: Colors.blueGrey);
    controller.cameraEnabled.value = true;
    controller.canFlipCamera.value = true;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: InAppCallScreen(
            controller: controller,
            videoView: const ColoredBox(color: Colors.black54),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pipFinder = find.byKey(const Key('in_app_call_self_preview'));
    final normalSize = tester.getSize(pipFinder);
    expect(normalSize.width, inInclusiveRange(112.0, 132.0));
    expect(normalSize.height / normalSize.width, closeTo(4 / 3, 0.02));

    // Double-tap expands PiP to 168-196dp
    final center = tester.getCenter(pipFinder);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    final expandedSize = tester.getSize(pipFinder);
    expect(expandedSize.width, inInclusiveRange(168.0, 196.0));
    expect(expandedSize.height / expandedSize.width, closeTo(4 / 3, 0.02));

    // Tap collapse handle collapses PiP to 48dp pill
    await tester.tap(find.byIcon(Icons.close_fullscreen_rounded));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final collapsedSize = tester.getSize(pipFinder);
    expect(collapsedSize.width, 48.0);
    expect(collapsedSize.height, 48.0);

    // Tapping collapsed pill restores it
    await tester.tap(pipFinder);
    await tester.pumpAndSettle();
    expect(tester.getSize(pipFinder).width, inInclusiveRange(168.0, 196.0));
  });

  testWidgets('Meet More tray opens 2-col morphing tiles and toggles Video Effects & Blur', (tester) async {
    bool? denoiseSet;
    final controller = ActiveCallController(
      wearWatchConnected: true,
      onCheckWearWatchConnected: () async => true,
      onSetVideoProcessing: (effect, denoise, bgId, _) async {
        denoiseSet = denoise;
        return true;
      },
    );
    addTearDown(controller.dispose);
    controller.startOngoing(
      callUuid: 'meet-more-1',
      callerName: 'Maya Lin',
      isVideo: true,
      joinLink: 'https://facetime.apple.com/join#more',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(
          controller: controller,
          videoView: const ColoredBox(color: Colors.teal),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('in_app_call_more_tray')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('in_app_call_voice_isolation_toggle')), findsOneWidget);
    expect(find.byKey(const Key('in_app_call_video_denoise_toggle')), findsOneWidget);
    expect(find.text('Audio Route'), findsOneWidget);
    expect(find.text('Keypad'), findsOneWidget);
    expect(find.text('Transfer to Watch'), findsOneWidget);
    expect(find.text('Open Link'), findsOneWidget);

    // Initial default is ON; tap toggles to false
    await tester.tap(find.byKey(const Key('in_app_call_video_denoise_toggle')));
    await tester.pump();
    expect(denoiseSet, isFalse);

    // Tap again toggles back to true
    await tester.tap(find.byKey(const Key('in_app_call_video_denoise_toggle')));
    await tester.pump();
    expect(denoiseSet, isTrue);
  });
}
