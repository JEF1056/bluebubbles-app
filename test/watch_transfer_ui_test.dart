import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/facetime_transfer_icon.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/services/facetime/facetime_media_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Transfer to Watch button is hidden when wearWatchConnected is false', (tester) async {
    final controller = ActiveCallController(
      wearWatchConnected: false,
      onCheckWearWatchConnected: () async => false,
    );
    addTearDown(controller.dispose);

    controller.startOngoing(
      callUuid: 'call-no-watch',
      callerName: 'Maya Lin',
      isVideo: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('call-transfer-watch')), findsNothing);
    expect(find.byType(WatchTransferIcon), findsNothing);
  });

  testWidgets('Top-right header does not show Transfer to Watch button even when wearWatchConnected is true',
      (tester) async {
    final controller = ActiveCallController(
      wearWatchConnected: true,
      onCheckWearWatchConnected: () async => true,
      onTransferCallToWatch: (uuid) async => true,
    );
    addTearDown(controller.dispose);

    controller.startOngoing(
      callUuid: 'call-with-watch',
      callerName: 'Jordan Vance',
      isVideo: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('call-transfer-watch')), findsNothing);
    expect(find.byType(WatchTransferIcon), findsNothing);
  });

  testWidgets('Audio sheet shows Transfer to Watch and triggers transfer while Video effects sheet does not',
      (tester) async {
    String? transferredUuid;
    final controller = ActiveCallController(
      wearWatchConnected: true,
      onCheckWearWatchConnected: () async => true,
      onTransferCallToWatch: (uuid) async {
        transferredUuid = uuid;
        return true;
      },
      onFetchAudioDevices: () async => (
        outputs: const <FaceTimeAudioDevice>[
          FaceTimeAudioDevice(
            id: 'earpiece',
            label: 'Phone Earpiece',
            kind: FaceTimeAudioDeviceKind.earpiece,
            isInput: false,
            isActive: true,
          ),
          FaceTimeAudioDevice(
            id: 'speaker',
            label: 'Speaker',
            kind: FaceTimeAudioDeviceKind.speaker,
            isInput: false,
            isActive: false,
          ),
        ],
        inputs: const <FaceTimeAudioDevice>[],
        activeOutputId: 'earpiece',
        activeInputId: null,
      ),
    );
    addTearDown(controller.dispose);

    controller.startOngoing(
      callUuid: 'call-sheet-watch',
      callerName: 'Jordan Vance',
      isVideo: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InAppCallScreen(
          controller: controller,
          videoView: const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pump();

    // Open Video effects sheet and confirm no Transfer to Watch row is injected there.
    await tester.tap(find.byKey(const Key('in_app_call_video_effects')));
    await tester.pumpAndSettle();
    expect(find.text('Video effects'), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-sheet-transfer-watch')), findsNothing);

    // Dismiss Video effects sheet.
    Navigator.of(tester.element(find.text('Video effects'))).pop();
    await tester.pumpAndSettle();

    // Open Audio & microphone sheet and confirm Transfer to Watch row is shown and triggers transfer.
    await tester.tap(find.bySemanticsLabel('Audio & microphone'));
    await tester.pumpAndSettle();
    expect(find.text('Audio & microphone'), findsOneWidget);
    final sheetTransfer = find.byKey(const ValueKey('audio-sheet-transfer-watch'));
    expect(sheetTransfer, findsOneWidget);

    await tester.tap(sheetTransfer);
    await tester.pumpAndSettle();
    expect(transferredUuid, 'call-sheet-watch');
  });
}
