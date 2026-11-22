import 'dart:async';

import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_nearby_sheet.dart';
import 'package:bluebubbles/database/global/findmy_device.dart';
import 'package:bluebubbles/helpers/ui/findmy_helpers.dart';
import 'package:bluebubbles/services/backend/findmy/findmy_ble_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;

class _FakeFindMyBleService extends FindMyBleService {
  _FakeFindMyBleService({
    required this.spec,
    this.bleRingSucceeds = true,
    this.canLaunchUwb = true,
  }) : super(isSupportedOverride: true);

  final FindMyBleSpec spec;
  final bool bleRingSucceeds;
  final bool canLaunchUwb;
  final StreamController<FindMyBleScanEvent> scanController =
      StreamController<FindMyBleScanEvent>.broadcast();

  int bleRingCalls = 0;
  bool? lastStopArg;
  String? lockedPrivacyId;
  bool launchedUwb = false;

  @override
  Future<bool> checkPermissions() async => true;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> isBluetoothEnabled() async => true;

  @override
  Future<FindMyBleSpec?> getBleSpec(String deviceId, {bool forceRefresh = false}) async => spec;

  @override
  Stream<FindMyBleScanEvent> scanStream(FindMyBleSpec spec) => scanController.stream;

  @override
  Future<bool> ringGoogleTag({
    required FindMyBleSpec spec,
    String? bleAddress,
    bool stop = false,
    String? component,
  }) async {
    bleRingCalls++;
    lastStopArg = stop;
    return bleRingSucceeds;
  }

  @override
  Future<bool> lockSamsungBeacon(String deviceId, String privacyIdHex) async {
    lockedPrivacyId = privacyIdHex;
    return true;
  }

  @override
  Future<bool> canLaunchUwbApp(FindMyBleSpec spec) async => canLaunchUwb;

