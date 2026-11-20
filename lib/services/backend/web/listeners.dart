import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/models/models.dart';

/// Class to replace objectbox DB listener functionality with an old-fashioned
/// stream based listener
class WebListeners {
  static const int _maxTrackedGuids = 5000;
  static final Set<String> _messageGuids = {};
  static final Set<String> _chatGuids = {};

  static final StreamController<MessageUpdateEvent> _messageUpdate = StreamController.broadcast();
  static final StreamController<NewMessageEvent> _newMessage = StreamController.broadcast();

  static final StreamController<Chat> _chatUpdate = StreamController.broadcast();
  static final StreamController<Chat> _newChat = StreamController.broadcast();

  static Stream<MessageUpdateEvent> get messageUpdate => _messageUpdate.stream;
  static Stream<NewMessageEvent> get newMessage => _newMessage.stream;

  static Stream<Chat> get chatUpdate => _chatUpdate.stream;
  static Stream<Chat> get newChat => _newChat.stream;

  static void _trackGuid(Set<String> set, String? guid) {
    if (guid == null || guid.isEmpty) return;
    // shortcut: FIFO eviction at 5000 GUIDs, replace with LRU if long-lived web sessions re-emit old GUIDs
    if (set.length >= _maxTrackedGuids && !set.contains(guid)) {
      set.remove(set.first);
    }
    set.add(guid);
  }

  static void notifyMessage(Message m, {Chat? chat, String? tempGuid}) {
    final guid = m.guid;
    if (tempGuid != null) {
      if (_messageGuids.contains(tempGuid)) {
        _trackGuid(_messageGuids, guid);
        _messageUpdate.add(MessageUpdateEvent(m, tempGuid, chat));
      } else {
        _trackGuid(_messageGuids, tempGuid);
        _newMessage.add(NewMessageEvent(m, chat));
      }
    } else {
      if (guid != null && _messageGuids.contains(guid)) {
        _messageUpdate.add(MessageUpdateEvent(m, null, chat));
      } else {
        _trackGuid(_messageGuids, guid);
        _newMessage.add(NewMessageEvent(m, chat));
      }
    }
  }

  static void notifyChat(Chat c) {
    if (_chatGuids.contains(c.guid)) {
      _chatUpdate.add(c);
    } else {
      _trackGuid(_chatGuids, c.guid);
      _newChat.add(c);
    }
  }

  static void reset() {
    _messageGuids.clear();
    _chatGuids.clear();
  }
}
