import 'dart:async';

import 'package:bluebubbles/services/backend/settings/shared_preferences_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:universal_io/io.dart';
import 'package:uuid/uuid.dart';

/// Stable client identity sent on FaceTime session/call API requests so the
/// server can track which device owns or took over an active call.
class ClientDeviceIdentity {
  static const String prefsKey = 'facetime_client_device_id';
  static String? _cachedDeviceId;

  final String deviceId;
  final String deviceName;

  const ClientDeviceIdentity({required this.deviceId, required this.deviceName});

  static ClientDeviceIdentity resolve({String? deviceId, String? deviceName}) {
    return ClientDeviceIdentity(
      deviceId: (deviceId != null && deviceId.isNotEmpty) ? deviceId : resolveDeviceId(),
      deviceName: (deviceName != null && deviceName.isNotEmpty) ? deviceName : resolveDeviceName(),
    );
  }

  static String resolveDeviceId() {
    final cached = _cachedDeviceId;
    if (cached != null && cached.isNotEmpty) return cached;

    if (GetIt.I.isRegistered<SharedPreferencesService>()) {
      try {
        // ignore: deprecated_member_use_from_same_package
        final prefs = GetIt.I<SharedPreferencesService>().i;
        final stored = prefs.getString(prefsKey);
        if (stored != null && stored.isNotEmpty) {
          _cachedDeviceId = stored;
          return stored;
        }
        final generated = const Uuid().v4();
        _cachedDeviceId = generated;
        unawaited(prefs.setString(prefsKey, generated));
        return generated;
      } catch (_) {
        // SharedPreferencesService may be registered in tests before .init().
      }
    }

    final generated = const Uuid().v4();
    _cachedDeviceId = generated;
    return generated;
  }

  static String resolveDeviceName() {
    if (kIsWeb) return 'Web';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'Unknown';
  }

  @visibleForTesting
  static void setCachedDeviceIdForTest(String? id) {
    _cachedDeviceId = id;
  }
}

/// A FaceTime call the server's Mac is on, from `/api/v2/facetime/*`'s `call` object.
class FaceTimeCall {
  final String callUuid;
  final String? status;
  final bool isVideo;
  final String? address;
  final String? groupUuid;

  const FaceTimeCall({required this.callUuid, this.status, this.isVideo = true, this.address, this.groupUuid});

  factory FaceTimeCall.fromMap(Map<String, dynamic> map) => FaceTimeCall(
    callUuid: (map['call_uuid'] ?? map['uuid'] ?? map['session_uuid'] ?? '') as String,
    status: map['status'] as String?,
    isVideo: map['is_video'] as bool? ?? true,
    address: map['address'] as String?,
    groupUuid: map['group_uuid'] as String?,
  );
}

/// What `POST facetime/call`, `/session`, `/answer`, or `/handoff` answers with.
class PlacedFaceTimeCall {
  final String? link;
  final FaceTimeCall call;
  final Map<String, dynamic>? session;

  const PlacedFaceTimeCall({this.link, required this.call, this.session});
}

/// A refusal from the server's FaceTime routes, carrying its sentence for the user.
///
/// [call] is set when the call was placed but no link could be minted for it: the call is
/// ringing, so the caller should offer to hang it up (`FaceTimeApi.leave`).
class FaceTimeException implements Exception {
  final String message;
  final int? statusCode;
  final FaceTimeCall? call;

  const FaceTimeException(this.message, {this.statusCode, this.call});

  @override
  String toString() => message;
}
