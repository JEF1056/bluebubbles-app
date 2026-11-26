import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/method_channel_service.dart';
import 'package:bluebubbles/services/network/method_channel_actions.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingMethodChannelService extends MethodChannelService {
  final List<(String, dynamic)> calls = [];

  @override
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) async {
    calls.add((method, arguments));
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Handoff draft and read sync tests', () {
    test('Notification deletion conditions when message dateRead updates', () {
      final existingUnread = Message(
        guid: 'msg-1',
        isFromMe: false,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(1000),
        dateRead: null,
      );

      final updatedRead = Message(
        guid: 'msg-1',
        isFromMe: false,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(1000),
        dateRead: DateTime.fromMillisecondsSinceEpoch(2000),
      );

      final shouldDelete = !(updatedRead.isFromMe ?? false) &&
          existingUnread.dateRead == null &&
          updatedRead.dateRead != null;

      expect(shouldDelete, isTrue);

      final outgoingMessage = Message(
        guid: 'msg-2',
        isFromMe: true,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(1000),
        dateRead: DateTime.fromMillisecondsSinceEpoch(2000),
      );

      final shouldDeleteOutgoing = !(outgoingMessage.isFromMe ?? false) &&
          existingUnread.dateRead == null &&
          outgoingMessage.dateRead != null;

      expect(shouldDeleteOutgoing, isFalse);
    });

    test('Draft text extraction from intent payload supports draftText and text', () {
      final intentWithDraft = <String, dynamic>{
        'chatGuid': 'chat-1',
        'draftText': 'Hello from Wear',
      };
      final draft1 = intentWithDraft['draftText'] ?? intentWithDraft['text'];
      expect(draft1, 'Hello from Wear');

      final intentWithText = <String, dynamic>{
        'chatGuid': 'chat-2',
        'text': 'Fallback text',
      };
      final draft2 = intentWithText['draftText'] ?? intentWithText['text'];
      expect(draft2, 'Fallback text');

      final intentWithoutDraft = <String, dynamic>{
        'chatGuid': 'chat-3',
      };
      final draft3 = intentWithoutDraft['draftText'] ?? intentWithoutDraft['text'];
      expect(draft3, isNull);
    });

    test('Android desktop-read dismissal sends NEW_MESSAGE_TAG and keepBubble', () async {
      final service = _RecordingMethodChannelService();
      final actions = MethodChannelActions(service);
      await actions.deleteNotification(
        notificationId: 42,
        tag: NotificationsService.NEW_MESSAGE_TAG,
        readBefore: 2000,
        keepBubble: true,
      );

      expect(NotificationsService.NEW_MESSAGE_TAG, 'com.bluebubbles.messaging.NEW_MESSAGE_NOTIFICATION');
      expect(service.calls, hasLength(1));
      expect(service.calls.single.$1, 'delete-notification');
      expect(service.calls.single.$2, {
        'notification_id': 42,
        'tag': NotificationsService.NEW_MESSAGE_TAG,
        'read_before': 2000,
        'keep_bubble': true,
      });
    });
  });
}
