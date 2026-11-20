import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/models/models.dart' show MessageSaveResult, ServerDetails;
import 'package:bluebubbles/services/backend/lifecycle/web_lifecycle_interop.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/network/api/chat_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
      headers: {Headers.contentTypeHeader: ['application/json']},
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
  final int? readBefore;

  const _ToggleCall({
    required this.hasUnread,
    required this.force,
    required this.clearLocalNotifications,
    required this.privateMark,
    required this.readBefore,
  });
}

class _RecordingChat extends Chat {
  final List<_ToggleCall> toggleCalls = [];

  _RecordingChat({
    required super.guid,
    super.id = 1,
    super.hasUnreadMessage = false,
  });

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
      readBefore: readBefore,
    ));
    if (hasUnreadMessage != hasUnread || force) {
      hasUnreadMessage = hasUnread;
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

_CapturingAdapter _registerTestServices() {
  Get.testMode = true;
  final adapter = _CapturingAdapter();
  final settings = _FakeSettingsService()..settings = Settings();
  settings.settings.tabletMode.value = true;
  settings.settings.privateMarkChatAsRead.value = true;

  final http = HttpService()..originOverride = 'https://mock.bluebubbles.local';
  http.dio = Dio()..httpClientAdapter = adapter;
  http.chat = ChatApi(http);

  GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  GetIt.I.registerSingleton<SettingsService>(settings);
  GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  GetIt.I.registerSingleton<HttpService>(http);
  GetIt.I.registerSingleton<SocketService>(SocketService());
  GetIt.I.registerSingleton<ChatsService>(ChatsService());
  GetIt.I.registerSingleton<BaseLogger>(_FakeLogger());
  GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
  return adapter;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    Get.reset();
    await GetIt.I.reset();
  });

  group('Web focus & lifecycle interop', () {
    test('isWebDocumentFocused stub defaults true and listenWebLifecycle accepts optional onFocusChange', () {
      expect(isWebDocumentFocused, isTrue);
      final dispose = listenWebLifecycle(
        onVisibilityChange: (_) {},
        onOnlineChange: (_) {},
        onFocusChange: (_) {},
      );
      dispose();
    });

    test('AppLifecycleState.inactive marks active chat dead on mobile and skips on desktop', () async {
      _registerTestServices();
      final binding = TestWidgetsFlutterBinding.instance;
      final chat = _RecordingChat(guid: 'iMessage;-;+15550001');

      // Mobile: inactive immediately marks chat dead; setActiveToAlive respects isForeground
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      ChatsSvc.setActiveChatSync(chat, clearNotifications: false, save: false);
      expect(ChatsSvc.activeChat?.isAlive.value, isTrue);
      expect(ChatsSvc.isChatActive(chat.guid), isTrue);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      LifecycleSvc.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(ChatsSvc.activeChat?.isAlive.value, isFalse);

      ChatsSvc.setActiveToAlive();
      expect(ChatsSvc.activeChat?.isAlive.value, isFalse);
      expect(ChatsSvc.isChatActive(chat.guid), isFalse);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      ChatsSvc.setActiveToAlive();
      expect(ChatsSvc.activeChat?.isAlive.value, isTrue);
      expect(ChatsSvc.isChatActive(chat.guid), isTrue);

      // Desktop: inactive does not pre-clear isAlive before close() records wasActiveAliveBefore
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      LifecycleSvc.windowFocused = true;
      LifecycleSvc.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(ChatsSvc.activeChat?.isAlive.value, isTrue);

      await LifecycleSvc.close();
      expect(LifecycleSvc.wasActiveAliveBefore, isTrue);
      expect(ChatsSvc.activeChat?.isAlive.value, isFalse);

      ChatsSvc.setActiveToAlive();
      expect(ChatsSvc.activeChat?.isAlive.value, isFalse);

      LifecycleSvc.windowFocused = true;
      LifecycleSvc.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(ChatsSvc.activeChat?.isAlive.value, isTrue);
    });
  });

  group('Foreground, sub-route, and peek gating', () {
    test('isChatActive returns false when backgrounded, showingSubRoute, or peeked (alive: false)', () {
      _registerTestServices();
      final chat = _RecordingChat(guid: 'iMessage;-;+15550002');
      LifecycleSvc.windowFocused = true;
      ChatsSvc.setActiveChatSync(chat, clearNotifications: false, save: false);
      expect(ChatsSvc.isChatActive(chat.guid), isTrue);

      // Backgrounded window
      LifecycleSvc.windowFocused = false;
      expect(ChatsSvc.isChatActive(chat.guid), isFalse);
      LifecycleSvc.windowFocused = true;
      expect(ChatsSvc.isChatActive(chat.guid), isTrue);

      // Sub-route open on top of conversation
      final controller = cvc(chat);
      ChatsSvc.activeChat!.controller = controller;
      controller.showingSubRoute = true;
      expect(ChatsSvc.isChatActive(chat.guid), isFalse);
      controller.showingSubRoute = false;
      expect(ChatsSvc.isChatActive(chat.guid), isTrue);

      // Peek view (alive: false)
      ChatsSvc.setActiveChatSync(chat, clearNotifications: false, save: false, alive: false);
      expect(ChatsSvc.activeChat?.isActive.value, isTrue);
      expect(ChatsSvc.activeChat?.isAlive.value, isFalse);
      expect(ChatsSvc.isChatActive(chat.guid), isFalse);
    });

    test('setActiveChatSync does not mark alive or clear unread when window is not in foreground', () async {
      _registerTestServices();
      final chat = _RecordingChat(guid: 'iMessage;-;+15550003', hasUnreadMessage: true);
      LifecycleSvc.windowFocused = false;

      ChatsSvc.setActiveChatSync(chat, clearNotifications: true, save: false);
      await Future<void>.delayed(Duration.zero);

      expect(ChatsSvc.activeChat?.isAlive.value, isFalse);
      expect(chat.toggleCalls, isEmpty);
      expect(chat.hasUnreadMessage, isTrue);
    });

    test('ConversationView autoOpened defaults false and preserves true', () {
      final chat = _RecordingChat(guid: 'iMessage;-;+15550004');
      expect(ConversationView(chat: chat).autoOpened, isFalse);
      expect(ConversationView(chat: chat, autoOpened: true).autoOpened, isTrue);
    });
  });

  group('No unsolicited read receipts on read chats, outgoing echoes, or non-PrivateAPI', () {
    test('setActiveChatSync and setChatHasUnread do not call toggleHasUnreadAsync on already-read active chat', () async {
      _registerTestServices();
      final readChat = _RecordingChat(guid: 'iMessage;-;+15550005', hasUnreadMessage: false);
      LifecycleSvc.windowFocused = true;

      ChatsSvc.setActiveChatSync(readChat, clearNotifications: true, save: false);
      await Future<void>.delayed(Duration.zero);

      expect(readChat.toggleCalls, isEmpty);

      // Calling setChatHasUnread directly without force short-circuits without DB/network work
      await ChatsSvc.setChatHasUnread(readChat, false);
      expect(readChat.toggleCalls, isEmpty);

      // Genuine unread -> read still works when foregrounded
      final unreadChat = _RecordingChat(guid: 'iMessage;-;+15550009', hasUnreadMessage: true);
      ChatsSvc.setActiveChatSync(unreadChat, clearNotifications: true, save: false);
      await Future<void>.delayed(Duration.zero);

      expect(unreadChat.toggleCalls, hasLength(1));
      expect(unreadChat.toggleCalls.single.hasUnread, isFalse);
      expect(unreadChat.toggleCalls.single.force, isFalse);
      expect(unreadChat.toggleCalls.single.privateMark, isTrue);
      expect(unreadChat.hasUnreadMessage, isFalse);
    });

    test('addMessageToChat never sends privateMark: true for isFromMe echoes, even when active', () async {
      _registerTestServices();
      final chat = _RecordingChat(guid: 'iMessage;-;+15550006', hasUnreadMessage: false);
      LifecycleSvc.windowFocused = true;
      ChatsSvc.setActiveChatSync(chat, clearNotifications: false, save: false);

      final outgoing = Message(
        guid: 'out-1',
        text: 'sent from another device',
        isFromMe: true,
        dateCreated: DateTime.now(),
      );
      await ChatsSvc.addMessageToChat(chat, outgoing);

      expect(chat.toggleCalls, hasLength(1));
      expect(chat.toggleCalls.single.hasUnread, isFalse);
      expect(chat.toggleCalls.single.force, isFalse);
      expect(chat.toggleCalls.single.privateMark, isFalse);

      // Incoming message while active in foreground still leaves hasUnreadMessage = true
      // until explicit user interaction (no unsolicited privateMark: true)
      final incoming = Message(
        guid: 'in-1',
        text: 'hello',
        isFromMe: false,
        dateCreated: DateTime.now(),
      );
      await ChatsSvc.addMessageToChat(chat, incoming);

      expect(chat.toggleCalls, hasLength(2));
      expect(chat.toggleCalls.last.hasUnread, isTrue);
      expect(chat.toggleCalls.last.force, isTrue);
      expect(chat.toggleCalls.last.privateMark, isFalse);
      expect(chat.hasUnreadMessage, isTrue);

      // Unfocused window: resumed() or onUserChatInteraction never marks read
      LifecycleSvc.windowFocused = false;
      LifecycleSvc.didChangeAppLifecycleState(AppLifecycleState.resumed);
      final controller = cvc(chat);
      ChatsSvc.activeChat!.controller = controller;
      controller.onUserChatInteraction(immediate: true);
      await Future<void>.delayed(Duration.zero);
      expect(chat.hasUnreadMessage, isTrue);
      expect(chat.toggleCalls, hasLength(2));

      // Focused & interactive: explicit user interaction marks read with privateMark: true
      LifecycleSvc.windowFocused = true;
      LifecycleSvc.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(chat.hasUnreadMessage, isTrue); // resumed() alone never marks read
      controller.onUserChatInteraction(immediate: true);
      await Future<void>.delayed(Duration.zero);
      expect(chat.hasUnreadMessage, isFalse);
      expect(chat.toggleCalls, hasLength(3));
      expect(chat.toggleCalls.last.hasUnread, isFalse);
      expect(chat.toggleCalls.last.privateMark, isTrue);
    });

    test('addMessageToChat marks unread locally without privateMark when active chat is behind sub-route or unfocused', () async {
      _registerTestServices();
      final chat = _RecordingChat(guid: 'iMessage;-;+15550007', hasUnreadMessage: false);
      LifecycleSvc.windowFocused = true;
      ChatsSvc.setActiveChatSync(chat, clearNotifications: false, save: false);
      final controller = cvc(chat);
      ChatsSvc.activeChat!.controller = controller;
      controller.showingSubRoute = true;

      final incoming = Message(
        guid: 'in-subroute',
        text: 'arrive behind settings',
        isFromMe: false,
        dateCreated: DateTime.now(),
      );
      await ChatsSvc.addMessageToChat(chat, incoming);

      expect(chat.toggleCalls, hasLength(1));
      expect(chat.toggleCalls.single.hasUnread, isTrue);
      expect(chat.toggleCalls.single.privateMark, isFalse);
    });

    test('Chat.toggleAutoReadAsync updates preference without eager HttpSvc.chat.markRead', () async {
      final adapter = _registerTestServices();
      final chat = _RecordingChat(guid: 'iMessage;-;+15550008', id: 42);

      SettingsSvc.settings.enablePrivateAPI.value = false;
      await chat.toggleAutoReadAsync(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chat.autoSendReadReceipts, isTrue);
      expect(adapter.requests, isEmpty);

      SettingsSvc.settings.enablePrivateAPI.value = true;
      await chat.toggleAutoReadAsync(false);
      await chat.toggleAutoReadAsync(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chat.autoSendReadReceipts, isTrue);
      expect(adapter.requests, isEmpty);
    });
  });
}
