import 'package:bluebubbles/database/io/chat.dart';
import 'package:bluebubbles/helpers/types/helpers/chat_background_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('backgroundGuidInProperties', () {
    test('prefers backgroundProperties.trabaid over backgroundChannelGUID', () {
      final props = [
        {
          'backgroundChannelGUID': 'AB8083A0-FC1A-4315-9151-E7B57E2DF3C0',
          'backgroundProperties': {
            'trabaid': '11111111-2222-3333-4444-555555555555',
          },
        },
      ];
      expect(backgroundGuidInProperties(props), '11111111-2222-3333-4444-555555555555');
    });

    test('falls back to backgroundChannelGUID and supports single map', () {
      expect(
        backgroundGuidInProperties({'backgroundChannelGUID': 'AB8083A0-FC1A-4315-9151-E7B57E2DF3C0'}),
        'AB8083A0-FC1A-4315-9151-E7B57E2DF3C0',
      );
    });

    test('rejects unsafe paths and missing values', () {
      expect(backgroundGuidInProperties([{'backgroundChannelGUID': '../etc/passwd'}]), isNull);
      expect(backgroundGuidInProperties(null), isNull);
      expect(backgroundGuidInProperties([{}]), isNull);
    });
  });

  group('serverBackgroundGuidFromPath', () {
    test('parses server-synced filename and ignores local backgrounds', () {
      final filename = serverBackgroundFilename('AB8083A0-FC1A-4315-9151-E7B57E2DF3C0');
      expect(
        serverBackgroundGuidFromPath('/data/user/0/app/backgrounds/chat/$filename'),
        'AB8083A0-FC1A-4315-9151-E7B57E2DF3C0',
      );
      expect(serverBackgroundGuidFromPath('/data/user/0/app/backgrounds/chat/background-12345.jpg'), isNull);
      expect(serverBackgroundGuidFromPath(null), isNull);
    });
  });

  group('Chat.fromMap / Chat.toMap', () {
    test('extracts and preserves serverBackgroundGuid and hasServerProperties', () {
      final chat = Chat.fromMap({
        'guid': 'any;-;+16266165776',
        'properties': [
          {
            'backgroundChannelGUID': 'AB8083A0-FC1A-4315-9151-E7B57E2DF3C0',
            'backgroundProperties': {'trabaid': 'AB8083A0-FC1A-4315-9151-E7B57E2DF3C0'},
          },
        ],
      });
      expect(chat.serverBackgroundGuid, 'AB8083A0-FC1A-4315-9151-E7B57E2DF3C0');
      expect(chat.hasServerProperties, isTrue);

      final roundTripped = Chat.fromMap(chat.toMap());
      expect(roundTripped.serverBackgroundGuid, 'AB8083A0-FC1A-4315-9151-E7B57E2DF3C0');
      expect(roundTripped.hasServerProperties, isTrue);
    });
  });

  group('shouldSyncServerBackground', () {
    test('skips when user has a locally-picked image or dynamic wallpaper', () {
      expect(
        shouldSyncServerBackground(
          serverGuid: 'NEW-GUID',
          hasServerProperties: true,
          existingPath: '/app/backgrounds/chat/background-12345.jpg',
          wallpaperType: 'image',
        ),
        isFalse,
      );
      expect(
        shouldSyncServerBackground(
          serverGuid: 'NEW-GUID',
          hasServerProperties: true,
          existingPath: null,
          wallpaperType: 'dynamic',
        ),
        isFalse,
      );
      expect(
        shouldSyncServerBackground(
          serverGuid: null,
          hasServerProperties: true,
          existingPath: '/app/backgrounds/chat/background-server-OLD.jpg',
          wallpaperType: 'dynamic',
        ),
        isFalse,
      );
    });

    test('syncs new/changed server wallpaper and clears removed server wallpaper', () {
      expect(
        shouldSyncServerBackground(
          serverGuid: 'NEW-GUID',
          hasServerProperties: true,
          existingPath: null,
          wallpaperType: null,
        ),
        isTrue,
      );
      expect(
        shouldSyncServerBackground(
          serverGuid: 'NEW-GUID',
          hasServerProperties: true,
          existingPath: '/app/backgrounds/chat/background-server-NEW-GUID.jpg',
          wallpaperType: 'image',
        ),
        isFalse,
      );
      expect(
        shouldSyncServerBackground(
          serverGuid: null,
          hasServerProperties: true,
          existingPath: '/app/backgrounds/chat/background-server-OLD.jpg',
          wallpaperType: 'image',
        ),
        isTrue,
      );
    });
  });
}
