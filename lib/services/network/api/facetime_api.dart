import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:dio/dio.dart';

class FaceTimeApi {
  final BaseApi _svc;
  final ClientDeviceIdentity Function() _identityResolver;
  static final RegExp _dtmfRegex = RegExp(r'^[0-9*#ABCD]$');

  FaceTimeApi(this._svc, {ClientDeviceIdentity Function()? identityResolver})
      : _identityResolver = identityResolver ?? ClientDeviceIdentity.resolve;

  Map<String, dynamic> _identityData({String? displayName, String? chatGuid}) {
    final identity = _identityResolver();
    return {
      'deviceId': identity.deviceId,
      'deviceName': identity.deviceName,
      if (displayName != null && displayName.isNotEmpty) 'displayName': displayName,
      if (chatGuid != null && chatGuid.isNotEmpty) 'chatGuid': chatGuid,
    };
  }

  static String? _extractLink(dynamic rawLink) {
    if (rawLink is String && rawLink.isNotEmpty) return rawLink;
    if (rawLink is Map && rawLink['url'] is String && (rawLink['url'] as String).isNotEmpty) {
      return rawLink['url'] as String;
    }
    return null;
  }

  static PlacedFaceTimeCall _parsePlacedCall(Map<String, dynamic> data, {String? fallbackUuid}) {
    final session = data['session'] is Map ? (data['session'] as Map).cast<String, dynamic>() : null;
    final rawCall = data['call'] is Map ? (data['call'] as Map).cast<String, dynamic>() : null;
    final callMap = rawCall ?? session ?? <String, dynamic>{'call_uuid': fallbackUuid ?? ''};
    return PlacedFaceTimeCall(
      link: _extractLink(data['link']) ?? _extractLink(session?['link']),
      call: FaceTimeCall.fromMap(callMap),
      session: session,
    );
  }

