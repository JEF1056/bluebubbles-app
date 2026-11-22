import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/composer_popover.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/messages_view_components.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_suffix.dart';
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
  bool floatingComposer = true,
  ValueNotifier<double>? bottomPaddingNotifier,
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
            floatingComposer: floatingComposer,
            onComposerHeightChanged: bottomPaddingNotifier == null
                ? null
                : (h) {
                    if ((h - bottomPaddingNotifier.value).abs() <= 0.5) return;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      ConversationView.applyComposerBottomPadding(
                        bottomPadding: bottomPaddingNotifier,
                        targetHeight: h,
                        scrollController: controller.scrollController,
                      );
                    });
                  },
            messagesArea: CustomScrollView(
              key: listKey,
              reverse: true,
              controller: controller.scrollController,
              slivers: [
                if (bottomPaddingNotifier != null)
                  SliverToBoxAdapter(
                    child: ValueListenableBuilder<double>(
                      valueListenable: bottomPaddingNotifier,
                      builder: (_, height, _) => SizedBox(height: height),
                    ),
                  ),
                SliverList.builder(
                  itemCount: 25,
                  itemBuilder: (context, index) => ListTile(
                    key: ValueKey('msg-$index'),
                    title: Text('Message $index'),
                  ),
                ),
              ],
            ),
            scrollDownButton: ScrollDownButton(controller: controller),
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
      'Material Android floating composer (keyboard open): messages extend under bar while ScrollDownButton, resting messages, and inline icons adapt to multiline expansion',
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
    final bottomPaddingNotifier = ValueNotifier<double>(68.0);
    addTearDown(bottomPaddingNotifier.dispose);
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
      floatingComposer: true,
      bottomPaddingNotifier: bottomPaddingNotifier,
    ));
    await tester.pumpAndSettle();

    final initialComposerRect = tester.getRect(find.byKey(composerKey));
    final initialListRect = tester.getRect(find.byKey(listKey));
    final initialScrollDownRect = tester.getRect(find.descendant(
      of: find.byType(ScrollDownButton),
      matching: find.byIcon(Icons.arrow_downward_rounded),
    ));
    // Messages list extends underneath the floating composer down to the keyboard inset.
    expect(initialListRect.bottom, closeTo(viewport.height - viewInsets.bottom, 0.5));
    expect(initialListRect.bottom, greaterThan(initialComposerRect.top));
    expect(initialScrollDownRect.bottom, lessThanOrEqualTo(initialComposerRect.top + 0.01));

    // Expand with 6-line body first and check inline pill icons stay bottom-aligned with Send.
    controller.textController.text = List.generate(6, (i) => 'Multiline message line $i').join('\n');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final multilineComposerRect = tester.getRect(find.byKey(composerKey));
    final multilineScrollDownRect = tester.getRect(find.descendant(
      of: find.byType(ScrollDownButton),
      matching: find.byIcon(Icons.arrow_downward_rounded),
    ));
    final addIconRect = tester.getRect(find.byIcon(Icons.add_circle_outline));
    final galleryIconRect = tester.getRect(find.byIcon(Icons.image_outlined));
    final sendSuffixRect = tester.getRect(find.byType(TextFieldSuffix));
    final msg0AtRestRect = tester.getRect(find.byKey(const ValueKey('msg-0')));

    expect(multilineComposerRect.height, greaterThan(initialComposerRect.height + 40.0));
    // ScrollDownButton shifts upward synchronously above the expanded composer.
    expect(multilineScrollDownRect.bottom, lessThanOrEqualTo(multilineComposerRect.top + 0.01));
    expect(multilineScrollDownRect.bottom, lessThan(initialScrollDownRect.bottom - 40.0));
    // Inline + and gallery icons remain bottom-aligned on the same baseline as the Send button.
    expect((addIconRect.center.dy - sendSuffixRect.center.dy).abs(), lessThanOrEqualTo(4.0));
    expect((galleryIconRect.center.dy - sendSuffixRect.center.dy).abs(), lessThanOrEqualTo(4.0));
    // Resting latest message sits cleanly above the expanded composer.
    expect(msg0AtRestRect.bottom, lessThanOrEqualTo(multilineComposerRect.top + 1.0));

    // Scrolling up lets messages pass underneath the floating composer.
    controller.scrollController.jumpTo(120);
    await tester.pump();
    final msg0ScrolledRect = tester.getRect(find.byKey(const ValueKey('msg-0')));
    expect(msg0ScrolledRect.bottom, greaterThan(multilineComposerRect.top + 40.0));

    // Further expand with reply banner, attachment strip, multiline subject, and 20-line body.
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
    final scrollDownButtonRect = tester.getRect(find.descendant(
      of: find.byType(ScrollDownButton),
      matching: find.byIcon(Icons.arrow_downward_rounded),
    ));

    expect(composerRect.height, greaterThan(initialComposerRect.height));
    expect(composerRect.top, greaterThanOrEqualTo(headerRect.bottom - 0.01));
    expect(listRect.bottom, closeTo(viewport.height - viewInsets.bottom, 0.5));
    expect(scrollDownButtonRect.bottom, lessThanOrEqualTo(composerRect.top + 0.01));
    expect(composerRect.bottom, lessThanOrEqualTo(viewport.height - viewInsets.bottom + 0.01));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
      'Material Android edge-to-edge (keyboard closed): messages extend behind floating bar and gesture inset while composer stays above gesture bar',
      (tester) async {
    const viewport = Size(390, 844);
    const viewPadding = EdgeInsets.only(top: 24, bottom: 24);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final chat = Chat(guid: 'iMessage;-;+15550004321', chatIdentifier: '+15550004321')
      ..autoSendTypingIndicators = false;
    final controller = ConversationViewController(chat, tag_: 'edge-to-edge');
    controller.showScrollDown.value = true;
    final bottomPaddingNotifier = ValueNotifier<double>(68.0);
    addTearDown(bottomPaddingNotifier.dispose);
    addTearDown(() => Get.delete<ConversationViewController>(tag: 'edge-to-edge', force: true));

    const headerKey = Key('edge-header');
    const listKey = Key('edge-list');
    const composerKey = Key('edge-composer');

    await tester.pumpWidget(_buildConversationHarness(
      viewportSize: viewport,
      viewInsets: EdgeInsets.zero,
      viewPadding: viewPadding,
      chat: chat,
      controller: controller,
      headerKey: headerKey,
      listKey: listKey,
      composerKey: composerKey,
      floatingComposer: true,
      bottomPaddingNotifier: bottomPaddingNotifier,
    ));
    await tester.pumpAndSettle();

    final listRect = tester.getRect(find.byKey(listKey));
    final composerRect = tester.getRect(find.byKey(composerKey));
    final scrollDownRect = tester.getRect(find.descendant(
      of: find.byType(ScrollDownButton),
      matching: find.byIcon(Icons.arrow_downward_rounded),
    ));

    // Messages reach the physical bottom edge behind both the floating bar and gesture inset.
    expect(listRect.bottom, closeTo(viewport.height, 0.5));
    // Composer clears the 24px gesture bar; ScrollDownButton clears the composer.
    expect(composerRect.bottom, closeTo(viewport.height - viewPadding.bottom, 0.5));
    expect(scrollDownRect.bottom, lessThanOrEqualTo(composerRect.top + 0.01));
    expect(bottomPaddingNotifier.value, closeTo(composerRect.height + viewPadding.bottom, 1.0));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
      'Web short viewport floating composer: expanding composer + popover stay above multiline bar without covering header or ScrollDownButton',
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
    final bottomPaddingNotifier = ValueNotifier<double>(68.0);
    addTearDown(bottomPaddingNotifier.dispose);
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
      floatingComposer: true,
      bottomPaddingNotifier: bottomPaddingNotifier,
    ));
    await tester.pumpAndSettle();

    // Open a composer popover anchored to the bottom-aligned Gallery button at 2 lines,
    // then expand to multiline and verify the popover rises above the growing pill.
    controller.textController.text = 'Web line 1\nWeb line 2';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    const popoverKey = Key('test-popover-card');
    final anchorContext = tester.element(find.byIcon(Icons.image_outlined));
    final popoverFuture = showComposerPopover(
      anchorContext,
      controller,
      height: 300,
      builder: (_) => const SizedBox(key: popoverKey, child: Text('Emoji Picker')),
    );
    await tester.pumpAndSettle();

    final pillRect2Lines = tester.getRect(find.byKey(controller.textFieldKey));
    final popoverRect2Lines = tester.getRect(find.byKey(popoverKey));
    expect(popoverRect2Lines.bottom, lessThanOrEqualTo(pillRect2Lines.top + 0.01));

    // Grow the composer while the popover is open and verify it rises to stay clear.
    controller.textController.text = List.generate(6, (i) => 'Web multiline line $i').join('\n');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final pillRect6Lines = tester.getRect(find.byKey(controller.textFieldKey));
    final popoverRect6Lines = tester.getRect(find.byKey(popoverKey));
    expect(pillRect6Lines.top, lessThan(pillRect2Lines.top - 20.0));
    expect(popoverRect6Lines.bottom, lessThanOrEqualTo(pillRect6Lines.top + 0.01));
    expect(popoverRect6Lines.bottom, lessThan(popoverRect2Lines.bottom - 20.0));

    // Dismiss popover and stress-test extreme expansion + formatting panel.
    Navigator.of(anchorContext, rootNavigator: true).pop();
    await tester.pumpAndSettle();
    await popoverFuture;

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
    expect(listRect.bottom, closeTo(shortWebViewport.height, 0.5));
    expect(scrollDownButtonRect.bottom, lessThanOrEqualTo(composerRect.top + 0.01));
    expect(composerRect.bottom, lessThanOrEqualTo(shortWebViewport.height + 0.01));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Docked layout (iOS/Samsung) keeps messages non-overlapping above composer', (tester) async {
    const viewport = Size(390, 844);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final chat = Chat(guid: 'iMessage;-;+15550007777', chatIdentifier: '+15550007777')
      ..autoSendTypingIndicators = false;
    final controller = ConversationViewController(chat, tag_: 'docked-ios');
    controller.showScrollDown.value = true;
    addTearDown(() => Get.delete<ConversationViewController>(tag: 'docked-ios', force: true));

    const headerKey = Key('docked-header');
    const listKey = Key('docked-list');
    const composerKey = Key('docked-composer');

    await tester.pumpWidget(_buildConversationHarness(
      viewportSize: viewport,
      viewInsets: EdgeInsets.zero,
      viewPadding: const EdgeInsets.only(top: 24),
      chat: chat,
      controller: controller,
      headerKey: headerKey,
      listKey: listKey,
      composerKey: composerKey,
      floatingComposer: false,
    ));
    await tester.pumpAndSettle();

    final listRect = tester.getRect(find.byKey(listKey));
    final composerRect = tester.getRect(find.byKey(composerKey));
    expect(composerRect.top, greaterThanOrEqualTo(listRect.bottom - 0.01));

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

  testWidgets(
      'Scroll compensation: near-bottom keeps latest message visible at offset 0.0 while scrolled-up preserves history position across expand/shrink',
      (tester) async {
    const viewport = Size(390, 844);
    const viewInsets = EdgeInsets.only(bottom: 330);
    const viewPadding = EdgeInsets.only(top: 24);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    settingsService.settings.privateSubjectLine.value = false;
    final chat = Chat(guid: 'iMessage;-;+15550008888', chatIdentifier: '+15550008888')
      ..autoSendTypingIndicators = false;
    final controller = ConversationViewController(chat, tag_: 'scroll-comp');
    final bottomPaddingNotifier = ValueNotifier<double>(68.0);
    addTearDown(bottomPaddingNotifier.dispose);
    addTearDown(() => Get.delete<ConversationViewController>(tag: 'scroll-comp', force: true));

    const headerKey = Key('comp-header');
    const listKey = Key('comp-list');
    const composerKey = Key('comp-composer');

    await tester.pumpWidget(_buildConversationHarness(
      viewportSize: viewport,
      viewInsets: viewInsets,
      viewPadding: viewPadding,
      chat: chat,
      controller: controller,
      headerKey: headerKey,
      listKey: listKey,
      composerKey: composerKey,
      floatingComposer: true,
      bottomPaddingNotifier: bottomPaddingNotifier,
    ));
    await tester.pumpAndSettle();

    // Case 1: Near bottom (offset <= 24.0) snaps to 0.0 and keeps msg-0 above expanding pill.
    controller.scrollController.jumpTo(20.0);
    await tester.pump();
    controller.textController.text = List.generate(6, (i) => 'Near bottom line $i').join('\n');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final expandedComposerRect = tester.getRect(find.byKey(composerKey));
    final msg0NearBottomRect = tester.getRect(find.byKey(const ValueKey('msg-0')));
    expect(controller.scrollController.offset, 0.0);
    expect(msg0NearBottomRect.bottom, lessThanOrEqualTo(expandedComposerRect.top + 1.0));

    // Reset to single line and scroll up into history (offset > 24.0).
    controller.textController.clear();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    controller.scrollController.jumpTo(120.0);
    await tester.pump();
    final paddingBeforeExpand = bottomPaddingNotifier.value;
    final offsetBeforeExpand = controller.scrollController.offset;
    final msg4BeforeExpand = tester.getRect(find.byKey(const ValueKey('msg-4')));

    controller.textController.text = List.generate(6, (i) => 'Scrolled up line $i').join('\n');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final expandDelta = bottomPaddingNotifier.value - paddingBeforeExpand;
    final msg4AfterExpand = tester.getRect(find.byKey(const ValueKey('msg-4')));
    expect(expandDelta, greaterThan(40.0));
    expect(controller.scrollController.offset, closeTo(offsetBeforeExpand + expandDelta, 1.0));
    expect(msg4AfterExpand.top, closeTo(msg4BeforeExpand.top, 1.0));

    // Shrink back while still scrolled up: history stays stationary again.
    controller.textController.clear();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final msg4AfterShrink = tester.getRect(find.byKey(const ValueKey('msg-4')));
    expect(controller.scrollController.offset, closeTo(offsetBeforeExpand, 1.0));
    expect(msg4AfterShrink.top, closeTo(msg4BeforeExpand.top, 1.0));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Initial floating composer bottom padding accounts for edge-to-edge viewPadding.bottom',
      (tester) async {
    late double closedPadding;
    late double openPadding;

    await tester.pumpWidget(
      Column(
        children: [
          MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              viewPadding: EdgeInsets.only(top: 24, bottom: 24),
              viewInsets: EdgeInsets.zero,
            ),
            child: Builder(
              builder: (context) {
                closedPadding = ConversationView.initialComposerBottomPadding(context);
                return const SizedBox.shrink();
              },
            ),
          ),
          MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              viewPadding: EdgeInsets.only(top: 24, bottom: 24),
              viewInsets: EdgeInsets.only(bottom: 330),
            ),
            child: Builder(
              builder: (context) {
                openPadding = ConversationView.initialComposerBottomPadding(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      ),
    );

    expect(closedPadding, 92.0);
    expect(openPadding, 68.0);
  });
}
