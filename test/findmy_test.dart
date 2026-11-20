import 'dart:async';

import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_detail_sheet.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_device_list_tile.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_devices_tab_view.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_friend_list_tile.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_friends_tab_view.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_items_tab_view.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_map_widget.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart';
import 'package:bluebubbles/database/global/findmy_device.dart';
import 'package:bluebubbles/database/global/findmy_friend.dart';
import 'package:bluebubbles/database/io/contact_v2.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/findmy_helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';
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

    test('isLiveFresh requires live stream (status == live or isLive == true) and !isOld regardless of age', () {
      final now = DateTime(2026, 11, 17, 12, 0, 0);
      expect(
        _friend(lastUpdated: now.subtract(const Duration(seconds: 30)), status: LocationStatus.live)
            .isLiveFresh(now),
        isTrue,
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(minutes: 5)), status: LocationStatus.live)
            .isLiveFresh(now),
        isTrue,
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
      expect(
        FindMyFriend.fromJson({'status': 'live', 'is_live': false, 'last_updated': now.millisecondsSinceEpoch})
            .isLiveFresh(now),
        isFalse,
      );
      expect(
        FindMyFriend.fromJson({'status': 'shallow', 'is_live': true, 'last_updated': now.millisecondsSinceEpoch})
            .isLiveFresh(now),
        isTrue,
      );
    });

    test('displayFreshness formats locating with real age, live, relative age, and old states', () {
      final now = DateTime(2026, 11, 17, 12, 0, 0);
      expect(
        _friend(locatingInProgress: true, status: LocationStatus.shallow).displayFreshness(now),
        'Locating…',
      );
      expect(
        _friend(
          lastUpdated: now.subtract(const Duration(minutes: 5)),
          locatingInProgress: true,
          status: LocationStatus.shallow,
        ).displayFreshness(now),
        'Locating… · 5m ago',
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(seconds: 15)), status: LocationStatus.live)
            .displayFreshness(now),
        'Live',
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(minutes: 5)), status: LocationStatus.shallow)
            .displayFreshness(now),
        '5m ago',
      );
      expect(
        _friend(lastUpdated: now.subtract(const Duration(hours: 2)), isOld: true).displayFreshness(now),
        'Old · 2h ago',
      );
      expect(
        _friend(lastUpdated: null, status: LocationStatus.shallow).displayFreshness(now),
        '',
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

    test('map style definitions provide valid OpenFreeMap style URLs', () {
      for (final style in FindMyMapStyle.values) {
        expect(style.label, isNotEmpty);
        expect(style.styleUrl, startsWith('https://tiles.openfreemap.org/styles/'));
        expect(style.attribution, contains('OpenFreeMap'));
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
      expect(animatedZoom, FindMyController.defaultFocusZoom);
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
      controller.setMapStyle(FindMyMapStyle.fiord);
      expect(controller.mapStyle.value, FindMyMapStyle.fiord);

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
      expect(zoomed, FindMyController.defaultInitialZoom);
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
      expect(find.textContaining('mi'), findsOneWidget);
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
        expect(find.text('AirPods Pro'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    });

    test('Dark mode map styling, proximity, ETA, and distinct device icon helpers', () {
      expect(isDarkFindMyMapStyle(FindMyMapStyle.standard, Brightness.dark), isTrue);
      expect(isDarkFindMyMapStyle(FindMyMapStyle.standard, Brightness.light), isFalse);
      expect(isDarkFindMyMapStyle(FindMyMapStyle.dark, Brightness.light), isTrue);
      expect(isDarkFindMyMapStyle(FindMyMapStyle.bright, Brightness.dark), isFalse);

      expect(
        resolveFindMyStyleUrl(FindMyMapStyle.standard, Brightness.dark),
        'https://tiles.openfreemap.org/styles/dark',
      );
      expect(
        resolveFindMyStyleUrl(FindMyMapStyle.standard, Brightness.light),
        'https://tiles.openfreemap.org/styles/liberty',
      );
      expect(
        resolveFindMyMapBackgroundColor(FindMyMapStyle.standard, Brightness.dark),
        const Color(0xFF0C0C0C),
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
      expect(find.text('Locating… · 4m ago'), findsOneWidget);
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
      await tester.pumpAndSettle();

      expect(controller.tabIndex.value, 0);
      expect(controller.friendsController.offset, 0);
      expect(find.byKey(ValueKey('findmy-inline-friend-${friends[8].stableId}')), findsOneWidget);

      controller.clearSelection();
      await tester.pump();
      expect(controller.selectedFriendId.value, isNull);
      expect(controller.friendsController.offset, 0);
    });

    test('repeated onAppPaused + single onAppResumed resumes locationSub', () async {
      final controller = FindMyController(autoFetch: false);
      final streamController = StreamController<Position>();
      addTearDown(() async {
        controller.onClose();
        await streamController.close();
      });

      controller.locationSub = streamController.stream.listen((_) {});
      expect(controller.locationSub!.isPaused, isFalse);

      controller.onAppPaused();
      controller.onAppPaused();
      controller.onAppPaused();
      expect(controller.locationSub!.isPaused, isTrue);

      controller.onAppResumed();
      expect(controller.locationSub!.isPaused, isFalse);
    });

    test('getLocations catches position errors and auto-fits pins once map is ready when location is null',
        () async {
      final cameraCalls = <(LatLng, double)>[];
      final streamController = StreamController<Position>.broadcast();
      final controller = FindMyController(
        autoFetch: false,
        fetchCurrentPosition: () async => throw Exception('Geolocation denied'),
        positionStream: () => streamController.stream,
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async => Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
          statusCode: 200,
          data: {
            'data': [
              {
                'coordinates': [37.3349, -122.009],
                'long_address': '1 Apple Park Way',
                'title': 'Alice',
                'handle': 'alice@example.com',
                'last_updated': DateTime(2026, 11, 18, 12, 0).millisecondsSinceEpoch,
                'status': 'shallow',
              },
            ],
          },
        ),
      );
      addTearDown(() async {
        controller.onClose();
        await streamController.close();
      });
      controller.registerCameraAnimator((center, zoom, {offset = Offset.zero}) {
        cameraCalls.add((center, zoom));
      });

      await controller.getLocations(
        refreshFriends: true,
        refreshDevices: false,
        skipFetchWhenNotRefreshing: true,
      );
      expect(controller.location.value, isNull);
      expect(cameraCalls, isEmpty);

      controller.completer.complete();
      await pumpEventQueue();
      expect(cameraCalls, hasLength(1));
      expect(cameraCalls.first.$1.latitude, closeTo(37.3349, 0.001));
      expect(cameraCalls.first.$1.longitude, closeTo(-122.009, 0.001));

      // Subsequent refreshes do not re-fit the user's map camera.
      await controller.getLocations(
        refreshFriends: true,
        refreshDevices: false,
        skipFetchWhenNotRefreshing: true,
      );
      await pumpEventQueue();
      expect(cameraCalls, hasLength(1));
    });

    test('getLocations animates to initial position if no pin selected and catches stream errors', () async {
      final now = DateTime(2026, 11, 18, 12, 0);
      final initialPos = Position(
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
      final cameraCalls = <(LatLng, double)>[];
      final streamController = StreamController<Position>.broadcast();
      final controller = FindMyController(
        autoFetch: false,
        fetchCurrentPosition: () async => initialPos,
        positionStream: () => streamController.stream,
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async => Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
          statusCode: 200,
          data: {'data': []},
        ),
      );
      addTearDown(() async {
        controller.onClose();
        await streamController.close();
      });
      controller.registerCameraAnimator((center, zoom, {offset = Offset.zero}) {
        cameraCalls.add((center, zoom));
      });
      controller.completer.complete();

      await controller.getLocations(
        refreshFriends: true,
        refreshDevices: false,
        skipFetchWhenNotRefreshing: true,
      );
      await pumpEventQueue();

      expect(controller.location.value, isNotNull);
      expect(cameraCalls, hasLength(1));
      expect(cameraCalls.first.$1.latitude, closeTo(37.7749, 0.0001));
      expect(cameraCalls.first.$1.longitude, closeTo(-122.4194, 0.0001));
      expect(cameraCalls.first.$2, FindMyController.defaultInitialZoom);

      // Stream error must not become an unhandled zone error.
      streamController.addError(Exception('Position unavailable'));
      await pumpEventQueue();
    });

    test('getLocations does not animate to initial position when a pin is already selected', () async {
      final now = DateTime(2026, 11, 18, 12, 0);
      final initialPos = Position(
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
      final cameraCalls = <(LatLng, double)>[];
      final streamController = StreamController<Position>.broadcast();
      final controller = FindMyController(
        autoFetch: false,
        fetchCurrentPosition: () async => initialPos,
        positionStream: () => streamController.stream,
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async => Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
          statusCode: 200,
          data: {'data': []},
        ),
      );
      addTearDown(() async {
        controller.onClose();
        await streamController.close();
      });
      controller.selectedFriendId.value = 'alice@example.com';
      controller.registerCameraAnimator((center, zoom, {offset = Offset.zero}) {
        cameraCalls.add((center, zoom));
      });
      controller.completer.complete();

      await controller.getLocations(
        refreshFriends: true,
        refreshDevices: false,
        skipFetchWhenNotRefreshing: true,
      );
      await pumpEventQueue();

      expect(controller.location.value, isNotNull);
      expect(cameraCalls, isEmpty);
    });
  });

  group('Mobile FindMy fitAllPins & initial sheet snap', () {
    test('computeFindMyFitAllPadding accounts for phone bottom sheet and marker bounds', () {
      const phoneSize = Size(390, 844);
      const sheetHeight = 392.0; // 48% snap on 390x844
      final phonePad = computeFindMyFitAllPadding(
        viewportSize: phoneSize,
        viewPadding: const EdgeInsets.only(top: 20),
        isPhone: true,
        bottomSheetHeight: sheetHeight,
      );
      expect(phonePad.left, greaterThanOrEqualTo(58.0)); // >= half marker width (116/2)
      expect(phonePad.right, greaterThanOrEqualTo(58.0));
      expect(phonePad.top, greaterThanOrEqualTo(66.0));
      expect(phonePad.bottom, greaterThanOrEqualTo(sheetHeight + 46.0)); // >= sheet + half marker height
      expect(phonePad.horizontal, lessThan(phoneSize.width));
      expect(phonePad.vertical, lessThan(phoneSize.height));

      final desktopPad = computeFindMyFitAllPadding(
        viewportSize: const Size(1280, 800),
        isPhone: false,
      );
      expect(desktopPad, FindMyController.defaultFitAllPinsPadding);

      // Tiny viewport clamps without throwing or leaving negative interior bounds.
      final tinyPad = computeFindMyFitAllPadding(
        viewportSize: const Size(240, 320),
        isPhone: true,
        bottomSheetHeight: 280,
      );
      expect(tinyPad.horizontal, lessThanOrEqualTo(160.0));
      expect(tinyPad.vertical, lessThanOrEqualTo(240.0));
    });

    testWidgets('fitAllPins places SF and Cupertino markers in unoccluded upper map on 390x844', (tester) async {
      final sf = _friend(title: 'SF', handleAddress: 'sf@example.com');
      final cupertino = FindMyFriend(
        latitude: 37.3349,
        longitude: -122.0090,
        longAddress: 'Cupertino, CA',
        shortAddress: 'Cupertino',
        title: 'Cupertino',
        subtitle: null,
        handle: null,
        handleAddress: 'cup@example.com',
        lastUpdated: DateTime(2026, 11, 18, 12),
        status: LocationStatus.live,
        locatingInProgress: false,
      );
      final sfPin = FindMyFriend(
        latitude: 37.7749,
        longitude: -122.4194,
        longAddress: 'San Francisco, CA',
        shortAddress: 'SF',
        title: sf.title,
        subtitle: null,
        handle: null,
        handleAddress: 'sf@example.com',
        lastUpdated: DateTime(2026, 11, 18, 12),
        status: LocationStatus.live,
        locatingInProgress: false,
      );
      final controller = FindMyController(autoFetch: false);
      addTearDown(controller.onClose);
      controller.friends.addAll([sfPin, cupertino]);
      controller.friendsWithLocation.addAll([sfPin, cupertino]);

      const sheetHeight = 392.0;
      controller.fitAllPinsPaddingProvider = () => computeFindMyFitAllPadding(
            viewportSize: const Size(390, 844),
            isPhone: true,
            bottomSheetHeight: sheetHeight,
          );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 844,
              child: FindMyMapWidget(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      controller.fitAllPins();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final sfOffset = projectLatLngToScreenOffset(
        const LatLng(37.7749, -122.4194),
        center: controller.cameraCenter.value,
        zoom: controller.cameraZoom.value,
        viewportSize: const Size(390, 844),
      );
      final cupOffset = projectLatLngToScreenOffset(
        const LatLng(37.3349, -122.0090),
        center: controller.cameraCenter.value,
        zoom: controller.cameraZoom.value,
        viewportSize: const Size(390, 844),
      );
      final visibleMapBottom = 844.0 - sheetHeight;

      expect(sfOffset.dy, greaterThanOrEqualTo(46.0));
      expect(cupOffset.dy + 46.0, lessThanOrEqualTo(visibleMapBottom));
      expect(sfOffset.dx, inInclusiveRange(58.0, 390.0 - 58.0));
      expect(cupOffset.dx, inInclusiveRange(58.0, 390.0 - 58.0));
    });

    testWidgets('FindMyPage on phone snaps bottom sheet to 48% with People rows visible',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      Get.testMode = true;
      if (!GetIt.I.isRegistered<SettingsService>()) {
        GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
      }
      if (!GetIt.I.isRegistered<NavigatorService>()) {
        GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
      }
      if (!GetIt.I.isRegistered<BaseLogger>()) {
        GetIt.I.registerSingleton<BaseLogger>(_NoopFindMyLogger());
      }
      if (!GetIt.I.isRegistered<ThemesService>()) {
        GetIt.I.registerSingleton<ThemesService>(ThemesService());
      }
      if (!GetIt.I.isRegistered<ChatsService>()) {
        GetIt.I.registerSingleton<ChatsService>(ChatsService());
      }
      if (!GetIt.I.isRegistered<HttpService>()) {
        GetIt.I.registerSingleton<HttpService>(HttpService());
      }

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        Get.reset();
        await GetIt.I.reset();
      });

      final ctrl = Get.put(FindMyController(autoFetch: false));
      final people = [
        _friend(title: 'Alice Chen', handleAddress: 'alice@example.com'),
        _friend(title: 'Bob Martinez', handleAddress: 'bob@example.com'),
      ];
      ctrl.friends.addAll(people);
      ctrl.friendsWithLocation.addAll(people);
      ctrl.fetching2.value = false;

      await tester.pumpWidget(
        const GetMaterialApp(
          home: FindMyPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(ctrl.sheetController.isAttached, isTrue);
      expect(ctrl.sheetController.size, closeTo(0.48, 0.01));
      expect(find.text('Alice Chen'), findsOneWidget);
      expect(find.text('Bob Martinez'), findsOneWidget);
      final aliceRect = tester.getRect(find.text('Alice Chen'));
      expect(aliceRect.bottom, lessThan(844.0));
    });

    test('P0-1 & B2: shared controller uses one-shot GPS in ensureFriendsLoaded and full interactivity after activatePage',
        () async {
      var fakeNow = DateTime(2026, 11, 19, 12, 0);
      final pos = Position(
        longitude: -122.4194,
        latitude: 37.7749,
        timestamp: fakeNow,
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
      final streamController = StreamController<Position>.broadcast();
      int fetchPositionCalls = 0;
      int streamCalls = 0;
      int friendRefreshCalls = 0;

      final controller = FindMyController(
        now: () => fakeNow,
        autoFetch: false,
        fetchCurrentPosition: () async {
          fetchPositionCalls++;
          return pos;
        },
        positionStream: () {
          streamCalls++;
          return streamController.stream;
        },
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async {
          friendRefreshCalls++;
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
            statusCode: 200,
            data: {'data': []},
          );
        },
        refreshDevicesRequest: ({deviceId, force = false}) async => Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/devices/refresh'),
          statusCode: 200,
          data: {'data': []},
        ),
      )..isBackgroundShared = true;
      addTearDown(() async {
        controller.onClose();
        await streamController.close();
      });

      // B2: ensureFriendsLoaded before FindMyPage opens fetches one-shot position without starting GPS stream.
      await controller.ensureFriendsLoaded();
      await pumpEventQueue();
      expect(fetchPositionCalls, 1);
      expect(streamCalls, 0);
      expect(controller.location.value, isNotNull);
      expect(controller.locationSub, isNull);
      expect(controller.hasMovedToCurrentLocation.value, isFalse);

      // Before activatePage, tab changes & app resume do not trigger interactive refreshes.
      final callsBeforeActivate = friendRefreshCalls;
      controller.onTabChanged(0);
      controller.onAppResumed();
      expect(friendRefreshCalls, callsBeforeActivate);

      // P0-1: activatePage unlocks interactive refreshes, tab switches, and page GPS stream.
      controller.activatePage();
      await pumpEventQueue();
      expect(friendRefreshCalls, greaterThan(callsBeforeActivate));
      expect(streamCalls, 1);
      expect(controller.locationSub, isNotNull);

      fakeNow = fakeNow.add(const Duration(seconds: 15));
      final beforeTabSwitch = friendRefreshCalls;
      controller.onTabChanged(0);
      await pumpEventQueue();
      expect(friendRefreshCalls, beforeTabSwitch + 1);

      // Staleness timer pauses in background and restarts on resume.
      controller.onAppPaused();
      expect(controller.locationSub!.isPaused, isTrue);
      fakeNow = fakeNow.add(const Duration(seconds: 15));
      controller.onAppResumed();
      await pumpEventQueue();
      expect(controller.locationSub!.isPaused, isFalse);
      expect(friendRefreshCalls, beforeTabSwitch + 2);
    });

    testWidgets('P0-2 & P1-Visual: FindMyPage disposes shared TabController/GPS stream cleanly and fits pre-cached pins above phone sheet',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      Get.testMode = true;
      if (!GetIt.I.isRegistered<SettingsService>()) {
        GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
      }
      if (!GetIt.I.isRegistered<NavigatorService>()) {
        GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
      }
      if (!GetIt.I.isRegistered<BaseLogger>()) {
        GetIt.I.registerSingleton<BaseLogger>(_NoopFindMyLogger());
      }
      if (!GetIt.I.isRegistered<ThemesService>()) {
        GetIt.I.registerSingleton<ThemesService>(ThemesService());
      }
      if (!GetIt.I.isRegistered<ChatsService>()) {
        GetIt.I.registerSingleton<ChatsService>(ChatsService());
      }
      if (!GetIt.I.isRegistered<HttpService>()) {
        GetIt.I.registerSingleton<HttpService>(HttpService());
      }

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;

      final streamController = StreamController<Position>.broadcast();
      final now = DateTime(2026, 11, 19, 12, 0);
      final userPos = Position(
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
      final sfJson = {
        'coordinates': [37.7749, -122.4194],
        'long_address': 'San Francisco, CA',
        'short_address': 'SF',
        'title': 'SF',
        'handle': 'sf@example.com',
        'last_updated': now.millisecondsSinceEpoch,
        'status': 'live',
      };
      final cupJson = {
        'coordinates': [37.3349, -122.0090],
        'long_address': 'Cupertino, CA',
        'short_address': 'Cupertino',
        'title': 'Cupertino',
        'handle': 'cup@example.com',
        'last_updated': now.millisecondsSinceEpoch,
        'status': 'live',
      };
      final ctrl = Get.put(FindMyController(
        autoFetch: false,
        fetchCurrentPosition: () async => userPos,
        positionStream: () => streamController.stream,
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async => Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
          statusCode: 200,
          data: {
            'data': [sfJson, cupJson],
          },
        ),
        refreshDevicesRequest: ({deviceId, force = false}) async => Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/devices/refresh'),
          statusCode: 200,
          data: {'data': []},
        ),
      )..isBackgroundShared = true);

      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await streamController.close();
        Get.reset();
        await GetIt.I.reset();
      });

      // Pre-populate location + cached pins (simulating chat header ensure() before FindMyPage opens).
      await ctrl.ensureFriendsLoaded();
      final sf = ctrl.friends.first;

      await tester.pumpWidget(const GetMaterialApp(home: FindMyPage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(ctrl.tabController, isNotNull);
      expect(ctrl.locationSub, isNotNull);

      // Initial load focuses up close in 3D tilt rather than zooming out to a flat overview.
      expect(ctrl.cameraZoom.value, greaterThanOrEqualTo(15.5));
      expect(ctrl.cameraPitch.value, FindMyController.default3DPitch);

      // P1-Visual: Explicit fitAllPins fits cached pins cleanly above the 48% sheet.
      ctrl.fitAllPins();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final sfOffset = projectLatLngToScreenOffset(
        const LatLng(37.7749, -122.4194),
        center: ctrl.cameraCenter.value,
        zoom: ctrl.cameraZoom.value,
        viewportSize: const Size(390, 844),
      );
      final cupOffset = projectLatLngToScreenOffset(
        const LatLng(37.3349, -122.0090),
        center: ctrl.cameraCenter.value,
        zoom: ctrl.cameraZoom.value,
        viewportSize: const Size(390, 844),
      );
      final sheetHeight = 146.0 + (844.0 * 0.78 - 146.0) * 0.48;
      expect(sfOffset.dy, greaterThanOrEqualTo(46.0));
      expect(cupOffset.dy + 46.0, lessThanOrEqualTo(844.0 - sheetHeight));

      // P0-2: Disposing FindMyPage cleans up TabController and cancels continuous GPS stream on shared controller.
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pump();
      expect(ctrl.tabController, isNull);
      expect(ctrl.locationSub, isNull);
      expect(ctrl.completer.isCompleted, isFalse);

      // Re-opening via openForFriend remains null-safe when TabController is disposed and cleanly re-creates state.
      unawaited(ctrl.openForFriend(tester.element(find.byType(SizedBox)), sf));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(ctrl.tabIndex.value, 0);
      expect(ctrl.tabController, isNotNull);
      expect(ctrl.locationSub, isNotNull);
      expect(ctrl.selectedFriendId.value, sf.stableId);

      // Pop pushed route so FindMyPage disposes cleanly before test teardown.
      Navigator.of(tester.element(find.byType(FindMyPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(ctrl.tabController, isNull);
      expect(ctrl.locationSub, isNull);

      Get.delete<FindMyController>(force: true);
    });
  });

  group('FindMy list & camera UX (#426)', () {
    testWidgets('pinned friends are never duplicated and focused unpinned friend lifts to index 0 above Pinned',
        (tester) async {
      final now = DateTime.now();
      final pinned = FindMyFriend(
        latitude: 37.7749,
        longitude: -122.4194,
        title: 'Alice Pinned',
        subtitle: null,
        handle: Handle(address: '+15550001111'),
        handleAddress: '+15550001111',
        longAddress: '100 Market St, San Francisco, CA',
        shortAddress: 'San Francisco, CA',
        lastUpdated: now,
        status: LocationStatus.live,
        locatingInProgress: false,
      );
      final unpinned = FindMyFriend(
        latitude: 37.7850,
        longitude: -122.4090,
        title: 'Bob Unpinned',
        subtitle: null,
        handle: Handle(address: '+15550002222'),
        handleAddress: '+15550002222',
        longAddress: '200 Howard St, San Francisco, CA',
        shortAddress: 'San Francisco, CA',
        lastUpdated: now,
        status: LocationStatus.live,
        locatingInProgress: false,
      );
      final controller = FindMyController(
        autoFetch: false,
        readPrefList: (k) => k == kFindMyPinnedFriendsPrefKey ? ['15550001111'] : const [],
        writePrefList: (_, __) async {},
      );
      controller.setFriendPinned(pinned, true);
      controller.friends.assignAll([pinned, unpinned]);
      controller.friendsWithLocation.assignAll([pinned, unpinned]);

      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller.friendsController,
              slivers: [FindMyFriendsTabView(controller: controller)],
            ),
          ),
        ),
      );

      // Pinned friend appears exactly once (only in Pinned section, not duplicated in People).
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('People'), findsOneWidget);
      expect(find.text('Alice Pinned'), findsOneWidget);
      expect(find.text('Bob Unpinned'), findsOneWidget);

      // Focus unpinned friend: moves to index 0 above Pinned with expanded card and no duplicate below.
      controller.focusFriend(unpinned);
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('findmy-inline-friend-${unpinned.stableId}')), findsOneWidget);
      expect(find.byKey(const ValueKey('findmy-inline-refresh')), findsOneWidget);
      expect(find.byKey(const ValueKey('findmy-inline-chat')), findsOneWidget);
      expect(find.byKey(const ValueKey('findmy-inline-close')), findsOneWidget);
      expect(find.text('Bob Unpinned'), findsOneWidget);
      expect(find.text('Alice Pinned'), findsOneWidget);

      final bobTop = tester.getTopLeft(find.byKey(ValueKey('findmy-inline-friend-${unpinned.stableId}'))).dy;
      final pinnedHeaderTop = tester.getTopLeft(find.text('Pinned')).dy;
      expect(bobTop, lessThan(pinnedHeaderTop));

      // Close/Unfocus restores normal Pinned + People order with no duplicates.
      await tester.tap(find.byKey(const ValueKey('findmy-inline-close')));
      await tester.pumpAndSettle();
      expect(controller.selectedFriendId.value, isNull);
      expect(find.text('Alice Pinned'), findsOneWidget);
      expect(find.text('Bob Unpinned'), findsOneWidget);
    });

    test('map camera follows active friend across location updates and stops on clearSelection', () async {
      final now = DateTime.now();
      final cameraCalls = <({LatLng center, double zoom, double? pitch, bool fly})>[];
      final alice = FindMyFriend(
        latitude: 37.7749,
        longitude: -122.4194,
        title: 'Alice Follow',
        subtitle: null,
        handle: Handle(address: '+15550003333'),
        handleAddress: '+15550003333',
        longAddress: '100 Market St, San Francisco, CA',
        shortAddress: 'San Francisco, CA',
        lastUpdated: now,
        status: LocationStatus.live,
        locatingInProgress: false,
      );
      final controller = FindMyController(
        autoFetch: false,
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async => Response(
          requestOptions: RequestOptions(path: ''),
          statusCode: 200,
          data: {'data': []},
        ),
        fetchCurrentPosition: () async => null,
      );
      controller.registerCamera3DAnimator((center, zoom, {offset = Offset.zero, pitch, bearing, padding, fly = false}) {
        cameraCalls.add((center: center, zoom: zoom, pitch: pitch, fly: fly));
      });
      if (!controller.completer.isCompleted) controller.completer.complete();
      controller.activatePage();
      controller.friends.assignAll([alice]);
      controller.friendsWithLocation.assignAll([alice]);

      controller.focusFriend(alice);
      await Future<void>.delayed(Duration.zero);
      expect(cameraCalls.length, 1);
      expect(cameraCalls.last.center.latitude, closeTo(37.7749, 1e-4));

      // Live location update moves Alice -> camera follows keeping current zoom & pitch.
      controller.cameraZoom.value = 17.5;
      controller.cameraPitch.value = 32.0;
      controller.handleNewFindMyLocation(FindMyFriend(
        latitude: 37.7810,
        longitude: -122.4110,
        title: 'Alice Follow',
        subtitle: null,
        handle: Handle(address: '+15550003333'),
        handleAddress: '+15550003333',
        longAddress: '100 Market St, San Francisco, CA',
        shortAddress: 'San Francisco, CA',
        lastUpdated: now.add(const Duration(seconds: 5)),
        status: LocationStatus.live,
        locatingInProgress: false,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(cameraCalls.length, 2);
      expect(cameraCalls.last.center.latitude, closeTo(37.7810, 1e-4));
      expect(cameraCalls.last.center.longitude, closeTo(-122.4110, 1e-4));
      expect(cameraCalls.last.zoom, closeTo(17.5, 1e-4));
      expect(cameraCalls.last.pitch, closeTo(32.0, 1e-4));
      expect(cameraCalls.last.fly, isFalse);

      // Unfocus stops following subsequent location updates.
      controller.clearSelection();
      final countAfterClear = cameraCalls.length;
      controller.handleNewFindMyLocation(FindMyFriend(
        latitude: 37.7900,
        longitude: -122.4000,
        title: 'Alice Follow',
        subtitle: null,
        handle: Handle(address: '+15550003333'),
        handleAddress: '+15550003333',
        longAddress: '100 Market St, San Francisco, CA',
        shortAddress: 'San Francisco, CA',
        lastUpdated: now.add(const Duration(seconds: 10)),
        status: LocationStatus.live,
        locatingInProgress: false,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(cameraCalls.length, countAfterClear);
    });

    test('first-entry camera zooms to user location even when friends load before GPS resolves', () async {
      final gpsCompleter = Completer<Position?>();
      final cameraCalls = <({LatLng center, double zoom, double? pitch})>[];
      final now = DateTime.now();
      final controller = FindMyController(
        autoFetch: false,
        fetchCurrentPosition: () => gpsCompleter.future,
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async => Response(
          requestOptions: RequestOptions(path: ''),
          statusCode: 200,
          data: {
            'data': [
              {
                'id': 'friend-1',
                'handle': {'address': '+15550004444'},
                'coordinates': [40.7128, -74.0060],
                'last_updated': now.millisecondsSinceEpoch,
                'status': 'live',
              },
            ],
          },
        ),
        refreshDevicesRequest: ({deviceId, force = false}) async => Response(
          requestOptions: RequestOptions(path: ''),
          statusCode: 200,
          data: {'data': []},
        ),
      );
      controller.registerCamera3DAnimator((center, zoom, {offset = Offset.zero, pitch, bearing, padding, fly = false}) {
        cameraCalls.add((center: center, zoom: zoom, pitch: pitch));
      });
      if (!controller.completer.isCompleted) controller.completer.complete();

      controller.activatePage();
      // Friends load while GPS is still in flight -> must NOT prematurely focus NYC friend.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.friendsWithLocation, hasLength(1));
      expect(cameraCalls, isEmpty);

      // Now user's GPS resolves in San Francisco -> zooms straight to user's location!
      gpsCompleter.complete(
        Position(
          latitude: 37.7749,
          longitude: -122.4194,
          timestamp: now,
          accuracy: 5,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(cameraCalls, hasLength(1));
      expect(cameraCalls.single.center.latitude, closeTo(37.7749, 1e-4));
      expect(cameraCalls.single.center.longitude, closeTo(-122.4194, 1e-4));
      expect(cameraCalls.single.zoom, closeTo(FindMyController.defaultInitialZoom, 1e-4));
      expect(cameraCalls.single.pitch, closeTo(FindMyController.default3DPitch, 1e-4));
    });
  });

  group('FindMy ring, targeted device refresh, and offline row selection', () {
    test('FindMyDevice.fromJson classifies utag and Accessory deviceClass as accessories', () {
      final utag = FindMyDevice.fromJson({'id': 'utag:tag-1', 'name': 'SmartTag2'});
      final acc = FindMyDevice.fromJson({'id': 'apple-1', 'name': 'Keys', 'deviceClass': 'Accessory'});
      final phone = FindMyDevice.fromJson({'id': 'gfind:pixel', 'name': 'Pixel 10', 'isConsideredAccessory': false});
      expect(utag.isConsideredAccessory, isTrue);
      expect(acc.isConsideredAccessory, isTrue);
      expect(phone.isConsideredAccessory, isFalse);
    });

    test('targeted selectDevice refreshes with force:true and merges without dropping other devices', () async {
      final now = DateTime(2026, 11, 20, 12, 0, 0);
      final calls = <({String? deviceId, bool force})>[];
      final controller = FindMyController(
        now: () => now,
        autoFetch: false,
        fetchCurrentPosition: () async => null,
        positionStream: () => const Stream.empty(),
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async => Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
          statusCode: 200,
          data: {'data': []},
        ),
        refreshDevicesRequest: ({deviceId, force = false}) async {
          calls.add((deviceId: deviceId, force: force));
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/devices/refresh'),
            statusCode: 200,
            data: {
              'data': [
                {
                  'id': 'gfind:tag-1',
                  'name': 'Wallet Tag',
                  'isConsideredAccessory': true,
                  'location': {
                    'latitude': 37.3349,
                    'longitude': -122.009,
                    'timeStamp': now.millisecondsSinceEpoch,
                  },
                },
              ],
            },
          );
        },
      )..activatePage();
      if (!controller.completer.isCompleted) controller.completer.complete();
      await pumpEventQueue();
      calls.clear();
      addTearDown(controller.onClose);

      final other = FindMyDevice.fromJson({'id': 'apple:mac', 'name': 'MacBook'});
      final tag = FindMyDevice.fromJson({'id': 'gfind:tag-1', 'name': 'Wallet Tag', 'isConsideredAccessory': true});
      controller.devices.addAll([other, tag]);

      controller.selectDevice(tag);
      await pumpEventQueue();

      expect(calls, [(deviceId: 'gfind:tag-1', force: true)]);
      expect(controller.devices.map((d) => d.id), containsAll(['apple:mac', 'gfind:tag-1']));
      final updated = controller.devices.firstWhere((d) => d.id == 'gfind:tag-1');
      expect(updated.location?.latitude, closeTo(37.3349, 1e-4));
    });

    test('toggleRingDevice supports cloud start/stop, gfind BLE fallback, and utag SmartThings handoff', () async {
      final fakeBle = _FakeFindMyBleService();
      final ringCalls = <({String deviceId, bool stop, String? component})>[];
      var cloudShouldFail = false;

      final controller = FindMyController(autoFetch: false)
        ..bleService = fakeBle
        ..cloudRingOverride = (deviceId, {stop = false, component}) async {
          ringCalls.add((deviceId: deviceId, stop: stop, component: component));
          if (cloudShouldFail) {
            return Response(
              requestOptions: RequestOptions(path: '/icloud/findmy/devices/ring'),
              statusCode: 200,
              data: {'ok': false, 'error': 'Cloud ring unreachable'},
            );
          }
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/devices/ring'),
            statusCode: 200,
            data: {'ok': true},
          );
        };
      addTearDown(controller.onClose);

      final buds = FindMyDevice.fromJson({
        'id': 'gfind:buds-1',
        'name': 'Pixel Buds',
        'features': {
          'TRACKER_PROVIDER': 'gfind',
          'CAN_RING': true,
          'HAS_BLE_RING': true,
          'RING_COMPONENTS': ['left', 'right'],
        },
      });

      // BLE succeeds first on Android with component
      expect(await controller.toggleRingDevice(buds, component: 'left'), isTrue);
      expect(fakeBle.ringGoogleTagCalls, 1);
      expect(fakeBle.lastComponent, 'left');
      expect(controller.ringingDeviceId.value, 'gfind:buds-1');

      // Stop calls BLE + cloud
      expect(await controller.toggleRingDevice(buds, component: 'left'), isTrue);
      expect(controller.ringingDeviceId.value, isNull);
      expect(ringCalls.last, (deviceId: 'gfind:buds-1', stop: true, component: 'left'));

      // BLE failure falls back to cloud; cloud failure returns false & clears nothing
      fakeBle.bleRingSucceeds = false;
      expect(await controller.toggleRingDevice(buds, component: 'right'), isTrue);
      expect(ringCalls.last, (deviceId: 'gfind:buds-1', stop: false, component: 'right'));
      expect(controller.ringingDeviceId.value, 'gfind:buds-1');

      expect(await controller.toggleRingDevice(buds, component: 'right'), isTrue);
      expect(controller.ringingDeviceId.value, isNull);

      cloudShouldFail = true;
      expect(await controller.toggleRingDevice(buds, component: 'right'), isFalse);
      expect(controller.ringingDeviceId.value, isNull);

      // SmartTag2 hands off to SmartThings via launchUwbApp
      final smartTag = FindMyDevice.fromJson({
        'id': 'utag:st-1',
        'name': 'Keys SmartTag2',
        'features': {
          'TRACKER_PROVIDER': 'utag',
          'CAN_RING': true,
          'SUPPORTS_UWB': true,
        },
      });
      expect(await controller.toggleRingDevice(smartTag), isTrue);
      expect(fakeBle.launchUwbCalls, 1);
    });

    testWidgets('offline device and friend rows remain tappable and detail sheet shows L/R ring chips', (tester) async {
      final controller = FindMyController(autoFetch: false);
      addTearDown(controller.onClose);

      final offlineTag = FindMyDevice.fromJson({
        'id': 'gfind:offline-1',
        'name': 'Offline Tag',
        'isConsideredAccessory': true,
        'features': {
          'TRACKER_PROVIDER': 'gfind',
          'CAN_RING': true,
          'CAN_FIND_NEARBY': true,
          'RING_COMPONENTS': ['left', 'right'],
        },
      });
      final offlineFriend = FindMyFriend.fromJson({
        'id': 'friend-offline-1',
        'handle': {'address': '+15559990000'},
        'title': 'Bob',
      });
      controller.devices.add(offlineTag);
      controller.friends.add(offlineFriend);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                FindMyDeviceListTile(item: offlineTag, controller: controller, isItem: true),
                FindMyFriendListTile(item: offlineFriend, controller: controller, withLocation: false),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('Offline Tag'));
      await tester.pump();
      expect(controller.selectedDeviceId.value, 'gfind:offline-1');

      await tester.tap(find.text('Bob'));
      await tester.pump();
      expect(controller.selectedFriendId.value, offlineFriend.stableId);

      controller.selectDevice(offlineTag);
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

      expect(find.text('Find Nearby'), findsOneWidget);
      expect(find.text('Play Sound'), findsOneWidget);
      expect(find.text('LEFT'), findsOneWidget);
      expect(find.text('RIGHT'), findsOneWidget);
    });
  });
}