  @override
  Future<bool> launchUwbApp(FindMyBleSpec spec) async {
    launchedUwb = true;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
  });

  tearDown(() {
    Get.reset();
  });

  test('FindMyDevice.fromJson parses utag and gfind mixed features and splits Items vs Devices', () {
    final smartTag = FindMyDevice.fromJson({
      'id': 'utag:tag1',
      'name': 'Keys',
      'deviceClass': 'Accessory',
      'isConsideredAccessory': true,
      'role': {'emoji': '🔑', 'name': 'Keys'},
      'features': {
        'TRACKER_PROVIDER': 'utag',
        'CAN_RING': true,
        'CAN_FIND_NEARBY': true,
        'HAS_BLE_RING': false,
        'SUPPORTS_UWB': true,
        'RING_COMPONENTS': ['all'],
      },
    });
    final pixelPhone = FindMyDevice.fromJson({
      'id': 'gfind:phone1',
      'name': 'Pixel 9 Pro',
      'deviceClass': 'Android',
      'isConsideredAccessory': false,
      'features': {
        'TRACKER_PROVIDER': 'gfind',
        'CAN_RING': true,
        'CAN_FIND_NEARBY': false,
        'HAS_BLE_RING': false,
        'SUPPORTS_UWB': false,
      },
    });
    final earbuds = FindMyDevice.fromJson({
      'id': 'gfind:buds1',
      'name': 'Pixel Buds Pro 2',
      'deviceClass': 'Accessory',
      'isConsideredAccessory': true,
      'features': {
        'TRACKER_PROVIDER': 'gfind',
        'CAN_RING': true,
        'CAN_FIND_NEARBY': true,
        'HAS_BLE_RING': true,
        'RING_COMPONENTS': ['left', 'right', 'case'],
      },
    });

    expect(smartTag.isConsideredAccessory, isTrue);
    expect(smartTag.trackerProvider, 'utag');
    expect(smartTag.canRing, isTrue);
    expect(smartTag.canFindNearby, isTrue);
    expect(smartTag.supportsUwb, isTrue);
    expect(smartTag.role?['emoji'], '🔑');
    expect(iconForFindMyDevice(smartTag), Icons.sell_outlined);

    expect(pixelPhone.isConsideredAccessory, isFalse);
    expect(pixelPhone.trackerProvider, 'gfind');
    expect(iconForFindMyDevice(pixelPhone), Icons.phone_android);

    expect(earbuds.hasBleRing, isTrue);
    expect(earbuds.ringComponents, ['left', 'right', 'case']);
    expect(iconForFindMyDevice(earbuds), Icons.headphones);
  });

  test('FindMyBleService caches /ble-spec until expiresAt', () async {
    var fetchCount = 0;
    var now = DateTime(2026, 11, 20, 10, 0, 0);
    final service = FindMyBleService(
      isSupportedOverride: false,
      now: () => now,
      fetchSpec: (deviceId) async {
        fetchCount++;
        return Response(
          requestOptions: RequestOptions(path: '/ble-spec'),
          statusCode: 200,
          data: {
            'data': {
              'deviceId': deviceId,
              'rawId': 'raw1',
              'provider': 'gfind',
              'serviceUuid': 'feaa',
              'expiresAt': now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
              'eidsHex': ['0102'],
              'supportsUwb': false,
            },
          },
        );
      },
    );

    expect(service.isSupported, isFalse);
    final s1 = await service.getBleSpec('gfind:tag1');
    final s2 = await service.getBleSpec('gfind:tag1');
    expect(fetchCount, 1);
    expect(s1?.rawId, 'raw1');
    expect(s2?.rawId, 'raw1');

    now = now.add(const Duration(minutes: 6));
    await service.getBleSpec('gfind:tag1');
    expect(fetchCount, 2);
  });

  test('FindMyController.toggleRingDevice tries BLE first, falls back to cloud, and stops both', () async {
    final gfindTag = FindMyDevice.fromJson({
      'id': 'gfind:tag1',
      'name': 'Backpack Tag',
      'features': {
        'TRACKER_PROVIDER': 'gfind',
        'CAN_RING': true,
        'HAS_BLE_RING': true,
      },
    });
    final spec = FindMyBleSpec(
      deviceId: 'gfind:tag1',
      rawId: 'raw1',
      provider: 'gfind',
      serviceUuid: 'feaa',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ringKeyHex: '00112233445566778899aabbccddeeff',
    );

    final fakeBle = _FakeFindMyBleService(spec: spec, bleRingSucceeds: false);
    final controller = FindMyController(autoFetch: false);
    controller.bleService = fakeBle;
    final cloudCalls = <bool>[];
    controller.cloudRingOverride = (deviceId, {bool stop = false, String? component}) async {
      cloudCalls.add(stop);
      return Response(requestOptions: RequestOptions(path: '/ring'), statusCode: 200);
    };

    // Start: BLE fails -> falls back to cloud
    final started = await controller.toggleRingDevice(gfindTag);
    expect(started, isTrue);
    expect(fakeBle.bleRingCalls, 1);
    expect(fakeBle.lastStopArg, isFalse);
    expect(cloudCalls, [false]);
    expect(controller.ringingDeviceId.value, 'gfind:tag1');

    // Stop: calls BLE stop + cloud stop
    final stopped = await controller.toggleRingDevice(gfindTag);
    expect(stopped, isTrue);
    expect(fakeBle.bleRingCalls, 2);
    expect(fakeBle.lastStopArg, isTrue);
    expect(cloudCalls, [false, true]);
    expect(controller.ringingDeviceId.value, isNull);
  });

  testWidgets('FindMyNearbySheet shows RSSI radar, UWB button, earbuds chips, and SmartTag lock',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);

    final smartTag = FindMyDevice.fromJson({
      'id': 'utag:tag1',
      'name': 'Wallet Tag',
      'features': {
        'TRACKER_PROVIDER': 'utag',
        'CAN_RING': true,
        'CAN_FIND_NEARBY': true,
        'SUPPORTS_UWB': true,
        'RING_COMPONENTS': ['left', 'right'],
      },
    });
    final spec = FindMyBleSpec(
      deviceId: 'utag:tag1',
      rawId: 'utag-raw-1',
      provider: 'utag',
      serviceUuid: 'fd5a',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      supportsUwb: true,
      ringComponents: const ['left', 'right'],
    );
    final fakeBle = _FakeFindMyBleService(spec: spec, canLaunchUwb: true);
    final controller = FindMyController(autoFetch: false)..bleService = fakeBle;

    await tester.pumpWidget(
      GetMaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: FindMyNearbySheet(
              device: smartTag,
              controller: controller,
              bleService: fakeBle,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Wallet Tag'), findsOneWidget);
    expect(find.text('Open UWB Arrow'), findsOneWidget);
    expect(find.text('LEFT'), findsOneWidget);
    expect(find.text('RIGHT'), findsOneWidget);

    // Emit unmatched SmartTag beacon -> 1-tap Lock button appears
    fakeBle.scanController.add(
      const FindMyBleScanEvent(
        matched: false,
        nearbyBeacons: [
          FindMyBleBeacon(
            privacyIdHex: 'aabbccdd11223344',
            bleAddress: 'AA:BB:CC:DD:EE:FF',
            rssi: -58,
            uwbCapable: true,
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Lock'), findsOneWidget);
    await tester.tap(find.text('Lock'));
    await tester.pump();
    expect(fakeBle.lockedPrivacyId, 'aabbccdd11223344');

    // Emit matched RSSI event -> distance & trend pill appear
    fakeBle.scanController.add(
      const FindMyBleScanEvent(
        matched: true,
        rssi: -54,
        meters: 0.9,
        zone: 'here',
        trend: 'stronger',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('~0.9 m'), findsOneWidget);
    expect(find.text('Here • Stronger'), findsOneWidget);

    // Tap UWB button
    await tester.tap(find.text('Open UWB Arrow'));
    await tester.pump();
    expect(fakeBle.launchedUwb, isTrue);

    await fakeBle.scanController.close();
  });
}
