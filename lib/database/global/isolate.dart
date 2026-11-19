import 'package:bluebubbles/database/models.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart';
import 'package:universal_io/io.dart';

Future<Image?> decodeIsolate(PlatformFile file) async {
  try {
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    if (kIsWeb) {
      return decodeImage(bytes);
    }
    return await compute((b) => decodeImage(b), bytes);
  } catch (_) {
    return null;
  }
}
