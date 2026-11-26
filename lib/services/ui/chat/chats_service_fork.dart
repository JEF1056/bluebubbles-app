part of 'chats_service.dart';

/// Returns `null` when the payload does not carry a `pinnedChatGuids` list so
/// error/unsupported responses never wipe local pins.
List<String>? _extractPinnedChatGuids(dynamic payload) {
  if (payload is! Map) return null;
  dynamic rawList;
  if (payload['data'] is Map && (payload['data'] as Map).containsKey('pinnedChatGuids')) {
    rawList = (payload['data'] as Map)['pinnedChatGuids'];
  } else if (payload.containsKey('pinnedChatGuids')) {
    rawList = payload['pinnedChatGuids'];
  }
  if (rawList is! List) return null;
  final seen = <String>{};
  final result = <String>[];
  for (final item in rawList) {
    if (item is String && item.isNotEmpty && seen.add(item)) {
      result.add(item);
    }
  }
  return result;
}

/// Compute `(chat, isPinned, pinIndex)` updates needed for [chats] to match [pinnedGuids].
List<({Chat chat, bool isPinned, int? pinIndex})> _computePinUpdates(
  Iterable<Chat> chats,
  List<String> pinnedGuids,
) {
  final pinIndexByGuid = <String, int>{
    for (int i = 0; i < pinnedGuids.length; i++) pinnedGuids[i]: i,
  };
  final updates = <({Chat chat, bool isPinned, int? pinIndex})>[];
  for (final chat in chats) {
    final int? targetIndex = pinIndexByGuid[chat.guid];
    final bool targetPinned = targetIndex != null;
    if ((chat.isPinned ?? false) != targetPinned || chat.pinIndex != targetIndex) {
      updates.add((chat: chat, isPinned: targetPinned, pinIndex: targetIndex));
    }
  }
  return updates;
}

extension ChatsServiceFork on ChatsService {
  void _syncLocusContext(String? chatGuid) {
    if (kIsWeb || !Platform.isAndroid) return;
    if (!GetIt.I.isRegistered<MethodChannelService>()) return;
    unawaited(MethodChannelSvc.actions.setLocusContext(chatGuid));
  }

  /// Set a chat as the active chat synchronously
  void setActiveChatSync(
    Chat chat, {
    bool clearNotifications = true,
    bool save = true,
    bool alive = true,
  }) {
    Logger.debug('Setting active chat to ${chat.guid} (${chat.displayName})');

    final foreground = _isAppForeground;

    // Get or create the chat state
    final chatState = getOrCreateChatState(chat);

    // Set this chat as active
    activeChat = chatState;
    chatState.updateActiveInternal(true);
    chatState.updateAliveInternal(alive && foreground);

    // Clear all other chats to inactive
    setAllInactiveSync(save: false, clearActive: false);

    if (foreground && alive) {
      _syncLocusContext(chat.guid);
    }

    if (clearNotifications && alive && _isUiInteractive) {
      // Defer the observable update to avoid updating during build phase
      Future.microtask(() {
        if (isChatActive(chatState.chat.guid) && _isUiInteractive) {
          setChatHasUnread(chatState.chat, false);
        }
      });
    }

    if (save) {
      unawaited(PrefsSvc.messaging.setLastOpenedChat(chat.guid));
    }
  }

  Future<void> _syncChatPinToServer(String guid, bool pinned) async {
    final epoch = _pinReorderEpoch;
    try {
      final resp = await HttpSvc.chat.setPinned(guid, pinned: pinned);
      final guids = _extractPinnedChatGuids(resp.data);
      // Don't overwrite a drag-reorder slot with the server's append-only pin response.
      if (guids != null && epoch == _pinReorderEpoch) {
        await applyPinnedChatGuids(guids);
      }
    } catch (e) {
      Logger.debug("Failed to sync chat pin to server: $e", tag: "ChatsService");
    }
  }
}
