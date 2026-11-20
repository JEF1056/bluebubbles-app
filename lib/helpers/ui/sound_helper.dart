import 'dart:async';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/web_audio_player.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/platform/shims/native_media.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart';
import 'package:universal_io/io.dart';

const MethodChannel _androidSoundChannel = MethodChannel('com.bluebubbles.messaging');

/// Authentic Google Messages sound assets bundled with the app.
class AppSounds {
  const AppSounds._();

  static const String messageSent = 'assets/sounds/message_sent.wav';
  static const String messageIncoming = 'assets/sounds/message_incoming.wav';
  static const String recordingStart = 'assets/sounds/recording_start_audio.wav';
  static const String recordingStop = 'assets/sounds/recording_stop_audio.wav';

  static const List<String> all = <String>[
    messageSent,
    messageIncoming,
    recordingStart,
    recordingStop,
  ];
}

final Map<String, Future<String?>> _cachedNativePaths = <String, Future<String?>>{};

/// Materializes a bundled sound asset to [FilesystemSvc.soundsPath] so native
/// players (`media_kit` and `audio_waveforms`) can play it from a file path.
Future<String?> ensureBundledSoundFile(String assetPath) {
  return _cachedNativePaths[assetPath] ??= () async {
    try {
      final outPath = join(FilesystemSvc.soundsPath, 'gmsg_${basename(assetPath)}');
      final file = File(outPath);
      if (!await file.exists() || await file.length() == 0) {
        final data = await rootBundle.load(assetPath);
        await file.create(recursive: true);
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      return outPath;
    } catch (e, stack) {
      Logger.warn('Failed to materialize bundled sound $assetPath', error: e, trace: stack);
      _cachedNativePaths.remove(assetPath);
      return null;
    }
  }();
}

/// Plays [customPath] if non-null, otherwise plays the bundled Google Messages [assetPath].
Future<void> playAppSound(
  String assetPath, {
  String? customPath,
  double volume = 1.0,
}) async {
  final clampedVol = volume.clamp(0.0, 1.0);
  if (clampedVol <= 0) return;

  if (kIsWeb) {
    await playWebSoundAsset(assetPath, volume: clampedVol, customUrl: customPath);
    return;
  }

  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _androidSoundChannel.invokeMethod<bool>('play-app-sound', {
        'assetPath': assetPath,
        'customPath': customPath,
        'volume': clampedVol,
      });
      return;
    }

    final path = (customPath != null && customPath.isNotEmpty)
        ? customPath
        : await ensureBundledSoundFile(assetPath);
    if (path == null || path.isEmpty) return;

    if (kIsDesktop) {
      final player = Player();
      player.stream.completed
          .firstWhere((done) => done)
          .then((_) => Future.delayed(const Duration(milliseconds: 500), player.dispose));
      await player.setVolume(clampedVol * 100.0);
      await player.open(Media(path));
    } else {
      final controller = PlayerController();
      await controller.preparePlayer(path: path, volume: clampedVol, shouldExtractWaveform: false);
      await controller.startPlayer();
      unawaited(
        controller.onCompletion.first.whenComplete(controller.dispose).catchError((Object _) {}),
      );
    }
  } catch (e, stack) {
    Logger.warn('Failed to play app sound $assetPath', error: e, trace: stack);
  }
}
