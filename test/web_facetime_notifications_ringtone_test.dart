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
    startWebFaceTimeRingback(callUuid: 'call-1', volume: 0.8);
    stopWebFaceTimeRingback(callUuid: 'call-1');
    playWebFaceTimeCallEndedTone(volume: 0.8);

    expect(NotificationsService.FACETIME_CHANNEL, 'com.bluebubbles.incoming_facetimes_v2');

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
      onAnswerServerCall: (uuid, {audioOnly = false, mode, displayName, chatGuid}) async => PlacedFaceTimeCall(
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

  test('buildOutgoingRingbackWavBytes generates valid 6.0s 22050Hz 16-bit mono WAV with lead-in and silence tail', () {
    final bytes = buildOutgoingRingbackWavBytes();
    final data = ByteData.sublistView(bytes);

    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(data.getUint16(20, Endian.little), 1); // PCM
    expect(data.getUint16(22, Endian.little), 1); // mono
    expect(data.getUint32(24, Endian.little), 22050);
    expect(data.getUint16(34, Endian.little), 16);

    final dataSize = data.getUint32(40, Endian.little);
    expect(bytes.length, 44 + dataSize);
    expect(dataSize, (22050 * 6.0).round() * 2);

    // 250ms lead-in silence
    var leadInPeak = 0;
    for (var i = 0; i < (22050 * 0.25).floor(); i++) {
      final sample = data.getInt16(44 + i * 2, Endian.little).abs();
      if (sample > leadInPeak) leadInPeak = sample;
    }
    expect(leadInPeak, 0);

    // Active 440Hz+480Hz window (0.25s..2.25s)
    var activePeak = 0;
    for (var i = (22050 * 0.3).round(); i < (22050 * 2.2).round(); i++) {
      final sample = data.getInt16(44 + i * 2, Endian.little).abs();
      if (sample > activePeak) activePeak = sample;
    }
    expect(activePeak, greaterThan(1000));

    // Trailing 3.75s silence (2.25s..6.0s)
    var tailPeak = 0;
    for (var i = (22050 * 2.26).round(); i < dataSize ~/ 2; i++) {
      final sample = data.getInt16(44 + i * 2, Endian.little).abs();
      if (sample > tailPeak) tailPeak = sample;
    }
    expect(tailPeak, 0);
  });

  test('buildCallEndedToneWavBytes generates valid 310ms 22050Hz 16-bit mono WAV', () {
    final bytes = buildCallEndedToneWavBytes();
    final data = ByteData.sublistView(bytes);

    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(data.getUint16(20, Endian.little), 1);
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint32(24, Endian.little), 22050);
    expect(data.getUint16(34, Endian.little), 16);

    final dataSize = data.getUint32(40, Endian.little);
    expect(bytes.length, 44 + dataSize);
    expect(dataSize, (22050 * 0.31).round() * 2);

    var peak = 0;
    for (var i = 0; i < dataSize ~/ 2; i++) {
      final sample = data.getInt16(44 + i * 2, Endian.little).abs();
      if (sample > peak) peak = sample;
    }
    expect(peak, greaterThan(1000));
  });

  test('ActiveCallController manages outgoing ringback and call-ended tone lifecycle', () async {
    final events = <String>[];
    final controller = ActiveCallController(
      deviceId: 'web-1',
      deviceName: 'Web',
      onStartOutgoingRingback: (uuid) => events.add('rb_start:$uuid'),
      onStopOutgoingRingback: (uuid) => events.add('rb_stop:$uuid'),
      onPlayCallEndedTone: () => events.add('ended'),
      onEndNativeCall: (_, {onlyIfRinging = false}) async {},
      onDeclineServerCall: (_) async {},
      onLeaveServerCall: (_) async {},
      onDismissOverlay: (_, {keepCallState = false}) {},
    );

    // 1. startOutgoing starts ringback; assigning UUID afterwards does not restart; startOngoing stops it.
    controller.startOutgoing(callerName: 'Alice');
    controller.startOutgoing(callUuid: 'ft-out-1', callerName: 'Alice');
    expect(events, ['rb_start:null']);
    controller.startOngoing(callUuid: 'ft-out-1', callerName: 'Alice', isVideo: true, isOutgoing: true);
    expect(events, ['rb_start:null', 'rb_stop:ft-out-1']);

    // 2. status=6 on ongoing local call plays ended tone.
    events.clear();
    controller.applyServerSession({'uuid': 'ft-out-1', 'status_id': 6});
    expect(events, ['ended']);

    // 3. isLinkOnly outgoing call does NOT start ringback.
    events.clear();
    controller.startOutgoing(callUuid: 'ft-link-1', callerName: 'Bob', isLinkOnly: true);
    expect(events, isEmpty);
    await controller.endCall();
    expect(events, ['ended']);

    // 4. Outgoing -> setConnecting stops ringback.
    events.clear();
    controller.startOutgoing(callUuid: 'ft-out-2', callerName: 'Carol');
    controller.setConnecting(callUuid: 'ft-out-2');
    expect(events, ['rb_start:ft-out-2', 'rb_stop:ft-out-2']);
    controller.clear();

    // 5. Outgoing -> applyServerSession(status=1) stops ringback.
    events.clear();
    controller.startOutgoing(callUuid: 'ft-out-3', callerName: 'Dan');
    controller.applyServerSession({'uuid': 'ft-out-3', 'status_id': 1, 'active_device_id': 'web-1'});
    expect(events, ['rb_start:ft-out-3', 'rb_stop:ft-out-3']);
    // Local endCall on ongoing call plays ended tone.
    events.clear();
    await controller.endCall();
    expect(events, ['ended']);

    // 6. Outgoing -> status=6 stops ringback and plays ended tone.
    events.clear();
    controller.startOutgoing(callUuid: 'ft-out-4', callerName: 'Eve');
    controller.applyServerSession({'uuid': 'ft-out-4', 'status_id': 6});
    expect(events, ['rb_start:ft-out-4', 'rb_stop:ft-out-4', 'ended']);

    // 7. Outgoing -> reconcileServerSessions([]) stops ringback (no ended tone on reconcile).
    events.clear();
    controller.startOutgoing(callUuid: 'ft-out-5', callerName: 'Frank');
    controller.reconcileServerSessions(const []);
    expect(events, ['rb_start:ft-out-5', 'rb_stop:ft-out-5']);

    // 8. Outgoing on other device (nowOnOtherDevice) stops ringback and does NOT play ended tone.
    events.clear();
    controller.applyServerSession({
      'uuid': 'ft-out-6',
      'status_id': 3,
      'display_name': 'Grace',
      'active_device_id': 'web-1',
    });
    controller.applyServerSession({
      'uuid': 'ft-out-6',
      'status_id': 3,
      'display_name': 'Grace',
      'active_device_id': 'mac-1',
    });
    controller.applyServerSession({'uuid': 'ft-out-6', 'status_id': 6});
    expect(events, ['rb_start:ft-out-6', 'rb_stop:ft-out-6']);

    // 9. Unanswered incoming call -> status=6 or endCall does NOT play ended tone.
    events.clear();
    controller.startIncoming(callUuid: 'ft-in-1', callerName: 'Heidi', isVideo: true);
    controller.applyServerSession({'uuid': 'ft-in-1', 'status_id': 6});
    expect(events, isEmpty);

    controller.startIncoming(callUuid: 'ft-in-2', callerName: 'Ivan', isVideo: false);
    await controller.endCall();
    expect(events, isEmpty);

    // 10. dispose stops active ringback.
    events.clear();
    controller.startOutgoing(callUuid: 'ft-out-7', callerName: 'Judy');
    controller.dispose();
    expect(events, ['rb_start:ft-out-7', 'rb_stop:ft-out-7']);
  });
}
