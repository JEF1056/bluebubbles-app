import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/pages/messages_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
import 'package:get/get.dart';
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

class _FakePrefsThemeActions extends SharedPreferencesThemeActions {
  _FakePrefsThemeActions(super.service);

  @override
  String? getSelectedLightTheme() => null;

  @override
  String? getSelectedDarkTheme() => null;
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    theme = _FakePrefsThemeActions(this);
  }
}

void _registerTestServices() {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    final settingsService = SettingsService()..settings = Settings();
    GetIt.I.registerSingleton<SettingsService>(settingsService);
  }
  if (!GetIt.I.isRegistered<SharedPreferencesService>()) {
    GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  }
  if (!GetIt.I.isRegistered<ThemesService>()) {
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  }
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (!GetIt.I.isRegistered<HandleService>()) {
    GetIt.I.registerSingleton<HandleService>(HandleService());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
  if (!GetIt.I.isRegistered<CacheService>()) {
    GetIt.I.registerSingleton<CacheService>(CacheService());
  }
  if (!GetIt.I.isRegistered<EventDispatcher>()) {
    GetIt.I.registerSingleton<EventDispatcher>(EventDispatcher());
  }
}

Message _msg(int idx) {
  return Message(
    guid: 'msg-$idx',
    text: 'Message $idx',
    dateCreated: DateTime.fromMillisecondsSinceEpoch(1700000000000 + idx * 1000),
    isFromMe: idx.isEven,
    handleId: idx.isEven ? 0 : 1,
    hasAttachments: false,
  );
}

class _FakeMessagesService extends MessagesService {
  final Future<bool> Function(int offset, int limit, _FakeMessagesService self) onLoadChunk;
  final List<int> requestedOffsets = [];

  _FakeMessagesService(super.tag, this.onLoadChunk);

  @override
  Future<bool> loadChunk(int offset, ConversationViewController controller, {int limit = 25}) async {
    requestedOffsets.add(offset);
    final result = await onLoadChunk(offset, limit, this);
    messagesLoaded = true;
    return result;
  }
}

Future<void> _pumpMessagesView(
  WidgetTester tester,
  Chat chat,
  _FakeMessagesService service,
) async {
  final controller = ConversationViewController(chat);
  addTearDown(() {
    Get.delete<MessagesService>(tag: service.tag, force: true);
    controller.dispose();
  });

  await tester.pumpWidget(
    GetMaterialApp(
      theme: ThemeData.light().copyWith(
        extensions: const [
          BubbleColors(),
          BubbleText(bubbleText: TextStyle(fontSize: 15)),
        ],
      ),
      home: Scaffold(
        body: ChatStateScope(
          chatState: ChatState(chat),
          child: MessagesView(
            controller: controller,
            customService: service,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(_registerTestServices);

  group('MessagesService.hasMoreForChunk', () {
    test('returns false when server returned fewer than limit messages', () {
      expect(MessagesService.hasMoreForChunk(reachedServerEnd: true, addedToStruct: 6), isFalse);
      expect(MessagesService.hasMoreForChunk(reachedServerEnd: true, addedToStruct: 1), isFalse);
      expect(MessagesService.hasMoreForChunk(reachedServerEnd: true, addedToStruct: 0), isFalse);
    });

    test('returns false when no new messages or reactions were added', () {
      expect(MessagesService.hasMoreForChunk(reachedServerEnd: false, addedToStruct: 0), isFalse);
    });

    test('returns true only when server page was full and added items', () {
      expect(MessagesService.hasMoreForChunk(reachedServerEnd: false, addedToStruct: 25), isTrue);
    });
  });

  group('MessagesView pagination', () {
    testWidgets('stops immediately when initial chunk reaches end of history', (tester) async {
      final chat = Chat(guid: 'any;-;+16504086627-short', chatIdentifier: '+16504086627');
      final service = _FakeMessagesService(chat.guid, (offset, limit, self) async {
        self.struct.addMessages(List.generate(6, _msg));
        return false;
      });

      await _pumpMessagesView(tester, chat, service);

      expect(service.requestedOffsets, [0]);
      expect(find.byType(Loader), findsNothing);
      expect(find.byType(MessageHolder), findsNWidgets(6));
    });

    testWidgets('loads final partial page once, merges last message, and hides Loader', (tester) async {
      final chat = Chat(guid: 'any;-;+16504086627-partial', chatIdentifier: '+16504086627');
      final service = _FakeMessagesService(chat.guid, (offset, limit, self) async {
        if (offset == 0) {
          self.struct.addMessages(List.generate(5, (i) => _msg(i + 1)));
          return true;
        }
        self.struct.addMessages([_msg(0)]);
        return false;
      });

      await _pumpMessagesView(tester, chat, service);

      expect(service.requestedOffsets, [0, 5]);
      expect(find.byType(Loader), findsNothing);
      expect(find.byType(MessageHolder), findsNWidgets(6));
    });

    testWidgets('stops without looping when next chunk adds 0 new messages', (tester) async {
      final chat = Chat(guid: 'any;-;+16504086627-dup', chatIdentifier: '+16504086627');
      final service = _FakeMessagesService(chat.guid, (offset, limit, self) async {
        if (offset == 0) {
          self.struct.addMessages(List.generate(5, _msg));
          return true;
        }
        return false;
      });

      await _pumpMessagesView(tester, chat, service);

      expect(service.requestedOffsets, [0, 5]);
      expect(find.byType(Loader), findsNothing);
    });

    testWidgets('stops without looping when next chunk throws an error', (tester) async {
      final chat = Chat(guid: 'any;-;+16504086627-err', chatIdentifier: '+16504086627');
      final service = _FakeMessagesService(chat.guid, (offset, limit, self) async {
        if (offset == 0) {
          self.struct.addMessages(List.generate(5, _msg));
          return true;
        }
        throw Exception('network failure');
      });

      await _pumpMessagesView(tester, chat, service);

      expect(service.requestedOffsets, [0, 5]);
      expect(find.byType(Loader), findsNothing);
    });
  });
}
