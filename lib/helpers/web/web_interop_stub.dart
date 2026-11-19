import 'dart:typed_data';

void downloadBytes(
  Uint8List bytes,
  String filename, {
  String mimeType = 'application/octet-stream',
}) {}

String createObjectUrlFromBytes(Uint8List bytes) => '';

Future<void> preventNextContextMenu() async {}

void suppressBrowserFindShortcut() {}

bool get isWebDocumentHidden => false;

String get webNotificationPermission => 'denied';

Future<String> requestWebNotificationPermission() async => 'denied';
