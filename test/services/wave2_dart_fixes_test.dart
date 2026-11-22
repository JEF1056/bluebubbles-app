import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/oauth_helpers.dart';
import 'package:bluebubbles/models/models.dart' show ServerDetails;
import 'package:bluebubbles/services/network/api/firebase_api.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/network/downloads_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response, FormData;
import 'package:get_it/get_it.dart';

class _SilentLogger extends BaseLogger {
  @override
  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void error(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

class _FakeSettingsService extends SettingsService {
  final Rx<ServerDetails> _details = const ServerDetails(
    macOSVersion: 14,
    macOSMinorVersion: 0,
    serverVersion: '1.9.0',
    serverVersionCode: 10900,
  ).obs;

  @override
  ServerDetails get serverDetails => _details.value;
}

class _StubAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions options) handler;

  _StubAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return handler(options);
  }
}

class _FakeHttpService extends HttpService {
  _FakeHttpService(HttpClientAdapter adapter) {
    dio = Dio()..httpClientAdapter = adapter;
    message = MessageApi(this);
    firebase = FirebaseApi(this);
  }

  @override
  String get origin => 'https://example.invalid';
}

ResponseBody _jsonBody(Object? payload, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(payload),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await GetIt.I.reset();
    Get.reset();
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
    final settings = _FakeSettingsService()..settings = Settings();
    settings.settings.guidAuthKey.value = 'test-guid';
    GetIt.I.registerSingleton<SettingsService>(settings);
  });

  tearDown(() async {
    await GetIt.I.reset();
    Get.reset();
  });

  group('MessageApi Wave 2 fixes', () {
    test('getCount rejects updated && onlyMe via assert and allows single flags', () async {
      final requestedPaths = <String>[];
      final http = _FakeHttpService(_StubAdapter((options) {
        requestedPaths.add(options.uri.path);
        return _jsonBody({'status': 200, 'data': {'total': 3}});
      }));
      GetIt.I.registerSingleton<HttpService>(http);

      await expectLater(
        () => http.message.getCount(updated: true, onlyMe: true),
        throwsAssertionError,
      );

      await http.message.getCount(updated: true, onlyMe: false);
      await http.message.getCount(updated: false, onlyMe: true);
      await http.message.getCount();

      expect(requestedPaths, [
        '/api/v1/message/count/updated',
        '/api/v1/message/count/me',
        '/api/v1/message/count',
      ]);
    });

    test('sendAttachmentChunked handles 0-byte files without LateInitializationError', () async {
      final chunkFields = <Map<String, String>>[];
      final http = _FakeHttpService(_StubAdapter((options) {
        final form = options.data as FormData;
        chunkFields.add(Map<String, String>.fromEntries(form.fields));
        return _jsonBody({'status': 200, 'data': {'guid': 'msg-1'}});
      }));
      GetIt.I.registerSingleton<HttpService>(http);

      final tempDir = Directory.systemTemp.createTempSync('wave2_empty_chunk_');
      addTearDown(() => tempDir.delete(recursive: true));
      final diskFile = File('${tempDir.path}/empty.txt')..writeAsBytesSync(const []);
      final emptyFile = PlatformFile(
        name: 'empty.txt',
        path: diskFile.path,
        size: 0,
        bytes: Uint8List(0),
      );

      final response = await http.message.sendAttachmentChunked(
        'iMessage;-;+15555550100',
        'temp-guid-1',
        emptyFile,
      );

      expect(response.statusCode, 200);
      expect(chunkFields, hasLength(1));
      expect(chunkFields.single['chunkIndex'], '0');
      expect(chunkFields.single['isComplete'], 'true');
    });
  });

  group('fetchFirebaseProjects null safety', () {
    test('handles null results and missing resources without throwing', () async {
      final http = _FakeHttpService(_StubAdapter((options) {
        if (options.uri.toString().contains('projects?')) {
          return _jsonBody({
            'results': [
              {'projectId': 'p1'},
              {'projectId': 'p2', 'resources': null},
              'unexpected-entry',
            ],
          });
        }
        return _jsonBody({
          'fields': {
            'serverUrl': {'stringValue': 'https://bb.example'},
          },
        });
      }));
      GetIt.I.registerSingleton<HttpService>(http);

      final projects = await fetchFirebaseProjects('token');
      expect(projects, hasLength(2));
      expect(projects.every((p) => p['serverUrl'] == 'https://bb.example'), isTrue);

      GetIt.I.unregister<HttpService>();
      GetIt.I.registerSingleton<HttpService>(
        _FakeHttpService(_StubAdapter((_) => _jsonBody({'results': null}))),
      );
      expect(await fetchFirebaseProjects('token'), isEmpty);
    });
  });

  group('AttachmentDownloadController queue key', () {
    test('retains original guid after attachment.guid mutates', () {
      final attachment = Attachment(guid: 'old-guid-123');
      final controller = AttachmentDownloadController(attachment: attachment);
      attachment.guid = 'new-guid-456';
      expect(controller.queueKey, 'old-guid-123');
    });
  });
}
