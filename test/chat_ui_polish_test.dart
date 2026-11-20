import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_details/widgets/findmy_location_card.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_holder_reactions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/send_button.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_suffix.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/wrappers/tablet_mode_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _FakeSettingsService extends SettingsService {
  @override
  ServerDetails get serverDetails => const ServerDetails(
        macOSVersion: 14,
        macOSMinorVersion: 0,
        serverVersion: '1.9.0',
        serverVersionCode: 10900,
      );
}

class _FakeDesktopPrefs extends SharedPreferencesDesktopActions {
  _FakeDesktopPrefs(super.service);
  double? _ratio;

  @override
  double? getSplitRatio() => _ratio;

  @override
  Future<void> setSplitRatio(double ratio) async {
    _ratio = ratio;
  }
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

class _SpyConversationViewController extends ConversationViewController {
  _SpyConversationViewController(super.chat, {super.tag_});

  final List<bool> interactionCalls = [];

  @override
  void onUserChatInteraction({bool immediate = false}) {
    interactionCalls.add(immediate);
  }
}

class _TestFindMyController extends FindMyController {
  _TestFindMyController() : super(autoFetch: false);

  Chat? openedChat;

  @override
  void activatePage() {}

  @override
  Future<void> ensureFriendsLoaded({Duration maxAge = const Duration(minutes: 2)}) async {}

