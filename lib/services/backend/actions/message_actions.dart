import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/reaction_helpers.dart';
import 'package:bluebubbles/helpers/types/helpers/message_helper.dart';
import 'package:bluebubbles/helpers/types/helpers/misc_helpers.dart';
import 'package:bluebubbles/utils/logger/logger.dart';

class MessageActions {
  /// Marks the turns of [turn]'s iMessage app session that it replaced as [AppSessionTypes.SUPERSEDED], linked to the
  /// session's first message (which links to itself), as Messages does once a newer turn arrives. Messages rewrites
  /// those rows in place, so sync, which only fetches new rows, would never see it. Which rows count is
  /// [AppSessionTypes.isReplacedBy], shared with the on-screen copy in MessagesService. Runs inside a write transaction.
  /// Returns the rows it rewrote, so a caller holding its own copies of them can match.
  static List<Message> retireEarlierTurns(Message turn) {
    if (!AppSessionTypes.replacesEarlierTurns(turn)) return const [];
    final first = turn.associatedMessageGuid!;
    final query = Database.messages
        .query((Message_.guid.equals(first) | Message_.associatedMessageGuid.equals(first)) &
            Message_.guid.notEquals(turn.guid!) &
            Message_.dateCreated.lessThan(turn.dateCreated!.millisecondsSinceEpoch))
        .build();
    final earlier = query.find().where((m) => AppSessionTypes.isReplacedBy(m, turn)).toList();
    query.close();
    for (final message in earlier) {
      message.associatedMessageType = AppSessionTypes.SUPERSEDED;
      message.associatedMessageGuid = first;
    }
    if (earlier.isNotEmpty) Database.messages.putMany(earlier);
    return earlier;
  }

  static Future<List<Message>?> getMessages() async {
    // Fetch a message with a limit of 1 using ObjectBox
    final oneDayAgo = DateTime.now().subtract(const Duration(days: 1));
    final query = Database.messages
        .query(Message_.dateCreated.greaterThan(oneDayAgo.millisecondsSinceEpoch))
        .build();
    try {
      final messages = await query.findAsync();
      if (messages.isNotEmpty) {
        return messages;
      }
      return null;
    } finally {
      query.close();
    }
  }

  static Future<int> replaceMessage(dynamic data) async {
    final oldGuid = data['oldGuid'] as String?;
    final newMessageData = data['newMessageData'] as Map<String, dynamic>;

    return Database.runInTransaction(TxMode.write, () {
      final messageBox = Database.messages;
      final inputNewMessage = Message.fromMap(newMessageData);

      // Find existing message
      final query = messageBox.query(Message_.guid.equals(oldGuid ?? '')).build();
      query.limit = 1;
      final existing = query.findFirst();
      query.close();

      if (existing == null) {
        throw Exception("Cannot replace on a null existing message!!");
      }

      if (inputNewMessage.guid == null || inputNewMessage.guid!.isEmpty) {
        Logger.error(
          'Refusing to replace message ${existing.guid} with null or empty GUID',
          tag: 'MessageActions',
        );
        return existing.id!;
      }

      // Guard against a race: another async path (e.g. socket new-message) may
      // have already inserted inputNewMessage.guid before this transaction ran.
      // If so, merge into the existing real-GUID row, remove the stale temp row,
      // and return the real row's ID (matching AttachmentActions.replaceAttachmentAsync).
      final conflictingQuery = messageBox.query(Message_.guid.equals(inputNewMessage.guid!)).build();
      conflictingQuery.limit = 1;
      final conflicting = conflictingQuery.findFirst();
      conflictingQuery.close();

      if (conflicting != null && conflicting.id != existing.id) {
        _applyReplacementFields(conflicting, inputNewMessage, preserveDelivered: true);
        messageBox.put(conflicting, mode: PutMode.update);
        retireEarlierTurns(conflicting);
        messageBox.remove(existing.id!);
        return conflicting.id!;
      }

      if (existing.guid != inputNewMessage.guid) {
        existing.guid = inputNewMessage.guid;
      }
      _applyReplacementFields(existing, inputNewMessage);

      try {
        messageBox.put(existing, mode: PutMode.update);
        // Our own turn is saved here, when its temp GUID is swapped for the real one
        retireEarlierTurns(existing);
      } catch (ex) {
        Logger.warn(
            'Failed to replace message! This is likely due to a unique constraint being violated: ${ex.toString()}');
      }

      // Return just the ID for efficient transfer across isolates
      return existing.id!;
    });
  }

