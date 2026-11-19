import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/web_audio_player.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/web_video_player.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Web audio/video URL helpers', () {
    test('buildWebAttachmentStreamUrl builds Range-friendly download URL', () {
      final url = buildWebAttachmentStreamUrl(
        apiRoot: 'https://example.com/api/v1',
        guid: 'p:0/ABC-123',
        authGuid: 'secret-pw',
      );
      final uri = Uri.parse(url);
      expect(uri.path, '/api/v1/attachment/p%3A0%2FABC-123/download');
      expect(uri.queryParameters['guid'], 'secret-pw');
      expect(uri.queryParameters.containsKey('format'), isFalse);
    });

    test('isCafAudio detects CAF mime types and extensions', () {
      expect(isCafAudio(mimeType: 'audio/x-caf'), isTrue);
      expect(isCafAudio(mimeType: 'AUDIO/CAF'), isTrue);
      expect(isCafAudio(fileName: 'Audio Message.caf'), isTrue);
      expect(isCafAudio(transferName: 'voice.CAF'), isTrue);
      expect(isCafAudio(mimeType: 'audio/mp4', fileName: 'voice.m4a'), isFalse);
    });

    test('buildWebAudioStreamUrl requests format=m4a for CAF', () {
      final cafUrl = buildWebAudioStreamUrl(
        apiRoot: 'https://example.com/api/v1',
        guid: 'att-1',
        authGuid: 'pw',
        isCaf: true,
      );
      expect(Uri.parse(cafUrl).queryParameters['format'], 'm4a');

      final mp3Url = buildWebAudioStreamUrl(
        apiRoot: 'https://example.com/api/v1',
        guid: 'att-2',
        authGuid: 'pw',
        isCaf: false,
      );
      expect(Uri.parse(mp3Url).queryParameters.containsKey('format'), isFalse);
    });
  });

  group('VM stubs', () {
    testWidgets('WebVideoPlayer stub builds and WebAudioController/chime no-op safely', (tester) async {
      final videoCtrl = WebVideoController();
      await videoCtrl.play();
      await videoCtrl.pause();
      await videoCtrl.setMuted(true);
      videoCtrl.dispose();

      final audioCtrl = WebAudioController(
        file: PlatformFile(name: 'voice.caf', size: 0),
      );
      expect(audioCtrl.isPlaying, isFalse);
      await audioCtrl.play();
      await audioCtrl.seek(const Duration(seconds: 2));
      audioCtrl.dispose();

      await playWebChime(isSend: false, volume: 0.5);

      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: WebVideoPlayer(),
      ));
      expect(find.byType(SizedBox), findsOneWidget);
    });
  });
}
