import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_library_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_drop_target.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/reply_holder.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/database/html/message.dart' as html_msg;
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_server_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/send_data.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
import 'package:get/get.dart' hide Response;
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

class _TestSettings extends Settings {
  @override
  Future<Settings> saveManyAsync(List<String> keys) async => this;
}

class _FakePrefsThemeActions extends SharedPreferencesThemeActions {
  _FakePrefsThemeActions(super.service);

  @override
  String? getSelectedLightTheme() => null;

  @override
  String? getSelectedDarkTheme() => null;
}

class _FakePrefsServerActions extends SharedPreferencesServerActions {
  _FakePrefsServerActions(super.service);

  @override
  bool hasSeenPrivateApiEnableTip() => true;

  @override
  bool isPrivateApiDisabledByUser() => false;
}

class _FakePrefsMessagingActions extends SharedPreferencesMessagingActions {
  _FakePrefsMessagingActions(super.service);

  @override
  List<String> getRecentTapbackEmojis({String? chatGuid}) => const [];
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    theme = _FakePrefsThemeActions(this);
    server = _FakePrefsServerActions(this);
    messaging = _FakePrefsMessagingActions(this);
  }
}

class _FakeMessageApi extends MessageApi {
  _FakeMessageApi(super.svc);

  @override
  Future<Response> fetchOne(String guid, {String withQuery = "", CancelToken? cancelToken}) async {
    return Response(
      requestOptions: RequestOptions(path: '/api/v1/message/$guid'),
      statusCode: 404,
    );
  }
}

class _FakeHttpService extends HttpService {
  _FakeHttpService() {
    message = _FakeMessageApi(this);
  }
}

class _FakeStickerLibraryService extends StickerLibraryService {
  @override
  Future<Uint8List> imageForSending(LibrarySticker sticker) async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      );
}

class _FakeOutgoingMessageHandler extends OutgoingMessageHandler {
  int placedCount = 0;

  @override
  Future<void> queuePlacedSticker({
    required Chat chat,
    required Message selected,
    required int part,
    required Uint8List bytes,
    required String fileName,
    required StickerPlacement placement,
  }) async {
    placedCount++;
  }
}

class _TestChat extends Chat {
  _TestChat({required super.guid, super.chatIdentifier});

  @override
  Future<Chat> saveAsync({
    bool updateIfAbsent = true,
    bool updateLocalVals = false,
    bool updateCustomAvatarPath = false,
    bool updateThreadOriginator = false,
    bool updateLatestMessage = false,
    bool updateAutoSendReadReceipts = false,
    bool updateAutoSendTypingIndicators = false,
    bool updateCustomBackgroundPath = false,
    bool updateCustomThemes = false,
    bool updateDateDeleted = false,
    bool updateDisplayName = false,
    bool updateHasUnreadMessage = false,
    bool updateIsArchived = false,
    bool updateIsPinned = false,
    bool updateKnownGroupPhotoGuid = false,
    bool updateLastReadMessageGuid = false,
    bool updateLockChatIcon = false,
    bool updateLockChatName = false,
    bool updateMuteArgs = false,
    bool updateMuteType = false,
    bool updatePinIndex = false,
    bool updateServiceName = false,
    bool updateTextFieldAttachments = false,
    bool updateTextFieldText = false,
    bool updateWallpaperSettings = false,
  }) async =>
      this;
}

