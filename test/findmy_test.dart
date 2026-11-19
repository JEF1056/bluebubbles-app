import 'dart:async';

import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_detail_sheet.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_device_list_tile.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_devices_tab_view.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_friend_list_tile.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_friends_tab_view.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_items_tab_view.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart';
import 'package:bluebubbles/database/global/findmy_device.dart';
import 'package:bluebubbles/database/global/findmy_friend.dart';
import 'package:bluebubbles/database/io/contact_v2.dart';
import 'package:bluebubbles/helpers/ui/findmy_helpers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

FindMyFriend _friend({
  DateTime? lastUpdated,
  LocationStatus? status = LocationStatus.shallow,
  bool locatingInProgress = false,
  bool isOld = false,
  double? horizontalAccuracy,
  String? title = 'Alice',
  String? handleAddress = 'alice@example.com',
}) =>
    FindMyFriend(
      latitude: 37.3349,
      longitude: -122.009,
      longAddress: null,
      shortAddress: null,
      title: title,
      subtitle: null,
      handle: null,
      handleAddress: handleAddress,
      lastUpdated: lastUpdated,
      status: status,
      locatingInProgress: locatingInProgress,
      horizontalAccuracy: horizontalAccuracy,
      isOld: isOld,
    );

void main() {
  group('FindMyFriend model & freshness', () {
    test('parses extended accuracy, speed, altitude, and state flags from JSON', () {
      final ts = DateTime(2026, 11, 17, 12, 0, 0).millisecondsSinceEpoch;
      final friend = FindMyFriend.fromJson({
        'coordinates': [37.3349, -122.009],
        'long_address': 'One Apple Park Way, Cupertino, CA',
        'short_address': 'Cupertino, CA',
        'title': null,
        'subtitle': null,
        'handle': null,
        'last_updated': ts,
        'status': 'live',
        'is_locating_in_progress': true,
        'horizontalAccuracy': 12.5,
        'verticalAccuracy': 4.2,
        'speed': 1.8,
        'altitude': 25.0,
        'isOld': false,
        'isInaccurate': true,
        'locationFinished': false,
      });

      expect(friend.horizontalAccuracy, 12.5);
      expect(friend.verticalAccuracy, 4.2);
      expect(friend.speed, 1.8);
      expect(friend.altitude, 25.0);
      expect(friend.timeStamp, ts);
      expect(friend.isOld, isFalse);
      expect(friend.isInaccurate, isTrue);
      expect(friend.locationFinished, isFalse);
      expect(friend.isLocatingInProgress, isTrue);
    });

    test('isLiveFresh requires live status, age < 60s, and !isOld', () {
      final now = DateTime(2026, 11, 17, 12, 0, 0);
      expect(
        _friend(lastUpdated: now.subtract(const Duration(seconds: 30)), status: LocationStatus.live)
            .isLiveFresh(now),
        isTrue,
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(seconds: 60)), status: LocationStatus.live)
            .isLiveFresh(now),
        isFalse,
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(seconds: 10)), status: LocationStatus.live, isOld: true)
            .isLiveFresh(now),
        isFalse,
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(seconds: 10)), status: LocationStatus.shallow)
            .isLiveFresh(now),
        isFalse,
      );
    });

    test('displayFreshness formats locating, live, relative age, and old states', () {
      final now = DateTime(2026, 11, 17, 12, 0, 0);
      expect(
        _friend(locatingInProgress: true, status: LocationStatus.shallow).displayFreshness(now),
        'Locating...',
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(seconds: 15)), status: LocationStatus.live)
            .displayFreshness(now),
        'Live',
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(minutes: 5)), status: LocationStatus.live)
            .displayFreshness(now),
        '5m ago',
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(hours: 2)), isOld: true).displayFreshness(now),
        'Old · 2h ago',
      );
    });

    test('resolveDisplayName never returns Unknown Friend when handleAddress exists', () {
      final withPhone = _friend(
        title: null,
        handleAddress: '+15551234567',
      );
      expect(withPhone.resolveDisplayName(), contains('555'));
      expect(withPhone.resolveDisplayName(), isNot('Unknown Friend'));

      final withEmail = _friend(
        title: null,
        handleAddress: 'test@example.com',
      );
      expect(withEmail.resolveDisplayName(), 'test@example.com');

      final withUnknownTitle = _friend(
        title: 'Unknown Friend',
        handleAddress: 'user@apple.com',
      );
      expect(withUnknownTitle.resolveDisplayName(), 'user@apple.com');

      final withCustomTitle = _friend(
        title: 'Alice Smith',
        handleAddress: '+15551234567',
      );
      expect(withCustomTitle.resolveDisplayName(), 'Alice Smith');

      final trulyUnknown = _friend(
        title: null,
        handleAddress: null,
      );
      expect(trulyUnknown.resolveDisplayName(), 'Unknown Friend');
    });

    test('resolveFriendDisplayName matches country-code variants symmetrically and prefers avatar contacts', () {
      final noAvatar = ContactV2(
        nativeContactId: 'c1',
        displayName: 'Alex Plain',
        addresses: ['4085958701'],
      );
      final withAvatar = ContactV2(
        nativeContactId: 'c2',
        displayName: 'Alex Photo',
        addresses: ['4085958701'],
        avatarPath: '/tmp/alex.png',
      );
      final plusOneContact = ContactV2(
        nativeContactId: 'c3',
        displayName: 'Sam PlusOne',
        addresses: ['+16505551234'],
      );

      expect(
        resolveFriendDisplayName(
          handleAddress: '+14085958701',
          contactsOverride: [noAvatar, withAvatar],
        ),
        'Alex Photo',
      );
      expect(
        resolveFriendDisplayName(
          handleAddress: '6505551234',
          contactsOverride: [plusOneContact],
        ),
        'Sam PlusOne',
      );
      expect(
        resolveFriendDisplayName(
          title: '+14085958701',
          contactsOverride: [noAvatar],
        ),
        'Alex Plain',
      );
    });
  });

  group('FindMyDevice model & freshness', () {
    test('parses double verticalAccuracy/altitude/speed and freshness helpers', () {
      final now = DateTime(2026, 11, 17, 12, 0, 0);
      final ts = now.subtract(const Duration(seconds: 20)).millisecondsSinceEpoch;
      final device = FindMyDevice.fromJson({
        'id': 'dev-1',
        'name': 'iPhone',
        'location': {
          'positionType': 'live',
          'latitude': 37.3349,
          'longitude': -122.009,
          'horizontalAccuracy': 15.0,
          'verticalAccuracy': 3.5,
          'altitude': 18.2,
          'speed': 0.5,
          'timeStamp': ts,
          'isOld': false,
          'isInaccurate': false,
          'locationFinished': true,
          'isLocatingInProgress': false,
        },
      });

      expect(device.location?.horizontalAccuracy, 15.0);
      expect(device.location?.verticalAccuracy, 3.5);
      expect(device.location?.altitude, 18.2);
      expect(device.location?.speed, 0.5);
      expect(device.isLiveFresh(now), isTrue);
      expect(device.displayFreshness(now), 'Live');
    });
  });

  group('Superseding rules', () {
    test('newer timestamp supersedes live status even with shallow/legacy', () {
      final t1 = DateTime(2026, 11, 17, 12, 0, 0);
      final t2 = t1.add(const Duration(seconds: 30));
      final existingLive = _friend(lastUpdated: t1, status: LocationStatus.live);
      final newerShallow = _friend(lastUpdated: t2, status: LocationStatus.shallow);
      final olderLive = _friend(lastUpdated: t1.subtract(const Duration(seconds: 10)), status: LocationStatus.live);

      expect(shouldSupersedeFriendLocation(existingLive, newerShallow), isTrue);
      expect(shouldSupersedeFriendLocation(newerShallow, olderLive), isFalse);

      final olderLocating = _friend(
        lastUpdated: t1.subtract(const Duration(seconds: 10)),
        status: LocationStatus.live,
        locatingInProgress: true,
      );
      final sameTsLocating = _friend(
        lastUpdated: t1,
        status: LocationStatus.legacy,
        locatingInProgress: true,
      );
      expect(shouldSupersedeFriendLocation(existingLive, olderLocating), isFalse);
      expect(shouldSupersedeFriendLocation(existingLive, sameTsLocating), isTrue);
    });

    test('device location supersedes only on >= timestamp or locating on tie', () {
      final d1 = FindMyDevice.fromJson({
        'id': 'dev-1',
        'location': {'timeStamp': 2000},
      });
      final dOld = FindMyDevice.fromJson({
        'id': 'dev-1',
        'location': {'timeStamp': 1000},
      });
      final dOldLocating = FindMyDevice.fromJson({
        'id': 'dev-1',
        'location': {'timeStamp': 1000, 'isLocatingInProgress': true},
      });
      final dNew = FindMyDevice.fromJson({
        'id': 'dev-1',
        'location': {'timeStamp': 3000},
      });

      expect(shouldSupersedeDeviceLocation(d1, dOld), isFalse);
      expect(shouldSupersedeDeviceLocation(d1, dOldLocating), isFalse);
      expect(shouldSupersedeDeviceLocation(d1, dNew), isTrue);
    });
  });

  group('FindMy helpers', () {
    test('distance formatting and bounds computation', () {
      const cupertino = LatLng(37.3349, -122.0090);
      const sf = LatLng(37.7749, -122.4194);
      final meters = distanceMetersBetween(cupertino, sf);
      expect(meters, greaterThan(50000));
      expect(formatFindMyDistance(450), '450 m away');
      expect(formatFindMyDistance(2400), '2.4 km away');
      expect(formatFindMyDistance(15400), '15 km away');

      expect(formatFindMyBattery(0.78), '78%');
      expect(formatFindMyBattery(1.0, status: 'Charging'), '100% · Charging');
      expect(formatFindMyBattery(null), isNull);

      expect(computeFindMyBounds([]), isNull);
      final single = computeFindMyBounds([cupertino]);
      expect(single, isNotNull);
      expect(single!.northEast.latitude, greaterThan(cupertino.latitude));
      expect(single.southWest.latitude, lessThan(cupertino.latitude));

      final multi = computeFindMyBounds([cupertino, sf]);
      expect(multi, isNotNull);
      expect(multi!.contains(cupertino), isTrue);
      expect(multi.contains(sf), isTrue);
    });

    test('map style definitions provide valid tile templates', () {
      for (final style in FindMyMapStyle.values) {
        expect(style.label, isNotEmpty);
        expect(style.urlTemplate, contains('{z}'));
        expect(style.urlTemplate, contains('{x}'));
        expect(style.urlTemplate, contains('{y}'));
      }
    });
  });

  group('FindMyController iOS parity behavior', () {
    test('focusFriend/focusDevice animates camera with sheet offset and opens detail sheet', () async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      LatLng? animatedCenter;
      double? animatedZoom;
      Offset? animatedOffset;
      var detailOpenedCount = 0;

      controller.registerCameraAnimator((center, zoom, {offset = Offset.zero}) {
        animatedCenter = center;
        animatedZoom = zoom;
        animatedOffset = offset;
      });
      controller.onRequestDetailSheetOpen = () => detailOpenedCount++;
      controller.detailSheetOffsetProvider = () => 120.0;

      final friend = _friend(
        lastUpdated: now.subtract(const Duration(seconds: 5)),
        status: LocationStatus.live,
      );
      controller.friends.add(friend);

      controller.focusFriend(friend);

      expect(controller.selectedFriendId.value, friend.stableId);
      expect(controller.selectedDeviceId.value, isNull);
      expect(detailOpenedCount, 1);
      expect(animatedCenter?.latitude, closeTo(37.3349, 0.0001));
      expect(animatedCenter?.longitude, closeTo(-122.009, 0.0001));
      expect(animatedZoom, 14.5);
      expect(animatedOffset, const Offset(0, -120.0));

      final device = FindMyDevice.fromJson({
        'id': 'dev-1',
        'name': 'MacBook Pro',
        'location': {'latitude': 37.7749, 'longitude': -122.4194, 'timeStamp': now.millisecondsSinceEpoch},
      });
      controller.devices.add(device);

      controller.focusDevice(device);

      expect(controller.selectedFriendId.value, isNull);
      expect(controller.selectedDeviceId.value, 'dev-1');
      expect(detailOpenedCount, 2);
      expect(animatedCenter?.latitude, closeTo(37.7749, 0.0001));

      controller.clearSelection();
      expect(controller.selectedFriendId.value, isNull);
      expect(controller.selectedDeviceId.value, isNull);
    });

    test('handleNewFindMyLocation interpolates pin coordinates and increments livePulseNonce', () {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final interpolated = <LatLng>[];
      controller.registerPinInterpolator((key, from, to, onStep) {
        final mid = LatLng((from.latitude + to.latitude) / 2, (from.longitude + to.longitude) / 2);
        interpolated.add(mid);
        onStep(mid);
        onStep(to);
      });

      final f1 = _friend(lastUpdated: now.subtract(const Duration(seconds: 20)), status: LocationStatus.live);
      controller.handleNewFindMyLocation(f1);
      final key = f1.stableId!;
      expect(controller.animatedPoints[key]?.latitude, closeTo(37.3349, 0.0001));
      final pulseBefore = controller.livePulseNonce.value;

      final f2 = FindMyFriend(
        latitude: 37.3549,
        longitude: -122.029,
        longAddress: null,
        shortAddress: null,
        title: 'Alice',
        subtitle: null,
        handle: null,
        handleAddress: 'alice@example.com',
        lastUpdated: now,
        status: LocationStatus.live,
        locatingInProgress: false,
      );
      controller.handleNewFindMyLocation(f2);

      expect(interpolated, isNotEmpty);
      expect(interpolated.first.latitude, closeTo(37.3449, 0.0001));
      expect(controller.animatedPoints[key]?.latitude, closeTo(37.3549, 0.0001));
      expect(controller.livePulseNonce.value, greaterThan(pulseBefore));
      expect(controller.markers[key], isNotNull);
    });

    test('map style, live tracking toggle, and recenterToUser update controller state', () async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      expect(controller.mapStyle.value, FindMyMapStyle.standard);
      controller.setMapStyle(FindMyMapStyle.satellite);
      expect(controller.mapStyle.value, FindMyMapStyle.satellite);

      expect(controller.liveTrackingEnabled.value, isTrue);
      controller.toggleLiveTracking();
      expect(controller.liveTrackingEnabled.value, isFalse);

      LatLng? centered;
      double? zoomed;
      controller.registerCameraAnimator((center, zoom, {offset = Offset.zero}) {
        centered = center;
        zoomed = zoom;
      });
      controller.location.value = Position(
        longitude: -122.4194,
        latitude: 37.7749,
        timestamp: now,
        accuracy: 12,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

      await controller.recenterToUser();
      expect(centered?.latitude, closeTo(37.7749, 0.0001));
      expect(centered?.longitude, closeTo(-122.4194, 0.0001));
      expect(zoomed, 14.5);
    });
  });

  group('FindMy widgets & centered pills', () {
    testWidgets('FindMyLiveBadge centers Live label text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: FindMyLiveBadge()),
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('Live'));
      expect(text.textAlign, TextAlign.center);
    });

    testWidgets('FindMyDetailSheet displays friend details, centered pills, actions, and close', (tester) async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      controller.location.value = Position(
        longitude: -122.4194,
        latitude: 37.7749,
        timestamp: now,
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

      final friend = FindMyFriend(
        latitude: 37.3349,
        longitude: -122.009,
        longAddress: 'One Apple Park Way, Cupertino, CA',
        shortAddress: 'Cupertino, CA',
        title: 'Alice',
        subtitle: null,
        handle: null,
        handleAddress: 'alice@example.com',
        lastUpdated: now.subtract(const Duration(seconds: 10)),
        status: LocationStatus.live,
        locatingInProgress: false,
        horizontalAccuracy: 12.0,
      );
      controller.friends.add(friend);
      controller.selectFriend(friend);

      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FindMyDetailSheet(
                controller: controller,
                onClose: () {
                  closed = true;
                  controller.clearSelection();
                },
              ),
            ),
          ),
        ),
      );

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('One Apple Park Way, Cupertino, CA'), findsOneWidget);
      expect(find.textContaining('km away'), findsOneWidget);
      expect(find.text('±12m'), findsOneWidget);
      expect(find.text('Directions'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      expect(find.text('Live On'), findsOneWidget);
      expect(find.text('Message'), findsOneWidget);
      expect(find.text('Contact'), findsOneWidget);
      expect(find.text('Info'), findsOneWidget);

      final accuracyText = tester.widget<Text>(find.text('±12m'));
      expect(accuracyText.textAlign, TextAlign.center);

      await tester.tap(find.byKey(const ValueKey('findmy-detail-close')));
      await tester.pump();
      expect(closed, isTrue);
      expect(controller.selectedFriendId.value, isNull);
    });

    testWidgets('FindMyDetailSheet displays live speed and altitude telemetry pills', (tester) async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final friend = FindMyFriend(
        latitude: 37.3349,
        longitude: -122.0090,
        longAddress: 'One Apple Park Way, Cupertino, CA',
        shortAddress: 'Cupertino, CA',
        title: 'Alice',
        subtitle: null,
        handle: null,
        handleAddress: 'alice@example.com',
        lastUpdated: now.subtract(const Duration(seconds: 4)),
        status: LocationStatus.live,
        locatingInProgress: false,
        horizontalAccuracy: 4.5,
        speed: 5.0, // 18 km/h
        altitude: 24.0,
      );
      controller.friends.add(friend);
      controller.selectFriend(friend);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FindMyDetailSheet(controller: controller),
            ),
          ),
        ),
      );

      expect(find.text('Live'), findsOneWidget);
      expect(find.text('±5m'), findsOneWidget);
      expect(find.text('18 km/h'), findsOneWidget);
      expect(find.text('24m alt'), findsOneWidget);
    });

    testWidgets('FindMyDetailSheet displays device battery badge and omits friend Message/Contact', (tester) async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final device = FindMyDevice.fromJson({
        'id': 'dev-mbp',
        'name': 'Studio MacBook',
        'deviceDisplayName': 'MacBook Pro',
        'batteryLevel': 0.78,
        'batteryStatus': 'NotCharging',
        'address': {'label': 'Cupertino', 'mapItemFullAddress': 'Cupertino, CA'},
        'location': {
          'latitude': 37.3349,
          'longitude': -122.009,
          'horizontalAccuracy': 18.0,
          'timeStamp': now.subtract(const Duration(minutes: 4)).millisecondsSinceEpoch,
          'isOld': false,
        },
      });
      controller.devices.add(device);
      controller.selectDevice(device);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FindMyDetailSheet(
                controller: controller,
                onClose: controller.clearSelection,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Studio MacBook'), findsOneWidget);
      expect(find.text('78%'), findsOneWidget);
      expect(find.text('±18m'), findsOneWidget);
      expect(find.text('Directions'), findsOneWidget);
      expect(find.text('Info'), findsOneWidget);
      expect(find.text('Message'), findsNothing);
      expect(find.text('Contact'), findsNothing);

      final batteryText = tester.widget<Text>(find.text('78%'));
      expect(batteryText.textAlign, TextAlign.center);
    });

    testWidgets('FindMyFriendMarker and FindMyDeviceMarker render circular iOS pins without pill clutter', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final now = DateTime(2026, 11, 18, 12, 0, 0);
        final controller = FindMyController(now: () => now, autoFetch: false);
        addTearDown(controller.onClose);

        final friend = _friend(lastUpdated: now, status: LocationStatus.live);
        final device = FindMyDevice.fromJson({
          'id': 'dev-1',
          'name': 'AirPods Pro',
          'modelDisplayName': 'AirPods Pro',
          'deviceClass': 'Accessory',
          'location': {'latitude': 37.33, 'longitude': -122.01, 'timeStamp': now.millisecondsSinceEpoch},
        });
        controller.friends.add(friend);
        controller.devices.add(device);
        controller.selectDevice(device);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  FindMyFriendMarker(friend: friend, controller: controller),
                  FindMyDeviceMarker(device: device, controller: controller),
                ],
              ),
            ),
          ),
        );

        expect(find.bySemanticsLabel('Alice'), findsOneWidget);
        expect(find.bySemanticsLabel('AirPods Pro'), findsOneWidget);
        expect(find.byIcon(Icons.headphones), findsOneWidget);
        expect(find.text('A'), findsOneWidget);
        expect(find.text('Alice'), findsNothing);
        expect(find.text('AirPods Pro'), findsNothing);
      } finally {
        semantics.dispose();
      }
    });

    test('Dark mode map styling, proximity, ETA, and distinct device icon helpers', () {
      expect(shouldApplyDarkMapFilter(FindMyMapStyle.standard, Brightness.dark), isTrue);
      expect(shouldApplyDarkMapFilter(FindMyMapStyle.standard, Brightness.light), isFalse);
      expect(shouldApplyDarkMapFilter(FindMyMapStyle.dark, Brightness.light), isTrue);
      expect(shouldApplyDarkMapFilter(FindMyMapStyle.satellite, Brightness.dark), isFalse);

      expect(
        resolveFindMyTileUrl(FindMyMapStyle.standard, Brightness.dark),
        allOf(contains('openstreetmap.org'), isNot(contains('cartocdn'))),
      );
      expect(
        resolveFindMyTileUrl(FindMyMapStyle.standard, Brightness.light),
        FindMyMapStyle.standard.urlTemplate,
      );
      expect(
        resolveFindMyMapBackgroundColor(FindMyMapStyle.standard, Brightness.dark),
        const Color(0xFF141E2B),
      );

      expect(formatFindMyProximity(10, deviceWithYou: true), 'With You');
      expect(formatFindMyProximity(30), 'With You');
      expect(formatFindMyProximity(500), 'Nearby');
      expect(formatFindMyProximity(56327), '35 mi');
      expect(formatFindMyEta(600), '1 min');
      expect(formatFindMyEta(104500), contains('hr'));

      expect(iconForFindMyDevice(FindMyDevice.fromJson({'deviceDisplayName': 'iPhone 15'})), Icons.phone_iphone);
      expect(iconForFindMyDevice(FindMyDevice.fromJson({'deviceDisplayName': 'MacBook Pro'})), Icons.laptop_mac);
      expect(iconForFindMyDevice(FindMyDevice.fromJson({'name': 'Mini', 'deviceDisplayName': 'Mac mini'})), Icons.dns_rounded);
      expect(iconForFindMyDevice(FindMyDevice.fromJson({'deviceDisplayName': 'iPad Pro'})), Icons.tablet_mac);
      expect(iconForFindMyDevice(FindMyDevice.fromJson({'deviceDisplayName': 'AirPods Pro'})), Icons.headphones);
      expect(iconForFindMyDevice(FindMyDevice.fromJson({'deviceDisplayName': 'Apple Watch'})), Icons.watch);
    });

    testWidgets('Inline expanded selection keeps other items visible in People and Devices lists', (tester) async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      controller.location.value = Position(
        longitude: -122.009,
        latitude: 37.3349,
        timestamp: now,
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

      final friendA = FindMyFriend(
        latitude: 37.8715,
        longitude: -122.2730,
        longAddress: 'Berkeley, CA',
        shortAddress: 'Berkeley, CA',
        title: 'Awdree',
        subtitle: null,
        handle: null,
        handleAddress: 'awdree@example.com',
        lastUpdated: now,
        status: LocationStatus.live,
        locatingInProgress: false,
        isOld: false,
      );
      final friendB = FindMyFriend(
        latitude: 37.7749,
        longitude: -122.4194,
        longAddress: 'San Francisco, CA',
        shortAddress: 'San Francisco, CA',
        title: 'Aaron Lee',
        subtitle: null,
        handle: null,
        handleAddress: 'aaron@example.com',
        lastUpdated: now.subtract(const Duration(minutes: 5)),
        status: LocationStatus.shallow,
        locatingInProgress: false,
        isOld: false,
      );
      controller.fetching.value = false;
      controller.fetching2.value = false;
      controller.friends.addAll([friendB, friendA]);
      controller.friendsWithLocation.addAll([friendB, friendA]);
      controller.selectFriend(friendA);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [FindMyFriendsTabView(controller: controller)],
            ),
          ),
        ),
      );

      // Selected friend expanded inline with Live, Contact, and overflow ... button
      expect(find.text('Awdree'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Contact'), findsOneWidget);
      expect(find.byKey(const ValueKey('findmy-inline-more')), findsOneWidget);
      // Unselected friend remains visible below!
      expect(find.text('Aaron Lee'), findsOneWidget);

      // Now test Devices list inline expansion keeping unselected rows visible
      final devSelected = FindMyDevice.fromJson({
        'id': 'dev-iphone',
        'name': "Jess's iPhone",
        'modelDisplayName': 'iPhone 15 Pro',
        'thisDevice': true,
        'deviceWithYou': true,
        'address': {'label': 'Lincoln Ave, San Martin'},
        'location': {'latitude': 37.3349, 'longitude': -122.009, 'timeStamp': now.millisecondsSinceEpoch},
      });
      final devOther = FindMyDevice.fromJson({
        'id': 'dev-mini',
        'name': 'Mini',
        'modelDisplayName': 'Mac mini',
        'deviceWithYou': true,
        'address': {'label': 'Lincoln Ave, San Martin'},
        'location': {'latitude': 37.3349, 'longitude': -122.009, 'timeStamp': now.millisecondsSinceEpoch},
      });
      controller.devices.addAll([devOther, devSelected]);
      controller.selectDevice(devSelected);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [FindMyDevicesTabView(controller: controller)],
            ),
          ),
        ),
      );

      expect(find.text("Jess's iPhone"), findsOneWidget);
      expect(find.text('Now'), findsOneWidget);
      expect(find.text('Directions'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      expect(find.text('Mini'), findsOneWidget);
      expect(find.text('With You'), findsOneWidget);
    });
  });

  group('3-tab Find My & Items tab', () {
    testWidgets('FindMyFloatingNavPill shows People, Devices, Items without Me and clears selection on tab switch',
        (tester) async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final alice = _friend(
        lastUpdated: now.subtract(const Duration(minutes: 2)),
        status: LocationStatus.shallow,
        title: 'Alice',
        handleAddress: 'alice@example.com',
      );
      controller.friends.add(alice);
      controller.selectFriend(alice);
      expect(controller.selectedFriendId.value, alice.stableId);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FindMyFloatingNavPill(
                controller: controller,
                onSelectTab: (page) {
                  controller.tabIndex.value = page;
                  controller.onTabChanged(page);
                },
              ),
            ),
          ),
        ),
      );

      expect(find.text('People'), findsOneWidget);
      expect(find.text('Devices'), findsOneWidget);
      expect(find.text('Items'), findsOneWidget);
      expect(find.text('Me'), findsNothing);

      await tester.tap(find.text('Items'));
      await tester.pump();

      expect(controller.tabIndex.value, 2);
      expect(controller.selectedFriendId.value, isNull);
    });

    testWidgets('FindMyItemsTabView renders M3 empty state and separates accessories from devices', (tester) async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);
      controller.fetching.value = false;

      // Empty items state when only regular devices exist
      final iphone = FindMyDevice.fromJson({
        'id': 'dev-iphone',
        'name': 'iPhone 15 Pro',
        'modelDisplayName': 'iPhone 15 Pro',
        'deviceWithYou': true,
        'address': {'label': 'Cupertino, CA'},
        'location': {'latitude': 37.3349, 'longitude': -122.009, 'timeStamp': now.millisecondsSinceEpoch},
      });
      controller.devices.add(iphone);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [FindMyItemsTabView(controller: controller)],
            ),
          ),
        ),
      );

      expect(find.text('No Items Found'), findsOneWidget);
      expect(find.text('AirTags and Find My accessories will appear here.'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);

      // Add an AirTag with location and an offline accessory without location
      final keysTag = FindMyDevice.fromJson({
        'id': 'item-keys',
        'name': 'House Keys',
        'deviceModel': 'AirTag',
        'isConsideredAccessory': true,
        'address': {'label': '1 Infinite Loop'},
        'location': {'latitude': 37.3318, 'longitude': -122.0312, 'timeStamp': now.millisecondsSinceEpoch},
      });
      final backpackTag = FindMyDevice.fromJson({
        'id': 'item-bag',
        'name': 'Backpack',
        'deviceModel': 'AirTag',
        'isConsideredAccessory': true,
      });
      controller.devices.addAll([keysTag, backpackTag]);
      controller.selectDevice(keysTag);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [FindMyItemsTabView(controller: controller)],
            ),
          ),
        ),
      );

      expect(find.text('House Keys'), findsOneWidget);
      expect(find.text('Backpack'), findsOneWidget);
      expect(find.text('No Location Found'), findsOneWidget);
      expect(find.text('iPhone 15 Pro'), findsNothing);

      // Devices tab excludes accessories
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [FindMyDevicesTabView(controller: controller)],
            ),
          ),
        ),
      );
      expect(find.text('iPhone 15 Pro'), findsOneWidget);
      expect(find.text('House Keys'), findsNothing);
    });
  });

  group('Per-person select -> targeted refresh -> live tracking -> cleanup', () {
    testWidgets('selectFriend forces targeted refresh, shows locating indicator, then transitions to green Live',
        (tester) async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final calls = <({String? handle, bool force, bool live, CancelToken? token})>[];
      final completer = Completer<Response>();

      final controller = FindMyController(
        now: () => now,
        autoFetch: false,
        livePollInterval: const Duration(seconds: 30),
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) {
          calls.add((handle: handle, force: force, live: live, token: cancelToken));
          return completer.future;
        },
      );
      addTearDown(controller.onClose);

      final alice = _friend(
        lastUpdated: now.subtract(const Duration(minutes: 4)),
        status: LocationStatus.shallow,
        title: 'Alice',
        handleAddress: 'alice@example.com',
      );
      final bob = _friend(
        lastUpdated: now.subtract(const Duration(minutes: 8)),
        status: LocationStatus.legacy,
        title: 'Bob',
        handleAddress: 'bob@example.com',
      );
      controller.friends.addAll([alice, bob]);
      controller.friendsWithLocation.addAll([alice, bob]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [FindMyFriendsTabView(controller: controller)],
            ),
          ),
        ),
      );

      controller.selectFriend(alice);
      await tester.pump();

      expect(calls, hasLength(1));
      expect(calls.single.handle, 'alice@example.com');
      expect(calls.single.force, isTrue);
      expect(calls.single.live, isTrue);
      expect(controller.locatingFriendId.value, alice.stableId);
      expect(find.text('Locating...'), findsOneWidget);
      expect(find.byKey(ValueKey('findmy-friend-locating-${alice.stableId}')), findsOneWidget);

      // Server returns targeted live update for Alice only
      completer.complete(
        Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
          statusCode: 200,
          data: {
            'data': [
              {
                'coordinates': [37.336, -122.011],
                'long_address': 'Cupertino, CA',
                'short_address': 'Cupertino, CA',
                'title': 'Alice',
                'handle': 'alice@example.com',
                'last_updated': now.millisecondsSinceEpoch,
                'status': 'live',
                'is_locating_in_progress': false,
                'isOld': false,
              },
            ],
          },
        ),
      );
      await tester.pump();

      expect(controller.locatingFriendId.value, isNull);
      expect(controller.friends, hasLength(2));
      expect(controller.friends.firstWhere((f) => f.title == 'Alice').status, LocationStatus.live);
      expect(find.text('Live'), findsOneWidget);
      final liveText = tester.widget<Text>(find.text('Live'));
      expect(liveText.style?.color, const Color(0xFF22C55E));
      expect(find.byKey(ValueKey('findmy-friend-locating-${alice.stableId}')), findsNothing);
      // Bob stays intact
      expect(find.text('Bob'), findsOneWidget);
    });

    test('switching friends cancels stale request and ignores late response', () async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final completers = <String?, Completer<Response>>{};
      final tokens = <String?, CancelToken?>{};

      final controller = FindMyController(
        now: () => now,
        autoFetch: false,
        livePollInterval: const Duration(seconds: 30),
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) {
          tokens[handle] = cancelToken;
          final c = Completer<Response>();
          completers[handle] = c;
          return c.future;
        },
      );
      addTearDown(controller.onClose);

      final alice = _friend(
        lastUpdated: now.subtract(const Duration(minutes: 4)),
        status: LocationStatus.shallow,
        title: 'Alice',
        handleAddress: 'alice@example.com',
      );
      final bob = _friend(
        lastUpdated: now.subtract(const Duration(minutes: 8)),
        status: LocationStatus.shallow,
        title: 'Bob',
        handleAddress: 'bob@example.com',
      );
      controller.friends.addAll([alice, bob]);

      controller.selectFriend(alice);
      expect(controller.locatingFriendId.value, alice.stableId);
      expect(tokens['alice@example.com']?.isCancelled, isFalse);

      // Rapidly switch to Bob before Alice completes
      controller.selectFriend(bob);
      expect(tokens['alice@example.com']?.isCancelled, isTrue);
      expect(controller.selectedFriendId.value, bob.stableId);
      expect(controller.locatingFriendId.value, bob.stableId);

      // Late Alice response arrives: must be ignored and must not clear Bob's locating state
      completers['alice@example.com']!.complete(
        Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
          statusCode: 200,
          data: {
            'data': [
              {
                'coordinates': [37.9, -122.9],
                'title': 'Alice',
                'handle': 'alice@example.com',
                'last_updated': now.millisecondsSinceEpoch,
                'status': 'live',
              },
            ],
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.selectedFriendId.value, bob.stableId);
      expect(controller.locatingFriendId.value, bob.stableId);
      expect(controller.friends.firstWhere((f) => f.title == 'Alice').status, LocationStatus.shallow);

      // Bob's response arrives cleanly
      completers['bob@example.com']!.complete(
        Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
          statusCode: 200,
          data: {
            'data': [
              {
                'coordinates': [37.77, -122.41],
                'title': 'Bob',
                'handle': 'bob@example.com',
                'last_updated': now.millisecondsSinceEpoch,
                'status': 'live',
              },
            ],
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.locatingFriendId.value, isNull);
      expect(controller.friends.firstWhere((f) => f.title == 'Bob').status, LocationStatus.live);
    });

    test('active per-person polling runs periodically and stops cleanly on clearSelection, tab change, and dispose',
        () async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      var callCount = 0;
      CancelToken? lastToken;

      final controller = FindMyController(
        now: () => now,
        autoFetch: false,
        livePollInterval: const Duration(milliseconds: 25),
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async {
          callCount++;
          lastToken = cancelToken;
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
            statusCode: 200,
            data: {
              'data': [
                {
                  'coordinates': [37.3349, -122.009],
                  'title': 'Alice',
                  'handle': handle,
                  'last_updated': now.millisecondsSinceEpoch,
                  'status': 'live',
                },
              ],
            },
          );
        },
      );

      final alice = _friend(
        lastUpdated: now.subtract(const Duration(minutes: 3)),
        status: LocationStatus.shallow,
        title: 'Alice',
        handleAddress: 'alice@example.com',
      );
      controller.friends.add(alice);

      controller.selectFriend(alice);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(callCount, greaterThanOrEqualTo(3));

      // clearSelection stops polling cleanly
      controller.clearSelection();
      final afterClear = callCount;
      expect(controller.selectedFriendId.value, isNull);
      expect(controller.locatingFriendId.value, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(callCount, afterClear);

      // Re-select then switch tab -> stops polling and cancels in-flight
      controller.selectFriend(alice);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(callCount, greaterThan(afterClear));
      controller.onTabChanged(1);
      final afterTab = callCount;
      expect(controller.selectedFriendId.value, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(callCount, afterTab);

      // Re-select then dispose -> stops polling cleanly
      controller.selectFriend(alice);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      controller.onClose();
      expect(lastToken?.isCancelled ?? false, isFalse);
      final afterDispose = callCount;
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(callCount, afterDispose);
    });

    test('true live mode streams pushed updates, falls back gently only when silent, and stops on lifecycle transitions',
        () async {
      var now = DateTime(2026, 11, 18, 12, 0, 0);
      final startedHandles = <String>[];
      final stoppedHandles = <String?>[];
      var fallbackRefreshCount = 0;

      final controller = FindMyController(
        now: () => now,
        autoFetch: false,
        liveFallbackInterval: const Duration(milliseconds: 45),
        startLiveFriendRequest: ({required handle, cancelToken}) async {
          startedHandles.add(handle);
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/live/start'),
            statusCode: 200,
            data: {
              'data': {
                'handle': handle,
                'live': true,
                'locations': [
                  {
                    'coordinates': [37.3349, -122.0090],
                    'title': handle == 'alice@example.com' ? 'Alice' : 'Bob',
                    'handle': handle,
                    'last_updated': now.millisecondsSinceEpoch,
                    'status': 'shallow',
                    'is_locating_in_progress': true,
                  },
                ],
              },
            },
          );
        },
        stopLiveFriendRequest: ({handle, cancelToken}) async {
          stoppedHandles.add(handle);
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/live/stop'),
            statusCode: 200,
            data: {'data': {'handle': handle, 'stopped': true}},
          );
        },
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async {
          fallbackRefreshCount++;
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
            statusCode: 200,
            data: {'data': []},
          );
        },
      );

      final alice = _friend(
        lastUpdated: now.subtract(const Duration(minutes: 4)),
        status: LocationStatus.shallow,
        title: 'Alice',
        handleAddress: 'alice@example.com',
      );
      final bob = _friend(
        lastUpdated: now.subtract(const Duration(minutes: 6)),
        status: LocationStatus.shallow,
        title: 'Bob',
        handleAddress: 'bob@example.com',
      );
      controller.friends.addAll([alice, bob]);

      // 1. selectFriend starts live stream immediately without hammering refreshFriends.
      controller.selectFriend(alice);
      await Future<void>.delayed(Duration.zero);
      expect(startedHandles, ['alice@example.com']);
      expect(controller.locatingFriendId.value, alice.stableId);
      expect(fallbackRefreshCount, 0);

      // 2. Pushed new-findmy-location clears locatingFriendId and updates telemetry.
      now = now.add(const Duration(milliseconds: 20));
      controller.handleNewFindMyLocation({
        'coordinates': [37.3352, -122.0094],
        'title': 'Alice',
        'handle': 'alice@example.com',
        'last_updated': now.millisecondsSinceEpoch,
        'status': 'live',
        'location_type': 2,
        'horizontal_accuracy': 4.2,
        'speed': 3.5,
        'altitude': 20.0,
        'is_locating_in_progress': false,
      });
      expect(controller.locatingFriendId.value, isNull);
      final updatedAlice = controller.friends.firstWhere((f) => f.title == 'Alice');
      expect(updatedAlice.status, LocationStatus.live);
      expect(updatedAlice.horizontalAccuracy, 4.2);
      expect(updatedAlice.speed, 3.5);
      expect(updatedAlice.altitude, 20.0);

      // 3. While live pushes are recent (< liveFallbackInterval), fallback refresh stays quiet.
      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(fallbackRefreshCount, 0);

      // 4. Once silent past liveFallbackInterval, gentle fallback refresh fires.
      now = now.add(const Duration(milliseconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(fallbackRefreshCount, greaterThanOrEqualTo(1));

      // 5. Switching to Bob stops Alice cleanly before starting Bob.
      controller.selectFriend(bob);
      await Future<void>.delayed(Duration.zero);
      expect(stoppedHandles, ['alice@example.com']);
      expect(startedHandles, ['alice@example.com', 'bob@example.com']);

      // 6. Pause stops Bob; resume restarts Bob.
      controller.onAppPaused();
      await Future<void>.delayed(Duration.zero);
      expect(stoppedHandles, ['alice@example.com', 'bob@example.com']);

      controller.onAppResumed();
      await Future<void>.delayed(Duration.zero);
      expect(startedHandles, ['alice@example.com', 'bob@example.com', 'bob@example.com']);

      // 7. toggleLiveTracking(false) stops Bob; onClose stops after re-enable.
      await controller.toggleLiveTracking();
      expect(stoppedHandles.last, 'bob@example.com');
      await controller.toggleLiveTracking();
      expect(startedHandles.last, 'bob@example.com');

      controller.onClose();
      await Future<void>.delayed(Duration.zero);
      expect(stoppedHandles.last, 'bob@example.com');
    });

    test('live keepalive renews server idle timer without flashing locating indicator', () async {
      var now = DateTime(2026, 11, 18, 12, 0, 0);
      final startedHandles = <String>[];

      final controller = FindMyController(
        now: () => now,
        autoFetch: false,
        liveFallbackInterval: const Duration(milliseconds: 60),
        liveKeepaliveInterval: const Duration(milliseconds: 30),
        startLiveFriendRequest: ({required handle, cancelToken}) async {
          startedHandles.add(handle);
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/live/start'),
            statusCode: 200,
            data: {'data': {'handle': handle, 'live': true, 'locations': []}},
          );
        },
        stopLiveFriendRequest: ({handle, cancelToken}) async {
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/live/stop'),
            statusCode: 200,
            data: {'data': {'handle': handle, 'stopped': true}},
          );
        },
      );
      addTearDown(controller.onClose);

      final alice = _friend(
        lastUpdated: now,
        status: LocationStatus.live,
        title: 'Alice',
        handleAddress: 'alice@example.com',
      );
      controller.friends.add(alice);

      controller.selectFriend(alice);
      await Future<void>.delayed(Duration.zero);
      expect(startedHandles, ['alice@example.com']);

      now = now.add(const Duration(seconds: 1));
      controller.handleNewFindMyLocation({
        'coordinates': [37.3352, -122.0094],
        'title': 'Alice',
        'handle': 'alice@example.com',
        'last_updated': now.millisecondsSinceEpoch,
        'status': 'live',
        'location_type': 2,
        'is_locating_in_progress': false,
      });
      expect(controller.locatingFriendId.value, isNull);

      // Advance simulated clock past liveKeepaliveInterval while stream is healthy
      now = now.add(const Duration(milliseconds: 40));
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(startedHandles.length, greaterThanOrEqualTo(2));
      expect(startedHandles.every((h) => h == 'alice@example.com'), isTrue);
      expect(controller.locatingFriendId.value, isNull);
    });
  });

  group('FindMy UI spinner centering & focus scroll-to-top', () {
    testWidgets('inline friend and device locating spinners vertically center with the more button', (tester) async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final alice = _friend(
        lastUpdated: now.subtract(const Duration(minutes: 2)),
        status: LocationStatus.shallow,
        title: 'Alice',
        handleAddress: 'alice@example.com',
      );
      controller.friends.add(alice);
      controller.selectedFriendId.value = alice.stableId;
      controller.locatingFriendId.value = alice.stableId;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FindMyFriendListTile(
              item: alice,
              controller: controller,
            ),
          ),
        ),
      );

      final friendSpinnerCenter =
          tester.getCenter(find.byKey(ValueKey('findmy-friend-locating-${alice.stableId}')));
      final friendMoreCenter = tester.getCenter(find.byKey(const ValueKey('findmy-inline-more')));
      expect(friendSpinnerCenter.dy, closeTo(friendMoreCenter.dy, 0.5));

      final macbook = FindMyDevice.fromJson({
        'id': 'dev-1',
        'name': 'MacBook Pro',
        'location': {'latitude': 37.7749, 'longitude': -122.4194, 'timeStamp': now.millisecondsSinceEpoch},
      });
      controller.devices.add(macbook);
      controller.selectedDeviceId.value = 'dev-1';
      controller.refreshing.value = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FindMyDeviceListTile(
              item: macbook,
              controller: controller,
            ),
          ),
        ),
      );

      final deviceSpinnerCenter = tester.getCenter(find.byType(CircularProgressIndicator).first);
      final deviceMoreCenter = tester.getCenter(find.byKey(const ValueKey('findmy-inline-more')));
      expect(deviceSpinnerCenter.dy, closeTo(deviceMoreCenter.dy, 0.5));
    });

    testWidgets('focusFriend and focusDevice jump scrolled list to top and switch tab when needed', (tester) async {
      final now = DateTime(2026, 11, 18, 12, 0, 0);
      final controller = FindMyController(now: () => now, autoFetch: false);
      addTearDown(controller.onClose);

      final friends = List.generate(
        12,
        (i) => _friend(
          lastUpdated: now.subtract(Duration(minutes: i + 1)),
          status: LocationStatus.shallow,
          title: 'Friend $i',
          handleAddress: 'friend$i@example.com',
        ),
      );
      controller.fetching2.value = false;
      controller.friends.addAll(friends);
      controller.friendsWithLocation.addAll(friends);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 240,
              child: CustomScrollView(
                controller: controller.friendsController,
                slivers: [
                  FindMyFriendsTabView(controller: controller),
                ],
              ),
            ),
          ),
        ),
      );

      controller.friendsController.jumpTo(200);
      await tester.pump();
      expect(controller.friendsController.offset, 200);

      controller.tabIndex.value = 1;
      controller.focusFriend(friends[8]);
      await tester.pump();

      expect(controller.tabIndex.value, 0);
      expect(controller.friendsController.offset, 0);
      expect(find.byKey(ValueKey('findmy-inline-friend-${friends[8].stableId}')), findsOneWidget);

      controller.clearSelection();
      await tester.pump();
      expect(controller.selectedFriendId.value, isNull);
      expect(controller.friendsController.offset, 0);
    });
  });
}
