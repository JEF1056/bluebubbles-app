import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/classes/chat_service_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatServiceType RCS support', () {
    test('rcs is visible and has RCS label and method', () {
      expect(ChatServiceType.rcs.isVisible, isTrue);
      expect(ChatServiceType.rcs.label, 'RCS');
      expect(ChatServiceType.rcs.method, 'RCS');
      expect(ChatServiceType.rcs.isRcsService, isTrue);
      expect(ChatServiceType.rcs.isIMessageService, isFalse);
    });

    test('fromServiceName parses RCS, iMessage, SMS case-insensitively', () {
      expect(ChatServiceType.fromServiceName('RCS'), ChatServiceType.rcs);
      expect(ChatServiceType.fromServiceName(' rcs '), ChatServiceType.rcs);
      expect(ChatServiceType.fromServiceName('iMessage'), ChatServiceType.iMessage);
      expect(ChatServiceType.fromServiceName('SMS'), ChatServiceType.sms);
      expect(ChatServiceType.fromServiceName('Text Forwarding'), ChatServiceType.sms);
      expect(ChatServiceType.fromServiceName(null), isNull);
      expect(ChatServiceType.fromServiceName(''), isNull);
      expect(ChatServiceType.fromServiceName('unknown'), isNull);
    });

    test('fromGuid parses RCS prefix', () {
      expect(ChatServiceType.fromGuid('RCS;-;+15551234567'), ChatServiceType.rcs);
      expect(ChatServiceType.fromGuid('SMS;-;+15551234567'), ChatServiceType.sms);
      expect(ChatServiceType.fromGuid('iMessage;-;+15551234567'), ChatServiceType.iMessage);
    });
  });

  group('Chat & Message RCS resolution', () {
    test('unified any;-; chat resolves RCS from serviceName', () {
      final chat = Chat.fromMap({
        'guid': 'any;-;+15551234567',
        'serviceName': 'RCS',
        'participants': [],
      });

      expect(chat.serviceName, 'RCS');
      expect(chat.service, ChatServiceType.rcs);
      expect(chat.isRCS, isTrue);
      expect(chat.isIMessage, isFalse);
      expect(chat.isSMS, isFalse);
      expect(chat.toMap()['serviceName'], 'RCS');
    });

    test('unified any;-; chat falls back to participant service when serviceName is null', () {
      final chat = Chat.fromMap({
        'guid': 'any;-;+15551234567',
        'participants': [
          {'address': '+15551234567', 'service': 'RCS'},
        ],
      });

      expect(chat.service, ChatServiceType.rcs);
      expect(chat.isRCS, isTrue);
    });

    test('Chat.merge preserves serviceName', () {
      final existing = Chat(guid: 'any;-;+15551234567');
      final incoming = Chat(guid: 'any;-;+15551234567', serviceName: 'RCS');
      existing.merge(incoming);

      expect(existing.serviceName, 'RCS');
      expect(existing.isRCS, isTrue);
    });

    test('unified any;-; chat prefers latestMessage service over stale chat.serviceName', () {
      final chat = Chat.fromMap({
        'guid': 'any;-;+16266165776',
        'serviceName': 'SMS',
      });
      chat.dbLatestMessage.target = Message.fromMap({
        'guid': 'msg-imsg-1',
        'service': 'iMessage',
        'text': 'Sigh',
      });

      expect(chat.service, ChatServiceType.iMessage);
      expect(chat.isIMessage, isTrue);
      expect(chat.isSMS, isFalse);
    });

    test('Message.fromMap and toMap preserve service', () {
      final msg = Message.fromMap({
        'guid': 'msg-1',
        'service': 'RCS',
        'text': 'Hello via RCS',
      });

      expect(msg.service, 'RCS');
      expect(msg.toMap()['service'], 'RCS');
    });

    test('supportsTapbackAndReply allows iMessage/RCS from message.service even if chat is SMS', () {
      expect(ChatServiceType.iMessage.supportsTapbackAndReply, isTrue);
      expect(ChatServiceType.rcs.supportsTapbackAndReply, isTrue);
      expect(ChatServiceType.sms.supportsTapbackAndReply, isFalse);

      final chat = Chat.fromMap({
        'guid': 'any;-;+15551234567',
        'serviceName': 'SMS',
      });
      final rcsMsg = Message.fromMap({'guid': 'msg-rcs-1', 'service': 'RCS'});
      final imsgMsg = Message.fromMap({'guid': 'msg-imsg-1', 'service': 'iMessage'});
      final smsMsg = Message.fromMap({'guid': 'msg-sms-1', 'service': 'SMS'});

      bool supports(Message m) =>
          chat.isIMessage ||
          chat.isRCS ||
          (ChatServiceType.fromServiceName(m.service)?.supportsTapbackAndReply ?? false);

      expect(supports(rcsMsg), isTrue);
      expect(supports(imsgMsg), isTrue);
      expect(supports(smsMsg), isFalse);
    });
  });
}
