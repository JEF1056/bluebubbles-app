import 'dart:async';

import 'package:bluebubbles/services/network/http_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

class FindMyBleSpec {
  const FindMyBleSpec({
    required this.deviceId,
    required this.rawId,
    required this.provider,
    required this.serviceUuid,
    required this.expiresAt,
    this.eidsHex = const [],
    this.ringKeyHex,
    this.ringComponents = const [],
    this.expectedPrivacyIdsHex = const [],
    this.supportsUwb = false,
    this.uwbPackage,
    this.uwbAction,
    this.uwbClass,
    this.uwbExtraKey,
    this.uwbFallbackPackage,
  });

  final String deviceId;
  final String rawId;
  final String provider;
  final String serviceUuid;
  final DateTime expiresAt;
  final List<String> eidsHex;
  final String? ringKeyHex;
  final List<String> ringComponents;
  final List<String> expectedPrivacyIdsHex;
  final bool supportsUwb;
  final String? uwbPackage;
  final String? uwbAction;
  final String? uwbClass;
  final String? uwbExtraKey;
  final String? uwbFallbackPackage;

  bool isExpired([DateTime? now]) => (now ?? DateTime.now()).isAfter(expiresAt);

  factory FindMyBleSpec.fromJson(Map<String, dynamic> json) {
    final rawExp = json['expiresAt'];
    DateTime expiresAt;
    if (rawExp is num) {
      expiresAt = DateTime.fromMillisecondsSinceEpoch(rawExp.toInt());
    } else if (rawExp is String) {
      expiresAt = DateTime.tryParse(rawExp) ?? DateTime.now().add(const Duration(minutes: 5));
    } else {
      expiresAt = DateTime.now().add(const Duration(minutes: 5));
    }

    List<String> stringList(dynamic v) =>
        v is List ? v.map((e) => e.toString()).where((e) => e.isNotEmpty).toList() : const [];

    return FindMyBleSpec(
      deviceId: json['deviceId']?.toString() ?? '',
      rawId: json['rawId']?.toString() ?? '',
      provider: json['provider']?.toString() ?? '',
      serviceUuid: json['serviceUuid']?.toString() ?? '',
      expiresAt: expiresAt,
      eidsHex: stringList(json['eidsHex']),
      ringKeyHex: json['ringKeyHex']?.toString(),
      ringComponents: stringList(json['ringComponents']),
      expectedPrivacyIdsHex: stringList(json['expectedPrivacyIdsHex']),
      supportsUwb: json['supportsUwb'] == true,
      uwbPackage: json['uwbPackage']?.toString(),
      uwbAction: json['uwbAction']?.toString(),
      uwbClass: json['uwbClass']?.toString(),
      uwbExtraKey: json['uwbExtraKey']?.toString(),
      uwbFallbackPackage: json['uwbFallbackPackage']?.toString(),
    );
  }
}

class FindMyBleBeacon {
  const FindMyBleBeacon({
    required this.privacyIdHex,
    required this.bleAddress,
    required this.rssi,
    this.uwbCapable = false,
  });

  final String privacyIdHex;
  final String bleAddress;
  final int rssi;
  final bool uwbCapable;

  factory FindMyBleBeacon.fromMap(Map<dynamic, dynamic> map) => FindMyBleBeacon(
        privacyIdHex: map['privacyIdHex']?.toString() ?? '',
        bleAddress: map['bleAddress']?.toString() ?? '',
        rssi: (map['rssi'] as num?)?.toInt() ?? -100,
        uwbCapable: map['uwbCapable'] == true,
      );
}

class FindMyBleScanEvent {
  const FindMyBleScanEvent({
    this.matched = false,
    this.timedOut = false,
    this.rssi,
    this.meters,
    this.zone,
    this.trend,
    this.bleAddress,
    this.gattRingReady = false,
    this.nearbyBeacons = const [],
  });

  final bool matched;
  final bool timedOut;
  final double? rssi;
  final double? meters;
  final String? zone;
  final String? trend;
  final String? bleAddress;
  final bool gattRingReady;
  final List<FindMyBleBeacon> nearbyBeacons;

  factory FindMyBleScanEvent.fromMap(Map<dynamic, dynamic> map) {
    if (map['type'] == 'timeout') {
      return const FindMyBleScanEvent(timedOut: true);
    }
    final rawBeacons = map['nearbyBeacons'];
    final beacons = rawBeacons is List
        ? rawBeacons.whereType<Map>().map(FindMyBleBeacon.fromMap).toList()
        : const <FindMyBleBeacon>[];
    return FindMyBleScanEvent(
      matched: map['matched'] == true,
      rssi: (map['rssi'] as num?)?.toDouble(),
      meters: (map['meters'] as num?)?.toDouble(),
      zone: map['zone']?.toString(),
      trend: map['trend']?.toString(),
      bleAddress: map['bleAddress']?.toString(),
      gattRingReady: map['gattRingReady'] == true,
      nearbyBeacons: beacons,
    );
  }
}

typedef FindMyBleSpecFetcher = Future<Response> Function(String deviceId);

