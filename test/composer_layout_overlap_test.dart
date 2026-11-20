import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/messages_view_components.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

void _registerServices(_FakeSettingsService settingsService) {
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

ThemeData _testTheme() => ThemeData(
      useMaterial3: true,
      extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
    );

Widget _buildConversationHarness({
  required Size viewportSize,
  required EdgeInsets viewInsets,
  required EdgeInsets viewPadding,
  required Chat chat,
  required ConversationViewController controller,
  required Key headerKey,
  required Key listKey,
  required Key composerKey,
}) {
  return MediaQuery(
    data: MediaQueryData(
      size: viewportSize,
      viewInsets: viewInsets,
      padding: viewPadding,
      viewPadding: viewPadding,
    ),
    child: MaterialApp(
      theme: _testTheme(),
      home: ChatStateScope(
        chatState: ChatState(chat),
        child: BBScaffold(
          extendBodyBehindAppBar: true,
          resizeToAvoidBottomInset: false,
          appBar: PreferredSize(
            preferredSize: const Size(double.infinity, kToolbarHeight),
            child: Container(
              key: headerKey,
              height: kToolbarHeight + viewPadding.top,
              alignment: Alignment.bottomLeft,
              child: const Text('Chat Header'),
            ),
          ),
          body: ConversationView.buildBodyLayout(
            messagesArea: Stack(
              children: [
                CustomScrollView(
                  key: listKey,
                  reverse: true,
                  controller: controller.scrollController,
                  slivers: [
                    SliverList.builder(
                      itemCount: 15,
                      itemBuilder: (context, index) => ListTile(
                        title: Text('Message $index'),
                      ),
                    ),
                  ],
                ),
                ScrollDownButton(controller: controller),
              ],
            ),
            composer: KeyedSubtree(
              key: composerKey,
              child: ConversationTextField(parentController: controller),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late _FakeSettingsService settingsService;

  setUp(() {
    settingsService = _FakeSettingsService()..settings = Settings();
    settingsService.settings.skin.value = Skins.Material;
    settingsService.settings.enablePrivateAPI.value = true;
    settingsService.settings.privateSubjectLine.value = true;
    settingsService.settings.privateSendTypingIndicators.value = false;
    _registerServices(settingsService);
  });

  testWidgets(
      'Mobile with keyboard open: multiline composer + reply + subject + attachment never overlaps header, messages, or ScrollDownButton',
      (tester) async {
    const viewport = Size(390, 844);
    const viewInsets = EdgeInsets.only(bottom: 330);
    const viewPadding = EdgeInsets.only(top: 24);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final chat = Chat(guid: 'iMessage;-;+15550001234', chatIdentifier: '+15550001234')
      ..autoSendTypingIndicators = false;
    final controller = ConversationViewController(chat, tag_: 'overlap-mobile');
    controller.showScrollDown.value = true;
    addTearDown(() => Get.delete<ConversationViewController>(tag: 'overlap-mobile', force: true));

    const headerKey = Key('test-header');
    const listKey = Key('test-list');
    const composerKey = Key('test-composer');

    await tester.pumpWidget(_buildConversationHarness(
      viewportSize: viewport,
      viewInsets: viewInsets,
      viewPadding: viewPadding,
      chat: chat,
      controller: controller,
      headerKey: headerKey,
      listKey: listKey,
      composerKey: composerKey,
    ));
    await tester.pumpAndSettle();

    final initialComposerRect = tester.getRect(find.byKey(composerKey));
    final initialListRect = tester.getRect(find.byKey(listKey));
    expect(initialComposerRect.top, greaterThanOrEqualTo(initialListRect.bottom - 0.01));

    // Expand with reply banner, attachment strip, multiline subject, and 20-line body.
    controller.replyToMessage = MessageReplyContext(
      Message(guid: 'reply-1', text: 'Replying to a previous message that wraps cleanly', isFromMe: false),
      0,
    );
    controller.pickedAttachments.add(
      PlatformFile(name: 'proposal.pdf', size: 128, bytes: Uint8List.fromList([1, 2, 3, 4])),
    );
    controller.subjectTextController.text = List.generate(8, (i) => 'Subject line $i').join('\n');
    controller.textController.text = List.generate(20, (i) => 'Body message line $i').join('\n');

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);

    final headerRect = tester.getRect(find.byKey(headerKey));
    final listRect = tester.getRect(find.byKey(listKey));
    final composerRect = tester.getRect(find.byKey(composerKey));
    final scrollDownFinder = find.byType(ScrollDownButton);
    final scrollDownButtonRect = tester.getRect(find.descendant(
      of: scrollDownFinder,
      matching: find.byIcon(Icons.arrow_downward_rounded),
    ));

    expect(composerRect.height, greaterThan(initialComposerRect.height));
    expect(composerRect.top, greaterThanOrEqualTo(headerRect.bottom - 0.01));
    expect(composerRect.top, greaterThanOrEqualTo(listRect.bottom - 0.01));
    expect(scrollDownButtonRect.bottom, lessThanOrEqualTo(composerRect.top + 0.01));
    expect(composerRect.bottom, lessThanOrEqualTo(viewport.height - viewInsets.bottom + 0.01));
    expect(listRect.height, greaterThanOrEqualTo(79.0));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
      'Web desktop & short viewport: expanding composer + pickers never overlaps header, messages, or ScrollDownButton',
      (tester) async {
    const shortWebViewport = Size(1024, 460);
    tester.view.physicalSize = shortWebViewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final chat = Chat(guid: 'iMessage;-;+15550005678', chatIdentifier: '+15550005678')
      ..autoSendTypingIndicators = false;
    final controller = ConversationViewController(chat, tag_: 'overlap-web');
    controller.showScrollDown.value = true;
    addTearDown(() => Get.delete<ConversationViewController>(tag: 'overlap-web', force: true));

    const headerKey = Key('web-header');
    const listKey = Key('web-list');
    const composerKey = Key('web-composer');

    await tester.pumpWidget(_buildConversationHarness(
      viewportSize: shortWebViewport,
      viewInsets: EdgeInsets.zero,
      viewPadding: EdgeInsets.zero,
      chat: chat,
      controller: controller,
      headerKey: headerKey,
      listKey: listKey,
      composerKey: composerKey,
    ));
    await tester.pumpAndSettle();

    controller.replyToMessage = MessageReplyContext(
      Message(guid: 'reply-web', text: 'Web reply banner text', isFromMe: false),
      0,
    );
    controller.pickedAttachments.add(
      PlatformFile(name: 'notes.txt', size: 64, bytes: Uint8List.fromList([5, 6, 7])),
    );
    controller.subjectTextController.text = List.generate(6, (i) => 'Web subject $i').join('\n');
    controller.textController.text = List.generate(20, (i) => 'Web multiline line $i').join('\n');
    controller.showTextFormattingPanel.value = true;

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);

    final headerRect = tester.getRect(find.byKey(headerKey));
    final listRect = tester.getRect(find.byKey(listKey));
    final composerRect = tester.getRect(find.byKey(composerKey));
    final scrollDownButtonRect = tester.getRect(find.descendant(
      of: find.byType(ScrollDownButton),
      matching: find.byIcon(Icons.arrow_downward_rounded),
    ));

    expect(composerRect.top, greaterThanOrEqualTo(headerRect.bottom - 0.01));
    expect(composerRect.top, greaterThanOrEqualTo(listRect.bottom - 0.01));
    expect(scrollDownButtonRect.bottom, lessThanOrEqualTo(composerRect.top + 0.01));
    expect(composerRect.bottom, lessThanOrEqualTo(shortWebViewport.height + 0.01));
    expect(listRect.height, greaterThanOrEqualTo(79.0));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Tightly bounded TextFieldComponent scrolls internally without overflow', (tester) async {
    final chat = Chat(guid: 'iMessage;-;+15550009999', chatIdentifier: '+15550009999')
      ..autoSendTypingIndicators = false;
    final controller = ConversationViewController(chat, tag_: 'tight-pill');
    controller.replyToMessage = MessageReplyContext(
      Message(guid: 'reply-tight', text: 'Tight reply preview', isFromMe: false),
      0,
    );
    controller.pickedAttachments.add(
      PlatformFile(name: 'tight.txt', size: 32, bytes: Uint8List.fromList([9, 8])),
    );
    controller.subjectTextController.text = List.generate(6, (i) => 'Subject $i').join('\n');
    controller.textController.text = List.generate(20, (i) => 'Line $i').join('\n');
    addTearDown(() => Get.delete<ConversationViewController>(tag: 'tight-pill', force: true));

    const pillKey = Key('tight-pill-box');
    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme(),
        home: Scaffold(
          body: ChatStateScope(
            chatState: ChatState(chat),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                key: pillKey,
                constraints: const BoxConstraints(maxHeight: 220),
                child: ConversationTextField(parentController: controller),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);
    final pillRect = tester.getRect(find.byKey(pillKey));
    expect(pillRect.height, lessThanOrEqualTo(220.0));
    expect(
      find.descendant(of: find.byKey(pillKey), matching: find.byType(SingleChildScrollView)),
      findsWidgets,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });
}
