import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/utils/logger/logger.dart';

class ChatMessages {
  final Map<String, Message> _messages = {};
  final Map<String, Message> _reactions = {};
  final Map<String, Attachment> _attachments = {};
  final Map<String, Map<String, Message>> _threads = {};
  final Map<String, Map<String, Message>> _edits = {};

  bool get isEmpty => _messages.isEmpty;
  bool get isNotEmpty => _messages.isNotEmpty;
  List<Message> get messages => _messages.values.toList();
  List<Message> get reactions => _reactions.values.toList();
  List<Attachment> get attachments => _attachments.values.toList();
  List<Message> threads(String originatorGuid, int originatorPart, {bool returnOriginator = true}) =>
      threadsForParts(originatorGuid, [originatorPart], returnOriginator: returnOriginator);

  /// Returns replies whose [Message.normalizedThreadPart] matches any value in
  /// [originatorParts], plus the originator when [returnOriginator] is true.
  List<Message> threadsForParts(
    String originatorGuid,
    Iterable<int> originatorParts, {
    bool returnOriginator = true,
  }) {
    final partIds = originatorParts.toSet();
    return _threads[originatorGuid]
            ?.values
            .where((e) =>
                (partIds.contains(e.normalizedThreadPart) && e.guid != originatorGuid) ||
                (returnOriginator ? e.guid == originatorGuid : false))
            .toList() ??
        [];
  }

  void addMessages(List<Message> __messages) {
    for (Message m in __messages) {
      final guid = m.guid;
      if (guid == null || guid.isEmpty) {
        Logger.warn('Skipping message id=${m.id} with null or empty guid in ChatMessages.addMessages',
            tag: 'ChatMessages');
        continue;
      }
      if (m.isReaction) {
        // add reactions
        _reactions[guid] = m;
      } else {
        // add regular texts
        _messages[guid] = m;
      }
      if (m.threadOriginatorGuid != null && !guid.startsWith("temp") && !m.isReaction) {
        // add threaded messages
        _threads[m.threadOriginatorGuid!] ??= {};
        _threads[m.threadOriginatorGuid]![guid] = m;
      }
      if (_threads.keys.contains(guid)) {
        // add thread 'originator'
        _threads[guid]![guid] = m;
      }
      _attachments.addEntries(
        m.dbAttachments.where((e) => e.guid != null && e.guid!.isNotEmpty).map((e) => MapEntry(e.guid!, e)),
      );
    }
  }

  void removeMessage(String guid) {
    _messages.remove(guid);
    _reactions.remove(guid);
    final result = _threads.remove(guid);
    if (result == null) {
      for (Map element in _threads.values) {
        element.remove(guid);
      }
    }
    final result2 = _edits.remove(guid);
    if (result2 == null) {
      for (Map element in _edits.values) {
        element.remove(guid);
      }
    }
  }

  void removeAttachments(Iterable<String> guids) {
    for (String s in guids) {
      _attachments.remove(s);
    }
  }

  void addThreadOriginator(Message m) {
    _threads[m.guid!] ??= {};
    _threads[m.guid]![m.guid!] = m;
  }

  Message? getMessage(String guid) {
    return _messages[guid] ?? _reactions[guid];
  }

  Attachment? getAttachment(String guid) {
    return _attachments[guid];
  }

  // It isn't guaranteed that the thread originator will be in the regular
  // messages list, in case it is much older than the currently loaded messages.
  // Prefer to use this method to find originator.
  Message? getThreadOriginator(String guid) {
    final fromOriginatorList = _threads[guid]?[guid];
    if (fromOriginatorList == null) {
      final message = getMessage(guid);
      if (message != null) addThreadOriginator(message);
      return message;
    } else {
      return fromOriginatorList;
    }
  }

  Message? getPreviousReply(String threadGuid, int threadPart, String messageGuid) {
    final thread = threads(threadGuid, threadPart)..sort((a, b) => Message.sort(a, b, descending: false));
    final index = thread.indexWhere((element) => element.guid == messageGuid);
    if (index > 0) {
      return thread[index - 1];
    }
    return null;
  }

  void flush() {
    _messages.clear();
    _reactions.clear();
    _attachments.clear();
    _threads.clear();
    _edits.clear();
  }
}
