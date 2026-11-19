import 'dart:async';
import 'dart:typed_data';

Future<({Uint8List bytes, String mimeType})?> readWebBlobUrlBytes(String blobUrl) async => null;

void revokeWebObjectUrl(String url) {}

StreamSubscription<void>? listenWebPaste({
  required bool Function() shouldHandle,
  required void Function(List<({String name, Uint8List bytes})> files) onFiles,
}) =>
    null;