void _registerBaseServices() {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = _TestSettings());
  }
  if (!GetIt.I.isRegistered<SharedPreferencesService>()) {
    GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
  if (!GetIt.I.isRegistered<HttpService>()) {
    GetIt.I.registerSingleton<HttpService>(_FakeHttpService());
  }
  if (!GetIt.I.isRegistered<StickerLibraryService>()) {
    GetIt.I.registerSingleton<StickerLibraryService>(_FakeStickerLibraryService());
  }
  if (!GetIt.I.isRegistered<OutgoingMessageHandler>()) {
    GetIt.I.registerSingleton<OutgoingMessageHandler>(_FakeOutgoingMessageHandler());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
  }
  if (!GetIt.I.isRegistered<EventDispatcher>()) {
    GetIt.I.registerSingleton<EventDispatcher>(EventDispatcher());
  }
  if (!GetIt.I.isRegistered<ContactServiceV2>()) {
    GetIt.I.registerSingleton<ContactServiceV2>(ContactServiceV2());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _registerBaseServices();

  group('Stickers DB protection & UI guards (#6)', () {
    test('OutgoingMessageHandler guards _finalizeOutgoingSuccess and _matchMessageWithExisting against null/empty guid',
        () async {
      final handler = OutgoingMessageHandler();
      final chat = Chat(guid: 'iMessage;-;+15550001111', chatIdentifier: '+15550001111');

      // HTTP 200 sticker response containing `{ identifier }` without `guid` must return early without touching DB
      await expectLater(
        handler.finalizeOutgoingSuccessForTest(chat, 'temp-sticker-1', {
          'data': {'identifier': 'sticker-uuid-only'},
        }),
        completes,
      );
      await expectLater(
        handler.finalizeOutgoingSuccessForTest(chat, 'temp-sticker-1', {
          'data': {'guid': ''},
        }),
        completes,
      );
      await expectLater(
        handler.matchMessageWithExistingForTest(chat, 'temp-sticker-1', Message(guid: null)),
        completes,
      );
      await expectLater(
        handler.matchMessageWithExistingForTest(chat, 'temp-sticker-1', Message(guid: '')),
        completes,
      );
    });

    test('ChatMessages.addMessages skips null/empty message and attachment GUIDs without crashing', () {
      final struct = ChatMessages();
      final nullMsg = Message(guid: null, text: 'bad-null');
      final emptyMsg = Message(guid: '', text: 'bad-empty');
      final badAtt = Attachment(guid: null, transferName: 'bad.png');
      final goodAtt = Attachment(guid: 'att-good', transferName: 'good.png');
      final goodMsg = Message(guid: 'msg-good', text: 'ok')..dbAttachments.addAll([badAtt, goodAtt]);

      expect(() => struct.addMessages([nullMsg, emptyMsg, goodMsg]), returnsNormally);
      expect(struct.messages.map((m) => m.guid), ['msg-good']);
      expect(struct.getAttachment('att-good'), isNotNull);
    });

    test('StickerHolder.scaleForPoints falls back to fallbackPixels when pixels <= 0 or non-finite', () {
      const expectedFallback = 100.0 * 3.0 / StickerHolder.fallbackPixels;
      expect(StickerHolder.scaleForPoints(100, 0), closeTo(expectedFallback, 1e-6));
      expect(StickerHolder.scaleForPoints(100, -12), closeTo(expectedFallback, 1e-6));
      expect(StickerHolder.scaleForPoints(100, double.nan), closeTo(expectedFallback, 1e-6));
      expect(StickerHolder.scaleForPoints(100, double.infinity), closeTo(expectedFallback, 1e-6));
      expect(StickerHolder.scaleForPoints(100, 600), closeTo(0.5, 1e-6));
    });

    testWidgets('StickerDropTarget accepts drops on iMessage chats and rejects non-iMessage (RCS/SMS) chats',
        (tester) async {
      final drag = StickerDrag(
        const LibrarySticker(
          identifier: 'st-1',
          shelf: 'saved',
          longestSide: 300,
        ),
      );

      for (final isIMessage in [false, true]) {
        final chat = isIMessage
            ? Chat(guid: 'iMessage;-;+15550004444', chatIdentifier: '+15550004444')
            : Chat(guid: 'RCS;-;+15550004444', chatIdentifier: '+15550004444');
        final msg = Message(guid: 'msg-drop-$isIMessage', text: 'Target', isFromMe: false);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: 20,
                    top: 20,
                    child: Draggable<StickerDrag>(
                      data: drag,
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      feedback: const SizedBox(width: 24, height: 24),
                      child: const ColoredBox(
                        key: ValueKey('drag_src'),
                        color: Colors.blue,
                        child: SizedBox(width: 48, height: 48),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 100,
                    top: 120,
                    width: 200,
                    height: 80,
                    child: Stack(
                      key: const ValueKey('drop_box'),
                      children: [
                        const SizedBox.expand(),
                        Positioned.fill(
                          child: StickerDropTarget(
                            chat: chat,
                            message: msg,
                            part: 0,
                            tailGutter: false,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        final srcCenter = tester.getCenter(find.byKey(const ValueKey('drag_src')));
        final dstCenter = tester.getCenter(find.byKey(const ValueKey('drop_box')));
        final gesture = await tester.startGesture(srcCenter);
        await tester.pump();
        // Break touch slop so _DragAvatar starts before moving over StickerDropTarget
        await gesture.moveBy(const Offset(24, 0));
        await tester.pump();
        await gesture.moveTo(dstCenter);
        await tester.pump();

        expect(
          find.descendant(of: find.byKey(const ValueKey('drop_box')), matching: find.byType(AnimatedContainer)),
          isIMessage ? findsOneWidget : findsNothing,
        );

        final fakeOutgoing = GetIt.I<OutgoingMessageHandler>() as _FakeOutgoingMessageHandler;
        final beforePlaced = fakeOutgoing.placedCount;
        await gesture.up();
        await tester.pumpAndSettle();
        expect(fakeOutgoing.placedCount - beforePlaced, isIMessage ? 1 : 0);
      }
    });
  });

  group('RCS tapbacks + replies (#8)', () {
    test('io & html Message.fromMap parse isRead and default associatedMessagePart to 0 for bare associatedMessageGuid',
        () {
      final bareIo = Message.fromMap({
        'guid': 'rcs-react-1',
        'associatedMessageGuid': 'rcs-target-1',
        'associatedMessageType': 'emoji',
        'associatedMessageEmoji': '❤️',
        'isRead': true,
      });
      expect(bareIo.isRead, isTrue);
      expect(bareIo.associatedMessageGuid, 'rcs-target-1');
      expect(bareIo.associatedMessagePart, 0);
      expect(bareIo.toMap()['isRead'], isTrue);

      final bareHtml = html_msg.Message.fromMap({
        'guid': 'rcs-react-1',
        'associatedMessageGuid': 'rcs-target-1',
        'associatedMessageType': 'emoji',
        'associatedMessageEmoji': '❤️',
        'isRead': 1,
      });
      expect(bareHtml.isRead, isTrue);
      expect(bareHtml.associatedMessageGuid, 'rcs-target-1');
      expect(bareHtml.associatedMessagePart, 0);
      expect(bareHtml.toMap()['isRead'], isTrue);

      final explicitPart = Message.fromMap({
        'guid': 'rcs-react-2',
        'associatedMessageGuid': 'rcs-target-1',
        'associatedMessagePart': 2,
        'associatedMessageType': 'emoji',
        'isRead': 0,
      });
      expect(explicitPart.isRead, isFalse);
      expect(explicitPart.associatedMessagePart, 2);

      final prefixed = Message.fromMap({
        'guid': 'imsg-react-1',
        'associatedMessageGuid': 'p:1/imsg-target-1',
        'associatedMessageType': 'love',
      });
      expect(prefixed.associatedMessageGuid, 'imsg-target-1');
      expect(prefixed.associatedMessagePart, 1);
      expect(prefixed.isRead, isNull);

      final unplacedSticker = Message.fromMap({
        'guid': 'sticker-legacy-1',
        'associatedMessageGuid': 'target-1',
        'associatedMessageType': ReactionTypes.PLACED_STICKER,
      });
      expect(unplacedSticker.associatedMessagePart, isNull);
    });

    test('io & html Message.merge and fillsGapsIn propagate associatedMessage* and isRead while guarding SUPERSEDED',
        () {
      final plain = Message(guid: 'rcs-msg-1', text: '❤️', isFromMe: false);
      final tapback = Message(
        guid: 'rcs-msg-1',
        text: '❤️',
        associatedMessageGuid: 'rcs-target-1',
        associatedMessageType: ReactionTypes.EMOJI,
        associatedMessagePart: 0,
        associatedMessageEmoji: '❤️',
        isRead: true,
      );

      expect(tapback.fillsGapsIn(plain), isTrue);
      expect(Message(guid: 'rcs-msg-1', isRead: true).fillsGapsIn(Message(guid: 'rcs-msg-1')), isFalse);

      final merged = Message.merge(plain, tapback);
      expect(merged.associatedMessageGuid, 'rcs-target-1');
      expect(merged.associatedMessageType, ReactionTypes.EMOJI);
      expect(merged.associatedMessagePart, 0);
      expect(merged.associatedMessageEmoji, '❤️');
      expect(merged.isRead, isTrue);
      expect(merged.isReaction, isTrue);

      final plainHtml = html_msg.Message(guid: 'rcs-msg-1', text: '❤️', isFromMe: false);
      final tapbackHtml = html_msg.Message(
        guid: 'rcs-msg-1',
        text: '❤️',
        associatedMessageGuid: 'rcs-target-1',
        associatedMessageType: ReactionTypes.EMOJI,
        associatedMessagePart: 0,
        associatedMessageEmoji: '❤️',
        isRead: true,
      );
      expect(tapbackHtml.fillsGapsIn(plainHtml), isTrue);
      final mergedHtml = html_msg.Message.merge(plainHtml, tapbackHtml);
      expect(mergedHtml.associatedMessageGuid, 'rcs-target-1');
      expect(mergedHtml.associatedMessageType, ReactionTypes.EMOJI);
      expect(mergedHtml.associatedMessagePart, 0);
      expect(mergedHtml.isRead, isTrue);
      expect(mergedHtml.isReaction, isTrue);

      final superseded = Message(
        guid: 'app-turn-1',
        balloonBundleId: '${AppSessionTypes.extensionBalloonPlugin}:0000:com.test.game',
        associatedMessageGuid: 'newer-turn',
        associatedMessageType: AppSessionTypes.SUPERSEDED,
        associatedMessagePart: 0,
      );
      final stale = Message(
        guid: 'app-turn-1',
        balloonBundleId: '${AppSessionTypes.extensionBalloonPlugin}:0000:com.test.game',
        associatedMessageGuid: 'older-turn',
        associatedMessageType: AppSessionTypes.UPDATE,
      );
      final appMerged = Message.merge(superseded, stale);
      expect(appMerged.associatedMessageType, AppSessionTypes.SUPERSEDED);
      expect(appMerged.associatedMessageGuid, 'newer-turn');
    });

    test('MessagesService.updateMessage converts standalone plain message to parent reaction & calls removeFunc', () {
      const chatGuid = 'RCS;-;+15550005555';
      final svc = ensureMessagesSvc(chatGuid);
      final removed = <String>[];
      final updatedCalls = <String>[];
      svc.chat = Chat(guid: chatGuid, chatIdentifier: '+15550005555');
      svc.newFunc = (_) {};
      svc.removeFunc = (m) => removed.add(m.guid!);
      svc.updateFunc = (m, {oldGuid}) => updatedCalls.add(m.guid!);

      final parent = Message(guid: 'parent-1', text: 'Hi', dateCreated: DateTime(2026, 11, 20, 12, 0));
      final standalone = Message(guid: 'rcs-emoji-1', text: '❤️', dateCreated: DateTime(2026, 11, 20, 12, 1));
      svc.struct.addMessages([parent, standalone]);
      final parentState = MessageState(parent)..onInit();
      final standaloneState = MessageState(standalone)..onInit();
      svc.messageStates['parent-1'] = parentState;
      svc.messageStates['rcs-emoji-1'] = standaloneState;

      final prevTrigger = svc.messageUpdateTrigger['parent-1'] ?? 0;
      final transitioned = Message(
        guid: 'rcs-emoji-1',
        text: '❤️',
        dateCreated: DateTime(2026, 11, 20, 12, 1),
        associatedMessageGuid: 'parent-1',
        associatedMessageType: ReactionTypes.EMOJI,
        associatedMessagePart: 0,
        associatedMessageEmoji: '❤️',
      );
      svc.updateMessage(transitioned);

      expect(removed, ['rcs-emoji-1']);
      expect(updatedCalls, isEmpty);
      expect(svc.struct.messages.map((m) => m.guid), ['parent-1']);
      expect(svc.messageStates.containsKey('rcs-emoji-1'), isFalse);
      expect(parent.associatedMessages.map((m) => m.guid), ['rcs-emoji-1']);
      expect(parentState.associatedMessages.map((m) => m.guid), ['rcs-emoji-1']);
      expect(svc.messageUpdateTrigger['parent-1'], isNot(prevTrigger));

      // Verify subsequent reaction update preserves newer associatedMessageType/Emoji rather than reverting to stale
      final updatedReaction = Message(
        guid: 'rcs-emoji-1',
        text: '😂',
        dateCreated: DateTime(2026, 11, 20, 12, 1),
        associatedMessageGuid: 'parent-1',
        associatedMessageType: ReactionTypes.LAUGH,
        associatedMessagePart: 0,
      );
      svc.struct.addMessages([transitioned]);
      svc.updateMessage(updatedReaction);
      expect(parentState.associatedMessages.single.associatedMessageType, ReactionTypes.LAUGH);

      Get.delete<MessagesService>(tag: chatGuid, force: true);
    });

    test('IncomingMessageHandler.refreshLatestMessageOnUpdate refreshes chat.latestMessage on plain->reaction update',
        () {
      final chat = _TestChat(guid: 'RCS;-;+15550006666', chatIdentifier: '+15550006666');
      final t0 = DateTime(2026, 11, 20, 12, 0);
      final plainEmoji = Message(
        guid: 'rcs-latest-1',
        text: '❤️',
        dateCreated: t0.add(const Duration(seconds: 5)),
        isFromMe: false,
      );
      chat.setLatestMessage(plainEmoji);

      final chatState = ChatsSvc.getOrCreateChatState(chat);
      ChatsSvc.updateChatLatestMessage(chat.guid, plainEmoji, allowOlder: true);
      expect(chatState.latestMessage.value?.isReaction, isFalse);

      final reacted = Message(
        guid: 'rcs-latest-1',
        text: '❤️',
        dateCreated: t0.add(const Duration(seconds: 5)),
        isFromMe: false,
        associatedMessageGuid: 'rcs-target-latest',
        associatedMessageType: ReactionTypes.EMOJI,
        associatedMessagePart: 0,
        associatedMessageEmoji: '❤️',
      );
      IncomingMessageHandler().refreshLatestMessageOnUpdate(
        chat,
        reacted,
        wasReaction: false,
      );

      expect(chatState.latestMessage.value?.guid, 'rcs-latest-1');
      expect(chatState.latestMessage.value?.isReaction, isTrue);
      expect(chat.dbLatestMessage.target?.isReaction, isTrue);
    });

    testWidgets('ReplyHolder preserves exact intermediate reply target on RCS while flattening on iMessage',
        (tester) async {
      final root = Message(guid: 'root-msg', text: 'Root original message', isFromMe: false);
      final middle = Message(
        guid: 'mid-msg',
        text: 'Middle quoted reply',
        isFromMe: true,
        threadOriginatorGuid: 'root-msg',
        threadOriginatorPart: '0:0:0',
      );

      for (final isRcs in [true, false]) {
        final chat = isRcs
            ? Chat(guid: 'RCS;-;+15550007777', chatIdentifier: '+15550007777')
            : Chat(guid: 'iMessage;-;+15550007777', chatIdentifier: '+15550007777');
        final svc = ensureMessagesSvc(chat.guid);
        svc.struct.addMessages([root, middle]);
        final controller = ConversationViewController(chat);
        controller.replyToMessage = MessageReplyContext(middle, 0);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChatStateScope(
                chatState: ChatsSvc.getOrCreateChatState(chat),
                child: ReplyHolder(controller: controller),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        if (isRcs) {
          expect(find.textContaining('Middle quoted reply'), findsOneWidget);
          expect(find.textContaining('Root original message'), findsNothing);
        } else {
          expect(find.textContaining('Root original message'), findsOneWidget);
          expect(find.textContaining('Middle quoted reply'), findsNothing);
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
    });

    testWidgets('ConversationTextField sends exact selected message GUID on RCS and root threadOriginatorGuid on iMessage',
        (tester) async {
      final middle = Message(
        guid: 'mid-guid-1',
        text: 'Intermediate message',
        isFromMe: false,
        threadOriginatorGuid: 'root-guid-1',
        threadOriginatorPart: '0:0:0',
      );

      for (final isRcs in [true, false]) {
        final chat = isRcs
            ? _TestChat(guid: 'RCS;-;+15550008888', chatIdentifier: '+15550008888')
            : _TestChat(guid: 'iMessage;-;+15550008888', chatIdentifier: '+15550008888');
        ensureMessagesSvc(chat.guid);
        final sent = <SendData>[];
        final controller = ConversationViewController(chat, tag_: chat.guid);
        Get.put<ConversationViewController>(controller, tag: chat.guid);
        controller.replyToMessage = MessageReplyContext(middle, 1);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light().copyWith(
              extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
            ),
            home: Scaffold(
              body: ChatStateScope(
                chatState: ChatsSvc.getOrCreateChatState(chat),
                child: Column(
                  children: [
                    const Spacer(),
                    ConversationTextField(
                      parentController: controller,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        controller.sendFunc = (data) async => sent.add(data);
        controller.textController.text = 'Follow-up reply';

        await tester.state<ConversationTextFieldState>(find.byType(ConversationTextField)).sendMessage();
        await tester.pump();

        expect(sent, hasLength(1));
        expect(sent.single.replyGuid, isRcs ? 'mid-guid-1' : 'root-guid-1');
        expect(sent.single.replyPart, isRcs ? 1 : 0);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
    });
  });
}
