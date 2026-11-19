import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/reply_bubble_section.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_line_painter.dart';
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

    test('Material ReplyQuoteHookPainter aligns stem on reply side and midY with quoted bubble center', () {
      const size = Size(300, 48); // 40dp quoted bubble + 8dp bottom gap
      const quotedH = 40.0;

      // Left-side row replying to right-side bubble: stem at x=18, top arm at midY=20 pointing right.
      final leftToRight = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: true,
        replyFromMe: false,
        quotedBubbleWidth: 120,
        quotedBubbleHeight: quotedH,
      ).getBounds();
      expect(leftToRight.left, closeTo(18.0, 0.01));
      expect(leftToRight.right, closeTo(18.0 + 28.0, 0.01));
      expect(leftToRight.top, closeTo(quotedH / 2.0, 0.01));
      expect(leftToRight.bottom, closeTo(size.height, 0.01));

      // Narrow width clamping: arm stops 6dp before quoted bubble left edge (300 - 260 - 6 = 34).
      final clampedLeftToRight = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: true,
        replyFromMe: false,
        quotedBubbleWidth: 260,
        quotedBubbleHeight: quotedH,
      ).getBounds();
      expect(clampedLeftToRight.right, lessThanOrEqualTo(300 - 260 - 6.0 + 0.01));

      // Mirrored isFromMe reply: stem at x=300-18, top arm at midY=20 pointing left.
      final rightToLeft = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: false,
        replyFromMe: true,
        quotedBubbleWidth: 120,
        quotedBubbleHeight: quotedH,
      ).getBounds();
      expect(rightToLeft.right, closeTo(300 - 18.0, 0.01));
      expect(rightToLeft.left, closeTo(300 - 18.0 - 28.0, 0.01));
      expect(rightToLeft.top, closeTo(quotedH / 2.0, 0.01));
      expect(rightToLeft.bottom, closeTo(size.height, 0.01));

      // Narrow width clamping for isFromMe reply: arm stops 6dp after quoted bubble right edge (260 + 6 = 266).
      final clampedRightToLeft = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: false,
        replyFromMe: true,
        quotedBubbleWidth: 260,
        quotedBubbleHeight: quotedH,
      ).getBounds();
      expect(clampedRightToLeft.left, greaterThanOrEqualTo(260 + 6.0 - 0.01));

      // Same-side replies draw a short vertical stem below the quoted bubble on the reply side.
      final sameLeft = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: false,
        replyFromMe: false,
        quotedBubbleHeight: quotedH,
      ).getBounds();
      expect(sameLeft.left, closeTo(18.0, 0.01));
      expect(sameLeft.right, closeTo(18.0, 0.01));
      expect(sameLeft.top, closeTo(quotedH, 0.01));
      expect(sameLeft.bottom, closeTo(size.height, 0.01));

      final sameRight = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: true,
        replyFromMe: true,
        quotedBubbleHeight: quotedH,
      ).getBounds();
      expect(sameRight.left, closeTo(300 - 18.0, 0.01));
      expect(sameRight.right, closeTo(300 - 18.0, 0.01));
      expect(sameRight.top, closeTo(quotedH, 0.01));
      expect(sameRight.bottom, closeTo(size.height, 0.01));
    });

    testWidgets('Material: right-side quoted reply bubble uses reduced opacity and renders hook box', (tester) async {
      final chat = Chat(guid: 'iMessage;-;mat-reply-opacity', chatIdentifier: 'mat-reply-opacity');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      final service = ensureMessagesSvc(chat.guid);
      final cvController = cvc(chat);

      final t0 = DateTime(2026, 11, 18, 15, 0, 0);
      final orig = _msg(guid: 'mo-orig', text: 'My original message', createdAt: t0, isFromMe: true);
      final reply = _msg(
        guid: 'mo-reply',
        text: 'Incoming reply',
        createdAt: t0.add(const Duration(minutes: 2)),
        isFromMe: false,
        threadOriginatorGuid: 'mo-orig',
        threadOriginatorPart: '0:0:0',
      );
      service.struct.addMessages([orig, reply]);

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

      final sectionFinder = find.byType(ReplyBubbleSection);
      expect(sectionFinder, findsOneWidget);

      final decoratedBox = tester.widget<DecoratedBox>(
        find.descendant(of: sectionFinder, matching: find.byType(DecoratedBox)).first,
      );
      final boxDec = decoratedBox.decoration as BoxDecoration;
      expect(boxDec.color!.a, closeTo(0.72, 0.02));

      final align = tester.widget<Align>(
        find.descendant(of: sectionFinder, matching: find.byType(Align)).first,
      );
      expect(align.alignment, Alignment.centerRight);

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });

    testWidgets('Tapping out of reply thread view (backdrop, row side, or bubble) dismisses without jumpToMessage',
        (tester) async {
      final chat = Chat(guid: 'iMessage;-;thread-dismiss-nojump', chatIdentifier: 'thread-dismiss-nojump');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }

      final service = ensureMessagesSvc(chat.guid);
      final cvController = cvc(chat);
      final jumpedGuids = <String>[];
      service.jumpToMessage = jumpedGuids.add;

      final t0 = DateTime(2026, 11, 18, 16, 0, 0);
      final orig = _msg(guid: 'td-orig', text: 'Originator message', createdAt: t0, isFromMe: false);
      final reply = _msg(
        guid: 'td-reply',
        text: 'Short reply',
        createdAt: t0.add(const Duration(minutes: 1)),
        isFromMe: true,
        threadOriginatorGuid: 'td-orig',
        threadOriginatorPart: '0:0:0',
      );
      service.struct.addMessages([orig, reply]);

      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.Material,
          child: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showReplyThread(
                  context,
                  orig,
                  MessagePart(part: 0, text: orig.text),
                  service,
                  cvController,
                ),
                child: const Text('Open Thread'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Tap the empty space on the left side of the sent reply row (previously caught by row AbsorbPointer).
      await tester.tap(find.text('Open Thread'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsOneWidget);

      final replyTextRect = tester.getRect(find.textContaining('Short reply', findRichText: true).last);
      await tester.tapAt(Offset(16, replyTextRect.center.dy));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Close thread'), findsNothing);
      expect(jumpedGuids, isEmpty);

      // 2. Tap directly on a message bubble inside the thread view.
      await tester.tap(find.text('Open Thread'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsOneWidget);

      final origRect = tester.getRect(find.textContaining('Originator message', findRichText: true).last);
      await tester.tapAt(origRect.center);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Close thread'), findsNothing);
      expect(jumpedGuids, isEmpty);

      // 3. Tap the blurred backdrop above the message list.
      await tester.tap(find.text('Open Thread'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsOneWidget);

      await tester.tapAt(const Offset(100, 90));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Close thread'), findsNothing);
      expect(jumpedGuids, isEmpty);

      // 4. Vertical drag inside a scrollable thread scrolls without dismissing or jumping.
      final manyReplies = List.generate(
        18,
        (i) => _msg(
          guid: 'td-many-$i',
          text: 'Scrollable reply item $i with extra text to fill space',
          createdAt: t0.add(Duration(minutes: 2 + i)),
          isFromMe: i.isEven,
          threadOriginatorGuid: 'td-orig',
          threadOriginatorPart: '0:0:0',
        ),
      );
      service.struct.addMessages(manyReplies);

      await tester.tap(find.text('Open Thread'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsOneWidget);

      final scrollView = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(SingleChildScrollView),
      );
      final scrollableFinder = scrollView.evaluate().isNotEmpty ? scrollView : find.byType(SingleChildScrollView);
      await tester.drag(scrollableFinder.first, const Offset(0, 200));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Close thread'), findsOneWidget);
      expect(jumpedGuids, isEmpty);

      // Dismiss cleanly via close button.
      await tester.tap(find.byTooltip('Close thread'));
      await tester.pumpAndSettle();
      expect(jumpedGuids, isEmpty);

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });

    testWidgets('Tapping Material L-hook and quote-hook bars opens thread without hijacking bubble/empty/select taps',
        (tester) async {
      final chat = Chat(guid: 'iMessage;-;tap-bars-material', chatIdentifier: 'tap-bars-material');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }

      final service = ensureMessagesSvc(chat.guid);
      final cvController = cvc(chat);

      final t0 = DateTime(2026, 11, 18, 17, 0, 0);
      final orig = _msg(guid: 'bar-orig', text: 'Originator question', createdAt: t0, isFromMe: false);
      final directReply = _msg(
        guid: 'bar-direct-reply',
        text: 'Direct reply',
        createdAt: t0.add(const Duration(minutes: 1)),
        isFromMe: true,
        threadOriginatorGuid: 'bar-orig',
        threadOriginatorPart: '0:0:0',
      );
      final unrelated = _msg(
        guid: 'bar-unrelated',
        text: 'Unrelated message',
        createdAt: t0.add(const Duration(minutes: 2)),
        isFromMe: false,
      );
      final quotedReply = _msg(
        guid: 'bar-quoted-reply',
        text: 'Quoted reply',
        createdAt: t0.add(const Duration(minutes: 3)),
        isFromMe: true,
        threadOriginatorGuid: 'bar-orig',
        threadOriginatorPart: '0:0:0',
      );
      service.struct.addMessages([orig, directReply, unrelated, quotedReply]);

      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.Material,
          child: ListView(
            children: [
              MessageHolder(cvController: cvController, message: orig, newMessage: directReply),
              MessageHolder(
                cvController: cvController,
                message: directReply,
                oldMessage: orig,
                newMessage: unrelated,
              ),
              MessageHolder(
                cvController: cvController,
                message: unrelated,
                oldMessage: directReply,
                newMessage: quotedReply,
              ),
              MessageHolder(
                cvController: cvController,
                message: quotedReply,
                oldMessage: unrelated,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Tap the Material L-hook bar on directReply (isFromMe=true => hook sits at left margin x ~ 18..46).
      final directHolder = find.byWidgetPredicate((w) => w is MessageHolder && w.message.guid == 'bar-direct-reply');
      final directLineBox = find.descendant(of: directHolder, matching: find.byType(ReplyLineBox));
      final directRect = tester.getRect(directLineBox);

      // Tapping empty space in the middle of the row should NOT open thread view.
      await tester.tapAt(Offset(directRect.center.dx, directRect.center.dy));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsNothing);

      // Tapping the message bubble itself should NOT open thread view.
      await tester.tap(find.textContaining('Direct reply', findRichText: true).first);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsNothing);

      // Tapping the white L-hook bar opens thread view.
      await tester.tapAt(Offset(directRect.left + 20, directRect.top + 12));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsOneWidget);
      await tester.tap(find.byTooltip('Close thread'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsNothing);

      // 2. Tap the Material quote-hook bar on quotedReply (quotedFromMe=false, replyFromMe=true => hook on right).
      final quotedHolder = find.byWidgetPredicate((w) => w is MessageHolder && w.message.guid == 'bar-quoted-reply');
      final sectionRect = tester.getRect(find.descendant(of: quotedHolder, matching: find.byType(ReplyBubbleSection)));

      // Tapping empty center of the quote row should NOT open thread view.
      await tester.tapAt(Offset(sectionRect.center.dx, sectionRect.center.dy));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsNothing);

      // Tapping the white curved quote hook on the right side opens thread view.
      await tester.tapAt(Offset(sectionRect.right - 20, sectionRect.bottom - 10));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsOneWidget);
      await tester.tap(find.byTooltip('Close thread'));
      await tester.pumpAndSettle();

      // 3. In select mode, tapping the L-hook selects the message instead of opening thread view.
      cvController.inSelectMode.value = true;
      await tester.pump();
      await tester.tapAt(Offset(directRect.left + 20, directRect.top + 12));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsNothing);
      expect(cvController.isSelected('bar-direct-reply'), isTrue);

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });

    testWidgets('iOS: tapping thread connector bar opens thread without hijacking bubble tap', (tester) async {
      final chat = Chat(guid: 'iMessage;-;tap-bars-ios', chatIdentifier: 'tap-bars-ios');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }

      final service = ensureMessagesSvc(chat.guid);
      final cvController = cvc(chat);

      final t0 = DateTime(2026, 11, 18, 18, 0, 0);
      final orig = _msg(guid: 'ios-orig', text: 'iOS originator', createdAt: t0, isFromMe: true);
      final reply = _msg(
        guid: 'ios-reply',
        text: 'iOS reply',
        createdAt: t0.add(const Duration(minutes: 1)),
        isFromMe: true,
        threadOriginatorGuid: 'ios-orig',
        threadOriginatorPart: '0:0:0',
      );
      service.struct.addMessages([orig, reply]);

      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.iOS,
          child: ListView(
            children: [
              MessageHolder(cvController: cvController, message: orig, newMessage: reply),
              MessageHolder(cvController: cvController, message: reply, oldMessage: orig),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final replyHolder = find.byWidgetPredicate((w) => w is MessageHolder && w.message.guid == 'ios-reply');
      final replyLineRect = tester.getRect(find.descendant(of: replyHolder, matching: find.byType(ReplyLineBox)));

      // Tapping the bubble itself should NOT open thread view.
      await tester.tap(find.textContaining('iOS reply', findRichText: true).first);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsNothing);

      // Tapping the iOS vertical connector line at x ~ 35 opens thread view.
      await tester.tapAt(Offset(replyLineRect.left + 35, replyLineRect.center.dy));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsOneWidget);
      await tester.tap(find.byTooltip('Close thread'));
      await tester.pumpAndSettle();

      // Tapping the iOS originator's lower connector line also opens thread view.
      final origHolder = find.byWidgetPredicate((w) => w is MessageHolder && w.message.guid == 'ios-orig');
      final origLineRect = tester.getRect(find.descendant(of: origHolder, matching: find.byType(ReplyLineBox)));
      await tester.tapAt(Offset(origLineRect.left + 35, origLineRect.center.dy));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsOneWidget);
      await tester.tap(find.byTooltip('Close thread'));
      await tester.pumpAndSettle();

      // Tapping the iOS connector line beside a quoted same-side ReplyBubbleSection also opens thread view.
      final unrelated = _msg(
        guid: 'ios-unrelated',
        text: 'Middle message',
        createdAt: t0.add(const Duration(minutes: 2)),
        isFromMe: false,
      );
      final quotedReply = _msg(
        guid: 'ios-quoted-reply',
        text: 'Later reply',
        createdAt: t0.add(const Duration(minutes: 3)),
        isFromMe: true,
        threadOriginatorGuid: 'ios-orig',
        threadOriginatorPart: '0:0:0',
      );
      service.struct.addMessages([unrelated, quotedReply]);
      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.iOS,
          child: ListView(
            children: [
              MessageHolder(cvController: cvController, message: orig, newMessage: reply),
              MessageHolder(cvController: cvController, message: reply, oldMessage: orig, newMessage: unrelated),
              MessageHolder(cvController: cvController, message: unrelated, oldMessage: reply, newMessage: quotedReply),
              MessageHolder(cvController: cvController, message: quotedReply, oldMessage: unrelated),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final quotedHolder = find.byWidgetPredicate((w) => w is MessageHolder && w.message.guid == 'ios-quoted-reply');
      final quotedSectionRect =
          tester.getRect(find.descendant(of: quotedHolder, matching: find.byType(ReplyBubbleSection)));
      await tester.tapAt(Offset(quotedSectionRect.left + 35, quotedSectionRect.center.dy));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsOneWidget);
      await tester.tap(find.byTooltip('Close thread'));
      await tester.pumpAndSettle();

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });
  });
}
