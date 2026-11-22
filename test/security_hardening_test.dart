import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/global/server_payload.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show ServerDetails;
import 'package:bluebubbles/services/network/api/server_api.dart';
import 'package:bluebubbles/services/network/http_overrides.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/crypto_utils.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';

class _FakeLogger extends BaseLogger {
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
  final List<RequestOptions> requests = [];
  final Future<ResponseBody> Function(RequestOptions options) responder;

  _StubAdapter(this.responder);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Object data, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json']
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSettingsService settingsService;
  late HttpService httpService;
  late SocketService socketService;

  setUp(() async {
    await GetIt.I.reset();
    Get.reset();
    Get.testMode = true;

    settingsService = _FakeSettingsService()..settings = Settings();
    httpService = HttpService()..dio = Dio();
    httpService.server = ServerApi(httpService);
    socketService = SocketService();

    GetIt.I.registerSingleton<BaseLogger>(_FakeLogger());
    GetIt.I.registerSingleton<SettingsService>(settingsService);
    GetIt.I.registerSingleton<HttpService>(httpService);
    GetIt.I.registerSingleton<SocketService>(socketService);
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  });

  tearDown(() async {
    httpService.originOverride = null;
    await GetIt.I.reset();
    Get.reset();
  });

  group('M1: acceptsBadCertFor IP-literal-only cert override', () {
    test('accepts matching IPv4 and IPv6 literals only', () {
      expect(acceptsBadCertFor('192.168.1.42', '192.168.1.42'), isTrue);
      expect(acceptsBadCertFor('100.64.0.5', '100.64.0.5'), isTrue);
      expect(acceptsBadCertFor('::1', '::1'), isTrue);
      expect(acceptsBadCertFor('fd7a:115c:a1e0::1', 'FD7A:115C:A1E0::1'), isTrue);

      expect(acceptsBadCertFor('192.168.1.42', '192.168.1.43'), isFalse);
      expect(acceptsBadCertFor('bb.example.com', 'bb.example.com'), isFalse);
      expect(acceptsBadCertFor('bb.example.com', '*.example.com'), isFalse);
      expect(acceptsBadCertFor('localhost', 'localhost'), isFalse);
      expect(acceptsBadCertFor('', '192.168.1.42'), isFalse);
      expect(acceptsBadCertFor('192.168.1.42', ''), isFalse);
    });
  });

