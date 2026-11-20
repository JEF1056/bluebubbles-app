import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/services/network/http_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await GetIt.I.reset();
  });

  group('C2-26 HttpService.runApiGuarded 502/503 retry safety', () {
    late HttpService http;

    setUp(() {
      http = HttpService()..originOverride = 'https://test.trycloudflare.com';
      GetIt.I.registerSingleton<HttpService>(http);
    });

    test('retries GET 502 once on tunnel origin', () async {
      var calls = 0;
      final res = await http.runApiGuarded(() async {
        calls++;
        return http.returnSuccessOrError(
          Response(
            requestOptions: RequestOptions(path: '/api/v1/ping', method: 'GET'),
            statusCode: calls == 1 ? 502 : 200,
          ),
        );
      }, checkOrigin: false);

      expect(calls, 2);
      expect(res.statusCode, 200);
    });

    test('does not retry non-idempotent POST 502 Response', () async {
      var calls = 0;
      await expectLater(
        () => http.runApiGuarded(() async {
          calls++;
          return http.returnSuccessOrError(
            Response(
              requestOptions: RequestOptions(path: '/api/v1/message/text', method: 'POST'),
              statusCode: 502,
            ),
          );
        }, checkOrigin: false),
        throwsA(isA<Response>()),
      );

      expect(calls, 1);
    });

    test('does not retry non-idempotent POST DioException 503', () async {
      var calls = 0;
      final req = RequestOptions(path: '/api/v1/message/text', method: 'POST');
      await expectLater(
        () => http.runApiGuarded(() async {
          calls++;
          throw DioException(
            requestOptions: req,
            response: Response(requestOptions: req, statusCode: 503),
            type: DioExceptionType.badResponse,
          );
        }, checkOrigin: false),
        throwsA(isA<DioException>()),
      );

      expect(calls, 1);
    });

    test('retries POST 503 when explicitly marked idempotent', () async {
      var calls = 0;
      final res = await http.runApiGuarded(() async {
        calls++;
        return http.returnSuccessOrError(
          Response(
            requestOptions: RequestOptions(
              path: '/api/v1/query',
              method: 'POST',
              extra: const {'idempotent': true},
            ),
            statusCode: calls == 1 ? 503 : 200,
          ),
        );
      }, checkOrigin: false);

      expect(calls, 2);
      expect(res.statusCode, 200);
    });
  });

  testWidgets('C2-24 ActiveCallController pauses ticker in background and recomputes elapsed on resume',
      (tester) async {
    var now = DateTime(2026, 1, 1, 12, 0, 0);
    final controller = ActiveCallController(
      now: () => now,
      deviceId: 'dev-1',
      deviceName: 'Pixel',
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.startOngoing(
      callUuid: 'call-1',
      callerName: 'Alice',
      callerAddress: 'alice@example.com',
      isVideo: false,
      connectedAt: now,
    );

    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.elapsed, const Duration(seconds: 2));

    controller.setForeground(false);
    final notifyCountWhileBg = notifications;
    now = now.add(const Duration(seconds: 40));
    await tester.pump(const Duration(seconds: 5));
    expect(notifications, notifyCountWhileBg);
    expect(controller.elapsed, const Duration(seconds: 2));

    controller.setForeground(true);
    expect(controller.elapsed, const Duration(seconds: 42));
    expect(notifications, greaterThan(notifyCountWhileBg));

    controller.clear();
    controller.dispose();
  });
}
