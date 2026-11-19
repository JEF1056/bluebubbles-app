import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/handlers/web_input_interop.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_suffix.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/voice_message_recorder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:record/record.dart';

class _FakeAudioRecorder implements AudioRecorder {
  _FakeAudioRecorder(this.supported);

  final Set<AudioEncoder> supported;

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) async => supported.contains(encoder);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('Web voice recording helpers', () {
    test('audioExtensionForMime maps browser MIME types to extensions', () {
      expect(audioExtensionForMime('audio/mp4'), 'm4a');
      expect(audioExtensionForMime('audio/aac'), 'm4a');
      expect(audioExtensionForMime('audio/webm;codecs=opus'), 'webm');
      expect(audioExtensionForMime('audio/ogg; codecs=opus'), 'ogg');
      expect(audioExtensionForMime('audio/wav'), 'wav');
      expect(audioExtensionForMime(''), 'm4a');
    });

    test('pickWebAudioEncoder prefers aacLc, then opus, then wav', () async {
      expect(
        await pickWebAudioEncoder(_FakeAudioRecorder({AudioEncoder.aacLc, AudioEncoder.opus})),
        AudioEncoder.aacLc,
      );
      expect(
        await pickWebAudioEncoder(_FakeAudioRecorder({AudioEncoder.opus})),
        AudioEncoder.opus,
      );
      expect(
        await pickWebAudioEncoder(_FakeAudioRecorder(const {})),
        AudioEncoder.wav,
      );
    });
  });

  group('VoiceMessageRecorder null-controller web fallback', () {
    testWidgets('renders waveform fallback when recorderController is null', (tester) async {
      await tester.pumpWidget(
        const GetMaterialApp(
          home: Scaffold(
            body: VoiceMessageRecorder(
              recorderController: null,
              textFieldSize: Size(300, 50),
              iOS: true,
              samsung: false,
            ),
          ),
        ),
      );
      expect(find.byType(VoiceMessageRecorder), findsOneWidget);
      expect(find.text('0:00'), findsOneWidget);
    });
  });

  group('web_input_interop VM stubs', () {
    test('stub helpers no-op safely off web', () async {
      expect(await readWebBlobUrlBytes('blob:http://localhost/123'), isNull);
      revokeWebObjectUrl('blob:http://localhost/123');
      final sub = listenWebPaste(
        shouldHandle: () => true,
        onFiles: (_) {},
      );
      await sub?.cancel();
    });
  });
}
