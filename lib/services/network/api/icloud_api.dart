import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:dio/dio.dart';

// ignore: camel_case_types
class iCloudApi {
  final BaseApi _svc;

  iCloudApi(this._svc);

  /// Get FindMy devices from server
  Future<Response> getDevices({CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/icloud/findmy/devices",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Fetch proxy-cached device/item preview icon bytes from server
  Future<Response> getDeviceIcon(String deviceId, {CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/icloud/findmy/devices/icon",
        queryParameters: _svc.buildQueryParams({'id': deviceId}),
        options: Options(
          responseType: ResponseType.bytes,
          headers: _svc.headers,
        ),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  static const Duration _minActiveRefreshTimeout = Duration(seconds: 30);

  Duration _refreshReceiveTimeout({int multiplier = 1}) {
    final base = _svc.dio.options.receiveTimeout;
    if (base == null || base <= Duration.zero) return _minActiveRefreshTimeout;
    final scaled = base * multiplier;
    return scaled > _minActiveRefreshTimeout ? scaled : _minActiveRefreshTimeout;
  }

  /// Refresh FindMy devices on server
  Future<Response> refreshDevices({String? deviceId, bool force = false, CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final data = <String, dynamic>{
        if (force) 'force': true,
        if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      };
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/icloud/findmy/devices/refresh",
        data: data.isEmpty ? null : data,
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
        options: Options(
          receiveTimeout: _refreshReceiveTimeout(multiplier: 12),
          headers: _svc.headers,
        ),
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Ring or stop ringing a FindMy / uTag / Google Find device
  Future<Response> ringDevice(
    String deviceId, {
    bool stop = false,
    String? component,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final data = <String, dynamic>{
        'deviceId': deviceId,
        'action': stop ? 'stop' : 'start',
        if (component != null && component.isNotEmpty) 'component': component,
      };
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/icloud/findmy/devices/ring",
        data: data,
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Fetch short-lived BLE scan / direct GATT ring spec for a tracker
  Future<Response> getDeviceBleSpec(String deviceId, {CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/icloud/findmy/devices/ble-spec",
        queryParameters: _svc.buildQueryParams({'deviceId': deviceId}),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get FindMy friends from server
  Future<Response> getFriends({CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/icloud/findmy/friends",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Refresh FindMy friends on server
  Future<Response> refreshFriends({
    String? handle,
    bool force = false,
    bool live = false,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final data = <String, dynamic>{
        if (force) 'force': true,
        if (live) 'live': true,
        if (handle != null) 'handle': handle,
      };
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/icloud/findmy/friends/refresh",
        data: data.isEmpty ? null : data,
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
        options: Options(
          receiveTimeout: _refreshReceiveTimeout(multiplier: 2),
          headers: _svc.headers,
        ),
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Start true FindMy live location streaming for a focused friend handle
  Future<Response> startLiveFindMyFriend(String handle, {CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/icloud/findmy/friends/live/start",
        data: {'handle': handle},
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Stop FindMy live location streaming for a focused friend handle (or any active live friend)
  Future<Response> stopLiveFindMyFriend({String? handle, CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final trimmed = handle?.trim();
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/icloud/findmy/friends/live/stop",
        data: (trimmed != null && trimmed.isNotEmpty) ? {'handle': trimmed} : null,
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get iCloud account info
  Future<Response> getAccountInfo({CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/icloud/account",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get the iCloud contact card: your own, or the one [address] shared with you
  Future<Response> getAccountContact({String? address, CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/icloud/contact",
        queryParameters: _svc.buildQueryParams({"address": ?address}),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Set iCloud account alias
  Future<Response> setAccountAlias(String alias, {CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/icloud/account/alias",
        data: {"alias": alias},
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }
}
