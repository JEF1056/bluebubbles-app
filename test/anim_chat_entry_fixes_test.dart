import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_details/conversation_details.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/attachments_loader.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/links/links_section.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
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

class _MutableThemePrefs extends SharedPreferencesThemeActions {
  _MutableThemePrefs(super.service);
  String? lightTheme;
  String? darkTheme;

  @override
  String? getSelectedLightTheme() => lightTheme;

  @override
  String? getSelectedDarkTheme() => darkTheme;
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    theme = _MutableThemePrefs(this);
  }
}

class _FakeSettingsService extends SettingsService {
  _FakeSettingsService() {
    settings = Settings();
  }

  @override
  ServerDetails get serverDetails => const ServerDetails(
        macOSVersion: 14,
        macOSMinorVersion: 0,
        serverVersion: '2.0.0',
        serverVersionCode: 20000,
        apiVersions: [1, 2],
      );
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

class _FakeAttachmentChat extends Chat {
  _FakeAttachmentChat({required super.guid, required this.attachmentsFuture}) : super(chatIdentifier: guid);

  final Future<List<Attachment>> attachmentsFuture;

  @override
  Future<List<Attachment>> getAttachmentsAsync({bool fetchDeleted = false, int? limit}) => attachmentsFuture;
}

ThemeData _testTheme() => ThemeData(
      useMaterial3: true,
      extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
    );

void _registerCoreServices({_FakePrefsService? prefs}) {
  Get.testMode = true;
  GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  GetIt.I.registerSingleton<SettingsService>(_FakeSettingsService());
  GetIt.I.registerSingleton<SharedPreferencesService>(prefs ?? _FakePrefsService());
  GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  GetIt.I.registerSingleton<ChatsService>(_FakeChatsService());
  GetIt.I.registerSingleton<HandleService>(HandleService());
  GetIt.I.registerSingleton<ThemesService>(ThemesService());
  GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
  GetIt.I.registerSingleton<SyncService>(SyncService());
  GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  GetIt.I.registerSingleton<SocketService>(SocketService());
  GetIt.I.registerSingleton<NameAndPhotoSharingService>(NameAndPhotoSharingService());
  GetIt.I.registerSingleton<OutgoingMessageHandler>(OutgoingMessageHandler());
}

void main() {
  setUp(() {
    ThemesService.invalidateResolvedThemeCache();
  });

  tearDown(() async {
    ThemesService.invalidateResolvedThemeCache();
    Get.reset();
    await GetIt.I.reset();
  });

  group('P0-4: ThemesService resolved theme cache', () {
    test('caches resolved themes and invalidates on selection change or explicit invalidation', () {
      final prefs = _FakePrefsService();
      final themePrefs = prefs.theme as _MutableThemePrefs;
      themePrefs.lightTheme = 'Bright White';
      _registerCoreServices(prefs: prefs);

      int loadCount = 0;
      ThemeStruct load(String name) {
        loadCount++;
        return ThemeStruct(name: name, themeData: _testTheme());
      }

      final first = ThemesService.resolveThemeByName(null, Brightness.light, () => load(themePrefs.lightTheme!));
      final second = ThemesService.resolveThemeByName(null, Brightness.light, () => load(themePrefs.lightTheme!));
      expect(identical(first, second), isTrue);
      expect(loadCount, 1);

      // Selection changes via PrefsSvc.theme (even outside ThemesService) immediately miss stale cache.
      themePrefs.lightTheme = 'Material You (Light)';
      final afterSelectionChange =
          ThemesService.resolveThemeByName(null, Brightness.light, () => load(themePrefs.lightTheme!));
      expect(afterSelectionChange.name, 'Material You (Light)');
      expect(loadCount, 2);

      // Named theme cache hit & targeted invalidation.
      final custom1 = ThemesService.resolveThemeByName('CustomA', Brightness.dark, () => load('CustomA'));
      final custom2 = ThemesService.resolveThemeByName('CustomA', Brightness.dark, () => load('CustomA'));
      expect(identical(custom1, custom2), isTrue);
      expect(loadCount, 3);

      ThemesService.invalidateResolvedThemeCache('CustomA');
      ThemesService.resolveThemeByName('CustomA', Brightness.dark, () => load('CustomA'));
      expect(loadCount, 4);

      ThemesService.invalidateResolvedThemeCache();
      expect(ThemesService.resolvedThemeCacheSize, 0);
    });
  });

  group('P1-3: ConversationDetails route transition deferral & focus guard', () {
    testWidgets('AttachmentsLoader defers callback commit until route transition completes', (tester) async {
      _registerCoreServices();
      final completer = Completer<List<Attachment>>();
      final chat = _FakeAttachmentChat(guid: 'chat-att-1', attachmentsFuture: completer.future);

      int callbackCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      transitionDuration: const Duration(milliseconds: 300),
                      pageBuilder: (_, _, _) => AttachmentsLoader(
                        chat: chat,
                        onAttachmentsLoaded: (_, _, _) => callbackCalls++,
                      ),
                    ),
                  );
                },
                child: const Text('Push'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Async load finishes mid-transition, but commit must wait until transition settles.
      completer.complete(const []);
      await tester.pump();
      expect(callbackCalls, 0);

      // Advance past 300ms route transition.
      await tester.pumpAndSettle();
      expect(callbackCalls, 1);
    });

    testWidgets('AttachmentsLoader cancels deferred commit when popped mid-transition', (tester) async {
      _registerCoreServices();
      final completer = Completer<List<Attachment>>();
      final chat = _FakeAttachmentChat(guid: 'chat-att-2', attachmentsFuture: completer.future);

      int callbackCalls = 0;
      late NavigatorState nav;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                nav = Navigator.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      nav.push(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, _, _) => AttachmentsLoader(
            chat: chat,
            onAttachmentsLoaded: (_, _, _) => callbackCalls++,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      completer.complete(const []);
      await tester.pump();
      expect(callbackCalls, 0);

      // Pop before transition finishes.
      nav.pop();
      await tester.pumpAndSettle();
      expect(callbackCalls, 0);
    });

    testWidgets('LinksSection defers committing state until route transition completes', (tester) async {
      _registerCoreServices();
      final chat = Chat(guid: 'chat-links-1', chatIdentifier: 'chat-links-1');

      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      transitionDuration: const Duration(milliseconds: 300),
                      pageBuilder: (_, _, _) => Scaffold(
                        body: CustomScrollView(
                          slivers: [LinksSection(chat: chat, fullPage: true)],
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('Push'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Still mid-transition: LinksSection should still be in loading state.
      expect(find.text('No links'), findsNothing);

      await tester.pumpAndSettle();
      expect(find.text('No links'), findsOneWidget);
    });

    testWidgets('ConversationDetails.dispose only restores focus if active before push', (tester) async {
      _registerCoreServices();
      ThemesService.resolveThemeByName(
        null,
        Brightness.light,
        () => ThemeStruct(name: 'Bright White', themeData: _testTheme()),
      );
      ThemesService.resolveThemeByName(
        null,
        Brightness.dark,
        () => ThemeStruct(name: 'OLED Dark', themeData: _testTheme()),
      );
      final chat = _FakeAttachmentChat(guid: 'chat-details-focus', attachmentsFuture: Future.value(const []));
      final controller = cvc(chat);
      ChatsSvc.activeChat = ChatsSvc.getOrCreateChatState(chat)..controller = controller;

      late NavigatorState nav;
      await tester.pumpWidget(
        GetMaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                nav = Navigator.of(context);
                return TextField(focusNode: controller.focusNode);
              },
            ),
          ),
        ),
      );

      // Case 1: focus NOT active and keyboardOpen == false before pushing Details.
      expect(controller.lastFocusedNode.hasFocus, isFalse);
      controller.keyboardOpen = false;
      nav.push(MaterialPageRoute<void>(builder: (_) => ConversationDetails(chat: chat)));
      await tester.pumpAndSettle();
      nav.pop();
      await tester.pumpAndSettle();
      expect(controller.lastFocusedNode.hasFocus, isFalse);

      // Case 2: keyboard/focus WAS active before pushing Details.
      controller.keyboardOpen = true;
      nav.push(MaterialPageRoute<void>(builder: (_) => ConversationDetails(chat: chat)));
      await tester.pumpAndSettle();
      nav.pop();
      await tester.pumpAndSettle();
      expect(controller.lastFocusedNode.hasFocus, isTrue);

      controller.dispose();
      Get.delete<FindMyController>(force: true);
    });
  });

  group('P0-4: ConversationTextField autoOpenKeyboard deferral', () {
    testWidgets('defers autoOpenKeyboard focus until route transition completes', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      _registerCoreServices();
      SettingsSvc.settings.autoOpenKeyboard.value = true;
      SettingsSvc.settings.skin.value = Skins.Material;

      final chat = Chat(guid: 'chat-tf-1', chatIdentifier: 'chat-tf-1');
      final controller = cvc(chat);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      transitionDuration: const Duration(milliseconds: 300),
                      pageBuilder: (_, _, _) => Scaffold(
                        body: ConversationTextField(parentController: controller),
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Mid-transition: focus must NOT have been requested yet.
      expect(controller.focusNode.hasFocus, isFalse);

      await tester.pumpAndSettle();
      expect(controller.focusNode.hasFocus, isTrue);

      controller.dispose();
      Get.delete<FindMyController>(force: true);
    });
  });
}
