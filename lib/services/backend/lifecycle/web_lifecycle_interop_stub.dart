import 'package:flutter/foundation.dart';

bool get isWebNavigatorOnline => true;

VoidCallback listenWebLifecycle({
  required void Function(bool hidden) onVisibilityChange,
  required void Function(bool online) onOnlineChange,
  void Function(bool focused)? onFocusChange,
}) =>
    () {};
