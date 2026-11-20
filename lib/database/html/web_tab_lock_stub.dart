import 'package:flutter/foundation.dart';

class WebTabLock {
  WebTabLock._();
  static final WebTabLock instance = WebTabLock._();

  final ValueNotifier<bool> blockedListenable = ValueNotifier<bool>(false);
  Future<void> Function()? onRelinquish;

  bool get isBlocked => false;
  bool get isOwner => true;

  Future<bool> acquireOnStartup() async => true;

  Future<void> takeOver() async {}

  void reloadPage() {}
}
