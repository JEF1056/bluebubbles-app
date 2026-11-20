import 'dart:typed_data';

import 'package:bluebubbles/helpers/network/metadata/metadata.dart';
import 'package:bluebubbles/helpers/types/helpers/chat_background_helpers.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Web theming & media follow-ups', () {
    test('withEmojiFallback preserves ThemeData and BubbleText extension', () {
      final base = ThemeData.light().copyWith(
        extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
      );
      final resolved = base.withEmojiFallback;
      expect(resolved.extension<BubbleText>()?.bubbleText.fontSize, 15);
    });

    test('local web-bg:// background path is treated as local and not overwritten by server sync', () {
      const localWebPath = 'web-bg://iMessage;-;+15551234567';
      expect(serverBackgroundGuidFromPath(localWebPath), isNull);
      expect(
        shouldSyncServerBackground(
          serverGuid: 'server-bg-guid',
          hasServerProperties: true,
          existingPath: localWebPath,
          wallpaperType: null,
        ),
        isFalse,
      );
    });

    test('CachedPreviewImage supports in-memory bytes for web URL previews', () {
      final bytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      final cached = CachedPreviewImage(
        path: '',
        hash: 'deadbeef',
        fromDisk: true,
        bytes: bytes,
      );
      expect(cached.path, isEmpty);
      expect(cached.bytes, equals(bytes));
      expect(cached.fromDisk, isTrue);
    });

    test('FilesystemService web avatar cache stores, versions, resolves, and deletes web-avatar:// paths', () async {
      final fs = FilesystemService();
      final bytes1 = Uint8List.fromList([1, 2, 3, 4]);
      final bytes2 = Uint8List.fromList([5, 6, 7, 8]);
      final path1 = await fs.saveWebAvatar('you', bytes1);
      final path2 = await fs.saveWebAvatar('you', bytes2);
      expect(path1, startsWith('web-avatar://you?v='));
      expect(path2, startsWith('web-avatar://you?v='));
      expect(path2, isNot(equals(path1)));
      expect(FilesystemService.stripWebPathVersion(path1), 'web-avatar://you');
      expect(FilesystemService.stripWebPathVersion('web-bg://abc?v=42'), 'web-bg://abc');
      expect(FilesystemService.stripWebPathVersion('/tmp/local.jpg'), '/tmp/local.jpg');
      expect(fs.getCachedWebAvatarByPath(path2), equals(bytes2));
      expect(fs.getCachedWebAvatarByPath('/tmp/local.jpg'), isNull);

      await fs.deleteWebAvatar(path2);
      expect(fs.getCachedWebAvatarByPath(path2), isNull);
    });

    test('FilesystemService.getCachedChatBackgroundByPath ignores non-web-bg paths and transparent1x1Png is valid PNG', () {
      final fs = FilesystemService();
      expect(fs.getCachedChatBackgroundByPath('/tmp/bg.jpg'), isNull);
      expect(fs.getCachedChatBackgroundByPath('web-bg://missing?v=1'), isNull);
      expect(FilesystemService.transparent1x1Png.sublist(0, 4), equals([0x89, 0x50, 0x4E, 0x47]));
    });

    test('server web-bg:// background path preserves server GUID across updates and clears', () {
      const serverWebPath =
          'web-bg://any;-;+19499980689/background-server-AB8083A0-FC1A-4948-9B42-8DA282874142.jpg?v=1';
      expect(serverBackgroundGuidFromPath(serverWebPath), 'AB8083A0-FC1A-4948-9B42-8DA282874142');
      expect(serverBackgroundGuidFromPath('web-bg://any;-;+19499980689?v=2'), isNull);
      expect(
        shouldSyncServerBackground(
          serverGuid: 'AB8083A0-FC1A-4948-9B42-8DA282874142',
          hasServerProperties: true,
          existingPath: serverWebPath,
          wallpaperType: 'image',
        ),
        isFalse,
      );
      expect(
        shouldSyncServerBackground(
          serverGuid: 'NEW-GUID-1234',
          hasServerProperties: true,
          existingPath: serverWebPath,
          wallpaperType: 'image',
        ),
        isTrue,
      );
      expect(
        shouldSyncServerBackground(
          serverGuid: null,
          hasServerProperties: true,
          existingPath: serverWebPath,
          wallpaperType: 'image',
        ),
        isTrue,
      );
    });

    test('FilesystemService.saveWebContactAvatar content-hashes and evicts superseded photos', () async {
      final fs = FilesystemService();
      final a = Uint8List.fromList([10, 20, 30, 40]);
      final b = Uint8List.fromList([50, 60, 70, 80, 90]);
      final pathA1 = await fs.saveWebContactAvatar('uuid:ABPerson', a);
      final pathA2 = await fs.saveWebContactAvatar('uuid:ABPerson', a);
      expect(pathA1, startsWith('web-avatar://contact_'));
      expect(pathA2, equals(pathA1));
      expect(fs.getCachedWebAvatarByPath(pathA1), equals(a));

      final pathB = await fs.saveWebContactAvatar('uuid:ABPerson', b);
      expect(pathB, isNot(equals(pathA1)));
      expect(fs.getCachedWebAvatarByPath(pathA1), isNull);
      expect(fs.getCachedWebAvatarByPath(pathB), equals(b));
    });
  });
}
