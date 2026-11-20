import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

void downloadBytes(
  Uint8List bytes,
  String filename, {
  String mimeType = 'application/octet-stream',
}) {
  final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..click();
  Future.delayed(const Duration(seconds: 5), () => web.URL.revokeObjectURL(url));
}

String createObjectUrlFromBytes(Uint8List bytes) {
  final blob = web.Blob(<JSAny>[bytes.toJS].toJS);
  return web.URL.createObjectURL(blob);
}

bool _contextMenuSuppressed = false;

void suppressBrowserContextMenu() {
  if (_contextMenuSuppressed) return;
  _contextMenuSuppressed = true;
  web.EventStreamProviders.contextMenuEvent.forTarget(web.document).listen((web.MouseEvent event) {
    event.preventDefault();
  });
}

Future<void> preventNextContextMenu() async {
  // Suppress globally instead of awaiting `.first` inside onSecondaryTapUp:
  // macOS browsers fire `contextmenu` on mousedown before Flutter's tap-up.
  suppressBrowserContextMenu();
}

void suppressBrowserFindShortcut() {
  web.EventStreamProviders.keyDownEvent.forTarget(web.document).listen((web.KeyboardEvent e) {
    if (e.key == 'F3' || ((e.ctrlKey || e.metaKey) && (e.key == 'f' || e.key == 'F'))) {
      e.preventDefault();
    }
  });
}

bool get isWebDocumentHidden => web.document.hidden;

bool get isWebDocumentFocused => web.document.hasFocus();

bool get _hasWebNotificationApi {
  try {
    return globalContext.has('Notification');
  } catch (_) {
    return false;
  }
}

String get webNotificationPermission {
  if (!_hasWebNotificationApi) return 'unsupported';
  try {
    return web.Notification.permission;
  } catch (_) {
    return 'unsupported';
  }
}

Future<String> requestWebNotificationPermission() async {
  if (!_hasWebNotificationApi) return 'unsupported';
  try {
    final result = await web.Notification.requestPermission().toDart;
    return result.toDart;
  } catch (_) {
    return 'unsupported';
  }
}
