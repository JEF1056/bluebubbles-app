import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

bool _cfAccessCheckInFlight = false;

/// Detects an expired/missing Cloudflare Access cookie on `bb.jessfan.com` and
/// performs a single SSO bounce (60s cooldown prevents loops if server is down).
Future<bool> ensureCloudflareAccessSession(String serverOrigin) async {
  if (_cfAccessCheckInFlight) return false;
  try {
    if (web.window.location.origin != 'https://chat.jessfan.com') return false;
    final parsed = Uri.tryParse(serverOrigin);
    if (parsed == null || parsed.scheme != 'https' || !parsed.host.endsWith('.jessfan.com')) {
      return false;
    }
    const key = 'bb_cf_bounce_ts';
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = int.tryParse(web.window.sessionStorage.getItem(key) ?? '') ?? 0;
    if (now - last < 60000) return false;
    _cfAccessCheckInFlight = true;
    final res = await web.window
        .fetch(
          '${parsed.origin}/api/v1/access-check'.toJS,
          web.RequestInit(credentials: 'include', redirect: 'manual'),
        )
        .toDart;
    if (res.type == 'opaqueredirect') {
      web.window.sessionStorage.setItem(key, now.toString());
      web.window.location.replace('${parsed.origin}/api/v1/access-bounce');
      return true;
    }
  } catch (_) {
    // Network offline or tunnel unreachable; stay on cached UI.
  } finally {
    _cfAccessCheckInFlight = false;
  }
  return false;
}

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

bool get isAndroidWeb {
  try {
    return web.window.navigator.userAgent.toLowerCase().contains('android');
  } catch (_) {
    return false;
  }
}

/// Handle to a browser tab synchronously pre-opened on user gesture so a post-await
/// FaceTime join link can navigate it without triggering popup blockers.
class PendingCallTab {
  PendingCallTab(this._window);

  web.Window? _window;

  bool get isOpen {
    final win = _window;
    if (win == null) return false;
    try {
      return !win.closed;
    } catch (_) {
      return false;
    }
  }

  bool navigate(String url) {
    final win = _window;
    if (win == null) return false;
    try {
      if (win.closed) {
        _window = null;
        return false;
      }
      win.location.replace(url);
      win.focus();
      return true;
    } catch (_) {
      _window = null;
      return false;
    }
  }

  void close() {
    final win = _window;
    _window = null;
    if (win == null) return;
    try {
      if (!win.closed) {
        win.close();
      }
    } catch (_) {}
  }
}

PendingCallTab? openPendingCallTab() {
  try {
    final win = web.window.open('about:blank', 'bluebubbles_facetime_call');
    if (win == null) return null;
    return PendingCallTab(win);
  } catch (_) {
    return null;
  }
}
