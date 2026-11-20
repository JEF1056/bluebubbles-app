import 'dart:typed_data';

import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_detail_sheet.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_device_avatar.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_device_list_tile.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_nearby_sheet.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/findmy_helpers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final Uint8List _k1x1PngBytes = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

FindMyDevice _device({
  required String id,
  String? name,
  String? iconUrl,
  String? iconCategory,
  Map<String, dynamic>? role,
  Map<String, dynamic>? features,
  String? modelDisplayName,
  bool isConsideredAccessory = false,
}) {
  final now = DateTime(2026, 11, 20, 12, 0, 0);
  return FindMyDevice.fromJson({
    'id': id,
    'name': name ?? id,
    'modelDisplayName': modelDisplayName,
    'isConsideredAccessory': isConsideredAccessory,
    'iconUrl': iconUrl,
    'iconCategory': iconCategory,
    'role': role,
    'features': features,
    'location': {
      'latitude': 37.3349,
      'longitude': -122.0090,
      'timeStamp': now.millisecondsSinceEpoch,
    },
  });
}

void main() {
  tearDown(() {
    FindMyDeviceIconCache.instance.clear();
  });

  test('FindMyDevice parses iconUrl, iconCategory, roleEmoji and preserves them in toJson', () {
    final gfindEarbuds = _device(
      id: 'gfind:xm5',
      name: 'WF-1000XM5',
      iconUrl: 'https://lh3.googleusercontent.com/xm5.png',
      iconCategory: 'earbuds',
      features: {'TRACKER_PROVIDER': 'gfind'},
    );
    final airTag = _device(
      id: 'apple-tag-1',
      name: 'Keys',
      iconCategory: 'tag',
      role: {'emoji': '🔑', 'name': 'Keys'},
      isConsideredAccessory: true,
    );

    expect(gfindEarbuds.iconUrl, 'https://lh3.googleusercontent.com/xm5.png');
    expect(gfindEarbuds.iconCategory, 'earbuds');
    expect(gfindEarbuds.hasPreviewIcon, isTrue);
    expect(iconForFindMyDevice(gfindEarbuds), Icons.headphones);

    final serialized = gfindEarbuds.toJson();
    expect(serialized['iconUrl'], 'https://lh3.googleusercontent.com/xm5.png');
    expect(serialized['iconCategory'], 'earbuds');

    expect(airTag.hasPreviewIcon, isFalse);
    expect(airTag.roleEmoji, '🔑');
    expect(airTag.toJson()['role'], {'emoji': '🔑', 'name': 'Keys'});
    expect(iconForFindMyDevice(airTag), Icons.sell_outlined);
  });

  test('FindMyDeviceIconCache deduplicates in-flight fetches, caches by id+iconUrl, and skips missing iconUrl', () async {
    final cache = FindMyDeviceIconCache();
    var calls = 0;

    final noIcon = _device(id: 'apple-no-icon');
    expect(await cache.getOrFetch(noIcon, fetcher: (_) async {
      calls++;
      return _k1x1PngBytes;
    }), isNull);
    expect(calls, 0);

    final pixel = _device(
      id: 'gfind:pixel-10',
      iconUrl: 'https://gstatic.com/pixel10-v1.png',
      iconCategory: 'phone',
    );
    final results = await Future.wait([
      cache.getOrFetch(pixel, fetcher: (_) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return _k1x1PngBytes;
      }),
      cache.getOrFetch(pixel, fetcher: (_) async {
        calls++;
        return _k1x1PngBytes;
      }),
    ]);

    expect(calls, 1);
    expect(results[0], _k1x1PngBytes);
    expect(results[1], _k1x1PngBytes);
    expect(cache.peek(pixel), _k1x1PngBytes);

    // Changing iconUrl invalidates the cache key and fetches the updated art.
    final updatedPixel = _device(
      id: 'gfind:pixel-10',
      iconUrl: 'https://gstatic.com/pixel10-v2.png',
      iconCategory: 'phone',
    );
    await cache.getOrFetch(updatedPixel, fetcher: (_) async {
      calls++;
      return _k1x1PngBytes;
    });
    expect(calls, 2);

    // HTML/JSON proxy error pages are rejected before entering cache.
    final badDevice = _device(
      id: 'utag:bad',
      iconUrl: 'https://smartthings.com/tag.png',
    );
    final rejected = await cache.getOrFetch(
      badDevice,
      fetcher: (_) async => Uint8List.fromList('<html>auth</html>'.codeUnits),
    );
    expect(rejected, isNull);
    expect(cache.peek(badDevice), isNull);
  });

  testWidgets('FindMyDeviceAvatar renders product image with BoxFit.contain and FilterQuality.medium in light & dark mode',
      (tester) async {
    final cache = FindMyDeviceIconCache();
    final earbuds = _device(
      id: 'gfind:wf-xm6',
      name: 'WF-1000XM6',
      iconUrl: 'https://gstatic.com/xm6.png',
      iconCategory: 'earbuds',
      features: {'TRACKER_PROVIDER': 'gfind'},
    );

    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: Center(
              child: FindMyDeviceAvatar(
                device: earbuds,
                size: 44,
                cache: cache,
                fetcher: (_) async => _k1x1PngBytes,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.fit, BoxFit.contain);
      expect(image.filterQuality, FilterQuality.medium);
    }
  });

  testWidgets('FindMyDeviceAvatar handles AirTag role emoji fallback, corner badge, and redaction', (tester) async {
    final cache = FindMyDeviceIconCache();
    final airTagNoArt = _device(
      id: 'apple-airtag-1',
      name: 'Keys',
      role: {'emoji': '🔑'},
      isConsideredAccessory: true,
    );
    final airTagWithArt = _device(
      id: 'apple-airtag-2',
      name: 'Backpack',
      iconUrl: 'https://statici.icloud.com/airtag.png',
      iconCategory: 'tag',
      role: {'emoji': '🎒'},
      isConsideredAccessory: true,
    );
    cache.seedForTest(airTagWithArt, _k1x1PngBytes);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              FindMyDeviceAvatar(device: airTagNoArt, size: 44, cache: cache),
              FindMyDeviceAvatar(device: airTagWithArt, size: 44, cache: cache),
              FindMyDeviceAvatar(device: airTagNoArt, size: 44, redacted: true, cache: cache),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('🔑'), findsOneWidget);
    expect(find.text('🎒'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.sell_outlined), findsOneWidget);
  });

  testWidgets('FindMyDeviceAvatar is wired across map pin, list tile, detail sheet, and nearby sheet',
      (tester) async {
    final controller = FindMyController(now: () => DateTime(2026, 11, 20, 12, 0), autoFetch: false);
    addTearDown(controller.onClose);

    final smartTag = _device(
      id: 'utag:smarttag2',
      name: 'SmartTag2',
      iconUrl: 'https://smartthings.com/tag2.png',
      iconCategory: 'tag',
      features: {'TRACKER_PROVIDER': 'utag'},
      isConsideredAccessory: true,
    );
    FindMyDeviceIconCache.instance.seedForTest(smartTag, _k1x1PngBytes);
    controller.devices.add(smartTag);
    controller.selectDevice(smartTag);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                FindMyDeviceMarker(controller: controller, device: smartTag),
                FindMyDeviceListTile(item: smartTag, controller: controller, isItem: true),
                FindMyDetailSheet(controller: controller),
                FindMyNearbySheet(device: smartTag, controller: controller),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(FindMyDeviceAvatar), findsNWidgets(4));
    expect(find.byType(Image), findsNWidgets(4));
  });
}
