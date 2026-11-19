import 'package:bluebubbles/database/models.dart';
import 'package:flutter/foundation.dart';

class WebAudioController extends ChangeNotifier {
  WebAudioController({
    required PlatformFile file,
    Attachment? attachment,
  });

  bool get isPlaying => false;
  Duration get position => Duration.zero;
  Duration get duration => Duration.zero;
  bool get hasError => false;

  Future<void> play() async {}
  Future<void> pause() async {}
  Future<void> togglePlayPause() async {}
  Future<void> seek(Duration position) async {}
}

Future<void> playWebChime({
  required bool isSend,
  double volume = 1.0,
  String? customUrl,
}) async {}
