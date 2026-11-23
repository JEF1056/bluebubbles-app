import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_map_widget.dart';
import 'package:bluebubbles/database/global/findmy_friend.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/findmy_helpers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as maplibre;
// ignore: implementation_imports
import 'package:maplibre/src/translucent_pointer.dart';

FindMyFriend _testFriend({
  required String id,
  required String title,
  required double lat,
  required double lon,
}) =>
    FindMyFriend(
      latitude: lat,
      longitude: lon,
      longAddress: '$title Address',
      shortAddress: title,
      title: title,
      subtitle: null,
      handle: null,
      handleAddress: '$id@example.com',
      lastUpdated: DateTime(2026, 11, 20, 10, 0),
      status: LocationStatus.live,
      locatingInProgress: false,
    );

void main() {
  group('OpenFreeMap style resolution & legacy persistence', () {
    test('resolves all OpenFreeMap style URLs and dark-mode standard switch', () {
      expect(
        resolveFindMyStyleUrl(FindMyMapStyle.standard, Brightness.light),
        'https://tiles.openfreemap.org/styles/liberty',
      );
      expect(
        resolveFindMyStyleUrl(FindMyMapStyle.standard, Brightness.dark),
        'https://tiles.openfreemap.org/styles/dark',
      );
      expect(
        resolveFindMyStyleUrl(FindMyMapStyle.bright, Brightness.dark),
        'https://tiles.openfreemap.org/styles/bright',
      );
      expect(
        resolveFindMyStyleUrl(FindMyMapStyle.positron, Brightness.light),
        'https://tiles.openfreemap.org/styles/positron',
      );
      expect(
        resolveFindMyStyleUrl(FindMyMapStyle.dark, Brightness.light),
        'https://tiles.openfreemap.org/styles/dark',
      );
      expect(
        resolveFindMyStyleUrl(FindMyMapStyle.fiord, Brightness.light),
        'https://tiles.openfreemap.org/styles/fiord',
      );
      expect(FindMyMapStyle.standard.attribution, contains('OpenFreeMap'));
      expect(FindMyMapStyle.standard.attribution, contains('OpenMapTiles'));
      expect(FindMyMapStyle.standard.attribution, contains('OpenStreetMap'));
    });

    test('parseFindMyMapStyle falls back safely from legacy or unknown names', () {
      expect(parseFindMyMapStyle('satellite'), FindMyMapStyle.standard);
      expect(parseFindMyMapStyle('unknown-style'), FindMyMapStyle.standard);
      expect(parseFindMyMapStyle(null), FindMyMapStyle.standard);
      expect(parseFindMyMapStyle('fiord'), FindMyMapStyle.fiord);
      expect(parseFindMyMapStyle('POSITRON'), FindMyMapStyle.positron);
    });
  });

  group('3D bearing-aware marker depth ordering', () {
    maplibre.Marker mk(String key, double lat, double lon) => maplibre.Marker(
          point: maplibre.Geographic(lon: lon, lat: lat),
          size: const Size(96, 76),
          child: SizedBox.shrink(key: ValueKey(key)),
        );

    List<String> keysOf(List<maplibre.Marker> list) => [
          for (final m in list) (m.child.key as ValueKey<String>).value,
        ];

    test('sorts back-to-front along camera bearing and keeps selected highest', () {
      final north = mk('friend-north', 37.80, -122.40);
      final south = mk('friend-south', 37.70, -122.40);
      final east = mk('friend-east', 37.75, -122.30);
      final west = mk('friend-west', 37.75, -122.50);
      final self = mk('current', 37.75, -122.40);

      // Bearing 0 (North up): North is farthest (drawn first), South is closest (drawn later)
      expect(
        keysOf(orderFindMyMarkers([south, north], bearingDegrees: 0)),
        ['friend-north', 'friend-south'],
      );
      // Bearing 180 (South up): South is farthest (drawn first), North is closest
      expect(
        keysOf(orderFindMyMarkers([south, north], bearingDegrees: 180)),
        ['friend-south', 'friend-north'],
      );
      // Bearing 90 (East up): East is farthest (drawn first), West is closest
      expect(
        keysOf(orderFindMyMarkers([west, east], bearingDegrees: 90)),
        ['friend-east', 'friend-west'],
      );
      // Bearing 270 (West up): West is farthest (drawn first), East is closest
      expect(
        keysOf(orderFindMyMarkers([west, east], bearingDegrees: 270)),
        ['friend-west', 'friend-east'],
      );
      // Selected marker always sorts after current and unselected markers
      expect(
        keysOf(
          orderFindMyMarkers(
            [self, south, north],
            selectedFriendId: 'north',
            bearingDegrees: 0,
          ),
        ),
        ['friend-south', 'current', 'friend-north'],
      );
    });
  });

  group('Geodesic accuracy polygon math', () {
    test('builds closed GeoJSON polygon ring at requested geodesic radius', () {
      const center = LatLng(37.7749, -122.4194);
      const radiusMeters = 250.0;
      final feature = buildFindMyAccuracyFeature(center, radiusMeters, segments: 32);
      final ring = feature.geometry!.exterior!.positions.toList();

      expect(ring.length, 33);
      expect(ring.first.y, closeTo(ring.last.y, 1e-9));
      expect(ring.first.x, closeTo(ring.last.x, 1e-9));

      for (final pt in ring) {
        final dist = distanceMetersBetween(center, LatLng(pt.y, pt.x));
        expect(dist, closeTo(radiusMeters, 2.0));
      }
    });
  });

  group('OpenFreeMap 3D palette, anchor selection, and extrusion expression', () {
    test('uses neutral graphite dark palette and real OFM backgrounds', () {
      expect(resolveFindMyMapBackgroundColor(FindMyMapStyle.dark, Brightness.dark), const Color(0xFF0C0C0C));
      expect(resolveFindMyMapBackgroundColor(FindMyMapStyle.fiord, Brightness.dark), const Color(0xFF45516E));
      expect(resolveFindMyMapBackgroundColor(FindMyMapStyle.positron, Brightness.light), const Color(0xFFF2F3F0));
      expect(resolveFindMyMapBackgroundColor(FindMyMapStyle.bright, Brightness.light), const Color(0xFFF8F4F0));

      final darkBuilding = resolveFindMyBuildingExtrusionColor(FindMyMapStyle.dark, Brightness.dark);
      final darkTall = resolveFindMyBuildingExtrusionTallColor(FindMyMapStyle.dark, Brightness.dark);
      expect(darkBuilding, const Color(0xFF222428));
      expect(darkTall, const Color(0xFF2E3138));
      expect(resolveFindMyBuildingExtrusionOpacity(FindMyMapStyle.dark, Brightness.dark), 0.88);

      final exprJson = buildFindMy3DExtrusionColorExpression(FindMyMapStyle.dark, Brightness.dark).toJson();
      expect(exprJson, [
        'interpolate',
        ['linear'],
        ['coalesce', ['get', 'render_height'], 0],
        0,
        '#222428',
        45,
        '#2e3138',
      ]);
    });

    test('resolveFindMy3DAnchorLayerId skips early water_name symbol in dark and anchors after infra', () {
      // Mirrors live tiles.openfreemap.org/styles/dark layer order:
      // water_name [symbol] sits BEFORE building [fill] and roads/rail [line].
      final darkLayers = <({String id, String type, String? sourceLayer})>[
        (id: 'background', type: 'background', sourceLayer: null),
        (id: 'water', type: 'fill', sourceLayer: 'water'),
        (id: 'water_name', type: 'symbol', sourceLayer: 'water_name'),
        (id: 'building', type: 'fill', sourceLayer: 'building'),
        (id: 'highway_major_inner', type: 'line', sourceLayer: 'transportation'),
        (id: 'railway_dashline', type: 'line', sourceLayer: 'transportation'),
        (id: 'highway_name_other', type: 'symbol', sourceLayer: 'transportation_name'),
        (id: 'place_city', type: 'symbol', sourceLayer: 'place'),
      ];
      expect(resolveFindMy3DAnchorLayerId(darkLayers), 'highway_name_other');

      // Mirrors live bright: cablecar-dash [line] -> boundaries -> road_oneway [symbol]
      final brightLayers = <({String id, String type, String? sourceLayer})>[
        (id: 'background', type: 'background', sourceLayer: null),
        (id: 'building', type: 'fill', sourceLayer: 'building'),
        (id: 'building-top', type: 'fill', sourceLayer: 'building'),
        (id: 'cablecar-dash', type: 'line', sourceLayer: 'transportation'),
        (id: 'boundary_2', type: 'line', sourceLayer: 'boundary'),
        (id: 'road_oneway', type: 'symbol', sourceLayer: 'transportation'),
      ];
      expect(resolveFindMy3DAnchorLayerId(brightLayers), 'road_oneway');
      expect(isFindMyBuildingFillLayer(id: 'building', type: 'fill', sourceLayer: 'building'), isTrue);
      expect(isFindMyBuildingFillLayer(id: 'building-top', type: 'fill', sourceLayer: 'building'), isTrue);
      expect(isFindMyBuildingFillLayer(id: 'water', type: 'fill', sourceLayer: 'water'), isFalse);

      // Mirrors live fiord: building -> railway_dashline -> water_name [symbol]
      final fiordLayers = <({String id, String type, String? sourceLayer})>[
        (id: 'background', type: 'background', sourceLayer: null),
        (id: 'building', type: 'fill', sourceLayer: 'building'),
        (id: 'railway_dashline', type: 'line', sourceLayer: 'transportation'),
        (id: 'water_name', type: 'symbol', sourceLayer: 'water_name'),
      ];
      expect(resolveFindMy3DAnchorLayerId(fiordLayers), 'water_name');
    });
  });

  group('FindMyController 3D state & choreography', () {
    test('defaults to 3D at 32 deg tilt and close initial zoom, toggles 2D/3D, and resetNorth clears bearing', () {
      final controller = FindMyController(autoFetch: false);
      addTearDown(controller.onClose);

      expect(FindMyController.default3DPitch, 32.0);
      expect(FindMyController.defaultInitialZoom, 16.0);
      expect(FindMyController.defaultFocusZoom, 16.2);
      expect(controller.is3DEnabled.value, isTrue);
      expect(controller.cameraPitch.value, FindMyController.default3DPitch);
      expect(controller.cameraZoom.value, FindMyController.defaultInitialZoom);

      controller.toggle3D();
      expect(controller.is3DEnabled.value, isFalse);
      expect(controller.cameraPitch.value, 0.0);

      controller.toggle3D();
      expect(controller.is3DEnabled.value, isTrue);
      expect(controller.cameraPitch.value, FindMyController.default3DPitch);

      controller.onMapCameraChanged(
        center: const LatLng(37.77, -122.41),
        zoom: 16.0,
        pitch: 45.0,
        bearing: 135.0,
        reason: maplibre.CameraChangeReason.gesture,
      );
      expect(controller.cameraBearing.value, 135.0);

      controller.resetNorth();
      expect(controller.cameraBearing.value, 0.0);

      controller.toggle3D();
      expect(controller.is3DEnabled.value, isFalse);
      expect(controller.cameraPitch.value, 0.0);
    });

    test('gesture tilt updates is3DEnabled across threshold', () {
      final controller = FindMyController(autoFetch: false);
      addTearDown(controller.onClose);

      controller.onMapCameraChanged(
        center: const LatLng(37.77, -122.41),
        zoom: 16.0,
        pitch: 2.0,
        bearing: 0.0,
        reason: maplibre.CameraChangeReason.gesture,
      );
      expect(controller.is3DEnabled.value, isFalse);

      controller.onMapCameraChanged(
        center: const LatLng(37.77, -122.41),
        zoom: 16.0,
        pitch: 24.0,
        bearing: 12.0,
        reason: maplibre.CameraChangeReason.gesture,
      );
      expect(controller.is3DEnabled.value, isTrue);
    });

    test('flyToCamera pitches to 32 deg in 3D mode at street zoom and converts sheet offset to padding', () {
      final controller = FindMyController(autoFetch: false);
      addTearDown(controller.onClose);
      controller.toggle3D(enabled: true);

      controller.flyToCamera(
        const LatLng(37.3349, -122.0090),
        16.0,
        offset: const Offset(0, -140),
      );
      expect(controller.cameraPitch.value, FindMyController.default3DPitch);
      expect(controller.cameraZoom.value, 16.0);
      expect(controller.cameraPadding.bottom, 280.0);
    });
  });

  group('FindMyMapWidget 3D controls & coordinate glide', () {
    setUp(() {
      Get.testMode = true;
    });

    tearDown(() async {
      Get.reset();
      await GetIt.I.reset();
    });

    testWidgets('renders 3D toggle defaulting to 3D, compass, style picker, and interpolates coordinate updates', (tester) async {
      final controller = FindMyController(autoFetch: false);
      addTearDown(controller.onClose);

      final friend = _testFriend(id: 'alice', title: 'Alice', lat: 37.7749, lon: -122.4194);
      controller.friends.add(friend);
      controller.friendsWithLocation.add(friend);
      controller.buildFriendMarker(friend, animate: false);

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

      expect(find.byKey(const ValueKey('findmy-3d-toggle')), findsOneWidget);
      expect(find.byKey(const ValueKey('findmy-compass')), findsOneWidget);
      expect(find.byKey(const ValueKey('findmy-style-picker')), findsOneWidget);
      expect(find.text('3D'), findsOneWidget);

      // Toggle 2D/3D via UI button
      await tester.tap(find.byKey(const ValueKey('findmy-3d-toggle')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.is3DEnabled.value, isFalse);
      expect(find.text('2D'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('findmy-3d-toggle')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.is3DEnabled.value, isTrue);
      expect(find.text('3D'), findsOneWidget);

      // Coordinate glide interpolates smoothly over 650ms instead of snapping on frame 0
      final movedFriend = _testFriend(id: 'alice', title: 'Alice', lat: 37.7849, lon: -122.4094);
      controller.buildFriendMarker(movedFriend, animate: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final midPoint = controller.animatedPoints['alice@example.com']!;
      expect(midPoint.latitude, greaterThan(37.7749));
      expect(midPoint.latitude, lessThan(37.7849));

      await tester.pump(const Duration(milliseconds: 500));
      final endPoint = controller.animatedPoints['alice@example.com']!;
      expect(endPoint.latitude, closeTo(37.7849, 1e-6));
      expect(endPoint.longitude, closeTo(-122.4094, 1e-6));
    });
  });

  group('FindMy marker hit-testing & pinch-to-zoom pass-through', () {
    test('hitTestFindMyMarkerKey resolves topmost marker and leaves side padding open', () {
      const markers = [
        maplibre.Marker(
          point: maplibre.Geographic(lon: -122.42, lat: 37.77),
          size: Size(96, 76),
          alignment: Alignment.bottomCenter,
          child: SizedBox.shrink(key: ValueKey('friend-alice')),
        ),
        maplibre.Marker(
          point: maplibre.Geographic(lon: -122.42, lat: 37.77),
          size: Size(96, 76),
          alignment: Alignment.bottomCenter,
          child: SizedBox.shrink(key: ValueKey('device-mac')),
        ),
        maplibre.Marker(
          point: maplibre.Geographic(lon: -122.40, lat: 37.78),
          size: Size(72, 72),
          alignment: Alignment.center,
          child: SizedBox.shrink(key: ValueKey('current')),
        ),
      ];
      const offsets = [
        Offset(180, 300),
        Offset(190, 305),
        Offset(320, 420),
      ];

      // Overlap between friend-alice and device-mac selects topmost (device-mac)
      expect(
        hitTestFindMyMarkerKey(markers, offsets, const Offset(185, 280)),
        'device-mac',
      );
      // Only friend-alice covers x=156
      expect(
        hitTestFindMyMarkerKey(markers, offsets, const Offset(156, 270)),
        'friend-alice',
      );
      // Self location puck hit
      expect(
        hitTestFindMyMarkerKey(markers, offsets, const Offset(320, 420)),
        'current',
      );
      // Empty map background miss
      expect(
        hitTestFindMyMarkerKey(markers, offsets, const Offset(60, 60)),
        isNull,
      );
    });

    testWidgets('TranslucentPointer lets two-finger pinch reach map gesture detector even when started on a marker',
        (tester) async {
      int maxPointerCount = 0;
      double lastScale = 1.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 600,
              child: Stack(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleUpdate: (details) {
                      if (details.pointerCount > maxPointerCount) {
                        maxPointerCount = details.pointerCount;
                      }
                      lastScale = details.scale;
                    },
                    child: const SizedBox.expand(),
                  ),
                  TranslucentPointer(
                    child: Stack(
                      children: [
                        Positioned(
                          left: 100,
                          top: 200,
                          width: 96,
                          height: 76,
                          child: Container(
                            key: const ValueKey('pin-box'),
                            color: Colors.blue,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Finger 1 lands directly inside the opaque pin box; finger 2 lands nearby.
      final g1 = await tester.startGesture(const Offset(148, 240));
      final g2 = await tester.startGesture(const Offset(240, 240));
      await tester.pump();
      await g1.moveBy(const Offset(-40, 0));
      await g2.moveBy(const Offset(40, 0));
      await tester.pump();
      await g1.up();
      await g2.up();
      await tester.pump();

      expect(maxPointerCount, 2);
      expect(lastScale, greaterThan(1.2));
    });
  });
}