  @override
  Future<void> openForChat(BuildContext context, Chat chat) async {
    openedChat = chat;
  }
}

ThemeData _testTheme() => ThemeData(
      useMaterial3: true,
      extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
    );

void _registerBaseServices(_FakeSettingsService settingsService) {
  Get.testMode = true;
  if (GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.unregister<SettingsService>();
  }
  GetIt.I.registerSingleton<SettingsService>(settingsService);
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
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
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

void main() {
  late _FakeSettingsService settingsService;

  setUp(() {
    settingsService = _FakeSettingsService()..settings = Settings();
    settingsService.settings.skin.value = Skins.Material;
    settingsService.settings.privateSendTypingIndicators.value = false;
    _registerBaseServices(settingsService);
  });

  tearDown(() {
    if (Get.isRegistered<FindMyController>()) {
      Get.delete<FindMyController>(force: true);
    }
  });

  group('1. Interaction-gated read receipts', () {
    testWidgets('composer does not mark read on draft restore, triggers debounced on typing and immediate on send',
        (tester) async {
      final chat = Chat(guid: 'iMessage;-;+15550001111', chatIdentifier: '+15550001111', hasUnreadMessage: true)
        ..textFieldText = 'Saved draft'
        ..autoSendTypingIndicators = false;
      final controller = _SpyConversationViewController(chat, tag_: 'spy-composer')
        ..sendFunc = (_) async {};

      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: ChatStateScope(
              chatState: ChatState(chat),
              child: ConversationTextField(parentController: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      // Draft restore & initial mount must NEVER trigger read receipts.
      expect(controller.interactionCalls, isEmpty);

      // Typing into composer triggers debounced interaction (immediate: false).
      await tester.enterText(find.byType(TextField).last, 'Saved draft hello');
      await tester.pump();
      expect(controller.interactionCalls, contains(false));

      controller.interactionCalls.clear();
      final textFieldState = ConversationTextField.of(tester.element(find.byType(TextField).last))!;
      await textFieldState.sendMessage();
      await tester.pump();
      expect(controller.interactionCalls, contains(true));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      Get.delete<ConversationViewController>(tag: 'spy-composer', force: true);
    });
  });

  group('3. Bubble grouping, sculpted corners & tapback clearance', () {
    test('BubbleConnect connects within same-sender 3-min group and breaks on sender, time, or group events', () {
      final now = DateTime(2026, 11, 20, 12, 0);
      final m1 = Message(guid: 'm1', text: 'First', isFromMe: false, dateCreated: now);
      final m2 = Message(guid: 'm2', text: 'Second', isFromMe: false, dateCreated: now.add(const Duration(seconds: 30)));
      final m3GroupEvent = Message(
        guid: 'm3',
        isFromMe: false,
        itemType: 1,
        dateCreated: now.add(const Duration(seconds: 40)),
      );

      final p1 = MessagePart(part: 0, text: 'First');
      final p2 = MessagePart(part: 0, text: 'Second');
      final state1 = MessageState(m1)
        ..parts.add(p1)
        ..newMessage = m2;
      final state2 = MessageState(m2)
        ..parts.add(p2)
        ..oldMessage = m1
        ..newMessage = m3GroupEvent;

      expect(BubbleConnect.lower(state1, p1), isTrue);
      expect(BubbleConnect.upper(state2, p2), isTrue);
      expect(BubbleConnect.lower(state2, p2), isFalse);
    });

    testWidgets('ReactionSpacing uses 0 top overhang on Material (bottom-anchored via MaterialReactionBubble)',
        (tester) async {
      final msg = Message(guid: 'm1', text: 'Hello', isFromMe: true, dateCreated: DateTime.now());
      final reaction = Message(
        guid: 'r1',
        associatedMessageGuid: 'p:0/m1',
        associatedMessageType: 'love',
        isFromMe: false,
        dateCreated: DateTime.now(),
      );
      msg.associatedMessages.add(reaction);
      final part = MessagePart(part: 0, text: 'Hello');
      final msgState = MessageState(msg)..parts.add(part);

      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: MessageStateScope(
              messageState: msgState,
              child: ReactionSpacing(part: part),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(ReactionSpacing)).height, 0.0);
    });
  });

  group('4. Find My location card & privacy', () {
    testWidgets('FindMyLocationCard hides for groups and shows address/Live badge + opens Find My for 1:1',
        (tester) async {
      final fm = _TestFindMyController();
      Get.put<FindMyController>(fm);

      final groupChat = Chat(guid: 'iMessage;+;chat123', chatIdentifier: 'chat123');
      groupChat.handles.addAll([
        Handle(address: '+15551112222'),
        Handle(address: '+15553334444'),
      ]);

      final dmChat = Chat(guid: 'iMessage;-;+15551112222', chatIdentifier: '+15551112222');
      dmChat.handles.add(Handle(address: '+15551112222'));

      fm.friends.add(
        FindMyFriend(
          latitude: 37.4220,
          longitude: -122.0841,
          longAddress: '1600 Amphitheatre Pkwy, Mountain View, CA',
          shortAddress: 'Mountain View, CA',
          title: 'Alice',
          subtitle: 'Mountain View, CA',
          handle: Handle(address: '+15551112222'),
          handleAddress: '+15551112222',
          lastUpdated: DateTime.now(),
          status: null,
          isLive: true,
          locatingInProgress: false,
        ),
      );

      // Hidden for group chat.
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(body: FindMyLocationCard(chat: groupChat)),
        ),
      );
      expect(find.text('Mountain View, CA'), findsNothing);
      expect(find.text('1600 Amphitheatre Pkwy, Mountain View, CA'), findsNothing);

      // Shown for 1:1 chat with Live pill & tap -> openForChat.
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(body: FindMyLocationCard(chat: dmChat)),
        ),
      );
      await tester.pump();
      expect(find.textContaining('1600 Amphitheatre Pkwy'), findsOneWidget);
      expect(find.text('Live'), findsWidgets);

      await tester.tap(find.byType(FindMyLocationCard));
      expect(fm.openedChat?.guid, dmChat.guid);

      await tester.pumpWidget(const SizedBox.shrink());
      Get.delete<FindMyController>(force: true);
    });
  });

  group('5. Web Details panel default & fixed-width animation', () {
    testWidgets('TabletModeWrapper animates inspector cleanly with ClipRect and fixed 320px OverflowBox',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      expect(NavigationSvc.showInspectorDrawer.value, equals(!kIsWeb));
      NavigationSvc.showInspectorDrawer.value = false;

      final chat = Chat(guid: 'iMessage;-;+15551234567', chatIdentifier: '+15551234567');
      Get.put<FindMyController>(_TestFindMyController());
      GetIt.I<ChatsService>().activeChat = ChatState(chat);
      GetIt.I<ChatsService>().activeChatGuid.value = chat.guid;

      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: const Scaffold(
            body: TabletModeWrapper(
              initialRatio: 0.3,
              minRatio: 0.2,
              maxRatio: 0.45,
              left: SizedBox.expand(child: Text('Left')),
              right: SizedBox.expand(child: Text('Right')),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ClipRect), findsWidgets);

      NavigationSvc.showInspectorDrawer.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(OverflowBox), findsOneWidget);
      final overflow = tester.widget<OverflowBox>(find.byType(OverflowBox));
      expect(overflow.minWidth, 320);
      expect(overflow.maxWidth, 320);
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      Get.delete<FindMyController>(force: true);
      GetIt.I<ChatsService>().activeChat = null;
      GetIt.I<ChatsService>().activeChatGuid.value = null;
    });
  });

  group('6. Voice input button parity with Send button', () {
    testWidgets('Voice mic button matches SendButton exact circular size and zero padding on Material & iOS',
        (tester) async {
      for (final skin in [Skins.Material, Skins.iOS]) {
        settingsService.settings.skin.value = skin;
        final expectedSize = skin == Skins.iOS ? const Size(32, 32) : const Size(48, 48);
        final textController = TextEditingController();
        final subjectController = TextEditingController();
        final chat = Chat(guid: 'iMessage;-;+15559998888', chatIdentifier: '+15559998888');
        final controller = ConversationViewController(chat, tag_: 'suffix-${skin.name}');

        await tester.pumpWidget(
          MaterialApp(
            theme: _testTheme(),
            home: Scaffold(
              body: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFieldSuffix(
                    subjectTextController: subjectController,
                    textController: textController,
                    controller: controller,
                    recorderController: null,
                    sendMessage: ({String? effect}) async {},
                  ),
                  SendButton(
                    onLongPress: () {},
                    sendMessage: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        final buttons = tester.widgetList<TextButton>(find.byType(TextButton)).toList();
        expect(buttons.length, greaterThanOrEqualTo(2));
        for (final btn in buttons) {
          expect(btn.style?.padding?.resolve({}), EdgeInsets.zero);
        }

        final voiceRect = tester.getSize(find.byType(TextButton).first);
        final sendRect = tester.getSize(find.byType(TextButton).last);
        expect(voiceRect, expectedSize);
        expect(sendRect, expectedSize);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 4));
        Get.delete<ConversationViewController>(tag: 'suffix-${skin.name}', force: true);
        textController.dispose();
        subjectController.dispose();
      }
    });
  });
}
