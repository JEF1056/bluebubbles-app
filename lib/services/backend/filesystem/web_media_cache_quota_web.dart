import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<int?> estimateRemainingStorageBytes() async {
  try {
    final est = await web.window.navigator.storage.estimate().toDart;
    final remaining = est.quota - est.usage;
    return remaining > 0 ? remaining : 0;
  } catch (_) {
    return null;
  }
}

Future<({int? usage, int? quota})> estimateWebOriginStorage() async {
  try {
    final est = await web.window.navigator.storage.estimate().toDart;
    return (usage: est.usage, quota: est.quota);
  } catch (_) {
    return (usage: null, quota: null);
  }
}
