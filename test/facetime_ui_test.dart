import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/app/components/facetime/ongoing_call_pill.dart';
import 'package:bluebubbles/app/components/facetime/outgoing_facetime_sheet.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/main.dart' show AppShellFrame;
import 'package:bluebubbles/models/facetime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1x1 transparent PNG bytes for testing Image.memory avatar paths without asset loading.
final Uint8List _samplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('IncomingFaceTimeScreen renders video actions with >=48dp tap targets and handles reduced motion',
      (tester) async {
    var answeredVideo = false;
    var answeredAudio = false;
    var declined = false;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: IncomingFaceTimeScreen(
            callUuid: 'call-1',
            callerName: 'Maya Lin',
            avatarBytes: _samplePng,
            isAudio: false,
            onAnswerVideo: () => answeredVideo = true,
            onAnswerAudio: () => answeredAudio = true,
            onDecline: () => declined = true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Maya Lin'), findsOneWidget);
    expect(find.text('FaceTime Video'), findsOneWidget);
    expect(find.text('Incoming FaceTime Video'), findsOneWidget);
    expect(find.text('Answer Video'), findsOneWidget);
    expect(find.text('Audio Only'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);

    for (final label in ['Answer Video', 'Audio Only', 'Decline']) {
      final size = tester.getSize(find.bySemanticsLabel(label));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }

    await tester.tap(find.bySemanticsLabel('Decline'));
    await tester.pump();
    expect(declined, isTrue);

    await tester.tap(find.bySemanticsLabel('Audio Only'));
    await tester.pump();
    expect(answeredAudio, isTrue);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byIcon(Icons.call_rounded), findsWidgets);

    // Rebuild fresh to test Answer Video independently.
    await tester.pumpWidget(
      MaterialApp(
        home: IncomingFaceTimeScreen(
          callUuid: 'call-2',
          callerName: 'Alex Rivera',
          isAudio: false,
          onAnswerVideo: () => answeredVideo = true,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Answer Video'));
    await tester.pump();
    expect(answeredVideo, isTrue);
    expect(find.text('Generating call link…'), findsOneWidget);
    expect(find.text('Cancel Call'), findsOneWidget);
  });

  testWidgets('IncomingFaceTimeScreen omits Audio Only for audio calls', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: IncomingFaceTimeScreen(
          callUuid: 'call-audio',
          callerName: 'Jordan Vance',
          isAudio: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('FaceTime Audio'), findsOneWidget);
    expect(find.text('Answer Audio'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Audio Only'), findsNothing);
  });

  testWidgets('OutgoingFaceTimeSheet shows inline Telecom setup prompt on Android when disabled', (tester) async {
    var telecomEnabled = false;
    var openedAccounts = false;
    var placedNative = false;
    final controller = ActiveCallController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => OutgoingFaceTimeSheet(
                      callerName: 'Samira Patel',
                      callerAddress: '+15551234567',
                      isAndroid: true,
                      callController: controller,
                      checkTelecomEnabled: () async => telecomEnabled,
                      onOpenCallingAccounts: () async {
                        openedAccounts = true;
                        telecomEnabled = true;
                      },
                      requestCallPermissions: () async => true,
                      onPlaceNativeAudioCall: () async {
                        placedNative = true;
                        return true;
                      },
                      onStartServerCall: (video) async => const PlacedFaceTimeCall(
                        link: 'https://facetime.apple.com/join#v1',
                        call: FaceTimeCall(callUuid: 'uuid-1'),
                      ),
                      onOpenJoinLink: (_) async {},
                      onHangUpRingingCall: (_) async {},
                    ),
                  );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Sheet'));
    await tester.pumpAndSettle();

    expect(find.text('Samira Patel'), findsOneWidget);
    expect(find.text('Start video call'), findsOneWidget);
    expect(find.text('Start audio call'), findsOneWidget);

    await tester.tap(find.text('Start audio call'));
    await tester.pumpAndSettle();

    // Inline Telecom setup appears without a secondary popup AlertDialog.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Enable Calling Account'), findsOneWidget);
    expect(find.text('Open calling settings'), findsOneWidget);

    await tester.tap(find.text('Open calling settings'));
    await tester.pumpAndSettle();

    expect(openedAccounts, isTrue);
    expect(placedNative, isTrue);
    expect(controller.state.phase, ActiveCallPhase.ongoing);
    expect(controller.state.isVideo, isFalse);
  });

  testWidgets('OutgoingFaceTimeSheet handles No link to join refusal with Hang up call', (tester) async {
    String? hungUpUuid;
    final pendingCall = Completer<PlacedFaceTimeCall>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutgoingFaceTimeSheet(
            callerName: 'Chris Moore',
            callerAddress: 'chris@example.com',
            initialVideo: true,
            checkTelecomEnabled: () async => true,
            onOpenCallingAccounts: () async {},
            requestCallPermissions: () async => true,
            onPlaceNativeAudioCall: () async => false,
            onStartServerCall: (_) => pendingCall.future,
            onOpenJoinLink: (_) async {},
            onHangUpRingingCall: (uuid) async => hungUpUuid = uuid,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Calling Chris Moore…'), findsOneWidget);
    expect(find.text('Cancel call'), findsOneWidget);

    pendingCall.completeError(
      const FaceTimeException(
        'No link minted',
        call: FaceTimeCall(callUuid: 'ringing-uuid-99'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No link to join'), findsOneWidget);
    expect(find.text('Leave ringing'), findsOneWidget);
    expect(find.text('Hang up call'), findsOneWidget);

    await tester.tap(find.text('Hang up call'));
    await tester.pumpAndSettle();
    expect(hungUpUuid, 'ringing-uuid-99');
  });

  testWidgets('OngoingCallPillOverlay shows live mm:ss timer and wires Mute, Return, and End Call', (tester) async {
    var fakeNow = DateTime(2026, 11, 18, 12, 0, 0);
    bool? mutedState;
    String? returnedLink;
    String? endedUuid;

    final controller = ActiveCallController(
      now: () => fakeNow,
      onMuteChanged: (m) => mutedState = m,
      onReturnToCall: (link, _) async => returnedLink = link,
      onEndCall: (uuid, _) async => endedUuid = uuid,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const Scaffold(body: SizedBox.expand()),
            OngoingCallPillOverlay(controller: controller),
          ],
        ),
      ),
    );

    expect(find.text('Mute'), findsNothing);

    controller.startOngoing(
      callUuid: 'live-uuid-1',
      callerName: 'Dana Kim',
      avatarBytes: _samplePng,
      isVideo: true,
      joinLink: 'https://facetime.apple.com/join#live',
    );
    await tester.pumpAndSettle();

    expect(find.text('Dana Kim'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('Return'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);

    for (final label in ['Mute mic', 'Return to call', 'End call']) {
      final size = tester.getSize(find.bySemanticsLabel(label));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }

    fakeNow = fakeNow.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('00:03'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Mute mic'));
    await tester.pump();
    expect(mutedState, isTrue);
    expect(find.text('Unmute'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Return to call'));
    await tester.pump();
    expect(returnedLink, 'https://facetime.apple.com/join#live');

    await tester.tap(find.bySemanticsLabel('End call'));
    await tester.pump();
    expect(endedUuid, 'live-uuid-1');
    expect(controller.state.phase, ActiveCallPhase.idle);
    expect(find.text('Dana Kim'), findsNothing);

    // Native Telecom call without joinLink or return callback omits Return button.
    final telecomController = ActiveCallController();
    addTearDown(telecomController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const Scaffold(body: SizedBox.expand()),
            OngoingCallPillOverlay(controller: telecomController),
          ],
        ),
      ),
    );
    telecomController.startOngoing(
      callUuid: 'telecom-uuid-1',
      callerName: 'Telecom Caller',
      isVideo: false,
      isTelecomCall: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('Telecom Caller'), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
    expect(find.text('Return'), findsNothing);
  });

  testWidgets('showFaceTimeOverlay shows non-modal Continuity banner and opens IncomingFaceTimeScreen on tap',
      (tester) async {
    final controller = ActiveCallController();
    addTearDown(controller.dispose);
    late BuildContext hostContext;
    var chatTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: AppShellFrame(
          callController: controller,
          navigator: Scaffold(
            body: Builder(
              builder: (context) {
                hostContext = context;
                return Center(
                  child: ElevatedButton(
                    onPressed: () => chatTapped = true,
                    child: const Text('Chat action'),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    await showFaceTimeOverlay(
      'overlay-uuid-1',
      'Taylor Morgan',
      null,
      false,
      context: hostContext,
      controller: controller,
    );
    await tester.pumpAndSettle();

    // Non-modal Continuity banner is registered and chat underneath stays interactive.
    expect(faceTimeOverlays.containsKey('overlay-uuid-1'), isTrue);
    expect(find.byType(IncomingFaceTimeScreen), findsNothing);
    expect(find.text('Taylor Morgan'), findsOneWidget);
    await tester.tap(find.text('Chat action'));
    expect(chatTapped, isTrue);

    // Tapping the banner opens IncomingFaceTimeScreen; connecting updates it in place.
    await tester.tap(find.byKey(const Key('incoming_call_banner_tap')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(IncomingFaceTimeScreen), findsOneWidget);

    await showFaceTimeConnectingOverlay(
      'overlay-uuid-1',
      context: hostContext,
      controller: controller,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Generating call link…'), findsOneWidget);

    hideFaceTimeOverlay('overlay-uuid-1');
    controller.clear();
    await tester.pumpAndSettle();

    expect(find.byType(IncomingFaceTimeScreen), findsNothing);
    expect(faceTimeOverlays.containsKey('overlay-uuid-1'), isFalse);
  });

  testWidgets('OngoingCallPillOverlay renders outgoing, cross-device Handoff, and responsive AppShellFrame bars',
      (tester) async {
    var fakeNow = DateTime(2026, 11, 18, 12, 0, 0);
    String? handedOffUuid;
    String? endedUuid;

    final controller = ActiveCallController(
      now: () => fakeNow,
      deviceId: 'android-1',
      deviceName: 'Pixel',
      onHandoffServerCall: (uuid, {mode}) async {
        handedOffUuid = uuid;
        return const PlacedFaceTimeCall(
          link: 'https://facetime.apple.com/join#handoff',
          call: FaceTimeCall(callUuid: 'web-call-1'),
        );
      },
      onLaunchJoinLink: (_) async => true,
      onLeaveServerCall: (uuid) async => endedUuid = uuid,
    );
    addTearDown(controller.dispose);

    for (final width in [390.0, 768.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1.0;

      await tester.pumpWidget(
        MaterialApp(
          home: AppShellFrame(
            callController: controller,
            navigator: Scaffold(
              appBar: AppBar(
                key: Key('app_bar_$width'),
                title: const Text('Conversation'),
              ),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      );

      controller.startOutgoing(
        callUuid: 'out-1',
        callerName: 'Alex Rivera',
        isVideo: true,
        chatGuid: 'iMessage;-;+15551234567',
      );
      await tester.pumpAndSettle();

      expect(find.text('Alex Rivera'), findsOneWidget);
      expect(find.text('Calling…'), findsOneWidget);
      final barFinder = find.byKey(const ValueKey('call_bar_outgoing'));
      final barRect = tester.getRect(barFinder);
      final appBarRect = tester.getRect(find.byKey(Key('app_bar_$width')));
      expect(appBarRect.top, greaterThanOrEqualTo(barRect.bottom));
      expect(
        find.descendant(of: find.byType(OngoingCallPillOverlay), matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      final callBarDecoration = tester.widget<Container>(barFinder).decoration as BoxDecoration;
      expect(callBarDecoration.color!.a, inInclusiveRange(0.70, 0.80));
      expect(callBarDecoration.border!.bottom.color.a, inInclusiveRange(0.14, 0.22));
    }
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Cross-device Handoff ("On Web · 00:05" with Switch and End)
    controller.applyServerSession({
      'uuid': 'web-call-1',
      'status': 'answered',
      'display_name': 'Sam Lee',
      'is_video': true,
      'active_device_id': 'web-browser-1',
      'active_device_name': 'Web',
      'answered_at': fakeNow.subtract(const Duration(seconds: 5)).toIso8601String(),
    });
    await tester.pumpAndSettle();

    expect(find.text('Sam Lee'), findsOneWidget);
    expect(find.textContaining('On Web'), findsOneWidget);
    expect(find.text('Switch'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Switch to this device'));
    await tester.pumpAndSettle();
    expect(handedOffUuid, 'web-call-1');

    await tester.tap(find.bySemanticsLabel('End call'));
    await tester.pumpAndSettle();
    expect(endedUuid, 'web-call-1');
    expect(controller.state.phase, ActiveCallPhase.idle);
  });

  testWidgets('OutgoingFaceTimeSheet hangs up late server call after Cancel call', (tester) async {
    final pendingCall = Completer<PlacedFaceTimeCall>();
    String? hungUpUuid;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutgoingFaceTimeSheet(
            callerName: 'Late Cancel',
            initialVideo: true,
            checkTelecomEnabled: () async => true,
            onOpenCallingAccounts: () async {},
            requestCallPermissions: () async => true,
            onPlaceNativeAudioCall: () async => false,
            onStartServerCall: (_) => pendingCall.future,
            onOpenJoinLink: (_) async {},
            onHangUpRingingCall: (uuid) async => hungUpUuid = uuid,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Cancel call'));
    await tester.pumpAndSettle();

    pendingCall.complete(
      const PlacedFaceTimeCall(
        link: 'https://facetime.apple.com/join#late',
        call: FaceTimeCall(callUuid: 'late-cancel-uuid'),
      ),
    );
    await tester.pumpAndSettle();

    expect(hungUpUuid, 'late-cancel-uuid');
  });

  testWidgets('OngoingCallPillOverlay shows DTMF keypad for active audio call with callUuid', (tester) async {
    String? sentUuid;
    String? sentDigit;
    final controller = ActiveCallController(
      onSendDtmf: (uuid, digit) async {
        sentUuid = uuid;
        sentDigit = digit;
      },
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const Scaffold(body: SizedBox.expand()),
            OngoingCallPillOverlay(controller: controller),
          ],
        ),
      ),
    );

    controller.startOngoing(
      callerName: 'Continuity Call',
      isVideo: false,
      isTelecomCall: true,
      isTelephony: true,
    );
    controller.bindCallUuid('cell-out-1', isTelephony: true);
    controller.markConnected('cell-out-1', isTelephony: true);
    await tester.pumpAndSettle();

    expect(controller.state.isTelephony, isTrue);
    expect(controller.state.callUuid, 'cell-out-1');
    expect(find.text('Keypad'), findsOneWidget);

    await tester.tap(find.text('Keypad'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5'));
    await tester.pumpAndSettle();

    expect(sentUuid, 'cell-out-1');
    expect(sentDigit, '5');
  });
}
