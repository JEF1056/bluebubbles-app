import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

bool get isWebNavigatorOnline => web.window.navigator.onLine;

VoidCallback listenWebLifecycle({
  required void Function(bool hidden) onVisibilityChange,
  required void Function(bool online) onOnlineChange,
  void Function(bool focused)? onFocusChange,
}) {
  final subs = <StreamSubscription<web.Event>>[
    const web.EventStreamProvider<web.Event>('visibilitychange')
        .forTarget(web.document)
        .listen((_) => onVisibilityChange(web.document.hidden)),
    web.EventStreamProviders.onlineEvent
        .forTarget(web.window)
        .listen((_) => onOnlineChange(true)),
    web.EventStreamProviders.offlineEvent
        .forTarget(web.window)
        .listen((_) => onOnlineChange(false)),
    if (onFocusChange != null) ...[
      web.EventStreamProviders.focusEvent
          .forTarget(web.window)
          .listen((_) => onFocusChange(true)),
      web.EventStreamProviders.blurEvent
          .forTarget(web.window)
          .listen((_) => onFocusChange(false)),
    ],
  ];
  return () {
    for (final sub in subs) {
      sub.cancel();
    }
  };
}
