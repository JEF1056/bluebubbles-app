import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/action_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ActionHandler.extractReadBefore', () {
    test('prefers readAt over lastReadMessageTimestamp', () {
      expect(
        ActionHandler.extractReadBefore({
          'readAt': 1761629708971,
          'lastReadMessageTimestamp': 1761629700000,
        }),
        1761629708971,
      );
    });

    test('falls back to lastReadMessageTimestamp when readAt is null or non-positive', () {
      expect(
        ActionHandler.extractReadBefore({
          'readAt': null,
          'lastReadMessageTimestamp': 1761629700000,
        }),
        1761629700000,
      );
      expect(
        ActionHandler.extractReadBefore({
          'readAt': 0,
          'lastReadMessageTimestamp': 1761629700000,
        }),
        1761629700000,
      );
      expect(
        ActionHandler.extractReadBefore({
          'readAt': -5,
          'lastReadMessageTimestamp': 1761629700000,
        }),
        1761629700000,
      );
    });

    test('parses double and numeric string timestamps safely', () {
      expect(
        ActionHandler.extractReadBefore({'readAt': 1761629708971.0}),
        1761629708971,
      );
      expect(
        ActionHandler.extractReadBefore({'readAt': '1761629708971'}),
        1761629708971,
      );
      expect(
        ActionHandler.extractReadBefore({
          'readAt': 'not-a-timestamp',
          'lastReadMessageTimestamp': ' 1761629700000 ',
        }),
        1761629700000,
      );
    });

    test('returns null when neither timestamp is valid and positive', () {
      expect(ActionHandler.extractReadBefore(<String, dynamic>{}), isNull);
      expect(ActionHandler.extractReadBefore({'readAt': 0, 'lastReadMessageTimestamp': 0}), isNull);
      expect(ActionHandler.extractReadBefore({'readAt': 'bad', 'lastReadMessageTimestamp': -1}), isNull);
    });
  });

  group('Chat.clearNotificationsForPartialRead guard conditions', () {
    test('returns false when readBefore is null or chat has no latest message', () async {
      final chat = Chat(guid: 'iMessage;-;+15551234567');
      expect(await chat.clearNotificationsForPartialRead(null), isFalse);
      expect(await chat.clearNotificationsForPartialRead(1761629708971), isFalse);
    });

    test('returns false when latest message is from me, already read, or covered by readBefore', () async {
      final chat = Chat(guid: 'iMessage;-;+15551234567');

      chat.dbLatestMessage.target = Message(
        guid: 'm-from-me',
        isFromMe: true,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      expect(await chat.clearNotificationsForPartialRead(1000), isFalse);

      chat.dbLatestMessage.target = Message(
        guid: 'm-already-read',
        isFromMe: false,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(2000),
        dateRead: DateTime.fromMillisecondsSinceEpoch(2500),
      );
      expect(await chat.clearNotificationsForPartialRead(1000), isFalse);

      chat.dbLatestMessage.target = Message(
        guid: 'm-covered',
        isFromMe: false,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      expect(await chat.clearNotificationsForPartialRead(1000), isFalse);
      expect(await chat.clearNotificationsForPartialRead(1500), isFalse);
    });
  });
}
