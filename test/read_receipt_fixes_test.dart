import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/models/models.dart' show MessageSaveResult, ServerDetails;
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide FormData, Response;
import 'package:get_it/get_it.dart';

class _CapturingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
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

class _FakeMessagingPrefs extends SharedPreferencesMessagingActions {
  _FakeMessagingPrefs(super.service);

  @override
  Future<void> setLastOpenedChat(String? guid) async {}

  @override
  Future<void> clearLastOpenedChat() async {}
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    messaging = _FakeMessagingPrefs(this);
  }
}

class _FakeLifecycleService extends LifecycleService {
  bool foregroundOverride = true;
  bool uiInteractiveOverride = true;

  @override
  bool get isForeground => foregroundOverride;

  @override
  bool get isUiInteractive => uiInteractiveOverride;
}

class _RecordingChat extends Chat {
  final List<bool> unreadUpdates = [];

  _RecordingChat({
    required super.guid,
    super.hasUnreadMessage = false,
  }) : super(id: 42);

  @override
  Future<Chat> saveAsync({
    bool updateMuteType = false,
    bool updateMuteArgs = false,
    bool updateIsPinned = false,
    bool updatePinIndex = false,
    bool updateIsArchived = false,
    bool updateHasUnreadMessage = false,
    bool updateAutoSendReadReceipts = false,
    bool updateAutoSendTypingIndicators = false,
    bool updateCustomAvatarPath = false,
    bool updateCustomBackgroundPath = false,
    bool updateTextFieldText = false,
    bool updateTextFieldAttachments = false,
    bool updateDisplayName = false,
    bool updateDateDeleted = false,
    bool updateLockChatName = false,
    bool updateLockChatIcon = false,
    bool updateLastReadMessageGuid = false,
    bool updateLatestMessage = false,
    bool updateCustomThemes = false,
    bool updateWallpaperSettings = false,
    bool updateKnownGroupPhotoGuid = false,
    bool updateServiceName = false,
  }) async {
    return this;
  }

  @override
  Future<Chat> toggleHasUnreadAsync(
    bool hasUnread, {
    bool force = false,
    bool clearLocalNotifications = true,
    bool privateMark = true,
    int? readBefore,
  }) async {
    unreadUpdates.add(hasUnread);
    hasUnreadMessage = hasUnread;
    if (privateMark && !hasUnread) {
      await HttpSvc.dio.post('http://localhost/api/v1/chat/$guid/read');
    }
    return this;
  }

  @override
  Future<MessageSaveResult> addMessage(
    Message message, {
    bool changeUnreadStatus = true,
    bool checkForMessageText = true,
    bool clearNotificationsIfFromMe = true,
    List<Attachment> attachments = const [],
  }) async {
    return MessageSaveResult(message, true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CapturingAdapter adapter;
  late _FakeLifecycleService lifecycle;
  late ChatsService chatsService;

  setUp(() async {
    await GetIt.I.reset();
    Get.reset();
    Get.testMode = true;

    adapter = _CapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;

    GetIt.I.registerSingleton<BaseLogger>(_FakeLogger());
    GetIt.I.registerSingleton<SettingsService>(_FakeSettingsService()..settings = Settings());
    GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
    GetIt.I.registerSingleton<HttpService>(HttpService()..dio = dio);
    GetIt.I.registerSingleton<SocketService>(SocketService());
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
    GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());

    lifecycle = _FakeLifecycleService()
      ..headless = false
      ..windowFocused = true;
    GetIt.I.registerSingleton<LifecycleService>(lifecycle, signalsReady: true);
    GetIt.I.signalReady(lifecycle);

    chatsService = ChatsService();
    GetIt.I.registerSingleton<ChatsService>(chatsService);

    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() async {
    await GetIt.I.reset();
    Get.reset();
  });

  group('RR-P0-2: StartupTasks.onAppResume read-receipt gating', () {
    test('does not mark read when isUiInteractive is false even if isForeground is true', () async {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550001001', hasUnreadMessage: true);
      chatsService.setActiveChatSync(chat, clearNotifications: false, save: false);
      final controller = cvc(chat)..autoOpened = false;
      chatsService.activeChat!.controller = controller;

      lifecycle
        ..foregroundOverride = true
        ..uiInteractiveOverride = false;

      await StartupTasks.onAppResume();
      await Future<void>.delayed(Duration.zero);

      expect(chat.hasUnreadMessage, isTrue);
      expect(chat.unreadUpdates, isEmpty);
      expect(adapter.requests, isEmpty);
      controller.onClose();
    });

    test('does not mark read when active chat was autoOpened', () async {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550001002', hasUnreadMessage: true);
      chatsService.setActiveChatSync(chat, clearNotifications: false, save: false);
      final controller = cvc(chat)..autoOpened = true;
      chatsService.activeChat!.controller = controller;

      lifecycle
        ..foregroundOverride = true
        ..uiInteractiveOverride = true;

      await StartupTasks.onAppResume();
      await Future<void>.delayed(Duration.zero);

      expect(chat.hasUnreadMessage, isTrue);
      expect(chat.unreadUpdates, isEmpty);
      expect(adapter.requests, isEmpty);
      controller.onClose();
    });

    test('marks read when isUiInteractive is true and autoOpened is false', () async {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550001003', hasUnreadMessage: true);
      chatsService.setActiveChatSync(chat, clearNotifications: false, save: false);
      final controller = cvc(chat)..autoOpened = false;
      chatsService.activeChat!.controller = controller;

      lifecycle
        ..foregroundOverride = true
        ..uiInteractiveOverride = true;

      await StartupTasks.onAppResume();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(chat.hasUnreadMessage, isFalse);
      expect(chat.unreadUpdates, [false]);
      expect(adapter.requests, hasLength(1));
      controller.onClose();
    });
  });

  group('RR-P1-2: Chat.toggleAutoReadAsync never triggers eager markRead', () {
    test('updates autoSendReadReceipts without posting /read even when Private API is enabled', () async {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550002001', hasUnreadMessage: true);
      SettingsSvc.settings.enablePrivateAPI.value = true;
      SettingsSvc.settings.privateMarkChatAsRead.value = true;

      await chat.toggleAutoReadAsync(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.autoSendReadReceipts, isTrue);
      expect(adapter.requests, isEmpty);

      await chat.toggleAutoReadAsync(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.autoSendReadReceipts, isNull);
      expect(adapter.requests, isEmpty);
    });
  });

  group('RR-P1-3: setActiveChatSync microtask re-checks active and interactive state', () {
    test('skips mark-read if UI becomes non-interactive before microtask runs', () async {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550003001', hasUnreadMessage: true);
      lifecycle.uiInteractiveOverride = true;

      chatsService.setActiveChatSync(chat, alive: true, clearNotifications: true, save: false);
      // Simulate activity pausing/unfocusing synchronously before the queued microtask executes.
      lifecycle.uiInteractiveOverride = false;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(chat.hasUnreadMessage, isTrue);
      expect(chat.unreadUpdates, isEmpty);
      expect(adapter.requests, isEmpty);
    });

    test('skips mark-read if chat is deactivated before microtask runs', () async {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550003002', hasUnreadMessage: true);
      lifecycle.uiInteractiveOverride = true;

      chatsService.setActiveChatSync(chat, alive: true, clearNotifications: true, save: false);
      chatsService.setAllInactiveSync(save: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(chat.hasUnreadMessage, isTrue);
      expect(chat.unreadUpdates, isEmpty);
      expect(adapter.requests, isEmpty);
    });
  });
}
