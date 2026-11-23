import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/ongoing_call_pill.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_suffix.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/voice_message_recorder.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_map_widget.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as maplibre;
import 'package:record/record.dart';

final Uint8List _kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

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
  _FakeSettingsService({int serverVersionCode = 20000, List<int>? apiVersions})
      : _serverDetails = ServerDetails(
          macOSVersion: 14,
          macOSMinorVersion: 0,
          serverVersion: serverVersionCode >= 20000 ? '2.0.0' : '1.9.0',
          serverVersionCode: serverVersionCode,
          apiVersions: apiVersions ?? (serverVersionCode >= 20000 ? const [1, 2] : const [1]),
        );

  final ServerDetails _serverDetails;

  @override
  ServerDetails get serverDetails => _serverDetails;
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

class _FakeOutgoingMessageHandler extends OutgoingMessageHandler {
  @override
  Future<void> queue(OutgoingQueueItem item) async {}
}

class _FakeChatsService extends ChatsService {
  @override
  Future<void> setChatTextFieldText(Chat chat, String? value, {List<Run> runs = const []}) async {
    chat.textFieldText = value;
  }

  @override
  Future<void> setChatTextFieldAttachments(Chat chat, List<String> attachments) async {
    chat.textFieldAttachments = attachments;
  }
}

class _FakeAudioRecorder extends Fake implements AudioRecorder {
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;
  Completer<void>? startGate;
  String? stopOutputPath;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startCalls++;
    if (startGate != null && !startGate!.isCompleted) {
      await startGate!.future;
    }
  }

  @override
  Future<String?> stop() async {
    stopCalls++;
    return stopOutputPath;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class _FakeErrorInterceptorHandler extends ErrorInterceptorHandler {
  DioException? forwardedError;

  @override
  void next(DioException err) {
    forwardedError = err;
  }
}

class _FakeMessageApi extends Fake implements MessageApi {
  final List<({String guid, String withQuery})> fetchCalls = [];

  @override
  Future<Response> fetchOne(String guid, {String withQuery = "", CancelToken? cancelToken}) async {
    fetchCalls.add((guid: guid, withQuery: withQuery));
    return Response(
      requestOptions: RequestOptions(path: '/api/v1/message/$guid'),
      statusCode: 200,
      data: <String, dynamic>{
        'data': <String, dynamic>{'attachments': const <dynamic>[]},
      },
    );
  }
}

class _FakeHttpService extends Fake implements HttpService {
  _FakeHttpService(this.messageApi);
  final _FakeMessageApi messageApi;

  @override
  MessageApi get message => messageApi;

  @override
  String get origin => 'https://server.example';
}

void _registerCoreServices({_FakeSettingsService? settingsService, Directory? appDocDir}) {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  final settings = settingsService ?? (_FakeSettingsService()..settings = Settings());
  if (GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.unregister<SettingsService>();
  }
  GetIt.I.registerSingleton<SettingsService>(settings);
  if (!GetIt.I.isRegistered<SharedPreferencesService>()) {
    GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  }
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.unregister<ChatsService>();
  }
  GetIt.I.registerSingleton<ChatsService>(_FakeChatsService());
  if (!GetIt.I.isRegistered<HandleService>()) {
    GetIt.I.registerSingleton<HandleService>(HandleService());
  }
  if (!GetIt.I.isRegistered<ThemesService>()) {
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  }
  if (GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.unregister<FilesystemService>();
  }
  GetIt.I.registerSingleton<FilesystemService>(
    FilesystemService()..appDocDir = appDocDir ?? Directory.systemTemp,
  );
  if (!GetIt.I.isRegistered<bb_events.EventDispatcher>()) {
    GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
  }
  if (!GetIt.I.isRegistered<SyncService>()) {
    GetIt.I.registerSingleton<SyncService>(SyncService());
  }
  if (!GetIt.I.isRegistered<LifecycleService>()) {
    GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  }
  if (!GetIt.I.isRegistered<SocketService>()) {
    GetIt.I.registerSingleton<SocketService>(SocketService());
  }
  if (!GetIt.I.isRegistered<OutgoingMessageHandler>()) {
    GetIt.I.registerSingleton<OutgoingMessageHandler>(_FakeOutgoingMessageHandler());
  }
}