class _FakeFindMyBleService extends FindMyBleService {
  int ringGoogleTagCalls = 0;
  int launchUwbCalls = 0;
  bool bleRingSucceeds = true;
  bool permissionsGranted = true;
  String? lastComponent;

  @override
  bool get isSupported => true;

  @override
  Future<bool> checkPermissions() async => permissionsGranted;

  @override
  Future<bool> requestPermissions() async => permissionsGranted;

  @override
  Future<FindMyBleSpec?> getBleSpec(String deviceId, {bool forceRefresh = false}) async {
    return FindMyBleSpec(
      deviceId: deviceId,
      rawId: deviceId,
      provider: deviceId.startsWith('utag:') ? 'utag' : 'gfind',
      serviceUuid: deviceId.startsWith('utag:') ? 'fd5a' : 'feaa',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ringKeyHex: '0011223344556677',
      supportsUwb: deviceId.startsWith('utag:'),
      uwbPackage: deviceId.startsWith('utag:') ? 'com.samsung.android.oneconnect' : null,
    );
  }

  @override
  Future<bool> ringGoogleTag({
    required FindMyBleSpec spec,
    String? bleAddress,
    bool stop = false,
    String? component,
  }) async {
    ringGoogleTagCalls++;
    lastComponent = component;
    return bleRingSucceeds;
  }

  @override
  Future<bool> launchUwbApp(FindMyBleSpec spec) async {
    launchUwbCalls++;
    return true;
  }
}

class _NoopFindMyLogger extends BaseLogger {
  @override
  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void error(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}
