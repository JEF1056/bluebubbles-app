import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/material_conversation_tile.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MaterialTrailing.computeUnreadCount', () {
    test('returns 1 when chat.id is null', () {
      final chat = Chat(guid: 'iMessage;-;+15550001111');
      expect(MaterialTrailing.computeUnreadCount(chat, null), 1);
    });

    test('counts incoming non-associated messages until lastReadGuid', () {
      final chat = Chat(id: 42, guid: 'RCS;-;+15550002222');
      final msgs = [
        Message(guid: 'm-4', isFromMe: false),
        Message(guid: 'm-3', isFromMe: false, associatedMessageGuid: 'm-1'),
        Message(guid: 'm-2', isFromMe: true),
        Message(guid: 'm-1', isFromMe: false),
        Message(guid: 'm-read', isFromMe: false),
        Message(guid: 'm-older', isFromMe: false),
      ];

      final count = MaterialTrailing.computeUnreadCount(
        chat,
        'm-read',
        fetchMessages: (c, {int limit = 25}) => msgs,
      );
      expect(count, 2);
    });

    test('falls back to 1 when no incoming unread messages match', () {
      final chat = Chat(id: 7, guid: 'iMessage;-;+15550003333');
      final count = MaterialTrailing.computeUnreadCount(
        chat,
        'm-1',
        fetchMessages: (c, {int limit = 25}) => [Message(guid: 'm-1', isFromMe: false)],
      );
      expect(count, 1);
    });

    test('falls back to 1 if message fetch throws', () {
      final chat = Chat(id: 9, guid: 'iMessage;-;+15550004444');
      final count = MaterialTrailing.computeUnreadCount(
        chat,
        null,
        fetchMessages: (c, {int limit = 25}) => throw StateError('db unavailable'),
      );
      expect(count, 1);
    });
  });

  group('WebConnectivityBanner', () {
    testWidgets('hides when online and not reconnecting', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WebConnectivityBanner(onlineOverride: true, reconnectingOverride: false),
          ),
        ),
      );
      expect(find.text('Offline · Retry'), findsNothing);
      expect(find.text('Reconnecting…'), findsNothing);
    });

    testWidgets('shows offline tonal pill when offline and invokes retry on tap', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WebConnectivityBanner(
              onlineOverride: false,
              reconnectingOverride: false,
              onRetry: () => retried = true,
            ),
          ),
        ),
      );
      expect(find.text('Offline · Retry'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
      await tester.tap(find.text('Offline · Retry'));
      expect(retried, isTrue);
    });

    testWidgets('shows reconnecting pill when online and reconnecting', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WebConnectivityBanner(onlineOverride: true, reconnectingOverride: true),
          ),
        ),
      );
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