  static void _applyReplacementFields(
    Message target,
    Message source, {
    bool preserveDelivered = false,
  }) {
    // Before the text and edit date: whether formatting is kept depends on whether they changed
    target.takeOmittableFieldsFrom(source);
    if (source.text != null) {
      target.text = source.text;
    }

    target.dateDelivered = source.dateDelivered ?? target.dateDelivered;
    target.isDelivered = preserveDelivered ? (target.isDelivered || source.isDelivered) : source.isDelivered;
    target.dateRead = source.dateRead ?? target.dateRead;
    target.dateEdited = source.dateEdited ?? target.dateEdited;
    target.wasDeliveredQuietly = source.wasDeliveredQuietly ? source.wasDeliveredQuietly : target.wasDeliveredQuietly;
    target.didNotifyRecipient = source.didNotifyRecipient ? source.didNotifyRecipient : target.didNotifyRecipient;
    target.error = source.error;
    target.errorMessage = source.errorMessage;
    // An iMessage app turn is re-linked when a newer turn replaces it (type 2 to 3, or a first turn to itself), and
    // never back: a stale copy that still says type 2 leaves a replaced turn as it is
    final type = AppSessionTypes.mergedType(
        target.balloonBundleId ?? source.balloonBundleId, target.associatedMessageType, source.associatedMessageType);
    if (type == source.associatedMessageType) {
      target.associatedMessageGuid = source.associatedMessageGuid ?? target.associatedMessageGuid;
    }
    target.associatedMessageType = type;
    target.metadata = mergeTopLevelDicts(target.metadata, source.metadata);
    if (source.metadata?['translation'] != null) {
      target.metadata ??= {};
      target.metadata!['translation'] = source.metadata!['translation'];
    }
  }

  static Future<void> deleteMessage(dynamic data) async {
    final guid = data['guid'] as String;

    Database.runInTransaction(TxMode.write, () {
      final messageBox = Database.messages;

      final query = messageBox.query(Message_.guid.equals(guid)).build();
      final result = query.findFirst();
      query.close();
      if (result?.id != null) {
        messageBox.remove(result!.id!);
      }
    });
  }

  static Future<void> softDeleteMessage(dynamic data) async {
    final guid = data['guid'] as String;

    Database.runInTransaction(TxMode.write, () {
      final messageBox = Database.messages;

      final query = messageBox.query(Message_.guid.equals(guid)).build();
      query.limit = 1;
      final toDelete = query.findFirst();
      query.close();

      if (toDelete != null) {
        toDelete.dateDeleted = DateTime.now().toUtc();
        messageBox.put(toDelete);
      }
    });
  }

  static Future<Map<String, dynamic>> fetchAssociatedMessagesAsync(dynamic data) async {
    final messageGuid = data['messageGuid'] as String;
    final threadOriginatorGuid = data['threadOriginatorGuid'] as String?;

    return Database.runInTransaction(TxMode.read, () {
      final messageBox = Database.messages;

      // Fetch associated messages (reactions)
      final query = messageBox.query(Message_.associatedMessageGuid.equals(messageGuid)).build();
      List<Message> associatedMessages = query.find();
      query.close();

      associatedMessages = MessageHelper.normalizedAssociatedMessages(associatedMessages);

      // If there's a thread originator, fetch it
      if (threadOriginatorGuid != null) {
        final originatorQuery = messageBox.query(Message_.guid.equals(threadOriginatorGuid)).build();
        originatorQuery.limit = 1;
        final threadOriginator = originatorQuery.findFirst();
        originatorQuery.close();

        if (threadOriginator != null) {
          associatedMessages.add(threadOriginator);
        }
      }

      associatedMessages.sort((a, b) => (a.originalROWID ?? 0).compareTo(b.originalROWID ?? 0));

      return {
        'associatedMessages': associatedMessages.map((e) => e.toMap()).toList(),
      };
    });
  }