  /// Lists active FaceTime/iPhone call sessions on the server for reconnect reconciliation.
  Future<List<Map<String, dynamic>>> getFaceTimeSessions({CancelToken? cancelToken}) async {
    final response = await _svc.runApiGuarded(() {
      return _svc.dio.get(
        "${_svc.apiRoot}/facetime/sessions",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
    });
    final body = response.data;
    final dynamic rawSessions;
    if (body is Map) {
      final data = body['data'];
      rawSessions = data is Map ? data['sessions'] : body['sessions'];
    } else {
      rawSessions = null;
    }
    if (rawSessions is! List) return <Map<String, dynamic>>[];
    return rawSessions
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
  }

  /// Lists Mac-synced FaceTime/Phone call history entries from the server.
  Future<Response> getCallHistory({
    int limit = 50,
    int offset = 0,
    bool missedOnly = false,
    CancelToken? cancelToken,
  }) {
    return _svc.runApiGuarded(() {
      return _svc.dio.get(
        "${_svc.apiRoot}/facetime/history",
        queryParameters: _svc.buildQueryParams({
          'limit': limit,
          'offset': offset,
          if (missedOnly) 'missedOnly': true,
        }),
        cancelToken: cancelToken,
      );
    });
  }

  /// Creates a standalone FaceTime link session tracked by the server.
  Future<PlacedFaceTimeCall> createFaceTimeSession({
    String? displayName,
    String? chatGuid,
    List<String>? addresses,
    CancelToken? cancelToken,
  }) async {
    final response = await _runWithRefusal(() => _svc.runApiGuarded(() async {
          final response = await _svc.dio.post(
            "${_svc.apiRoot}/facetime/session",
            queryParameters: _svc.buildQueryParams(),
            data: {
              ..._identityData(displayName: displayName, chatGuid: chatGuid),
              if (addresses != null && addresses.isNotEmpty) 'addresses': addresses,
            },
            cancelToken: cancelToken,
          );
          return _svc.returnSuccessOrError(response);
        }));
    final data = (response.data['data'] as Map).cast<String, dynamic>();
    return _parsePlacedCall(data);
  }

  /// Answer a FaceTime call with the given [callUuid].
  /// The response is a data object with a `link` key containing the call link.
  Future<Response> answer(
    String callUuid, {
    bool audioOnly = false,
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/facetime/answer/$callUuid",
        queryParameters: _svc.buildQueryParams(),
        data: {
          if (audioOnly) 'audioOnly': true,
          ..._identityData(displayName: displayName, chatGuid: chatGuid),
        },
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Answer an incoming FaceTime call and claim it for this client device.
  Future<PlacedFaceTimeCall> answerFaceTime(
    String callUuid, {
    bool audioOnly = false,
    String? mode,
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) async {
    final response = await _runWithRefusal(() => _svc.runApiGuarded(() async {
          final response = await _svc.dio.post(
            "${_svc.apiRoot}/facetime/session/$callUuid/answer",
            queryParameters: _svc.buildQueryParams(),
            data: {
              'audioOnly': audioOnly,
              if (mode != null && mode.isNotEmpty) 'mode': mode,
              ..._identityData(displayName: displayName, chatGuid: chatGuid),
            },
            cancelToken: cancelToken,
          );
          return _svc.returnSuccessOrError(response);
        }));
    final data = (response.data['data'] as Map).cast<String, dynamic>();
    return _parsePlacedCall(data, fallbackUuid: callUuid);
  }

  /// Transfer an active FaceTime call onto this client device (`mode`: `"video"` or `"audio"`).
  Future<PlacedFaceTimeCall> handoffFaceTime(
    String callUuid, {
    String? mode,
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) async {
    final response = await _runWithRefusal(() => _svc.runApiGuarded(() async {
          final response = await _svc.dio.post(
            "${_svc.apiRoot}/facetime/session/$callUuid/handoff",
            queryParameters: _svc.buildQueryParams(),
            data: {
              if (mode != null && mode.isNotEmpty) 'mode': mode,
              ..._identityData(displayName: displayName, chatGuid: chatGuid),
            },
            cancelToken: cancelToken,
          );
          return _svc.returnSuccessOrError(response);
        }));
    final data = (response.data['data'] as Map).cast<String, dynamic>();
    return _parsePlacedCall(data, fallbackUuid: callUuid);
  }

  /// Transfer an active call back to the paired iPhone.
  Future<Map<String, dynamic>?> transferBackFaceTime(
    String callUuid, {
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) async {
    final response = await _runWithRefusal(() => _svc.runApiGuarded(() async {
          final response = await _svc.dio.post(
            "${_svc.apiRoot}/facetime/session/$callUuid/transfer_back",
            queryParameters: _svc.buildQueryParams(),
            data: _identityData(displayName: displayName, chatGuid: chatGuid),
            cancelToken: cancelToken,
          );
          return _svc.returnSuccessOrError(response);
        }));
    final body = response.data;
    if (body is Map && body['data'] is Map && body['data']['session'] is Map) {
      return (body['data']['session'] as Map).cast<String, dynamic>();
    }
    return null;
  }

  /// Sync mute state to the server for an active FaceTime call.
  Future<Response> setFaceTimeMuted(
    String callUuid,
    bool muted, {
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/facetime/session/$callUuid/mute",
        queryParameters: _svc.buildQueryParams(),
        data: {
          'muted': muted,
          ..._identityData(displayName: displayName, chatGuid: chatGuid),
        },
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Leave a FaceTime call with the given [callUuid]
  Future<Response> leave(
    String callUuid, {
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/facetime/leave/$callUuid",
        queryParameters: _svc.buildQueryParams(),
        data: _identityData(displayName: displayName, chatGuid: chatGuid),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Leave an active or outgoing FaceTime session on the server.
  Future<Response> leaveFaceTime(
    String callUuid, {
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/facetime/session/$callUuid/leave",
        queryParameters: _svc.buildQueryParams(),
        data: _identityData(displayName: displayName, chatGuid: chatGuid),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Decline an incoming FaceTime session on the server.
  Future<Response> declineFaceTime(
    String callUuid, {
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/facetime/session/$callUuid/decline",
        queryParameters: _svc.buildQueryParams(),
        data: _identityData(displayName: displayName, chatGuid: chatGuid),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Send a DTMF tone [digit] (`[0-9*#ABCD]`) for an active call [callUuid].
  Future<Response> dtmf(String callUuid, String digit, {CancelToken? cancelToken}) async {
    final normalized = digit.trim().toUpperCase();
    if (callUuid.isEmpty || !_dtmfRegex.hasMatch(normalized)) {
      throw ArgumentError.value(digit, 'digit', 'DTMF digit must match [0-9*#ABCD]');
    }
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/facetime/dtmf",
        queryParameters: _svc.buildQueryParams(),
        data: {
          'callUuid': callUuid,
          'digit': normalized,
        },
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Places an outgoing FaceTime/iPhone call and returns its session/link details.
  Future<PlacedFaceTimeCall> placeFaceTimeCall(
    String address, {
    bool video = true,
    bool isTelephony = false,
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) {
    return call(
      address,
      video: video,
      isTelephony: isTelephony,
      displayName: displayName,
      chatGuid: chatGuid,
      cancelToken: cancelToken,
    );
  }

  /// `POST facetime/call` — has the server's Mac ring [address] on FaceTime, and hands back a
  /// link to join the call. The Mac leaves on its own once someone has joined.
  ///
  /// **v2 only**: gate on `ServerDetails.supportsFaceTimeCalls`. [video] false rings the
  /// callee as FaceTime Audio.
  ///
  /// Refusals are thrown as [FaceTimeException] with the server's sentence: FaceTime or
  /// outgoing calls switched off on the server (403), or an address that isn't on FaceTime
  /// (400, checked before anything rings). When the call rang but no link came back, the
  /// exception carries the [FaceTimeCall] so the caller can hang it up.
  ///
  /// The server takes a list of addresses, but dials them as one 1:1 request; group calls
  /// aren't a supported flow, so this takes one.
  Future<PlacedFaceTimeCall> call(
    String address, {
    bool video = true,
    bool isTelephony = false,
    String? mode,
    String? displayName,
    String? chatGuid,
    CancelToken? cancelToken,
  }) async {
    final Response response;
    try {
      response = await _svc.runApiGuarded(() async {
        final response = await _svc.dio.post(
          "${_svc.apiRootV2}/facetime/call",
          queryParameters: _svc.buildQueryParams(),
          data: {
            'addresses': [address],
            'video': video,
            if (isTelephony) 'isTelephony': true,
            if (mode != null && mode.isNotEmpty) 'mode': mode,
            ..._identityData(displayName: displayName, chatGuid: chatGuid),
          },
          // An availability check, a dial (up to 20s) and a link (up to 15s) on the Mac.
          options: Options(receiveTimeout: _svc.dio.options.receiveTimeout! * 3),
          cancelToken: cancelToken,
        );
        return _svc.returnSuccessOrError(response);
      });
    } on Response catch (r) {
      throw _refusal(r);
    } on DioException catch (e) {
      if (e.response == null || CancelToken.isCancel(e)) rethrow;
      throw _refusal(e.response!);
    }

    final data = (response.data['data'] as Map).cast<String, dynamic>();
    return _parsePlacedCall(data);
  }

  Future<Response> _runWithRefusal(Future<Response> Function() request) async {
    try {
      return await request();
    } on Response catch (r) {
      throw _refusal(r);
    } on DioException catch (e) {
      if (e.response == null || CancelToken.isCancel(e)) rethrow;
      throw _refusal(e.response!);
    }
  }

  FaceTimeException _refusal(Response r) {
    final body = r.data is Map ? r.data as Map : const {};
    final error = body['error'] is Map ? body['error'] as Map : const {};
    final data = body['data'] is Map ? body['data'] as Map : const {};
    final message = (error['message'] ?? body['message'] ?? body['ended_error'] ?? data['ended_error'])?.toString();
    final call = data['call'] is Map ? FaceTimeCall.fromMap((data['call'] as Map).cast<String, dynamic>()) : null;
    return FaceTimeException(
      message == null || message.isEmpty ? "The server returned ${r.statusCode}" : message,
      statusCode: r.statusCode,
      call: call,
    );
  }
}
