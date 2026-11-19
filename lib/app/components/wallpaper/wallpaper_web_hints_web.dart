import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

bool get isWebDocumentHidden => web.document.hidden;

bool get webPrefersReducedMotion =>
    web.window.matchMedia('(prefers-reduced-motion: reduce)').matches;

int? get webHardwareConcurrency {
  final cores = web.window.navigator.hardwareConcurrency;
  return cores > 0 ? cores : null;
}

VoidCallback listenWebVisibilityChange(void Function(bool hidden) onChanged) {
  final StreamSubscription<web.Event> sub = const web.EventStreamProvider<web.Event>('visibilitychange')
      .forTarget(web.document)
      .listen((_) => onChanged(web.document.hidden));
  return sub.cancel;
}