class FindMyBleService {
  FindMyBleService({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    FindMyBleSpecFetcher? fetchSpec,
    bool? isSupportedOverride,
    DateTime Function()? now,
  })  : _methodChannel = methodChannel ?? const MethodChannel('com.bluebubbles.messaging/findmy_ble'),
        _eventChannel = eventChannel ?? const EventChannel('com.bluebubbles.messaging/findmy_ble_events'),
        _fetchSpec = fetchSpec,
        _isSupportedOverride = isSupportedOverride,
        _now = now ?? DateTime.now;

  static final FindMyBleService instance = FindMyBleService();

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final FindMyBleSpecFetcher? _fetchSpec;
  final bool? _isSupportedOverride;
  final DateTime Function() _now;
  final Map<String, FindMyBleSpec> _specCache = {};

  bool get isSupported =>
      _isSupportedOverride ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Future<FindMyBleSpec?> getBleSpec(String deviceId, {bool forceRefresh = false}) async {
    final cached = _specCache[deviceId];
    if (!forceRefresh && cached != null && !cached.isExpired(_now())) {
      return cached;
    }

    Response? res;
    if (_fetchSpec != null) {
      res = await _fetchSpec(deviceId);
    } else if (GetIt.I.isRegistered<HttpService>()) {
      res = await HttpSvc.icloud.getDeviceBleSpec(deviceId);
    }
    final data = res?.data is Map ? res!.data['data'] : null;
    if (data is! Map) return null;
    final spec = FindMyBleSpec.fromJson(Map<String, dynamic>.from(data));
    _specCache[deviceId] = spec;
    return spec;
  }

  void clearCache([String? deviceId]) {
    if (deviceId == null) {
      _specCache.clear();
    } else {
      _specCache.remove(deviceId);
    }
  }

  Future<bool> checkPermissions() async {
    if (!isSupported) return false;
    try {
      return await _methodChannel.invokeMethod<bool>('checkPermissions') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestPermissions() async {
    if (!isSupported) return false;
    try {
      return await _methodChannel.invokeMethod<bool>('requestPermissions') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isBluetoothEnabled() async {
    if (!isSupported) return false;
    try {
      return await _methodChannel.invokeMethod<bool>('isBluetoothEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  Stream<FindMyBleScanEvent> scanStream(FindMyBleSpec spec) {
    if (!isSupported) return const Stream.empty();
    final args = <String, dynamic>{
      'deviceId': spec.deviceId,
      'provider': spec.provider,
      'eidsHex': spec.eidsHex,
      'expectedPrivacyIdsHex': spec.expectedPrivacyIdsHex,
    };
    return _eventChannel.receiveBroadcastStream(args).map((event) {
      if (event is Map) return FindMyBleScanEvent.fromMap(event);
      return const FindMyBleScanEvent();
    });
  }

  /// Human-readable error message from the most recent [ringGoogleTag] attempt, if it failed.
  String? lastRingError;

  Future<bool> ringGoogleTag({
    required FindMyBleSpec spec,
    String? bleAddress,
    bool stop = false,
    String? component,
  }) async {
    lastRingError = null;
    if (!isSupported) {
      lastRingError = 'BLE tag ringing is only supported on Android';
      return false;
    }
    if (spec.ringKeyHex == null || spec.ringKeyHex!.isEmpty) {
      lastRingError = 'Missing Google Find My ring key';
      return false;
    }
    try {
      final res = await _methodChannel.invokeMethod<dynamic>('ringGoogleTag', {
        'deviceId': spec.deviceId,
        'bleAddress': bleAddress,
        'eidsHex': spec.eidsHex,
        'ringKeyHex': spec.ringKeyHex,
        'stop': stop,
        'component': component,
      });
      final ok = res is Map && res['ok'] == true;
      if (!ok) {
        lastRingError = 'Direct BLE GATT ring failed';
      }
      return ok;
    } on PlatformException catch (e) {
      lastRingError = e.message ?? e.code;
      Logger.warn('FindMyBleService.ringGoogleTag failed: ${e.code} ${e.message}');
      return false;
    } catch (e) {
      lastRingError = e.toString();
      Logger.warn('FindMyBleService.ringGoogleTag failed', error: e);
      return false;
    }
  }

  Future<bool> lockSamsungBeacon(String deviceId, String privacyIdHex) async {
    if (!isSupported) return false;
    try {
      return await _methodChannel.invokeMethod<bool>('lockSamsungBeacon', {
            'deviceId': deviceId,
            'privacyIdHex': privacyIdHex,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> canLaunchUwbApp(FindMyBleSpec spec) async {
    if (!isSupported || !spec.supportsUwb) return false;
    try {
      return await _methodChannel.invokeMethod<bool>('canLaunchUwbApp', {
            'provider': spec.provider,
            'uwbPackage': spec.uwbPackage,
            'uwbAction': spec.uwbAction,
            'uwbClass': spec.uwbClass,
            'uwbFallbackPackage': spec.uwbFallbackPackage,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> launchUwbApp(FindMyBleSpec spec) async {
    if (!isSupported) return false;
    try {
      return await _methodChannel.invokeMethod<bool>('launchUwbApp', {
            'provider': spec.provider,
            'rawId': spec.rawId,
            'uwbPackage': spec.uwbPackage,
            'uwbAction': spec.uwbAction,
            'uwbClass': spec.uwbClass,
            'uwbExtraKey': spec.uwbExtraKey,
            'uwbFallbackPackage': spec.uwbFallbackPackage,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
