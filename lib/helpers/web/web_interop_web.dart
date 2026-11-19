import 'dart:js_interop';
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

Future<void> preventNextContextMenu() async {
  final event = await web.EventStreamProviders.contextMenuEvent.forTarget(web.document).first;
  event.preventDefault();
}

void suppressBrowserFindShortcut() {
  web.EventStreamProviders.keyDownEvent.forTarget(web.document).listen((web.KeyboardEvent e) {
    if (e.key == 'F3' || (e.ctrlKey && (e.key == 'f' || e.key == 'F'))) {
      e.preventDefault();
    }
  });
}

bool get isWebDocumentHidden => web.document.hidden;

String get webNotificationPermission => web.Notification.permission;

Future<String> requestWebNotificationPermission() async {
  final result = await web.Notification.requestPermission().toDart;
  return result.toDart;
}

void showWebNotification({
  required String title,
  String? body,
  String? icon,
  String? tag,
  void Function()? onClick,
}) {
  final options = web.NotificationOptions();
  if (body != null) options.body = body;
  if (icon != null) options.icon = icon;
  if (tag != null) options.tag = tag;
  final notif = web.Notification(title, options);
  if (onClick != null) {
    notif.onclick = ((web.Event _) => onClick()).toJS;
  }
}
