Future<void> showWebNotificationEx({
  required String title,
  String? body,
  String? icon,
  String? tag,
  bool requireInteraction = false,
  bool renotify = false,
  void Function()? onClick,
}) async {}

Future<void> closeWebNotificationsByTag(String tag) async {}

void updateWebTitleAndBadge(int unreadCount) {}
