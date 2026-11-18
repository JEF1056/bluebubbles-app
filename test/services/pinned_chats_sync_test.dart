import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/chat/chats_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatsService.extractPinnedChatGuids', () {
    test('parses REST response envelope and deduplicates preserving order', () {
      final guids = ChatsService.extractPinnedChatGuids({
        'status': 200,
        'data': {
          'pinnedChatGuids': ['chat-b', 'chat-a', 'chat-b', '', 42],
        },
      });
      expect(guids, ['chat-b', 'chat-a']);
    });

    test('parses socket pinned-chats-updated payload', () {
      final guids = ChatsService.extractPinnedChatGuids({
        'pinnedChatGuids': ['chat-1', 'chat-2'],
      });
      expect(guids, ['chat-1', 'chat-2']);
    });

    test('parses empty pinnedChatGuids list as empty (not null)', () {
      final guids = ChatsService.extractPinnedChatGuids({
        'data': {'pinnedChatGuids': <String>[]},
      });
      expect(guids, isEmpty);
    });

    test('returns null for missing or error payloads so local pins are preserved', () {
      expect(ChatsService.extractPinnedChatGuids(null), isNull);
      expect(ChatsService.extractPinnedChatGuids({'status': 404, 'message': 'Not found'}), isNull);
      expect(ChatsService.extractPinnedChatGuids({'data': <String, dynamic>{}}), isNull);
    });
  });

  group('ChatsService.computePinUpdates & Chat pin mapping/sort', () {
    test('computes pin, unpin, and reorder diffs against iOS pinnedChatGuids', () {
      final c1 = Chat(guid: 'g1', isPinned: true, pinnedIndex: 0);
      final c2 = Chat(guid: 'g2', isPinned: true, pinnedIndex: 1);
      final c3 = Chat(guid: 'g3', isPinned: false, pinnedIndex: null);
      final c4 = Chat(guid: 'g4', isPinned: false, pinnedIndex: null);

      // Reorder: g3 -> 0, g1 -> 1; g2 unpinned; g4 stays unpinned
      final updates = ChatsService.computePinUpdates([c1, c2, c3, c4], ['g3', 'g1']);
      expect(updates.length, 3);

      final byGuid = {for (final u in updates) u.chat.guid: u};
      expect(byGuid['g3']?.isPinned, isTrue);
      expect(byGuid['g3']?.pinIndex, 0);
      expect(byGuid['g1']?.isPinned, isTrue);
      expect(byGuid['g1']?.pinIndex, 1);
      expect(byGuid['g2']?.isPinned, isFalse);
      expect(byGuid['g2']?.pinIndex, isNull);
      expect(byGuid.containsKey('g4'), isFalse);
    });

    test('Chat.fromMap reads server pinIndex as well as local _pinIndex', () {
      final fromServer = Chat.fromMap({
        'guid': 'iMessage;-;+15551234567',
        'chatIdentifier': '+15551234567',
        'isPinned': true,
        'pinIndex': 2,
      });
      expect(fromServer.isPinned, isTrue);
      expect(fromServer.pinIndex, 2);

      final fromLocal = Chat.fromMap({
        'guid': 'iMessage;-;+15551234567',
        'chatIdentifier': '+15551234567',
        'isPinned': true,
        '_pinIndex': 1,
      });
      expect(fromLocal.pinIndex, 1);
    });

    test('Chat.sort puts pinned chats first by pinIndex regardless of older message date', () {
      final oldPinnedFirst = Chat(guid: 'pin0', isPinned: true, pinnedIndex: 0)
        ..dbOnlyLatestMessageDate = DateTime.fromMillisecondsSinceEpoch(1000);
      final newerPinnedSecond = Chat(guid: 'pin1', isPinned: true, pinnedIndex: 1)
        ..dbOnlyLatestMessageDate = DateTime.fromMillisecondsSinceEpoch(5000);
      final newestUnpinned = Chat(guid: 'recent', isPinned: false, pinnedIndex: null)
        ..dbOnlyLatestMessageDate = DateTime.fromMillisecondsSinceEpoch(9000);
      final olderUnpinned = Chat(guid: 'older', isPinned: false, pinnedIndex: null)
        ..dbOnlyLatestMessageDate = DateTime.fromMillisecondsSinceEpoch(2000);

      final list = [olderUnpinned, newerPinnedSecond, newestUnpinned, oldPinnedFirst];
      list.sort(Chat.sort);

      expect(list.map((c) => c.guid).toList(), ['pin0', 'pin1', 'recent', 'older']);
    });
  });
}
