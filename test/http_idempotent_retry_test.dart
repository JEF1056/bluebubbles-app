import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/network/http_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:universal_io/io.dart';

class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;
  final ResponseBody Function(RequestOptions options) onFetch;

  _RecordingAdapter(this.onFetch);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    return onFetch(options);
  }
}

class _StubBaseApi implements BaseApi {
  @override
  final Dio dio;

  _StubBaseApi(this.dio);

  @override
  String get origin => 'http://192.168.1.10:1234';

  @override
  String get apiRoot => '$origin/api/v1';

  @override
  String get apiRootV2 => '$origin/api/v2';

  @override
  Map<String, String> get headers => const {};

  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const {}]) =>
      {...params, 'guid': 'test-guid'};

  @override
  Future<Response> runApiGuarded(Future<Response> Function() func, {bool checkOrigin = true}) => func();

  @override
  Future<Response> returnSuccessOrError(Response r) async => r;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await GetIt.I.reset();
  });

  group('HttpService.runApiGuarded idempotent connection-reset retry', () {
    late HttpService http;

    setUp(() {
      http = HttpService()..originOverride = 'http://192.168.1.10:1234';
      GetIt.I.registerSingleton<HttpService>(http);
    });

    test('retries GET once on HttpException connection closed (LAN http origin)', () async {
      var calls = 0;
      final req = RequestOptions(path: '/api/v1/ping', method: 'GET');
      final res = await http.runApiGuarded(() async {
        calls++;
        if (calls == 1) {
          throw DioException(
            requestOptions: req,
            type: DioExceptionType.connectionError,
            error: const HttpException('Connection closed before full header was received'),
          );
        }
        return Response(requestOptions: req, statusCode: 200);
      }, checkOrigin: false);

      expect(calls, 2);
      expect(res.statusCode, 200);
    });

    test('retries idempotent POST once on SocketException connection reset', () async {
      var calls = 0;
      final req = RequestOptions(
        path: '/api/v1/message/query',
        method: 'POST',
        extra: const {'idempotent': true},
      );
      final res = await http.runApiGuarded(() async {
        calls++;
        if (calls == 1) {
          throw DioException(
            requestOptions: req,
            type: DioExceptionType.unknown,
            error: const SocketException('Connection reset by peer'),
          );
        }
        return Response(requestOptions: req, statusCode: 200);
      }, checkOrigin: false);

      expect(calls, 2);
      expect(res.statusCode, 200);
    });

    test('does not retry non-idempotent POST on SocketException connection reset', () async {
      var calls = 0;
      final req = RequestOptions(path: '/api/v1/message/text', method: 'POST');
      await expectLater(
        () => http.runApiGuarded(() async {
          calls++;
          throw DioException(
            requestOptions: req,
            type: DioExceptionType.connectionError,
            error: const SocketException('Connection reset by peer'),
          );
        }, checkOrigin: false),
        throwsA(isA<DioException>()),
      );

      expect(calls, 1);
    });

    test('does not retry GET on connectionTimeout or cancel', () async {
      for (final type in [DioExceptionType.connectionTimeout, DioExceptionType.cancel]) {
        var calls = 0;
        final req = RequestOptions(path: '/api/v1/ping', method: 'GET');
        await expectLater(
          () => http.runApiGuarded(() async {
            calls++;
            throw DioException(requestOptions: req, type: type);
          }, checkOrigin: false),
          throwsA(isA<DioException>()),
        );
        expect(calls, 1);
      }
    });

    test('retries at most once when transient connection reset persists', () async {
      var calls = 0;
      final req = RequestOptions(path: '/api/v1/ping', method: 'GET');
      await expectLater(
        () => http.runApiGuarded(() async {
          calls++;
          throw DioException(
            requestOptions: req,
            type: DioExceptionType.connectionError,
            error: const HttpException('Connection closed while receiving data'),
          );
        }, checkOrigin: false),
        throwsA(isA<DioException>()),
      );

      expect(calls, 2);
    });
  });

  test('MessageApi.query marks request as idempotent', () async {
    final dio = Dio();
    final adapter = _RecordingAdapter(
      (_) => ResponseBody.fromString(
        jsonEncode({'status': 200, 'data': []}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    dio.httpClientAdapter = adapter;

    final api = MessageApi(_StubBaseApi(dio));
    await api.query(limit: 10);

    expect(adapter.lastOptions, isNotNull);
    expect(adapter.lastOptions!.extra['idempotent'], isTrue);
  });
}
