import 'dart:io';

import 'package:bluebubbles/database/global/settings.dart';
import 'package:bluebubbles/helpers/ui/sound_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _isValidWave(Uint8List bytes) {
  if (bytes.length < 44) return false;
  final riff = String.fromCharCodes(bytes.sublist(0, 4));
  final wave = String.fromCharCodes(bytes.sublist(8, 12));
  return riff == 'RIFF' && wave == 'WAVE';
}

int? _waveFormatCode(Uint8List bytes) {
  for (var i = 12; i + 10 <= bytes.length; i++) {
    if (bytes[i] == 0x66 && bytes[i + 1] == 0x6d && bytes[i + 2] == 0x74 && bytes[i + 3] == 0x20) {
      return bytes[i + 8] | (bytes[i + 9] << 8);
    }
  }
  return null;
}

bool _isValidOgg(Uint8List bytes) {
  if (bytes.length < 28) return false;
  return String.fromCharCodes(bytes.sublist(0, 4)) == 'OggS';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Google Messages sounds', () {
    test('all bundled Flutter sound assets exist, are declared in pubspec.yaml, and are standard PCM WAV', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final assetPath in AppSounds.all) {
        final file = File(assetPath);
        expect(file.existsSync(), isTrue, reason: 'Missing sound asset: $assetPath');
        final bytes = file.readAsBytesSync();
        expect(bytes.length, greaterThan(1000), reason: 'Sound asset too small: $assetPath');
        expect(_isValidWave(bytes), isTrue, reason: 'Invalid RIFF/WAVE header in $assetPath');
        expect(_waveFormatCode(bytes), equals(0x0001), reason: 'Expected standard PCM fmt 0x0001 in $assetPath');
        expect(pubspec.contains(assetPath), isTrue, reason: '$assetPath missing from pubspec.yaml');
      }
    });

    test('Android res/raw contains authentic Google Messages sounds and no legacy BlueBubbles chimes', () {
      const rawDir = 'android/app/src/main/res/raw';
      const expected = <String, bool Function(Uint8List)>{
        'message_incoming.ogg': _isValidOgg,
        'message_sent_v2.ogg': _isValidOgg,
        'recording_start_audio.wav': _isValidWave,
        'recording_stop_audio.wav': _isValidWave,
      };
      for (final entry in expected.entries) {
        final file = File('$rawDir/${entry.key}');
        expect(file.existsSync(), isTrue, reason: 'Missing res/raw/${entry.key}');
        final bytes = file.readAsBytesSync();
        expect(bytes.length, greaterThan(1000));
        expect(entry.value(bytes), isTrue, reason: 'Invalid audio header in res/raw/${entry.key}');
      }
      for (final legacy in const ['raspberry.wav', 'sugarfree.wav', 'twig.wav', 'walrus.wav']) {
        expect(File('$rawDir/$legacy').existsSync(), isFalse, reason: 'Legacy sound $legacy still present');
      }
    });

    test('default Settings map to Google Messages send/receive sounds out of the box', () {
      final settings = Settings();
      expect(settings.sendSoundPath.value, isNull);
      expect(settings.receiveSoundPath.value, isNull);
      expect(settings.soundVolume.value, equals(100));
      expect(AppSounds.messageSent, equals('assets/sounds/message_sent.wav'));
      expect(AppSounds.messageIncoming, equals('assets/sounds/message_incoming.wav'));
      expect(AppSounds.recordingStart, equals('assets/sounds/recording_start_audio.wav'));
      expect(AppSounds.recordingStop, equals('assets/sounds/recording_stop_audio.wav'));
    });

    test('Android playAppSound delegates to native SoundPool channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('com.bluebubbles.messaging');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          calls.add(call);
          return true;
        },
      );
      try {
        await playAppSound(AppSounds.messageSent, volume: 0.75);
        expect(calls, hasLength(1));
        expect(calls.single.method, equals('play-app-sound'));
        expect(calls.single.arguments, equals({
          'assetPath': AppSounds.messageSent,
          'customPath': null,
          'volume': 0.75,
        }));
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
