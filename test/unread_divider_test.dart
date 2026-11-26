import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/unread_separator.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/send_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

Message _msg(
  String guid,
  int epochMs, {
  bool isFromMe = false,
  bool? isRead,
  DateTime? dateRead,
  String? associatedMessageGuid,
  String? associatedMessageType,
  int itemType = 0,
}) {
  return Message(
    guid: guid,
    dateCreated: DateTime.fromMillisecondsSinceEpoch(epochMs),
    isFromMe: isFromMe,
    isRead: isRead,
    dateRead: dateRead,
    associatedMessageGuid: associatedMessageGuid,
    associatedMessageType: associatedMessageType,
    itemType: itemType,
  );
}

void main() {
  group('Chat.lastReadAt transient parsing', () {
    test('parses positive lastReadMessageTimestamp and ignores 0/null', () {
      final c1 = Chat.fromMap({
        'guid': 'iMessage;-;+15551234567',
        'lastReadMessageTimestamp': 1700000000000,
      });
      expect(c1.lastReadAt, 1700000000000);
      expect(c1.toMap()['lastReadMessageTimestamp'], 1700000000000);

      final cZero = Chat.fromMap({
        'guid': 'iMessage;-;+15551234567',
        'lastReadMessageTimestamp': 0,
      });
      expect(cZero.lastReadAt, isNull);

      final cNull = Chat.fromMap({
        'guid': 'iMessage;-;+15551234567',
      });
      expect(cNull.lastReadAt, isNull);
    });

    test('merge keeps newer lastReadAt', () {
      final a = Chat(guid: 'g1', lastReadAt: 1000);
      final b = Chat(guid: 'g1', lastReadAt: 2000);
      a.merge(b);
      expect(a.lastReadAt, 2000);
    });
  });

  group('ConversationViewController.computeUnreadDividerGuid', () {
    test('returns null when hasUnread is false or messages empty', () {
      expect(
        ConversationViewController.computeUnreadDividerGuid(
          messages: [_msg('m1', 1000)],
          hasUnread: false,
        ),
        isNull,
      );
      expect(
        ConversationViewController.computeUnreadDividerGuid(
          messages: const [],
          hasUnread: true,
        ),
        isNull,
      );
    });

    test('picks oldest unread incoming message after max(lastReadAt, lastReadMessageDateMs)', () {
      final messages = [
        _msg('m5', 5000),
        _msg('m4', 4000),
        _msg('m3', 3000),
        _msg('m2', 2000),
        _msg('m1', 1000, isFromMe: true),
      ];

      expect(
        ConversationViewController.computeUnreadDividerGuid(
          messages: messages,
          hasUnread: true,
          lastReadAt: 2000,
          lastReadMessageDateMs: 3000,
        ),
        'm4',
      );

      expect(
        ConversationViewController.computeUnreadDividerGuid(
          messages: messages,
          hasUnread: true,
          lastReadAt: 3000,
          lastReadMessageDateMs: 2000,
        ),
        'm4',
      );
    });

    test('skips reactions, group events, outgoing, and already-read messages (dateRead or isRead)', () {
      final messages = [
        _msg('m6', 6000),
        _msg('m5_isread', 5000, isRead: true),
        _msg('m4_group', 4000, itemType: 1),
        _msg('m3_react', 3000, associatedMessageGuid: 'm1', associatedMessageType: 'love'),
        _msg('m2_read', 2000, dateRead: DateTime.fromMillisecondsSinceEpoch(2500)),
        _msg('m1', 1000, isFromMe: true),
      ];

      expect(
        ConversationViewController.computeUnreadDividerGuid(
          messages: messages,
          hasUnread: true,
          lastReadAt: 1000,
        ),
        'm6',
      );
    });

    test('falls back to contiguous incoming run after latest isFromMe when boundary is null or Mac mark-unread', () {
      final messages = [
        _msg('m5', 5000, dateRead: DateTime.fromMillisecondsSinceEpoch(5100)),
        _msg('m4', 4000, dateRead: DateTime.fromMillisecondsSinceEpoch(4100)),
        _msg('m3_me', 3000, isFromMe: true),
        _msg('m2', 2000),
      ];

      // Boundary null -> fallback to contiguous incoming run after m3_me -> m4.
      expect(
        ConversationViewController.computeUnreadDividerGuid(
          messages: messages,
          hasUnread: true,
        ),
        'm4',
      );

      // Mac Mark as Unread: lastReadMessageDateMs == 5000 (newest) & dateRead != null -> fallback -> m4.
      expect(
        ConversationViewController.computeUnreadDividerGuid(
          messages: messages,
          hasUnread: true,
          lastReadMessageDateMs: 5000,
        ),
        'm4',
      );
    });
  });

  group('ConversationViewController unreadDividerGuid lifecycle', () {
    tearDown(() {
      Get.reset();
    });

    test('computes once on initUnreadDivider and clears on clearUnreadDivider / send', () async {
      final chat = Chat(guid: 'iMessage;-;+15550001111', hasUnreadMessage: true, lastReadAt: 1000);
      final controller = ConversationViewController(chat);
      final msgs = [_msg('m2', 2000), _msg('m1', 1000, isFromMe: true)];

      controller.initUnreadDivider(msgs);
      expect(controller.unreadDividerGuid.value, 'm2');

      // Subsequent call does not recompute.
      controller.clearUnreadDivider();
      expect(controller.unreadDividerGuid.value, isNull);
      controller.initUnreadDivider(msgs);
      expect(controller.unreadDividerGuid.value, isNull);

      // Reset via fresh controller and verify send() clears it.
      final controller2 = ConversationViewController(chat);
      controller2.initUnreadDivider(msgs);
      expect(controller2.unreadDividerGuid.value, 'm2');
      await controller2.send(const SendData(attachments: [], text: 'hi', subject: ''));
      expect(controller2.unreadDividerGuid.value, isNull);
    });

    test('snapshots _hadUnreadOnOpen before local badge clear and blocks late init after _readSent', () {
      final chat = Chat(guid: 'iMessage;-;+15550002222', hasUnreadMessage: true, lastReadAt: 1000);
      final controller = ConversationViewController(chat);
      // Simulate setActiveChatSync microtask clearing local badge before loadChunk finishes.
      chat.hasUnreadMessage = false;

      final msgs = [_msg('m2', 2000), _msg('m1', 1000, isFromMe: true)];
      controller.initUnreadDivider(msgs);
      expect(controller.unreadDividerGuid.value, 'm2');

      // If clearUnreadDivider() was called before initUnreadDivider() (read already sent),
      // late initUnreadDivider() must not re-show the divider.
      final chat2 = Chat(guid: 'iMessage;-;+15550003333', hasUnreadMessage: true, lastReadAt: 1000);
      final controller2 = ConversationViewController(chat2);
      controller2.clearUnreadDivider();
      controller2.initUnreadDivider(msgs);
      expect(controller2.unreadDividerGuid.value, isNull);
    });

    test('snapshotUnreadOnOpen refreshes unread state on pre-registered controller', () {
      final chat = Chat(guid: 'iMessage;-;+15550004444', hasUnreadMessage: false, lastReadAt: 1000);
      final controller = ConversationViewController(chat);
      chat.hasUnreadMessage = true;
      controller.snapshotUnreadOnOpen();
      chat.hasUnreadMessage = false;

      final msgs = [
        _msg('m-new', 2000, isFromMe: false),
        _msg('m-old', 1000, isFromMe: false),
      ];
      controller.initUnreadDivider(msgs);
      expect(controller.unreadDividerGuid.value, 'm-new');
    });

    test('scheduleAutoMarkRead clears unread divider after delay or on user interaction', () async {
      final chat = Chat(guid: 'iMessage;-;+15550005555', hasUnreadMessage: true, lastReadAt: 1000);
      final controller = ConversationViewController(chat);
      final msgs = [_msg('m2', 2000), _msg('m1', 1000, isFromMe: true)];
      controller.initUnreadDivider(msgs);
      expect(controller.unreadDividerGuid.value, 'm2');

      // Delay clears unread divider once elapsed.
      controller.scheduleAutoMarkRead(delay: const Duration(milliseconds: 30));
      expect(controller.unreadDividerGuid.value, 'm2');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controller.unreadDividerGuid.value, isNull);

      // User interaction within the delay window also clears it immediately.
      final chat2 = Chat(guid: 'iMessage;-;+15550006666', hasUnreadMessage: true, lastReadAt: 1000);
      final controller2 = ConversationViewController(chat2);
      controller2.initUnreadDivider(msgs);
      expect(controller2.unreadDividerGuid.value, 'm2');
      controller2.scheduleAutoMarkRead(delay: const Duration(seconds: 10));
      controller2.onUserChatInteraction(immediate: true);
      expect(controller2.unreadDividerGuid.value, isNull);
      controller2.onClose();
    });
  });

  group('UnreadSeparator widget', () {
    testWidgets('renders hairlines, primary color, typography, and margins', (tester) async {
      const primary = Color(0xFF123456);
      final theme = ThemeData(
        colorScheme: const ColorScheme.light(primary: primary),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Column(
              children: [
                UnreadSeparator(hasTimestampBelow: false),
                UnreadSeparator(hasTimestampBelow: true),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Unread'), findsNWidgets(2));

      final textWidget = tester.widget<Text>(find.text('Unread').first);
      expect(textWidget.style?.color, primary);
      expect(textWidget.style?.fontSize, 12.0);
      expect(textWidget.style?.height, 16.0 / 12.0);
      expect(textWidget.style?.letterSpacing, 0.4);
      expect(textWidget.style?.fontWeight, FontWeight.w400);

      final paddings = tester.widgetList<Padding>(find.byType(Padding)).toList();
      expect(
        paddings.any((p) => p.padding == const EdgeInsets.only(top: 16.0, bottom: 16.0)),
        isTrue,
      );
      expect(
        paddings.any((p) => p.padding == const EdgeInsets.only(top: 16.0, bottom: 8.0)),
        isTrue,
      );
    });
  });
}
