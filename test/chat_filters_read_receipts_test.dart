import 'package:bluebubbles/database/io/chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS chat filters and per-chat read receipts parsing', () {
    test('extracts EnableReadReceiptForChat override from plist properties list', () {
      expect(
        Chat.readReceiptsOverrideInProperties([
          {'EnableReadReceiptForChat': true},
        ]),
        isTrue,
      );
      expect(
        Chat.readReceiptsOverrideInProperties([
          {'EnableReadReceiptForChat': false},
        ]),
        isFalse,
      );
      expect(
        Chat.readReceiptsOverrideInProperties([
          {'wasDetectedAsSMSSpam': false},
        ]),
        isNull,
      );
      expect(Chat.readReceiptsOverrideInProperties(null), isNull);
    });

    test('archives iOS-filtered and spam chats unless pinned', () {
      final filtered = Chat.fromMap({
        'guid': 'any;-;93733(smsft)',
        'chatIdentifier': '93733(smsft)',
        'isArchived': false,
        'isFiltered': true,
        'isFilteredAsSpam': false,
        'isPinned': false,
      });
      expect(filtered.isArchived, isTrue);

      final spam = Chat.fromMap({
        'guid': 'any;-;+15752845644',
        'chatIdentifier': '+15752845644',
        'isArchived': false,
        'isFiltered': false,
        'isFilteredAsSpam': true,
        'isPinned': false,
      });
      expect(spam.isArchived, isTrue);

      final pinned = Chat.fromMap({
        'guid': 'any;-;+16266165776',
        'chatIdentifier': '+16266165776',
        'isArchived': false,
        'isFiltered': true,
        'isPinned': true,
        'properties': [
          {'EnableReadReceiptForChat': true},
        ],
      });
      expect(pinned.isArchived, isFalse);
      expect(pinned.autoSendReadReceipts, isTrue);

      final normal = Chat.fromMap({
        'guid': 'any;-;+12135567020',
        'chatIdentifier': '+12135567020',
        'isArchived': false,
        'isFiltered': false,
        'isFilteredAsSpam': false,
        'properties': [
          {'numberOfTimesRespondedtoThread': 3},
        ],
      });
      expect(normal.isArchived, isFalse);
      expect(normal.autoSendReadReceipts, isNull);
    });
  });
}
