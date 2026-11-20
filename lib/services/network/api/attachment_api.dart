import 'dart:typed_data';

import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:universal_io/io.dart';

class AttachmentApi {
  final BaseApi _svc;

  AttachmentApi(this._svc);

  /// Get the attachment data for the specified [guid]
  Future<Response> fetch(String guid, {CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/$guid",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  static bool isWebUnsupportedImageMime(String? mimeType) {
    if (mimeType == null) return false;
    final lower = mimeType.toLowerCase();
    return lower == 'image/heic' ||
        lower == 'image/heif' ||
        lower == 'image/tiff' ||
        lower == 'image/heic-sequence' ||
        lower == 'image/heif-sequence';
  }

  static Map<String, dynamic> buildDownloadQueryParams({
    bool original = false,
    String? mimeType,
    int? width,
    String? quality,
    bool isWeb = kIsWeb,
  }) {
    final params = <String, dynamic>{};
    // Omit original=true on web for HEIC/HEIF/TIFF so bluebubbles-server auto-converts via sips.
    if (!(isWeb && isWebUnsupportedImageMime(mimeType))) {
      params["original"] = original;
    }
    if (width != null) params["width"] = width;
    if (quality != null) params["quality"] = quality;
    return params;
  }

  /// Download the attachment data for the specified [guid].
  /// If [savePath] is provided, downloads directly to that file path (more efficient, avoids loading into memory).
  /// Otherwise returns bytes in response data (legacy behavior for web).
  Future<Response> download(
    String guid, {
    void Function(int, int)? onReceiveProgress,
    bool original = false,
    String? mimeType,
    int? width,
    String? quality,
    CancelToken? cancelToken,
    String? savePath,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/$guid/download",
        queryParameters: _svc.buildQueryParams(buildDownloadQueryParams(
          original: original,
          mimeType: mimeType,
          width: width,
          quality: quality,
        )),
        options: Options(
          responseType: savePath != null ? ResponseType.stream : ResponseType.bytes,
          receiveTimeout: _svc.dio.options.receiveTimeout! * 12,
          headers: _svc.headers,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );

      // If savePath provided, write stream directly to file
      if (savePath != null && response.data != null) {
        final file = File(savePath);
        await file.parent.create(recursive: true);

        final raf = await file.open(mode: FileMode.write);
        try {
          await for (final chunk in response.data.stream) {
            await raf.writeFrom(chunk);
          }
        } finally {
          await raf.close();
        }

        // Return response with file info instead of bytes
        return Response(
          requestOptions: response.requestOptions,
          statusCode: response.statusCode,
          statusMessage: response.statusMessage,
          headers: response.headers,
          extra: response.extra,
        );
      }

      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get the live photo data for the specified [guid]
  Future<Response> downloadLivePhoto(
    String guid, {
    void Function(int, int)? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/$guid/live",
        queryParameters: _svc.buildQueryParams(),
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: _svc.dio.options.receiveTimeout! * 12,
          headers: _svc.headers,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get the attachment blurhash for the specified [guid]
  Future<Response> downloadBlurhash(
    String guid, {
    void Function(int, int)? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/$guid/blurhash",
        queryParameters: _svc.buildQueryParams(),
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: _svc.dio.options.receiveTimeout! * 12,
          headers: _svc.headers,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Stages [filePath] (or [bytes] on web) for `message/multipart`, whose parts name it by the response's `data.path`.
  Future<Response> upload(
    String filePath,
    String fileName, {
    Uint8List? bytes,
    void Function(int, int)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final multipart = bytes != null
          ? MultipartFile.fromBytes(bytes, filename: fileName)
          : await MultipartFile.fromFile(filePath, filename: fileName);
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/attachment/upload",
        queryParameters: _svc.buildQueryParams(),
        data: FormData.fromMap({"attachment": multipart}),
        onSendProgress: onSendProgress,
        cancelToken: cancelToken,
        options: Options(sendTimeout: _svc.dio.options.sendTimeout! * 12),
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get the number of attachments in the server iMessage DB
  Future<Response> getCount({CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/count",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }
}
