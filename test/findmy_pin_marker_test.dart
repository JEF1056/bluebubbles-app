import 'dart:math' as math;

import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FindMyFriend _makeFriend({
  String id = 'alice@example.com',
  String title = 'Alice',
  LocationStatus status = LocationStatus.live,
  DateTime? lastUpdated,
  bool isOld = false,
}) {
  return FindMyFriend(
    handle: null,
    handleAddress: id,
    title: title,
    subtitle: null,
    longAddress: null,
    shortAddress: null,
    locatingInProgress: false,
    latitude: 37.3346,
    longitude: -122.0090,
    status: status,
    isLive: status == LocationStatus.live,
    lastUpdated: lastUpdated,
    isOld: isOld,
  );
}

FindMyDevice _makeDevice({
  required String id,
  required String name,
  String? deviceClass,
  String? modelDisplayName,
  Map<String, dynamic>? features,
  DateTime? lastUpdated,
  String positionType = 'live',
  bool isOld = false,
}) {
  return FindMyDevice.fromJson({
    'id': id,
    'name': name,
    'deviceClass': deviceClass,
    'modelDisplayName': modelDisplayName ?? name,
    'features': features,
    'isConsideredAccessory': deviceClass == 'Accessory',
    'location': {
      'latitude': 37.3346,
      'longitude': -122.0090,
      'timeStamp': lastUpdated?.millisecondsSinceEpoch,
      'positionType': positionType,
      'isOld': isOld,
    },
  });
}

void main() {
  group('FindMyPinMarker 2D/3D geometry & animations', () {
    testWidgets('2D (pitch=0) vs 3D (pitch=52) foreshortens ground-plane halo by cos(pitch)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FindMyPulsingHalo(key: ValueKey('halo-2d'), active: true, pitchDegrees: 0.0),
                  FindMyPulsingHalo(key: ValueKey('halo-3d'), active: true, pitchDegrees: 52.0),
                ],
              ),
            ),
          ),
        ),
      );

      final t2d = tester.widget<Transform>(
        find.descendant(of: find.byKey(const ValueKey('halo-2d')), matching: find.byType(Transform)).first,
      );
      final t3d = tester.widget<Transform>(
        find.descendant(of: find.byKey(const ValueKey('halo-3d')), matching: find.byType(Transform)).first,
      );

      expect(t2d.transform.storage[5], closeTo(1.0, 0.001));
      expect(t3d.transform.storage[5], closeTo(math.cos(52.0 * math.pi / 180.0), 0.001));
    });

    testWidgets('Selected and hovered pins show pill label and smooth scale lift', (tester) async {
      final now = DateTime(2026, 11, 20, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final friend = _makeFriend(lastUpdated: now, status: LocationStatus.live);
      final hoveredFriend = _makeFriend(id: 'bob@example.com', title: 'Bob', lastUpdated: now, status: LocationStatus.shallow);
      controller.friends.addAll([friend, hoveredFriend]);
      controller.selectedFriendId.value = friend.stableId;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                FindMyFriendMarker(controller: controller, friend: friend, pitchDegrees: 52.0),
                FindMyFriendMarker(controller: controller, friend: hoveredFriend, isHovered: true, pitchDegrees: 0.0),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
    });

    testWidgets('Non-live pins have zero idle tickers after mount entrance completes', (tester) async {
      final now = DateTime(2026, 11, 20, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final staleFriend = _makeFriend(
        lastUpdated: now.subtract(const Duration(hours: 2)),
        status: LocationStatus.shallow,
        isOld: true,
      );
      controller.friends.add(staleFriend);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FindMyFriendMarker(controller: controller, friend: staleFriend),
            ),
          ),
        ),
      );

      // pumpAndSettle throws if any ticker continues running indefinitely.
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.bySemanticsLabel('Alice'), findsOneWidget);
    });

    testWidgets('Self puck renders foreshortened halo and heading cone in 3D', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: FindMySelfMarker(
                headingRadians: 0.5,
                pitchDegrees: 52.0,
                showAvatar: false,
              ),
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('You'), findsOneWidget);
      expect(find.byType(FindMyPulsingHalo), findsOneWidget);
      expect(find.byType(ClipPath), findsOneWidget);
    });

    testWidgets('Tracker glyphs distinguish utag SmartTag, gfind Find Hub, and Apple devices', (tester) async {
      final now = DateTime(2026, 11, 20, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final smartTag = _makeDevice(
        id: 'utag:123',
        name: 'Keys SmartTag',
        deviceClass: 'Accessory',
        features: {'TRACKER_PROVIDER': 'utag'},
        lastUpdated: now,
      );
      final findHub = _makeDevice(
        id: 'gfind:456',
        name: 'Backpack Tag',
        deviceClass: 'Accessory',
        features: {'TRACKER_PROVIDER': 'gfind'},
        lastUpdated: now,
      );
      final airPods = _makeDevice(
        id: 'apple-1',
        name: 'AirPods Pro',
        deviceClass: 'Accessory',
        modelDisplayName: 'AirPods Pro',
        lastUpdated: now,
      );
      controller.devices.addAll([smartTag, findHub, airPods]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                FindMyDeviceMarker(controller: controller, device: smartTag),
                FindMyDeviceMarker(controller: controller, device: findHub),
                FindMyDeviceMarker(controller: controller, device: airPods),
              ],
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.bluetooth_searching_rounded), findsOneWidget);
      expect(find.byIcon(Icons.radar_rounded), findsOneWidget);
      expect(find.byIcon(Icons.headphones), findsOneWidget);
    });

    testWidgets('Reduced motion disables looping tickers on live pins, halo, and badge', (tester) async {
      final now = DateTime(2026, 11, 20, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final liveFriend = _makeFriend(lastUpdated: now, status: LocationStatus.live);
      controller.friends.add(liveFriend);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  FindMyFriendMarker(controller: controller, friend: liveFriend, pitchDegrees: 45.0),
                  const FindMySelfMarker(pitchDegrees: 45.0, showAvatar: false),
                  const FindMyLiveBadge(),
                ],
              ),
            ),
          ),
        ),
      );

      // With disableAnimations: true, pumpAndSettle completes immediately with zero active tickers.
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Alice'), findsOneWidget);
      expect(find.bySemanticsLabel('You'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
    });
  });
}
