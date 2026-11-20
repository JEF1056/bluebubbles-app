import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

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

String? _originalFaviconHref;
String? _originalFaviconType;
int _faviconUpdateSeq = 0;
String? _cachedFaviconSrc;
web.HTMLImageElement? _cachedFaviconImage;
String? _pendingFaviconSrc;
Future<web.HTMLImageElement?>? _pendingFaviconFuture;

Future<web.HTMLImageElement?> _loadFaviconImage(String sourceHref) {
  if (_cachedFaviconSrc == sourceHref && _cachedFaviconImage != null) {
    return Future.value(_cachedFaviconImage);
  }
  if (_pendingFaviconSrc == sourceHref && _pendingFaviconFuture != null) {
    return _pendingFaviconFuture!;
  }

  final completer = Completer<web.HTMLImageElement?>();
  final img = web.HTMLImageElement()..crossOrigin = 'anonymous';
  StreamSubscription<web.Event>? loadSub;
  StreamSubscription<web.Event>? errorSub;

  void finish(web.HTMLImageElement? result) {
    unawaited(loadSub?.cancel() ?? Future<void>.value());
    unawaited(errorSub?.cancel() ?? Future<void>.value());
    loadSub = null;
    errorSub = null;
    if (identical(_pendingFaviconFuture, completer.future)) {
      _pendingFaviconSrc = null;
      _pendingFaviconFuture = null;
    }
    if (!completer.isCompleted) {
      if (result != null) {
        _cachedFaviconSrc = sourceHref;
        _cachedFaviconImage = result;
      }
      completer.complete(result);
    }
  }

  loadSub = img.onLoad.listen((_) => finish(img));
  errorSub = img.onError.listen((_) => finish(null));
  _pendingFaviconSrc = sourceHref;
  _pendingFaviconFuture = completer.future;
  img.src = sourceHref;
  if (img.complete && img.naturalWidth > 0) {
    finish(img);
  }
  return completer.future;
}

web.HTMLLinkElement _ensureFaviconLink() {
  final existing = web.document.querySelector('link[rel~="icon"]');
  if (existing != null && existing.isA<web.HTMLLinkElement>()) {
    final link = existing as web.HTMLLinkElement;
    _originalFaviconHref ??= link.href;
    _originalFaviconType ??= link.type;
    return link;
  }
  final link = web.HTMLLinkElement()
    ..rel = 'icon'
    ..type = 'image/x-icon'
    ..href = 'icons/favicon.ico?v=5';
  _originalFaviconHref ??= link.href;
  _originalFaviconType ??= link.type;
  web.document.head?.appendChild(link);
  return link;
}

void _drawFaviconBadge(web.CanvasRenderingContext2D ctx, int size, int unreadCount) {
  final label = unreadCount > 99 ? '99+' : '$unreadCount';
  final double radius = size * (label.length >= 3 ? 0.34 : 0.28);
  final double cx = size - radius - 2;
  final double cy = radius + 2;

  ctx.beginPath();
  ctx.arc(cx, cy, radius, 0, math.pi * 2);
  ctx.fillStyle = '#FF3B30'.toJS;
  ctx.fill();
  ctx.lineWidth = math.max(2, size * 0.05);
  ctx.strokeStyle = '#FFFFFF'.toJS;
  ctx.stroke();

  final fontSize = (radius * (label.length >= 3 ? 0.95 : label.length == 2 ? 1.1 : 1.25)).round();
  ctx.fillStyle = '#FFFFFF'.toJS;
  ctx.font = 'bold ${fontSize}px system-ui, -apple-system, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(label, cx, cy + 1);
}

void _updateFaviconBadge(int unreadCount) {
  final link = _ensureFaviconLink();
  final seq = ++_faviconUpdateSeq;
  if (unreadCount <= 0) {
    if (_originalFaviconHref != null) {
      link.href = _originalFaviconHref!;
    }
    if (_originalFaviconType != null && _originalFaviconType!.isNotEmpty) {
      link.type = _originalFaviconType!;
    }
    return;
  }

  final sourceHref = _originalFaviconHref;
  if (sourceHref == null || sourceHref.isEmpty) return;

  const int size = 64;
  void render({web.HTMLImageElement? baseImage}) {
    if (seq != _faviconUpdateSeq) return;
    final canvas = web.HTMLCanvasElement()
      ..width = size
      ..height = size;
    final rawCtx = canvas.getContext('2d');
    if (rawCtx == null || !rawCtx.isA<web.CanvasRenderingContext2D>()) return;
    final ctx = rawCtx as web.CanvasRenderingContext2D;
    ctx.clearRect(0, 0, size, size);
    if (baseImage != null) {
      ctx.drawImage(baseImage, 0, 0, size, size);
    }
    _drawFaviconBadge(ctx, size, unreadCount);
    try {
      final dataUrl = canvas.toDataURL('image/png');
      link.type = 'image/png';
      link.href = dataUrl;
    } catch (_) {
      // Cross-origin canvas tainting blocks toDataURL; draw badge-only fallback instead.
      if (baseImage != null) {
        ctx.clearRect(0, 0, size, size);
        _drawFaviconBadge(ctx, size, unreadCount);
        try {
          final dataUrl = canvas.toDataURL('image/png');
          link.type = 'image/png';
          link.href = dataUrl;
        } catch (_) {}
      }
    }
  }

  if (_cachedFaviconSrc == sourceHref && _cachedFaviconImage != null) {
    render(baseImage: _cachedFaviconImage);
    return;
  }

  unawaited(_loadFaviconImage(sourceHref).then((img) {
    render(baseImage: img);
  }));
}

void updateWebTitleAndBadge(int unreadCount) {
  try {
    web.document.title = unreadCount > 0 ? '($unreadCount) BlueBubbles' : 'BlueBubbles';
    _updateFaviconBadge(unreadCount);
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
