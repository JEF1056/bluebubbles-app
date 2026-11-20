import 'dart:typed_data';

void downloadBytes(
  Uint8List bytes,
  String filename, {
  String mimeType = 'application/octet-stream',
}) {}

String createObjectUrlFromBytes(Uint8List bytes) => '';

void suppressBrowserContextMenu() {}

Future<void> preventNextContextMenu() async {}

void suppressBrowserFindShortcut() {}

bool get isWebDocumentHidden => false;

bool get isWebDocumentFocused => true;

String get webNotificationPermission => 'denied';

Future<String> requestWebNotificationPermission() async => 'denied';

bool get isAndroidWeb => false;

class PendingCallTab {
  bool get isOpen => false;

  bool navigate(String url) => false;

  void close() {}
}

PendingCallTab? openPendingCallTab() => null;

Future<bool> ensureCloudflareAccessSession(String serverOrigin) async => false;
