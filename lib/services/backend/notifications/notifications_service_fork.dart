part of 'notifications_service.dart';

int _faceTimeNotificationId(String? callUuid) {
  final numeric = callUuid?.numericOnly();
  if (numeric != null && numeric.isNotEmpty) {
    return int.tryParse(numeric.substring(0, min(8, numeric.length))) ?? (callUuid!.hashCode & 0x7fffffff);
  }
  if (callUuid != null) {
    return callUuid.hashCode & 0x7fffffff;
  }
  return Random().nextInt(9998) + 1;
}

extension NotificationsServiceFork on NotificationsService {
  void bindWebUnreadBadge() {
    if (!kIsWeb || headless || !GetIt.I.isRegistered<ChatsService>()) return;
    updateWebTitleAndBadge(ChatsSvc.unreadCount.value);
    _webUnreadWorker?.dispose();
    _webUnreadWorker = ever<int>(ChatsSvc.unreadCount, updateWebTitleAndBadge);
  }

  Future<void> deleteNotification(
    int notificationId, {
    String? tag,
    String? chatGuid,
    int? readBefore,
    String? callUuid,
    bool keepBubble = false,
  }) async {
    if (kIsDesktop) {
      final desktopKey = chatGuid ?? tag;
      if (desktopKey != null) {
        await clearDesktopNotificationsForChat(desktopKey, readBefore: readBefore);
      }
      return;
    }
    await MethodChannelSvc.actions.deleteNotification(
      notificationId: notificationId,
      tag: tag,
      readBefore: readBefore,
      callUuid: callUuid,
      keepBubble: keepBubble,
    );
  }
}