ThemeData _testTheme() => ThemeData(
      useMaterial3: true,
      extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
    );

void main() {
  tearDown(() async {
    Get.reset();
    await GetIt.I.reset();
  });

  group('FW-1: Voice recorder lifecycle & concurrency guard', () {
    testWidgets('ConversationTextField.dispose resets recording/preview state and deletes pending temp file',
        (tester) async {
      final settings = _FakeSettingsService()..settings = Settings();
      settings.settings.enablePrivateAPI.value = true;
      settings.settings.privateSendTypingIndicators.value = false;
      settings.settings.skin.value = Skins.iOS;
      _registerCoreServices(settingsService: settings);

      final tempDir = Directory.systemTemp.createTempSync('fw1_dispose_test_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final pendingFile = File('${tempDir.path}/pending_voice.m4a')..writeAsBytesSync([1, 2, 3, 4]);
      expect(pendingFile.existsSync(), isTrue);

      final chat = Chat(guid: 'iMessage;-;+15550004444', chatIdentifier: '+15550004444')
        ..autoSendTypingIndicators = false;
      final controller = ConversationViewController(chat, tag_: 'fw1-dispose');
      addTearDown(() => Get.delete<ConversationViewController>(tag: 'fw1-dispose', force: true));

      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: ChatStateScope(
            chatState: ChatState(chat),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: ConversationTextField(parentController: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      controller.showRecording.value = true;
      voicePreviewFor(controller).value = VoicePreviewData(
        file: PlatformFile(name: 'pending_voice.m4a', path: pendingFile.path, size: 4),
        path: pendingFile.path,
        onDiscard: () {},
        onSend: () async {},
        onRestart: () async {},
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(controller.showRecording.value, isFalse);
      expect(voicePreviewFor(controller).value, isNull);
      expect(pendingFile.existsSync(), isFalse);
    });

    testWidgets('_RecordingButton _busy guard drops overlapping taps while _startRecording is in flight',
        (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('fw1_busy_test_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final settings = _FakeSettingsService()..settings = Settings();
      settings.settings.skin.value = Skins.Material;
      settings.settings.soundVolume.value = 0;
      _registerCoreServices(settingsService: settings, appDocDir: tempDir);

      final fakeRecorder = _FakeAudioRecorder()..startGate = Completer<void>();
      final chat = Chat(guid: 'iMessage;-;+15550005555', chatIdentifier: '+15550005555')
        ..autoSendTypingIndicators = false;
      final controller = ConversationViewController(chat, tag_: 'fw1-busy');
      addTearDown(() => Get.delete<ConversationViewController>(tag: 'fw1-busy', force: true));

      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: Center(
              child: TextFieldSuffix(
                subjectTextController: controller.subjectTextController,
                textController: controller.textController,
                controller: controller,
                recorderController: null,
                audioRecorder: fakeRecorder,
                sendMessage: ({String? effect}) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final micFinder = find.byKey(const Key('voice-record-button'));
      expect(micFinder, findsOneWidget);

      // First tap enters _startRecording and suspends on startGate; second tap must be dropped by _busy.
      await tester.tap(micFinder);
      await tester.pump();
      await tester.tap(micFinder);
      await tester.pump();

      expect(fakeRecorder.startCalls, 1);
      expect(fakeRecorder.stopCalls, 0);
      expect(controller.showRecording.value, isTrue);

      fakeRecorder.startGate!.complete();
      await tester.pumpAndSettle();

      // Unmount while recording: verify injected recorder is not double-disposed by TextFieldSuffix.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(fakeRecorder.disposeCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('_RecordingButton onRestart holds _busy guard and ignores calls after unmount', (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('fw1_restart_test_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final recordedFile = File('${tempDir.path}/recorded.m4a')..writeAsBytesSync([1, 2, 3, 4]);
      final settings = _FakeSettingsService()..settings = Settings();
      settings.settings.skin.value = Skins.Material;
      settings.settings.soundVolume.value = 0;
      _registerCoreServices(settingsService: settings, appDocDir: tempDir);

      final fakeRecorder = _FakeAudioRecorder()..stopOutputPath = recordedFile.path;
      final chat = Chat(guid: 'iMessage;-;+15550006666', chatIdentifier: '+15550006666')
        ..autoSendTypingIndicators = false;
      final controller = ConversationViewController(chat, tag_: 'fw1-restart');
      addTearDown(() => Get.delete<ConversationViewController>(tag: 'fw1-restart', force: true));

      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: Center(
              child: TextFieldSuffix(
                subjectTextController: controller.subjectTextController,
                textController: controller.textController,
                controller: controller,
                recorderController: null,
                audioRecorder: fakeRecorder,
                sendMessage: ({String? effect}) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final micFinder = find.byKey(const Key('voice-record-button'));
      await tester.tap(micFinder);
      await tester.pumpAndSettle();
      expect(fakeRecorder.startCalls, 1);

      await tester.tap(micFinder);
      for (var i = 0; i < 50 && voicePreviewFor(controller).value == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(fakeRecorder.stopCalls, 1);

      final preview = voicePreviewFor(controller).value;
      expect(preview, isNotNull);

      // Suspend the restarted _startRecording so an overlapping Stop tap races unless _busy is held.
      fakeRecorder.startGate = Completer<void>();
      final restartFuture = preview!.onRestart();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(micFinder, findsOneWidget);

      await tester.tap(micFinder);
      await tester.pump();
      expect(fakeRecorder.stopCalls, 1);
      expect(fakeRecorder.startCalls, 2);

      fakeRecorder.startGate!.complete();
      await restartFuture;
      await tester.pumpAndSettle();

      // Calling onRestart after widget unmount must be a safe no-op.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await preview.onRestart();
      expect(fakeRecorder.startCalls, 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('FW-2: ApiInterceptor HTTP origin guard', () {
    test('isOwnHttpServerUri safely rejects relative and non-http(s) URIs without StateError', () {
      expect(ApiInterceptor.isOwnHttpServerUri(Uri.parse('/api/v1/ping'), 'https://server.example'), isFalse);
      expect(
        ApiInterceptor.isOwnHttpServerUri(Uri.parse('blob:https://server.example/abc'), 'https://server.example'),
        isFalse,
      );
      expect(ApiInterceptor.isOwnHttpServerUri(Uri.parse('data:text/plain,hello'), 'https://server.example'), isFalse);
      expect(ApiInterceptor.isOwnHttpServerUri(Uri.parse('file:///tmp/test.png'), 'https://server.example'), isFalse);
      expect(ApiInterceptor.isOwnHttpServerUri(Uri.parse('https://other.example/a'), 'https://server.example'), isFalse);
      expect(ApiInterceptor.isOwnHttpServerUri(Uri.parse('https://server.example/api/v1/ping'), ''), isFalse);
      expect(
        ApiInterceptor.isOwnHttpServerUri(
          Uri.parse('https://server.example/api/v1/ping'),
          'https://server.example',
        ),
        isTrue,
      );
    });

    test('ApiInterceptor.onError handles relative request URI cleanly', () {
      _registerCoreServices();
      GetIt.I.registerSingleton<HttpService>(_FakeHttpService(_FakeMessageApi()));

      final interceptor = ApiInterceptor();
      final handler = _FakeErrorInterceptorHandler();
      final err = DioException(
        requestOptions: RequestOptions(path: '/relative/endpoint'),
        type: DioExceptionType.connectionError,
      );

      expect(() => interceptor.onError(err, handler), returnsNormally);
      expect(handler.forwardedError, same(err));
    });
  });

  group('FW-3: FindMyMapWidget rebuild isolation', () {
    testWidgets('camera updates and marker hover update compass/3D without rebuilding outer controls', (tester) async {
      _registerCoreServices();
      final controller = FindMyController(autoFetch: false);
      addTearDown(controller.onClose);

      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 700,
              child: FindMyMapWidget(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      final controlsElementBefore = tester.element(find.byKey(const ValueKey('findmy-zoom-in')));

      for (var i = 0; i < 20; i++) {
        controller.onMapCameraChanged(
          center: LatLng(37.77 + i * 0.001, -122.41 - i * 0.001),
          zoom: 15.0 + i * 0.05,
          pitch: 20.0 + i * 0.5,
          bearing: i * 9.0,
          reason: maplibre.CameraChangeReason.gesture,
          settled: false,
        );
      }
      controller.hoveredMarkerKey.value = 'friend-alice';
      await tester.pump();
      controller.hoveredMarkerKey.value = null;
      await tester.pump();

      // Smooth per-frame bearing updates compass without churning markerOrderBearing.
      expect(controller.cameraBearing.value, closeTo(171.0, 1e-6));
      expect(controller.markerOrderBearing.value, closeTo(0.0, 1e-6));
      expect(controller.is3DEnabled.value, isTrue);

      // Settling onCameraMoveEnd commits markerOrderBearing once.
      controller.onMapCameraChanged(
        center: const LatLng(37.789, -122.429),
        zoom: 15.95,
        pitch: 29.5,
        bearing: 171.0,
        reason: maplibre.CameraChangeReason.gesture,
        settled: true,
      );
      await tester.pump();
      expect(controller.markerOrderBearing.value, closeTo(171.0, 1e-6));

      final controlsElementAfter = tester.element(find.byKey(const ValueKey('findmy-zoom-in')));
      expect(identical(controlsElementAfter, controlsElementBefore), isTrue);

      await tester.tap(find.byKey(const ValueKey('findmy-compass')));
      await tester.pump(const Duration(milliseconds: 550));
      expect(controller.cameraBearing.value, closeTo(0.0, 1e-6));

      await tester.tap(find.byKey(const ValueKey('findmy-3d-toggle')));
      await tester.pump(const Duration(milliseconds: 550));
      expect(controller.is3DEnabled.value, isFalse);
      expect(find.text('2D'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FW-4: OngoingCallPillOverlay lifecycle & keypad visibility check', () {
    testWidgets('unmounting after call ends with keypad open does not throw setState after dispose', (tester) async {
      final controller = ActiveCallController(
        onEndCall: (_, _) async {},
        onSendDtmf: (_, _) async {},
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OngoingCallPillOverlay(controller: controller),
          ),
        ),
      );

      controller.startOngoing(
        callUuid: 'fw4-audio-uuid',
        callerName: 'Pat Lee',
        isVideo: false,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Keypad'));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);

      // End call (schedules post-frame _closeKeypad) and unmount in the same frame.
      await controller.endCall();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('video call pill intentionally omits Keypad button (matches facetime_ui_test)', (tester) async {
      final controller = ActiveCallController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OngoingCallPillOverlay(controller: controller),
          ),
        ),
      );

      controller.startOngoing(
        callUuid: 'fw4-video-uuid',
        callerName: 'Sam Chen',
        isVideo: true,
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Mute mic'), findsOneWidget);
      expect(find.bySemanticsLabel('Keypad'), findsNothing);
    });
  });

  group('FW-5: StickerHolder placement rehydration via GetIt', () {
    testWidgets('rehydrates missing sticker placements when HttpService is registered in GetIt', (tester) async {
      final settings = _FakeSettingsService(serverVersionCode: 20000)..settings = Settings();
      _registerCoreServices(settingsService: settings);

      final fakeMessageApi = _FakeMessageApi();
      GetIt.I.registerSingleton<HttpService>(_FakeHttpService(fakeMessageApi));

      final msg = Message(
        guid: 'fw5-sticker-msg-1',
        associatedMessageGuid: 'fw5-parent-guid',
        associatedMessageType: 'sticker',
        associatedMessagePart: 0,
        dateCreated: DateTime(2026, 1, 1, 12, 0, 0),
      );
      msg.dbAttachments.add(
        Attachment(
          id: 901,
          guid: 'at_0_fw5-sticker-msg-1',
          mimeType: 'image/png',
          transferName: 'sticker.png',
          stickerPlacement: null,
          bytes: _kPng1x1,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 160,
              child: Stack(
                children: [
                  StickerHolder(stickerMessages: [msg]),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(fakeMessageApi.fetchCalls.length, 1);
      expect(fakeMessageApi.fetchCalls.single.guid, 'fw5-sticker-msg-1');
      expect(fakeMessageApi.fetchCalls.single.withQuery, 'attachment');
      expect(tester.takeException(), isNull);
    });
  });
}
