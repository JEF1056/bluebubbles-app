import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
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
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    messaging = _FakeMessagingPrefs(this);
  }
}

class _ToggleCall {
  final bool hasUnread;
  final bool force;
  final bool clearLocalNotifications;
  final bool privateMark;

  const _ToggleCall({
    required this.hasUnread,
    required this.force,
    required this.clearLocalNotifications,
    required this.privateMark,
  });
}

class _RecordingChat extends Chat {
  final List<_ToggleCall> toggleCalls = [];

  _RecordingChat({
    required super.guid,
    super.hasUnreadMessage = false,
  }) : super(id: 1);

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
    toggleCalls.add(_ToggleCall(
      hasUnread: hasUnread,
      force: force,
      clearLocalNotifications: clearLocalNotifications,
      privateMark: privateMark,
    ));
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
  late LifecycleService lifecycle;
  late ChatsService chatsService;

  setUp(() async {
    await GetIt.I.reset();
    Get.reset();
    adapter = _CapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;

    Get.testMode = true;
    GetIt.I.registerSingleton<BaseLogger>(_FakeLogger());
    GetIt.I.registerSingleton<SettingsService>(_FakeSettingsService()..settings = Settings());
    GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
    GetIt.I.registerSingleton<HttpService>(HttpService()..dio = dio);
    GetIt.I.registerSingleton<SocketService>(SocketService());
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
    GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());

    lifecycle = LifecycleService()
      ..headless = false
      ..windowFocused = true;
    GetIt.I.registerSingleton<LifecycleService>(lifecycle);

    chatsService = ChatsService();
    GetIt.I.registerSingleton<ChatsService>(chatsService);

    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() async {
    await GetIt.I.reset();
    Get.reset();
  });

  group('Interaction-gated read receipts', () {
    test('incoming !isFromMe message leaves/sets hasUnreadMessage=true even on active foreground chat', () async {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550001111', hasUnreadMessage: false);
      chatsService.setActiveChatSync(chat, clearNotifications: false, save: false);

      final incoming = Message(
        guid: 'msg-in-1',
        text: 'hello',
        isFromMe: false,
        dateCreated: DateTime.now(),
      );

      await chatsService.addMessageToChat(chat, incoming);

      expect(chat.hasUnreadMessage, isTrue);
      expect(chatsService.getChatState(chat.guid)?.hasUnreadMessage.value, isTrue);
      expect(chat.toggleCalls.last.hasUnread, isTrue);
      expect(chat.toggleCalls.last.force, isTrue);
      expect(chat.toggleCalls.last.privateMark, isFalse);
      expect(adapter.requests, isEmpty);
    });

    test('LifecycleSvc.resumed() / setActiveToAlive() never marks read or sends read receipts', () async {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550002222', hasUnreadMessage: true);
      chatsService.setActiveChatSync(chat, clearNotifications: false, save: false);
      chat.toggleCalls.clear();

      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(chat.hasUnreadMessage, isTrue);
      expect(chat.toggleCalls, isEmpty);
      expect(adapter.requests, isEmpty);
    });

    test('setActiveChatSync marks read only when alive=true and isUiInteractive=true', () async {
      final chat1 = _RecordingChat(guid: 'iMessage;-;+15550003333', hasUnreadMessage: true);
      chatsService.setActiveChatSync(chat1, alive: false, clearNotifications: true, save: false);
      await Future<void>.delayed(Duration.zero);
      expect(chat1.hasUnreadMessage, isTrue);
      expect(adapter.requests, isEmpty);

      lifecycle.windowFocused = false;
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      chatsService.setActiveChatSync(chat1, alive: true, clearNotifications: true, save: false);
      await Future<void>.delayed(Duration.zero);
      expect(chat1.hasUnreadMessage, isTrue);
      expect(adapter.requests, isEmpty);

      lifecycle.windowFocused = true;
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      chatsService.setActiveChatSync(chat1, alive: true, clearNotifications: true, save: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat1.hasUnreadMessage, isFalse);
      expect(adapter.requests.length, 1);
    });

    test('ConversationViewController.onUserChatInteraction debounces and gates on isUiInteractive & unread', () async {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550004444', hasUnreadMessage: true);
      chatsService.setActiveChatSync(chat, clearNotifications: false, save: false);
      final controller = ConversationViewController(chat);

      // Unfocused/paused -> ignored
      lifecycle.windowFocused = false;
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      controller.onUserChatInteraction(immediate: true);
      await Future<void>.delayed(Duration.zero);
      expect(chat.hasUnreadMessage, isTrue);
      expect(adapter.requests, isEmpty);

      // Resumed + showingSubRoute -> ignored
      lifecycle.windowFocused = true;
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      controller.showingSubRoute = true;
      controller.onUserChatInteraction(immediate: true);
      await Future<void>.delayed(Duration.zero);
      expect(chat.hasUnreadMessage, isTrue);
      expect(adapter.requests, isEmpty);

      // Resumed + !showingSubRoute + debounced -> marks read after 250ms
      controller.showingSubRoute = false;
      controller.onUserChatInteraction();
      expect(chat.hasUnreadMessage, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(chat.hasUnreadMessage, isFalse);
      expect(adapter.requests.length, 1);

      // Already read -> no extra request
      controller.onUserChatInteraction(immediate: true);
      await Future<void>.delayed(Duration.zero);
      expect(adapter.requests.length, 1);

      controller.onClose();
    });
  });
}
