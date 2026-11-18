import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/reply_holder.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/message_reply_context.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/ui/chat/send_data.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}

Message _msg({
  required String guid,
  required String text,
  required DateTime createdAt,
  bool isFromMe = false,
  String? threadOriginatorGuid,
  String? threadOriginatorPart,
}) {
  return Message(
    guid: guid,
    text: text,
    dateCreated: createdAt,
    isFromMe: isFromMe,
    handleId: isFromMe ? 0 : 1,
    hasAttachments: false,
    threadOriginatorGuid: threadOriginatorGuid,
    threadOriginatorPart: threadOriginatorPart,
  );
}

Widget _wrapApp({
  required Widget child,
  required Chat chat,
  required Skins skin,
}) {
  SettingsSvc.settings.skin.value = skin;
  final theme = ThemesService.materialYouTheme(skin == Skins.iOS ? Brightness.dark : Brightness.light);
  final chatState = ChatsSvc.getOrCreateChatState(chat);
  ChatsSvc.activeChat = chatState;
  return MaterialApp(
    theme: theme,
    home: ChatStateScope(
      chatState: chatState,
      child: Scaffold(
        body: child,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    _registerTestServices();
  });

  group('Reply threading resolution & grouping', () {
    late Chat chat;
    late MessagesService service;

    setUp(() {
      chat = Chat(guid: 'iMessage;-;+15550001111', chatIdentifier: '+15550001111');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      service = ensureMessagesSvc(chat.guid);
    });

    tearDown(() {
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
    });

    test('groups multiple replies chronologically with originator first (including temp- and missing originator in _threads)', () {
      final t0 = DateTime(2026, 11, 18, 10, 0, 0);
      final orig = _msg(guid: 'orig-1', text: 'Dinner tonight?', createdAt: t0);
      final r1 = _msg(
        guid: 'reply-1',
        text: 'Yes!',
        createdAt: t0.add(const Duration(minutes: 1)),
        isFromMe: true,
        threadOriginatorGuid: 'orig-1',
        threadOriginatorPart: '0:0:0',
      );
      final r2 = _msg(
        guid: 'reply-2',
        text: 'Thai food?',
        createdAt: t0.add(const Duration(minutes: 2)),
        threadOriginatorGuid: 'orig-1',
        threadOriginatorPart: '0:0:0',
      );
      final r3Temp = _msg(
        guid: 'temp-reply-3',
        text: 'Sounds great',
        createdAt: t0.add(const Duration(minutes: 3)),
        isFromMe: true,
        threadOriginatorGuid: 'orig-1',
        threadOriginatorPart: '0:0:0',
      );

      // Insert originator first, then replies (mimics live _handleNewMessage where _threads may omit orig)
      service.struct.addMessages([orig, r2, r1, r3Temp]);

      final fullThread = collectThreadMessages(orig, [0], service);
      expect(fullThread.map((m) => m.guid).toList(), ['orig-1', 'reply-1', 'reply-2', 'temp-reply-3']);

      final repliesOnly = collectThreadMessages(orig, [0], service, includeOriginator: false);
      expect(repliesOnly.map((m) => m.guid).toList(), ['reply-1', 'reply-2', 'temp-reply-3']);
      expect(formatReplyCountLabel(repliesOnly.length), '3 Replies');
      expect(formatReplyCountLabel(1), '1 Reply');
    });

    test('resolveRootReplyTarget walks reply chains to root originator and preserves multi-part index', () {
      final t0 = DateTime(2026, 11, 18, 11, 0, 0);
      final orig = _msg(guid: 'orig-root', text: 'Root message', createdAt: t0);
      final r1 = _msg(
        guid: 'reply-hop-1',
        text: 'First reply to part 2',
        createdAt: t0.add(const Duration(minutes: 1)),
        threadOriginatorGuid: 'orig-root',
        threadOriginatorPart: '2:0:0',
      );
      final r2 = _msg(
        guid: 'reply-hop-2',
        text: 'Chained reply to r1',
        createdAt: t0.add(const Duration(minutes: 2)),
        isFromMe: true,
        threadOriginatorGuid: 'reply-hop-1',
        threadOriginatorPart: '0:0:0',
      );
      service.struct.addMessages([orig, r1, r2]);

      final fromR1 = resolveRootReplyTarget(r1, 0, service: service);
      expect(fromR1.guid, 'orig-root');
      expect(fromR1.message?.guid, 'orig-root');
      expect(fromR1.part, 2);

      final fromR2 = resolveRootReplyTarget(r2, 0, service: service);
      expect(fromR2.guid, 'orig-root');
      expect(fromR2.message?.guid, 'orig-root');
      expect(fromR2.part, 2);

      final thread = collectThreadMessages(r2, [0], service);
      expect(thread.map((m) => m.guid).toList(), ['orig-root', 'reply-hop-1', 'reply-hop-2']);
    });

    test('resolveRootReplyTarget terminates safely on cyclic threadOriginatorGuid', () {
      final t0 = DateTime(2026, 11, 18, 11, 30, 0);
      final a = _msg(guid: 'cyc-a', text: 'A', createdAt: t0, threadOriginatorGuid: 'cyc-b');
      final b = _msg(guid: 'cyc-b', text: 'B', createdAt: t0.add(const Duration(seconds: 1)), threadOriginatorGuid: 'cyc-a');
      service.struct.addMessages([a, b]);

      final target = resolveRootReplyTarget(a, 0, service: service);
      expect(target.guid, isNotNull);
    });
  });

  group('Reply threading UI across Material and iOS skins', () {
    for (final skin in [Skins.Material, Skins.iOS]) {
      final skinLabel = skin == Skins.iOS ? 'iOS' : 'Material';

      testWidgets('$skinLabel: shows tappable N Replies indicator, opens full thread, and sends inside thread',
          (tester) async {
        final chat = Chat(guid: 'iMessage;-;thread-ui-$skinLabel', chatIdentifier: 'thread-ui-$skinLabel');
        if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
          Get.delete<MessagesService>(tag: chat.guid, force: true);
        }
        if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
          Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        }

        final service = ensureMessagesSvc(chat.guid);
        final cvController = cvc(chat);
        final sentPayloads = <SendData>[];

        final t0 = DateTime(2026, 11, 18, 12, 0, 0);
        final orig = _msg(guid: 'ui-orig', text: 'Where should we meet?', createdAt: t0);
        final r1 = _msg(
          guid: 'ui-r1',
          text: 'At the cafe',
          createdAt: t0.add(const Duration(minutes: 1)),
          isFromMe: true,
          threadOriginatorGuid: 'ui-orig',
          threadOriginatorPart: '0:0:0',
        );
        final r2 = _msg(
          guid: 'ui-r2',
          text: 'See you at 5',
          createdAt: t0.add(const Duration(minutes: 2)),
          threadOriginatorGuid: 'ui-orig',
          threadOriginatorPart: '0:0:0',
        );
        service.struct.addMessages([orig, r1, r2]);

        cvController.sendFunc = (data) async {
          sentPayloads.add(data);
          final next = _msg(
            guid: 'temp-sent-${sentPayloads.length}',
            text: data.text,
            createdAt: t0.add(Duration(minutes: 2 + sentPayloads.length)),
            isFromMe: true,
            threadOriginatorGuid: data.replyGuid,
            threadOriginatorPart: '${data.replyPart ?? 0}:0:0',
          );
          service.struct.addMessages([next]);
          service.getMessageStateIfExists(data.replyGuid!)?.threadReplyCount.value += 1;
          service.triggerMessageUpdate(data.replyGuid!);
        };

        await tester.pumpWidget(
          _wrapApp(
            chat: chat,
            skin: skin,
            child: ListView(
              children: [
                MessageHolder(
                  cvController: cvController,
                  message: orig,
                  newMessage: r1,
                ),
                MessageHolder(
                  cvController: cvController,
                  message: r1,
                  oldMessage: orig,
                  newMessage: r2,
                ),
                MessageHolder(
                  cvController: cvController,
                  message: r2,
                  oldMessage: r1,
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('2 Replies'), findsOneWidget);

        // Live update when another reply arrives before opening thread
        final r3 = _msg(
          guid: 'temp-live-r3',
          text: 'On my way',
          createdAt: t0.add(const Duration(minutes: 3)),
          isFromMe: true,
          threadOriginatorGuid: 'ui-orig',
          threadOriginatorPart: '0:0:0',
        );
        service.struct.addMessages([r3]);
        service.getMessageStateIfExists('ui-orig')?.threadReplyCount.value = 3;
        service.triggerMessageUpdate('ui-orig');
        await tester.pumpAndSettle();

        expect(find.text('3 Replies'), findsOneWidget);

        // Tap "3 Replies" pill to open full thread popup
        await tester.tap(find.text('3 Replies'));
        await tester.pumpAndSettle();

        // Thread popup displays header + originator + all replies + reply composer
        expect(find.byTooltip('Close thread'), findsOneWidget);
        expect(find.textContaining('Where should we meet?', findRichText: true), findsWidgets);
        expect(find.textContaining('At the cafe', findRichText: true), findsWidgets);
        expect(find.textContaining('See you at 5', findRichText: true), findsWidgets);
        expect(find.textContaining('On my way', findRichText: true), findsWidgets);
        expect(find.byType(TextField), findsOneWidget);

        // Send a new reply directly from inside the thread view
        await tester.enterText(find.byType(TextField), 'Bringing snacks!');
        await tester.pump();
        final sendIcon = skin == Skins.iOS ? CupertinoIcons.arrow_up : Icons.send_rounded;
        await tester.tap(find.byIcon(sendIcon));
        await tester.pumpAndSettle();

        expect(sentPayloads, hasLength(1));
        expect(sentPayloads.single.text, 'Bringing snacks!');
        expect(sentPayloads.single.replyGuid, 'ui-orig');
        expect(sentPayloads.single.replyPart, 0);
        expect(find.textContaining('Bringing snacks!', findRichText: true), findsWidgets);
        expect(find.text('4 Replies'), findsWidgets);

        // Close thread view cleanly
        await tester.tap(find.byTooltip('Close thread'));
        await tester.pumpAndSettle();

        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      });
    }

    testWidgets('Material: shows ReplyBubbleSection even when olderMessage is null and originator state was not built yet',
        (tester) async {
      final chat = Chat(guid: 'iMessage;-;offscreen-origin', chatIdentifier: 'offscreen-origin');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      final service = ensureMessagesSvc(chat.guid);
      final cvController = cvc(chat);

      final t0 = DateTime(2026, 11, 18, 13, 0, 0);
      final orig = _msg(guid: 'off-orig', text: 'Original offscreen message', createdAt: t0);
      final reply = _msg(
        guid: 'off-reply',
        text: 'Reply at top of loaded window',
        createdAt: t0.add(const Duration(minutes: 5)),
        isFromMe: true,
        threadOriginatorGuid: 'off-orig',
        threadOriginatorPart: '0:0:0',
      );
      service.struct.addMessages([orig, reply]);
      expect(service.getMessageStateIfExists('off-orig'), isNull);

      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.Material,
          child: MessageHolder(
            cvController: cvController,
            message: reply,
            oldMessage: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ReplyBubble), findsOneWidget);
      expect(find.textContaining('Original offscreen message'), findsOneWidget);

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });

    testWidgets('ReplyHolder normalizes replying to a reply onto the root originator & part', (tester) async {
      final chat = Chat(guid: 'iMessage;-;reply-holder-root', chatIdentifier: 'reply-holder-root');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      final service = ensureMessagesSvc(chat.guid);
      final cvController = cvc(chat);

      final t0 = DateTime(2026, 11, 18, 14, 0, 0);
      final orig = _msg(guid: 'rh-orig', text: 'Root topic', createdAt: t0);
      final r1 = _msg(
        guid: 'rh-r1',
        text: 'First reply',
        createdAt: t0.add(const Duration(minutes: 1)),
        threadOriginatorGuid: 'rh-orig',
        threadOriginatorPart: '1:0:0',
      );
      final r2 = _msg(
        guid: 'rh-r2',
        text: 'Second reply',
        createdAt: t0.add(const Duration(minutes: 2)),
        isFromMe: true,
        threadOriginatorGuid: 'rh-r1',
        threadOriginatorPart: '0:0:0',
      );
      service.struct.addMessages([orig, r1, r2]);

      cvController.replyToMessage = MessageReplyContext(r2, 0);

      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.iOS,
          child: ReplyHolder(controller: cvController),
        ),
      );
      await tester.pumpAndSettle();

      expect(cvController.replyToMessage?.message.guid, 'rh-orig');
      expect(cvController.replyToMessage?.partIndex, 1);

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });
  });
}