  static Future<int> saveMessageAsync(dynamic data) async {
    final messageData = data['messageData'] as Map<String, dynamic>;
    final chatData = data['chatData'] as Map<String, dynamic>?;
    final updateIsBookmarked = data['updateIsBookmarked'] as bool;

    return Database.runInTransaction(TxMode.write, () {
      final messageBox = Database.messages;
      final handleBox = Database.handles;

      final inputMessage = Message.fromMap(messageData);
      final inputChat = chatData != null ? Chat.fromMap(chatData) : null;

      // Find existing message
      final existingQuery = messageBox.query(Message_.guid.equals(inputMessage.guid ?? '')).build();
      existingQuery.limit = 1;
      final existing = existingQuery.findFirst();
      existingQuery.close();

      if (existing != null) {
        inputMessage.id = existing.id;
        inputMessage.text ??= existing.text;

        // Preserve existing handleRelation if available
        if (existing.handleRelation.hasValue && !inputMessage.handleRelation.hasValue) {
          inputMessage.handleRelation.target = existing.handleRelation.target;
          inputMessage.handle = existing.handleRelation.target;
        }

        // Preserve the chat relationship. inputMessage is rebuilt from a map, so its chat
        // relation is empty, and putting it over the existing row without a chat would
        // unlink the message from its chat and drop it from the conversation.
        if (inputChat == null && existing.chat.hasValue) {
          inputMessage.chat.targetId = existing.chat.targetId;
        }
      }

      // Save the participant & set the handle ID to the new participant
      // Only do handleId lookup if we don't already have a handleRelation
      if (inputMessage.handle == null && !inputMessage.handleRelation.hasValue && inputMessage.handleId != null) {
        final handleQuery = handleBox.query(Handle_.originalROWID.equals(inputMessage.handleId!)).build();
        handleQuery.limit = 1;
        final foundHandle = handleQuery.findFirst();
        handleQuery.close();
        inputMessage.handle = foundHandle;

        // Set up handleRelation for the ToOne relationship
        if (foundHandle != null && foundHandle.id != null) {
          inputMessage.handleRelation.target = foundHandle;
        }
      } else if (inputMessage.handleRelation.hasValue && inputMessage.handle == null) {
        // Use existing relationship to populate handle field
        inputMessage.handle = inputMessage.handleRelation.target;
      }

      // Save associated messages or the original message (depending on whether
      // this message is a reaction or regular message
      if (inputMessage.associatedMessageType != null && inputMessage.isReaction) {
        final associatedQuery = messageBox.query(Message_.guid.equals(inputMessage.associatedMessageGuid!)).build();
        associatedQuery.limit = 1;
        final associatedMessage = associatedQuery.findFirst();
        associatedQuery.close();

        if (associatedMessage != null) {
          associatedMessage.hasReactions = true;
          messageBox.put(associatedMessage);
        }
      } else if (!inputMessage.hasReactions) {
        final reactionQuery = messageBox.query(Message_.associatedMessageGuid.equals(inputMessage.guid ?? '')).build();
        reactionQuery.limit = 1;
        final reaction = reactionQuery.findFirst();
        reactionQuery.close();

        if (reaction != null) {
          inputMessage.hasReactions = true;
        }
      }

      if (!updateIsBookmarked) {
        inputMessage.isBookmarked = existing?.isBookmarked ?? inputMessage.isBookmarked;
      }

      try {
        if (inputChat != null) inputMessage.chat.target = inputChat;
        inputMessage.id = messageBox.put(inputMessage);
      } on UniqueViolationException catch (_) {
        final conflictQuery = messageBox.query(Message_.guid.equals(inputMessage.guid ?? '')).build();
        conflictQuery.limit = 1;
        final conflict = conflictQuery.findFirst();
        conflictQuery.close();
        if (conflict?.id == null) rethrow;
        inputMessage.id = conflict!.id;
      }

      // Return just the ID for efficient transfer across isolates
      return inputMessage.id!;
    });
  }

  static Future<int?> findOneAsync(dynamic data) async {
    final guid = data['guid'] as String?;
    final associatedMessageGuid = data['associatedMessageGuid'] as String?;

    return Database.runInTransaction(TxMode.read, () {
      final messageBox = Database.messages;

      Message? result;

      if (guid != null) {
        final query = messageBox.query(Message_.guid.equals(guid)).build();
        query.limit = 1;
        result = query.findFirst();
        query.close();
      } else if (associatedMessageGuid != null) {
        // Looks for a reaction to that message
        final query = messageBox
            .query(Message_.associatedMessageGuid.equals(associatedMessageGuid) & Message.reactionCondition)
            .build();
        query.limit = 1;
        result = query.findFirst();
        query.close();
      }

      // Return just the ID for efficient transfer across isolates
      return result?.id;
    });
  }

  static Future<List<int>> findAsync(dynamic data) async {
    // For now, we'll support finding all messages
    // A more sophisticated implementation would deserialize the condition JSON
    return Database.runInTransaction(TxMode.read, () {
      final messageBox = Database.messages;

      final query = messageBox.query().build();
      final results = query.find();
      query.close();

      // Return just the IDs for efficient transfer across isolates
      return results.map((e) => e.id!).toList();
    });
  }

  /// Re-links messages whose `handleId` (the sender's server-side ROWID)
  /// matches `serverHandleId` to `localHandleId`'s `handleRelation`.
  ///
  /// Mirrors `MessageHandleRelationshipMigration` — a message never gets a
  /// `handleRelation` if its `handleId` didn't match a `Handle.originalROWID`
  /// at save time (see "Handle Auditing" in Developer Tools). Scoped to a
  /// single server ROWID instead of a full-table scan since this only runs
  /// right after that one handle's `originalROWID` was repaired.
  static Future<int> relinkMessagesToHandle(dynamic data) async {
    final serverHandleId = data['handleId'] as int;
    final localHandleId = data['localHandleId'] as int;

    return Database.runInTransaction(TxMode.write, () {
      final messageBox = Database.messages;

      final query = messageBox.query(Message_.handleId.equals(serverHandleId)).build();
      final matches = query.find();
      query.close();

      final toUpdate = <Message>[];
      for (final message in matches) {
        if (message.isFromMe == true) continue;
        if (message.handleRelation.targetId == localHandleId) continue;
        message.handleRelation.targetId = localHandleId;
        toUpdate.add(message);
      }

      if (toUpdate.isNotEmpty) {
        messageBox.putMany(toUpdate);
      }

      return toUpdate.length;
    });
  }
}
