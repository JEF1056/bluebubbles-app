import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/global/settings.dart';
import 'package:bluebubbles/helpers/ui/sound_helper.dart';
import 'package:flutter_test/flutter_test.dart';

bool _isValidWave(Uint8List bytes) {
  if (bytes.length < 44) return false;
  final riff = String.fromCharCodes(bytes.sublist(0, 4));
  final wave = String.fromCharCodes(bytes.sublist(8, 12));
  return riff == 'RIFF' && wave == 'WAVE';
}

bool _isValidOgg(Uint8List bytes) {
  if (bytes.length < 28) return false;
  return String.fromCharCodes(bytes.sublist(0, 4)) == 'OggS';
}

void main() {
  group('Google Messages sounds', () {
    test('all bundled Flutter sound assets exist, are declared in pubspec.yaml, and are valid WAV', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final assetPath in AppSounds.all) {
        final file = File(assetPath);
        expect(file.existsSync(), isTrue, reason: 'Missing sound asset: $assetPath');
        final bytes = file.readAsBytesSync();
        expect(bytes.length, greaterThan(1000), reason: 'Sound asset too small: $assetPath');
        expect(_isValidWave(bytes), isTrue, reason: 'Invalid RIFF/WAVE header in $assetPath');
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
  });
}
