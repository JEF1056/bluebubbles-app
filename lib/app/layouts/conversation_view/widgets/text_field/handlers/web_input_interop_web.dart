import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<({Uint8List bytes, String mimeType})?> readWebBlobUrlBytes(String blobUrl) async {
  try {
    final response = await web.window.fetch(blobUrl.toJS).toDart;
    final blob = await response.blob().toDart;
    final buffer = await blob.arrayBuffer().toDart;
    return (bytes: buffer.toDart.asUint8List(), mimeType: blob.type);
  } catch (_) {
    return null;
  }
}

void revokeWebObjectUrl(String url) {
  if (url.startsWith('blob:')) {
    web.URL.revokeObjectURL(url);
  }
}

StreamSubscription<void>? listenWebPaste({
  required bool Function() shouldHandle,
  required void Function(List<({String name, Uint8List bytes})> files) onFiles,
}) {
  return web.EventStreamProviders.pasteEvent.forTarget(web.document).listen((web.ClipboardEvent event) {
    if (!shouldHandle()) return;
    final data = event.clipboardData;
    if (data == null) return;

    final rawFiles = <web.File>[];
    final fileList = data.files;
    for (int i = 0; i < fileList.length; i++) {
      final f = fileList.item(i);
      if (f != null) rawFiles.add(f);
    }
    if (rawFiles.isEmpty) {
      final items = data.items;
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.kind == 'file') {
          final f = item.getAsFile();
          if (f != null) rawFiles.add(f);
        }
      }
    }
    if (rawFiles.isEmpty) return;

    // Prevent browser from pasting placeholder text/filename when media files are present.
    event.preventDefault();
    unawaited(() async {
      final result = <({String name, Uint8List bytes})>[];
      for (int i = 0; i < rawFiles.length; i++) {
        final file = rawFiles[i];
        try {
          final buffer = await file.arrayBuffer().toDart;
          final bytes = buffer.toDart.asUint8List();
          if (bytes.isEmpty) continue;
          final name = file.name.isNotEmpty
              ? file.name
              : 'pasted_${DateTime.now().millisecondsSinceEpoch}_${i + 1}.${_extFromMime(file.type)}';
          result.add((name: name, bytes: bytes));
        } catch (_) {
          // Skip unreadable clipboard item.
        }
      }
      if (result.isNotEmpty) {
        onFiles(result);
      }
    }());
  });
}

String _extFromMime(String mimeType) {
  final clean = mimeType.split(';').first.trim().toLowerCase();
  return switch (clean) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/heic' => 'heic',
    'video/mp4' => 'mp4',
    'audio/mp4' => 'm4a',
    'application/pdf' => 'pdf',
    _ => () {
        if (!clean.contains('/')) return 'bin';
        final sub = clean.split('/').last.replaceAll(RegExp(r'[^a-z0-9]'), '');
        return sub.isEmpty ? 'bin' : sub;
      }(),
  };
}