  group('M2: Authenticated LAN identity proof', () {
    test('generateLanProofNonce returns 32 lowercase hex chars', () {
      final n1 = NetworkTasks.generateLanProofNonce();
      final n2 = NetworkTasks.generateLanProofNonce();
      expect(n1, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(n2, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(n1, isNot(equals(n2)));
    });

    test('lanProofMatches verifies HMAC-SHA256(key, nonce) and rejects tampering', () {
      const key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const nonce = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final validProof = Hmac(sha256, utf8.encode(key)).convert(utf8.encode(nonce)).toString();

      expect(
        NetworkTasks.lanProofMatches(key, nonce, {
          'status': 200,
          'data': {'proof': validProof},
        }),
        isTrue,
      );
      expect(
        NetworkTasks.lanProofMatches(key, nonce, {
          'status': 200,
          'data': {'proof': validProof.toUpperCase()},
        }),
        isTrue,
      );

      expect(
        NetworkTasks.lanProofMatches(key, nonce, {
          'status': 200,
          'data': {'proof': '0' * 64},
        }),
        isFalse,
      );
      expect(
        NetworkTasks.lanProofMatches('wrong-key', nonce, {
          'status': 200,
          'data': {'proof': validProof},
        }),
        isFalse,
      );
      expect(
        NetworkTasks.lanProofMatches(key, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', {
          'status': 200,
          'data': {'proof': validProof},
        }),
        isFalse,
      );
      expect(NetworkTasks.lanProofMatches('', nonce, {'data': {'proof': validProof}}), isFalse);
      expect(NetworkTasks.lanProofMatches(key, 'short', {'data': {'proof': validProof}}), isFalse);
      expect(NetworkTasks.lanProofMatches(key, nonce, 'pong'), isFalse);
    });

    test('ServerApi.lanProof sends unauthenticated request without guid/password query params', () async {
      settingsService.settings.guidAuthKey.value = 'super-secret-password';
      final adapter = _StubAdapter((options) async {
        return _jsonResponse({
          'status': 200,
          'data': {'proof': 'deadbeef'},
        });
      });
      httpService.dio = Dio()..httpClientAdapter = adapter;

      const nonce = '0123456789abcdef0123456789abcdef';
      await httpService.server.lanProof('http://192.168.1.50:1234', nonce);

      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.uri.toString(), 'http://192.168.1.50:1234/api/v1/lan-proof?nonce=$nonce');
      expect(req.queryParameters.containsKey('guid'), isFalse);
      expect(req.queryParameters.containsKey('password'), isFalse);
    });

    test('probeAddresses accepts only LAN host returning valid HMAC proof', () async {
      const key = 'lan-secret-key-hex';
      settingsService.settings.lanProofKey.value = key;
      final adapter = _StubAdapter((options) async {
        final nonce = options.queryParameters['nonce'] as String;
        if (options.uri.host == '192.168.1.10') {
          return _jsonResponse({
            'status': 200,
            'data': {'proof': 'forged' * 10 + '0000'},
          });
        }
        if (options.uri.scheme == 'http' && options.uri.host == '192.168.1.20') {
          final proof = Hmac(sha256, utf8.encode(key)).convert(utf8.encode(nonce)).toString();
          return _jsonResponse({
            'status': 200,
            'data': {'proof': proof},
          });
        }
        throw DioException(requestOptions: options, type: DioExceptionType.connectionError);
      });
      httpService.dio = Dio()..httpClientAdapter = adapter;

      final proven = await NetworkTasks.probeAddresses(['192.168.1.10', '192.168.1.20'], '1234');
      expect(proven, 'http://192.168.1.20:1234');
    });

    test('probeAddresses refuses all hosts when lanProofKey is unset', () async {
      settingsService.settings.lanProofKey.value = null;
      final adapter = _StubAdapter((options) async => _jsonResponse({'status': 200, 'data': {}}));
      httpService.dio = Dio()..httpClientAdapter = adapter;

      final proven = await NetworkTasks.probeAddresses(['192.168.1.20'], '1234');
      expect(proven, isNull);
      expect(adapter.requests, isEmpty);
    });

    test('Settings.toMap/fromMap round-trips lanProofKey and SocketSvc clears originOverride on disconnect', () {
      const key = 'persisted-lan-proof-key';
      final settings = Settings()..lanProofKey.value = key;
      final restored = Settings.fromMap(settings.toMap());
      expect(restored.lanProofKey.value, key);

      httpService.originOverride = 'http://192.168.1.20:1234';
      socketService.reproveLanOverrideForTest();
      expect(httpService.originOverride, isNull);
    });
  });

  group('M3: ApiInterceptor strips HttpSvc.headers off-origin', () {
    test('keeps sensitive headers on-origin and strips them off-origin and on non-HTTP URIs', () async {
      settingsService.settings.serverAddress.value = 'https://bb.example.com';
      settingsService.settings.customHeaders.value = {
        'CF-Access-Client-Id': 'client-id',
        'CF-Access-Client-Secret': 'client-secret',
        'Authorization': 'Bearer tunnel-token',
      };

      final captured = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(ApiInterceptor())
        ..httpClientAdapter = _StubAdapter((options) async {
          captured.add(options);
          return _jsonResponse({'status': 200});
        });

      // Merge default HttpSvc headers just like HttpSvc.dio does.
      dio.options.headers.addAll(httpService.headers);

      await dio.get('https://bb.example.com/api/v1/ping');
      await dio.get(
        'https://evil.example.net/track',
        options: Options(headers: {
          'cf-access-client-secret': 'case-variant',
          'X-Public-Header': 'keep-me',
        }),
      );
      await dio.get('data:text/plain;base64,SGk=');

      expect(captured, hasLength(3));
      expect(captured[0].headers['CF-Access-Client-Id'], 'client-id');
      expect(captured[0].headers['Authorization'], 'Bearer tunnel-token');

      expect(captured[1].headers.containsKey('CF-Access-Client-Id'), isFalse);
      expect(captured[1].headers.containsKey('CF-Access-Client-Secret'), isFalse);
      expect(captured[1].headers.containsKey('cf-access-client-secret'), isFalse);
      expect(captured[1].headers.containsKey('Authorization'), isFalse);
      expect(captured[1].headers['X-Public-Header'], 'keep-me');

      expect(captured[2].headers.containsKey('CF-Access-Client-Id'), isFalse);
      expect(captured[2].headers.containsKey('Authorization'), isFalse);
    });
  });

