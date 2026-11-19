import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

Future<void> showWebNotificationEx({
  required String title,
  String? body,
  String? icon,
  String? tag,
  void Function()? onClick,
}) async {
  final options = web.NotificationOptions();
  if (body != null) options.body = body;
  if (icon != null) options.icon = icon;
  if (tag != null) options.tag = tag;

  // Prefer window.Notification when an onClick callback is provided so click
  // handlers can focus the tab and open the chat (default flutter_service_worker.js
  // has no notificationclick listener). Fall back to ServiceWorkerRegistration.showNotification
  // when new Notification(...) throws (e.g. Android Chrome PWA).
  if (onClick != null) {
    try {
      final notif = web.Notification(title, options);
      notif.onclick = ((web.Event _) {
        try {
          web.window.focus();
        } catch (_) {}
        onClick();
      }).toJS;
      return;
    } catch (_) {
      // Fall through to ServiceWorkerRegistration.showNotification
    }
  }

  try {
    final nav = web.window.navigator as JSObject;
    if (nav.has('serviceWorker')) {
      final reg = await web.window.navigator.serviceWorker
          .getRegistration()
          .toDart
          .timeout(const Duration(milliseconds: 500));
      if (reg != null && reg.active != null) {
        await reg.showNotification(title, options).toDart;
        return;
      }
    }
  } catch (_) {
    // Fall through to window.Notification
  }

  final notif = web.Notification(title, options);
  if (onClick != null) {
    notif.onclick = ((web.Event _) {
      try {
        web.window.focus();
      } catch (_) {}
      onClick();
    }).toJS;
  }
}

void _ignorePromise(JSAny? value) {
  if (value != null && value.isA<JSPromise>()) {
    unawaited((value as JSPromise).toDart.then((_) {}, onError: (_) {}));
  }
}

void updateWebTitleAndBadge(int unreadCount) {
  try {
    web.document.title = unreadCount > 0 ? '($unreadCount) BlueBubbles' : 'BlueBubbles';
    final nav = web.window.navigator as JSObject;
    if (unreadCount > 0) {
      if (nav.has('setAppBadge')) {
        _ignorePromise(nav.callMethodVarArgs('setAppBadge'.toJS, [unreadCount.toJS]));
      }
    } else {
      if (nav.has('clearAppBadge')) {
        _ignorePromise(nav.callMethodVarArgs('clearAppBadge'.toJS));
      } else if (nav.has('setAppBadge')) {
        _ignorePromise(nav.callMethodVarArgs('setAppBadge'.toJS, [0.toJS]));
      }
    }
  } catch (_) {}
}
