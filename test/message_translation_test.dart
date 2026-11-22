import 'package:bluebubbles/database/global/models/message_translation.dart';
import 'package:bluebubbles/database/io/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageTranslation', () {
    test('fromJson and toJson round-trip', () {
      final json = {
        'text': 'Hello world',
        'sourceLanguage': 'es',
        'targetLanguage': 'en',
        'provider': 'google',
        'autoTranslated': true,
        'dateTranslated': 1700000000000,
      };
      final tr = MessageTranslation.fromJson(json);
      expect(tr.text, 'Hello world');
      expect(tr.sourceLanguage, 'es');
      expect(tr.targetLanguage, 'en');
      expect(tr.provider, 'google');
      expect(tr.autoTranslated, isTrue);
      expect(tr.dateTranslated?.millisecondsSinceEpoch, 1700000000000);
      expect(tr.sourceLanguageName, 'Spanish');
      expect(tr.toJson(), json);
    });

    test('languageName handles BCP-47 tags and fallbacks', () {
      expect(MessageTranslation.languageName('zh-CN'), 'Chinese (Simplified)');
      expect(MessageTranslation.languageName('zh_Hant'), 'Chinese (Traditional)');
      expect(MessageTranslation.languageName('es-MX'), 'Spanish');
      expect(MessageTranslation.languageName('ja'), 'Japanese');
      expect(MessageTranslation.languageName('xx-YY'), 'XX-YY');
      expect(MessageTranslation.languageName(''), 'Unknown');
    });

    test('Message.fromMap and Message.merge preserve and update translation', () {
      final msg1 = Message.fromMap({
        'guid': 'msg-1',
        'text': 'Hola',
        'isFromMe': false,
        'translation': {
          'text': 'Hello',
          'sourceLanguage': 'es',
          'targetLanguage': 'en',
          'provider': 'google',
          'autoTranslated': true,
          'dateTranslated': 1700000000000,
        },
      });
      expect(msg1.translation?.text, 'Hello');
      expect(msg1.translation?.sourceLanguageName, 'Spanish');

      final msg2 = Message.fromMap({
        'guid': 'msg-1',
        'text': 'Hola!',
        'isFromMe': false,
        'translation': {
          'text': 'Hello!',
          'sourceLanguage': 'es',
          'targetLanguage': 'en',
          'provider': 'apple',
          'autoTranslated': false,
          'dateTranslated': 1700000005000,
        },
      });
      final merged = Message.merge(msg1, msg2);
      expect(merged.translation?.text, 'Hello!');
      expect(merged.translation?.provider, 'apple');
    });

    test('Message.fillsGapsIn detects new and newer translations', () {
      final stored = Message.fromMap({'guid': 'msg-2', 'text': 'Hola', 'isFromMe': false});
      final translated = Message.fromMap({
        'guid': 'msg-2',
        'text': 'Hola',
        'isFromMe': false,
        'translation': {
          'text': 'Hello',
          'sourceLanguage': 'es',
          'targetLanguage': 'en',
          'provider': 'google',
          'autoTranslated': false,
          'dateTranslated': 1700000000000,
        },
      });
      final newer = Message.fromMap({
        'guid': 'msg-2',
        'text': 'Hola',
        'isFromMe': false,
        'translation': {
          'text': 'Hi there',
          'sourceLanguage': 'es',
          'targetLanguage': 'en',
          'provider': 'google',
          'autoTranslated': false,
          'dateTranslated': 1700000005000,
        },
      });
      expect(translated.fillsGapsIn(stored), isTrue);
      expect(translated.fillsGapsIn(translated), isFalse);
      expect(newer.fillsGapsIn(translated), isTrue);
      expect(translated.fillsGapsIn(newer), isFalse);
    });
  });
}