  group('M4: Attachment transferName path-traversal sanitization', () {
    test('neutralizes slash traversal and dot segments on mobile/POSIX and Windows', () {
      expect(Attachment.sanitizeTransferName('../../etc/passwd'), '.._.._etc_passwd');
      expect(Attachment.sanitizeTransferName('..'), '__');
      expect(Attachment.sanitizeTransferName('.'), '_');
      expect(
        Attachment.sanitizeTransferName(r'..\..\evil:file?.txt', isWindows: true),
        '.._.._evil_file_.txt',
      );

      final attachment = Attachment(guid: 'att-1', transferName: '../secret.txt');
      expect(attachment.path, '${attachment.directory}/.._secret.txt');
      expect(attachment.path.startsWith('${attachment.directory}/'), isTrue);
      expect(attachment.path.substring(attachment.directory.length + 1).contains('/'), isFalse);

      expect(FilesystemService.sanitizeGuid('../../etc'), 'etc');
      expect(FilesystemService.sanitizeGuid('../..'), 'unknown');
      expect(FilesystemService.sanitizeGuid(null), 'unknown');

      final traversalAttachment = Attachment(guid: '../../evil', transferName: '../secret.txt');
      expect(traversalAttachment.directory.endsWith('/evil'), isTrue);
      expect(traversalAttachment.path.contains('..'), isTrue); // filename only (`.._secret.txt`), not a path segment
      expect(traversalAttachment.path, '${traversalAttachment.directory}/.._secret.txt');
    });
  });

  group('Wave 1: ServerPayload decrypt order and isLegacy flag', () {
    test('decrypts encrypted data before jsonDecode and detects legacy vs typed payloads', () {
      const passphrase = 'test-server-password';
      final ciphertext = encryptAESCryptoJS(
        jsonEncode({'guid': 'msg-1', 'text': 'hello'}),
        passphrase,
      );

      final typed = ServerPayload.fromJson(
        {
          'type': 'NEW_MESAGE',
          'encrypted': true,
          'encoding': 'JSON_OBJECT',
          'data': ciphertext,
        },
        passphrase: passphrase,
      );
      expect(typed.isLegacy, isFalse);
      expect(typed.isDict, isTrue);
      expect(typed.data['guid'], 'msg-1');
      expect(typed.data['text'], 'hello');

      final legacy = ServerPayload.fromJson({'guid': 'legacy-1'});
      expect(legacy.isLegacy, isTrue);
      expect(legacy.isDict, isTrue);
      expect(legacy.data['guid'], 'legacy-1');
    });
  });

  group('W1 / W3 / P2-j: Web hardening and workflow SHA pin', () {
    test('web/index.html defines window.pmtiles stub', () {
      final indexHtml = File('web/index.html').readAsStringSync();
      expect(indexHtml, contains('window.pmtiles = { Protocol: class { tile() {} } };'));
    });

    test('web/_headers sets framing/object/base-uri CSP without breaking MapLibre referrer policy', () {
      final headers = File('web/_headers').readAsStringSync();
      expect(headers, contains('X-Frame-Options: DENY'));
      expect(headers, contains("Content-Security-Policy: frame-ancestors 'none'; object-src 'none'; base-uri 'self'"));
      expect(headers, contains('Referrer-Policy: strict-origin-when-cross-origin'));
    });

    test('web-deploy.yml pins cloudflare/wrangler-action to a 40-hex commit SHA', () {
      final workflow = File('.github/workflows/web-deploy.yml').readAsStringSync();
      expect(
        workflow,
        matches(RegExp(r'uses:\s*cloudflare/wrangler-action@[0-9a-f]{40}')),
      );
      expect(workflow, isNot(contains('cloudflare/wrangler-action@v3')));
    });
  });
}
