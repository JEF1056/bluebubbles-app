import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/app/layouts/settings/pages/server/server_management_panel.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show ServerDetails;
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/network/api/server_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';

class _FakeServerAdapter implements HttpClientAdapter {
  _FakeServerAdapter({required this.connected});

  bool connected;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!connected) {
      throw DioException(requestOptions: options, type: DioExceptionType.connectionError);
    }
    if (options.uri.path.endsWith('/ping')) {
      return ResponseBody.fromString(
        jsonEncode({'status': 200, 'message': 'pong'}),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        },
      );
    }
    if (options.uri.path.endsWith('/server/info')) {
      return ResponseBody.fromString(
        jsonEncode({
          'status': 200,
          'data': {
            'os_version': '14.5',
            'server_version': '1.9.9',
            'server_build_version': '2.0.0-beta.1',
            'private_api': true,
            'proxy_service': 'dynamic-dns',
            'helper_connected': true,
            'macos_time_sync': 0.012,
            'detected_icloud': 'user@icloud.com',
            'api_versions': [1, 2],
          },
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'status': 200, 'data': {}}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json']
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeHttpService extends HttpService {
  _FakeHttpService(this.adapter) {
    dio = Dio()..httpClientAdapter = adapter;
    server = ServerApi(this);
  }

  final _FakeServerAdapter adapter;

  @override
  String get origin => SettingsSvc.settings.serverAddress.value;
}

class _FakeSettingsService extends SettingsService {
  ServerDetails _details = const ServerDetails.empty();

  @override
  ServerDetails get serverDetails => _details;

  @override
  Future<void> updateServerDetails(ServerDetails details) async {
    _details = details;
  }
}

class _FakeLogger extends BaseLogger {
  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void error(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

class _FakeDesktopPrefs extends SharedPreferencesDesktopActions {
  _FakeDesktopPrefs(super.service);

  @override
  double? getSplitRatio() => null;

  @override
  Future<void> setSplitRatio(double ratio) async {}
}

class _FakeThemePrefs extends SharedPreferencesThemeActions {
  _FakeThemePrefs(super.service);

  @override
  String? getSelectedLightTheme() => null;

  @override
  String? getSelectedDarkTheme() => null;
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    desktop = _FakeDesktopPrefs(this);
    theme = _FakeThemePrefs(this);
  }
}

void _registerServices({
  required Skins skin,
  required bool connected,
}) {
  Get.testMode = true;
  final settings = _FakeSettingsService()
    ..settings = (Settings()
      ..skin.value = skin
      ..serverAddress.value = 'https://bb.jessfan.com'
      ..customHeaders.value = {'X-Custom-Header': 'test-value'}
      ..enablePrivateAPI.value = true)
    ..fcmData = FCMData();
  if (connected) {
    settings._details = const ServerDetails(
      macOSVersion: 14,
      macOSMinorVersion: 5,
      serverVersion: '1.9.9',
      serverVersionCode: 10909,
      privateApiEnabled: true,
      iCloudAccount: 'user@icloud.com',
      proxyService: 'dynamic-dns',
      apiVersions: [1, 2],
      serverBuildVersion: '2.0.0-beta.1',
    );
  }

  final socket = SocketService();
  socket.state.value = connected ? SocketState.connected : SocketState.disconnected;

  GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  GetIt.I.registerSingleton<SettingsService>(settings);
  GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  GetIt.I.registerSingleton<HttpService>(_FakeHttpService(_FakeServerAdapter(connected: connected)));
  GetIt.I.registerSingleton<AttachmentDownloadService>(AttachmentDownloadService());
  GetIt.I.registerSingleton<SocketService>(socket);
  GetIt.I.registerSingleton<ChatsService>(ChatsService());
  GetIt.I.registerSingleton<HandleService>(HandleService());
  GetIt.I.registerSingleton<ThemesService>(ThemesService());
  GetIt.I.registerSingleton<BaseLogger>(_FakeLogger());
  GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
}

void main() {
  tearDown(() async {
    Get.reset();
    await GetIt.I.reset();
  });

  for (final skin in [Skins.Material, Skins.iOS, Skins.Samsung]) {
    for (final connected in [true, false]) {
      testWidgets(
        'ServerManagementPanel renders without errors (${skin.name}, connected=$connected)',
        (tester) async {
          _registerServices(skin: skin, connected: connected);

          tester.view.physicalSize = const Size(1280, 900);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            GetMaterialApp(
              theme: ThemesService.whiteLightTheme,
              home: ServerManagementPanel(),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byType(ErrorWidget), findsNothing);
          expect(
            find.text(skin == Skins.iOS ? 'CONNECTION & SYNC' : 'Connection & Sync'),
            findsOneWidget,
          );
          expect(
            find.text(skin == Skins.iOS ? 'SERVER ACTIONS' : 'Server Actions'),
            findsOneWidget,
          );
          expect(find.text('https://bb.jessfan.com'), findsOneWidget);
          if (connected) {
            expect(find.text('Dynamic-dns'), findsOneWidget);
          }
        },
      );
    }
  }
}
