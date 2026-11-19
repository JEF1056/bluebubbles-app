import 'dart:typed_data';

import 'package:bluebubbles/services/backend/filesystem/web_media_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

void main() {
  Uint8List bytesOf(int length, [int fill = 1]) => Uint8List.fromList(List<int>.filled(length, fill));

  group('WebMediaCache', () {
    late WebMediaCache cache;
    late int dbCounter;

    setUp(() {
      dbCounter = DateTime.now().microsecondsSinceEpoch;
      cache = WebMediaCache.forTesting(
        idbFactory: idbFactoryMemory,
        dbName: 'test_media_$dbCounter',
        maxBytes: 100,
      );
    });

    tearDown(() async {
      await cache.close();
    });

    test('put, get, delete, clearAll, and usageBytes across stores', () async {
      await cache.put(WebMediaCache.attachmentsStore, 'att-1', bytesOf(30, 7));
      await cache.put(WebMediaCache.chatBackgroundsStore, 'chat-1', bytesOf(20, 9));
      await cache.put(WebMediaCache.fontsStore, 'iosFont', bytesOf(10, 3));

      expect(await cache.usageBytes(), 60);
      expect(await cache.get(WebMediaCache.attachmentsStore, 'att-1'), bytesOf(30, 7));
      expect(await cache.get(WebMediaCache.chatBackgroundsStore, 'chat-1'), bytesOf(20, 9));
      expect(await cache.get(WebMediaCache.fontsStore, 'iosFont'), bytesOf(10, 3));

      // Overwrite existing key updates usageBytes without double-counting.
      await cache.put(WebMediaCache.attachmentsStore, 'att-1', bytesOf(15, 5));
      expect(await cache.usageBytes(), 45);
      expect(await cache.get(WebMediaCache.attachmentsStore, 'att-1'), bytesOf(15, 5));

      // Delete removes entry and decrements usageBytes.
      await cache.delete(WebMediaCache.chatBackgroundsStore, 'chat-1');
      expect(await cache.get(WebMediaCache.chatBackgroundsStore, 'chat-1'), isNull);
      expect(await cache.usageBytes(), 25);

      // ClearAll wipes all stores and resets usageBytes.
      await cache.clearAll();
      expect(await cache.usageBytes(), 0);
      expect(await cache.get(WebMediaCache.attachmentsStore, 'att-1'), isNull);
      expect(await cache.get(WebMediaCache.fontsStore, 'iosFont'), isNull);
    });

    test('LRU eviction evicts least recently accessed entries when exceeding maxBytes', () async {
      await cache.put(WebMediaCache.attachmentsStore, 'a', bytesOf(40, 1));
      await cache.put(WebMediaCache.attachmentsStore, 'b', bytesOf(40, 2));

      // Touch 'a' so 'b' becomes the least recently used entry.
      expect(await cache.get(WebMediaCache.attachmentsStore, 'a'), bytesOf(40, 1));

      // Adding 'c' (40 bytes) pushes total to 120 > 100, so 'b' must be evicted.
      await cache.put(WebMediaCache.attachmentsStore, 'c', bytesOf(40, 3));

      expect(await cache.usageBytes(), 80);
      expect(await cache.get(WebMediaCache.attachmentsStore, 'b'), isNull);
      expect(await cache.get(WebMediaCache.attachmentsStore, 'a'), bytesOf(40, 1));
      expect(await cache.get(WebMediaCache.attachmentsStore, 'c'), bytesOf(40, 3));
    });

    test('caps effective limit below 50% of estimated storage quota (remaining + cache usage)', () async {
      late WebMediaCache quotaCache;
      quotaCache = WebMediaCache.forTesting(
        idbFactory: idbFactoryMemory,
        dbName: 'test_quota_$dbCounter',
        maxBytes: WebMediaCache.defaultMaxBytes,
        // Simulates navigator.storage.estimate() where remaining = quota - usage (120 - cacheUsage).
        quotaEstimator: () async => 120 - await quotaCache.usageBytes(),
      );
      addTearDown(quotaCache.close);

      await quotaCache.put(WebMediaCache.attachmentsStore, 'x', bytesOf(40, 4));
      await quotaCache.put(WebMediaCache.attachmentsStore, 'y', bytesOf(40, 5));

      expect(await quotaCache.usageBytes(), 40);
      expect(await quotaCache.get(WebMediaCache.attachmentsStore, 'x'), isNull);
      expect(await quotaCache.get(WebMediaCache.attachmentsStore, 'y'), bytesOf(40, 5));
    });

    test('getAllEntries with keyPrefix only loads matching entries', () async {
      await cache.put(WebMediaCache.attachmentsStore, 'avatar_1', bytesOf(10, 1));
      await cache.put(WebMediaCache.attachmentsStore, 'att_1', bytesOf(20, 2));
      await cache.put(WebMediaCache.attachmentsStore, 'avatar_2', bytesOf(15, 3));

      final avatars = await cache.getAllEntries(WebMediaCache.attachmentsStore, keyPrefix: 'avatar_');
      expect(avatars.keys.toSet(), {'avatar_1', 'avatar_2'});
      expect(avatars['avatar_1'], bytesOf(10, 1));
      expect(avatars['avatar_2'], bytesOf(15, 3));
    });

    test('LRU eviction preserves fontsStore and chatBackgroundsStore while evicting attachmentsStore', () async {
      await cache.put(WebMediaCache.fontsStore, 'iosFont', bytesOf(30, 1));
      await cache.put(WebMediaCache.chatBackgroundsStore, 'chat-bg', bytesOf(30, 2));
      await cache.put(WebMediaCache.attachmentsStore, 'att-old', bytesOf(30, 3));
      // Total = 90 <= 100. Adding 'att-new' (30) pushes total to 120 > 100.
      await cache.put(WebMediaCache.attachmentsStore, 'att-new', bytesOf(30, 4));

      expect(await cache.usageBytes(), 90);
      expect(await cache.get(WebMediaCache.fontsStore, 'iosFont'), bytesOf(30, 1));
      expect(await cache.get(WebMediaCache.chatBackgroundsStore, 'chat-bg'), bytesOf(30, 2));
      expect(await cache.get(WebMediaCache.attachmentsStore, 'att-old'), isNull);
      expect(await cache.get(WebMediaCache.attachmentsStore, 'att-new'), bytesOf(30, 4));
    });

    test('clearStore clears only the targeted store and preserves fontsStore', () async {
      await cache.put(WebMediaCache.fontsStore, 'iosFont', bytesOf(25, 6));
      await cache.put(WebMediaCache.attachmentsStore, 'att-1', bytesOf(25, 7));
      await cache.put(WebMediaCache.chatBackgroundsStore, 'bg-1', bytesOf(25, 8));

      await cache.clearStore(WebMediaCache.attachmentsStore);
      await cache.clearStore(WebMediaCache.chatBackgroundsStore);

      expect(await cache.usageBytes(), 25);
      expect(await cache.get(WebMediaCache.fontsStore, 'iosFont'), bytesOf(25, 6));
      expect(await cache.get(WebMediaCache.attachmentsStore, 'att-1'), isNull);
      expect(await cache.get(WebMediaCache.chatBackgroundsStore, 'bg-1'), isNull);
    });
  });
}
