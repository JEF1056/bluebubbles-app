import 'dart:typed_data';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/web_ringtone.dart';
import 'package:bluebubbles/app/components/facetime/web_ringtone_wav.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/backend/notifications/notifications_service.dart';
import 'package:bluebubbles/services/backend/notifications/web_notifications_interop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

void main() {
  tearDown(() async {
    await GetIt.I.reset();
  });

  test('web notification and ringtone stubs are safe no-ops on VM', () async {
    await showWebNotificationEx(
      title: 'Alice',
      body: 'Answer FaceTime Video Call',
      tag: 'call-1',
      requireInteraction: true,
      renotify: true,
    );
    await closeWebNotificationsByTag('call-1');

    startWebFaceTimeRingtone(callUuid: 'call-1', volume: 0.8);
    stopWebFaceTimeRingtone(callUuid: 'call-1');

    final notifs = NotificationsService();
    addTearDown(notifs.close);
    await expectLater(notifs.clearFaceTimeNotification('call-1'), completes);
  });

  test('buildIncomingRingtoneWavBytes generates valid 16-bit mono PCM WAV with silence tail', () {
    final bytes = buildIncomingRingtoneWavBytes();
    final data = ByteData.sublistView(bytes);

    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(bytes.sublist(12, 16)), 'fmt ');
    expect(data.getUint16(20, Endian.little), 1); // PCM
    expect(data.getUint16(22, Endian.little), 1); // mono
    expect(data.getUint32(24, Endian.little), 22050); // sample rate
    expect(data.getUint16(34, Endian.little), 16); // bits per sample
    expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');

    final dataSize = data.getUint32(40, Endian.little);
    expect(bytes.length, 44 + dataSize);
    expect(dataSize, (22050 * 2.8).round() * 2);

    // First chime window has non-zero samples; trailing second is silent for clean loop cadence.
    var chimePeak = 0;
    for (var i = 0; i < 22050 ~/ 2; i++) {
      final sample = data.getInt16(44 + i * 2, Endian.little).abs();
      if (sample > chimePeak) chimePeak = sample;
    }
    expect(chimePeak, greaterThan(1000));

    var tailPeak = 0;
    for (var i = (22050 * 1.5).round(); i < dataSize ~/ 2; i++) {
      final sample = data.getInt16(44 + i * 2, Endian.little).abs();
      if (sample > tailPeak) tailPeak = sample;
    }
    expect(tailPeak, 0);
  });

  test('ActiveCallController starts ringtone on incoming and stops on answer, decline, and status=6', () async {
    final events = <String>[];
    final controller = ActiveCallController(
      onStartIncomingRingtone: (uuid) => events.add('start:$uuid'),
      onStopIncomingRingtone: (uuid) => events.add('stop:$uuid'),
      onAnswerServerCall: (uuid, {audioOnly = false, displayName, chatGuid}) async => PlacedFaceTimeCall(
            link: 'https://facetime.apple.com/join#$uuid',
            call: FaceTimeCall(callUuid: uuid, isVideo: !audioOnly),
          ),
      onDeclineServerCall: (_) async {},
      onLaunchJoinLink: (_) async => true,
      onDismissOverlay: (_, {keepCallState = false}) {},
    );

    // Status 4 (incoming) starts ringtone once; duplicate incoming for same UUID does not restart.
    controller.applyServerSession({
      'uuid': 'ft-ring-1',
      'status_id': 4,
      'display_name': 'Alice',
      'is_video': true,
    });
    controller.startIncoming(
      callUuid: 'ft-ring-1',
      callerName: 'Alice',
      isVideo: true,
    );
    expect(events, ['start:ft-ring-1']);

    // Answering transitions to connecting/ongoing and stops ringtone.
    final answered = await controller.answerCall(audioOnly: true);
    expect(answered, isTrue);
    expect(events.first, 'start:ft-ring-1');
    expect(events.skip(1), everyElement('stop:ft-ring-1'));
    expect(events.length, greaterThanOrEqualTo(2));

    // Status 6 (disconnected) on an incoming call stops ringtone.
    events.clear();
    controller.applyServerSession({
      'uuid': 'ft-ring-2',
      'status_id': 4,
      'display_name': 'Bob',
      'is_video': false,
    });
    controller.applyServerSession({
      'uuid': 'ft-ring-2',
      'status_id': 6,
    });
    expect(events.first, 'start:ft-ring-2');
    expect(events.skip(1), everyElement('stop:ft-ring-2'));
    expect(events.length, greaterThanOrEqualTo(2));

    // Status 6 stops an orphaned ringtone even if controller wasn't in incoming phase.
    events.clear();
    controller.applyServerSession({
      'uuid': 'ft-ring-orphan',
      'status_id': 6,
    });
    expect(events, contains('stop:ft-ring-orphan'));

    // Decline stops ringtone.
    events.clear();
    controller.startIncoming(callUuid: 'ft-ring-3', callerName: 'Carol', isVideo: true);
    await controller.declineCall();
    expect(events.first, 'start:ft-ring-3');
    expect(events.skip(1), everyElement('stop:ft-ring-3'));
    expect(events.length, greaterThanOrEqualTo(2));

    // Remote answer (status_id=1) stops ringtone.
    events.clear();
    controller.applyServerSession({
      'uuid': 'ft-ring-4',
      'status_id': 4,
      'display_name': 'Dan',
    });
    controller.applyServerSession({
      'uuid': 'ft-ring-4',
      'status_id': 1,
      'active_device_id': 'mac-1',
    });
    expect(events.first, 'start:ft-ring-4');
    expect(events.skip(1), everyElement('stop:ft-ring-4'));
    expect(events.length, greaterThanOrEqualTo(2));

    // Empty session reconciliation stops ringtone.
    events.clear();
    controller.applyServerSession({
      'uuid': 'ft-ring-5',
      'status_id': 4,
      'display_name': 'Eve',
    });
    controller.reconcileServerSessions(const []);
    expect(events.first, 'start:ft-ring-5');
    expect(events.skip(1), everyElement('stop:ft-ring-5'));
    expect(events.length, greaterThanOrEqualTo(2));

    // Dispose stops active ringtone.
    events.clear();
    controller.applyServerSession({
      'uuid': 'ft-ring-6',
      'status_id': 4,
      'display_name': 'Frank',
    });
    controller.dispose();
    expect(events.first, 'start:ft-ring-6');
    expect(events.skip(1), everyElement('stop:ft-ring-6'));
    expect(events.length, greaterThanOrEqualTo(2));
  });
}
