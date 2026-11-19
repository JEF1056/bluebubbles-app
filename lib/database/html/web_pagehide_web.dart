import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool _pagehideRegistered = false;

void registerWebPagehideFlush(Future<void> Function() onFlush) {
  if (_pagehideRegistered) return;
  _pagehideRegistered = true;
  web.window.addEventListener(
    'pagehide',
    ((web.Event _) {
      unawaited(onFlush().catchError((Object _) {}));
    }).toJS,
  );
}
