import 'dart:io';

import 'package:bluebubbles/app/components/animated_dropdown_menu.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_image.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/ui/system_ui_overlay_style_helpers.dart';
import 'package:bluebubbles/main.dart' show AppShellFrame;
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_server_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
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

class _TestSettingsService extends SettingsService {
  @override
  ServerDetails get serverDetails => const ServerDetails(
        macOSVersion: 14,
        macOSMinorVersion: 0,
        serverVersion: '1.9.0',
        serverVersionCode: 10900,
      );
}

class _TestSyncService extends SyncService {}

void main() {
  late _TestSettingsService settings;

  setUp(() {
    Get.testMode = true;
    settings = _TestSettingsService()..settings = _TestSettings();
    settings.settings.finishedSetup.value = true;
    settings.settings.skin.value = Skins.Material;

    if (!GetIt.I.isRegistered<BaseLogger>()) {
      GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
    }
    if (GetIt.I.isRegistered<SettingsService>()) {
      GetIt.I.unregister<SettingsService>();
    }
    GetIt.I.registerSingleton<SettingsService>(settings);

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
    if (!GetIt.I.isRegistered<LifecycleService>()) {
      GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
    }

    if (GetIt.I.isRegistered<SyncService>()) {
      GetIt.I.unregister<SyncService>();
    }
    GetIt.I.registerSingleton<SyncService>(_TestSyncService());

    if (GetIt.I.isRegistered<SocketService>()) {
      GetIt.I.unregister<SocketService>();
    }
    GetIt.I.registerSingleton<SocketService>(SocketService());
  });

  group('buildSystemUiOverlayStyle', () {
    test('always enforces transparent edge-to-edge bars and disabled contrast scrims', () {
      for (final immersive in [false, true]) {
        final lightStyle = buildSystemUiOverlayStyle(
          surfaceColor: Colors.white,
          immersiveMode: immersive,
          systemNavigationBarColor: Colors.black,
          statusBarColor: Colors.red,
        );
        expect(lightStyle.statusBarColor, Colors.transparent);
        expect(lightStyle.systemNavigationBarColor, Colors.transparent);
        expect(lightStyle.systemNavigationBarDividerColor, Colors.transparent);
        expect(lightStyle.systemNavigationBarContrastEnforced, isFalse);
        expect(lightStyle.systemStatusBarContrastEnforced, isFalse);
        expect(lightStyle.statusBarIconBrightness, Brightness.dark);
        expect(lightStyle.systemNavigationBarIconBrightness, Brightness.dark);

        final darkStyle = buildSystemUiOverlayStyle(
          surfaceColor: Colors.black,
          immersiveMode: immersive,
        );
        expect(darkStyle.statusBarColor, Colors.transparent);
        expect(darkStyle.systemNavigationBarColor, Colors.transparent);
        expect(darkStyle.systemNavigationBarDividerColor, Colors.transparent);
        expect(darkStyle.systemNavigationBarContrastEnforced, isFalse);
        expect(darkStyle.systemStatusBarContrastEnforced, isFalse);
        expect(darkStyle.statusBarIconBrightness, Brightness.light);
        expect(darkStyle.systemNavigationBarIconBrightness, Brightness.light);
      }
    });
  });

  group('BBScaffold edge-to-edge', () {
    testWidgets('preserves bottom padding when extendBodyBehindBottomPill is true', (tester) async {
      EdgeInsets? innerPadding;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: 24, bottom: 32)),
          child: MaterialApp(
            home: BBScaffold(
              body: Builder(
                builder: (context) {
                  innerPadding = MediaQuery.paddingOf(context);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      expect(innerPadding?.bottom, 32);
    });

    testWidgets('consumes bottom padding when safeAreaBottom is explicitly true', (tester) async {
      EdgeInsets? innerPadding;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: 24, bottom: 32)),
          child: MaterialApp(
            home: BBScaffold(
              safeAreaBottom: true,
              body: Builder(
                builder: (context) {
                  innerPadding = MediaQuery.paddingOf(context);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      expect(innerPadding?.bottom, 0);
    });
  });

  group('ThemeSwitcher Android predictive back route', () {
    test('uses MaterialPageRoute on Android even for iOS skin', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      settings.settings.skin.value = Skins.iOS;
      final route = ThemeSwitcher.buildPageRoute<void>(
        builder: (_) => const SizedBox.shrink(),
      );
      expect(route, isA<MaterialPageRoute<void>>());
    });
  });

  group('AppShellFrame edge-to-edge & banner tinting', () {
    testWidgets('preserves bottom viewPadding when top notice banner is active', (tester) async {
      EdgeInsets? navPadding;
      EdgeInsets? navViewPadding;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 800),
            padding: EdgeInsets.only(top: 28, bottom: 24),
            viewPadding: EdgeInsets.only(top: 28, bottom: 24),
          ),
          child: MaterialApp(
            home: AppShellFrame(
              showSyncIndicatorOverride: true,
              syncStatusOverride: const SyncStatusSnapshot(
                kind: SyncStatusKind.failed,
                issueKey: 'sync_connection',
                message: 'Connection error',
              ),
              navigator: Builder(
                builder: (context) {
                  navPadding = MediaQuery.paddingOf(context);
                  navViewPadding = MediaQuery.viewPaddingOf(context);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(navPadding?.top, 0);
      expect(navPadding?.bottom, 24);
      expect(navViewPadding?.bottom, 24);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color != null &&
              ((w.decoration as BoxDecoration).color!.a) < 1.0,
        ),
        findsWidgets,
      );
    });
  });

  group('NavigatorPopHandler predictive back', () {
    testWidgets('allows root back when nested navigator is at initial route and pops nested route first', (tester) async {
      final nestedKey = GlobalKey<NavigatorState>();
      var canHandlePopRoot = false;

      await tester.pumpWidget(
        MaterialApp(
          onNavigationNotification: (notification) {
            canHandlePopRoot = notification.canHandlePop;
            return true;
          },
          home: NavigatorPopHandler(
            onPopWithResult: (_) => nestedKey.currentState?.maybePop(),
            child: Navigator(
              key: nestedKey,
              onGenerateInitialRoutes: (_, _) => [
                MaterialPageRoute<void>(builder: (_) => const Text('Root')),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(canHandlePopRoot, isFalse);

      nestedKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('Detail')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Detail'), findsOneWidget);
      expect(canHandlePopRoot, isTrue);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Detail'), findsNothing);
      expect(find.text('Root'), findsOneWidget);
      expect(canHandlePopRoot, isFalse);
    });
  });

  group('Android edge-to-edge overlays, sheets, and popups', () {
    void configureEdgeToEdgeView(
      WidgetTester tester, {
      FakeViewPadding padding = const FakeViewPadding(top: 48, bottom: 34),
      FakeViewPadding viewPadding = const FakeViewPadding(top: 48, bottom: 34),
      FakeViewPadding viewInsets = FakeViewPadding.zero,
    }) {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = padding;
      tester.view.viewPadding = viewPadding;
      tester.view.viewInsets = viewInsets;
    }

    testWidgets('showBBBottomSheet extends surface to bottom while clearing gesture bar and status bar without keyboard double-padding', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.reset();
      });
      configureEdgeToEdgeView(tester);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light().copyWith(
            bottomSheetTheme: const BottomSheetThemeData(
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
            ),
          ),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    showBBBottomSheet<void>(
                      context: ctx,
                      useSafeArea: true,
                      isScrollControlled: true,
                      builder: (_) => const SizedBox(
                        key: ValueKey('sheet-tall-content'),
                        height: 900,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Text('Sheet Bottom Action'),
                        ),
                      ),
                    );
                  },
                  child: const Text('Open Sheet'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      final contentRect = tester.getRect(find.byKey(const ValueKey('sheet-tall-content')));
      expect(contentRect.top, greaterThanOrEqualTo(48));
      expect(contentRect.bottom, lessThanOrEqualTo(800 - 34));

      final sheetSurfaceRect = tester.getRect(find.byType(BottomSheet));
      expect(sheetSurfaceRect.bottom, 800);

      // Dismiss and re-open with keyboard open (padding.bottom == 0, viewPadding.bottom == 34, viewInsets.bottom == 300).
      Navigator.of(tester.element(find.byKey(const ValueKey('sheet-tall-content')))).pop();
      await tester.pumpAndSettle();

      configureEdgeToEdgeView(
        tester,
        padding: const FakeViewPadding(top: 48, bottom: 0),
        viewPadding: const FakeViewPadding(top: 48, bottom: 34),
        viewInsets: const FakeViewPadding(bottom: 300),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    showBBBottomSheet<void>(
                      context: ctx,
                      useSafeArea: true,
                      isScrollControlled: true,
                      padding: EdgeInsets.zero,
                      builder: (_) => const SizedBox(
                        key: ValueKey('sheet-kbd-content'),
                        height: 120,
                        child: Center(child: Text('Keyboard Sheet')),
                      ),
                    );
                  },
                  child: const Text('Open Kbd Sheet'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Kbd Sheet'));
      await tester.pumpAndSettle();

      final kbdContentRect = tester.getRect(find.byKey(const ValueKey('sheet-kbd-content')));
      // Must sit directly above the 300px IME without double-padding the 34px gesture bar.
      expect(kbdContentRect.bottom, closeTo(500, 1.0));
    });

    testWidgets('AnimatedDropdownMenu stays clamped within top/bottom viewPadding', (tester) async {
      addTearDown(tester.view.reset);
      configureEdgeToEdgeView(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: AnimatedDropdownMenu(
                  menuWidth: 180,
                  trigger: (ctx, showMenu) => ElevatedButton(
                    onPressed: showMenu,
                    child: const Text('Menu Trigger'),
                  ),
                  menuBuilder: (_, hideMenu) => DropdownMenuCard(
                    width: 180,
                    children: List.generate(
                      20,
                      (i) => SizedBox(
                        height: 44,
                        child: Center(child: Text('Option $i')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Menu Trigger'));
      await tester.pumpAndSettle();

      final menuRect = tester.getRect(find.byType(SingleChildScrollView).last);
      expect(menuRect.top, greaterThanOrEqualTo(48));
      expect(menuRect.bottom, lessThanOrEqualTo(800 - 34));
    });

    testWidgets('MessagePopup clamps tapback pill and bottom toolbar inside top/bottom viewPadding', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.reset();
      });
      configureEdgeToEdgeView(tester);

      SettingsSvc.settings.enablePrivateAPI.value = true;
      SettingsSvc.settings.privateAPISend.value = true;

      final chat = Chat(guid: 'any;-;+14085550177', chatIdentifier: '+14085550177', serviceName: 'RCS');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      final service = ensureMessagesSvc(chat.guid);
      final cvController = cvc(chat);
      final msg = Message.fromMap({
        'guid': 'edge-popup-msg',
        'text': 'Edge popup test message',
        'service': 'RCS',
        'dateCreated': DateTime(2026, 11, 19, 8, 30).millisecondsSinceEpoch,
        'isFromMe': false,
        'handleId': 1,
        'hasAttachments': false,
      });
      service.struct.addMessages([msg]);
      final msgState = service.getOrCreateState(msg);
      final chatState = ChatsSvc.getOrCreateChatState(chat);
      ChatsSvc.activeChat = chatState;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemesService.materialYouTheme(Brightness.light),
          home: ChatStateScope(
            chatState: chatState,
            child: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(ctx).push(
                        PageRouteBuilder<void>(
                          opaque: false,
                          barrierDismissible: true,
                          pageBuilder: (_, _, _) => MessagePopup(
                            childPosition: const Offset(20, 12),
                            size: const Size(180, 48),
                            controller: msgState,
                            part: msgState.parts.first,
                            cvController: cvController,
                            serverDetails: const MessagePopupServerDetails(
                              minSierra: true,
                              minBigSur: true,
                              supportsOriginalDownload: true,
                            ),
                            sendTapback: ([_, _, _]) {},
                            widthContext: () => ctx,
                            child: const SizedBox(
                              width: 180,
                              height: 48,
                              child: Center(child: Text('Top-edge bubble')),
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Open MessagePopup'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open MessagePopup'));
      await tester.pumpAndSettle();

      // Tapback pill must be clamped >= top viewPadding (48) even when bubble is at y=12.
      final firstTapbackIcon = find.text(ReactionTypes.reactionToEmoji['love']!);
      expect(firstTapbackIcon, findsOneWidget);
      expect(tester.getRect(firstTapbackIcon).top, greaterThanOrEqualTo(48));

      // Bottom action bar must clear the 34px bottom gesture bar (bottom <= 800 - 34).
      final replyAction = find.text('Reply');
      expect(replyAction, findsOneWidget);
      expect(tester.getRect(replyAction).bottom, lessThanOrEqualTo(800 - 34));
    });

    testWidgets('FullscreenImage clears top status bar and bottom gesture bar while extending bottom bar surface', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.reset();
      });
      configureEdgeToEdgeView(tester);

      // Valid 1x1 transparent PNG so PhotoView decodes without spinning on an error/loading indicator.
      final png1x1 = Uint8List.fromList(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
      ]);

      final attachment = Attachment(
        guid: 'edge-img-1',
        mimeType: 'image/png',
        transferName: 'photo.png',
        totalBytes: png1x1.length,
      );
      final file = PlatformFile(
        name: 'photo.png',
        size: png1x1.length,
        bytes: png1x1,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemesService.materialYouTheme(Brightness.light),
          home: Scaffold(
            body: FullscreenImage(
              file: file,
              attachment: attachment,
              showInteractions: true,
              updatePhysics: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final closeRect = tester.getRect(find.byIcon(Icons.close));
      expect(closeRect.top, greaterThanOrEqualTo(48));

      final shareRect = tester.getRect(find.byIcon(Icons.share_outlined));
      expect(shareRect.bottom, lessThanOrEqualTo(800 - 34));
    });

    testWidgets('showBBBottomSheet scrollableBuilder expands/shrinks via inner scroll and clears bottom viewPadding', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.reset();
      });
      configureEdgeToEdgeView(tester);

      ScrollController? attachedScrollController;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    showBBBottomSheet<void>(
                      context: ctx,
                      padding: EdgeInsets.zero,
                      initialChildSize: 0.5,
                      minChildSize: 0.25,
                      maxChildSize: 0.9,
                      scrollableBuilder: (sheetCtx, scrollController) {
                        attachedScrollController = scrollController;
                        return ListView.builder(
                          controller: scrollController,
                          physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
                          padding: EdgeInsets.only(bottom: 24 + MediaQuery.viewPaddingOf(sheetCtx).bottom),
                          itemCount: 30,
                          itemBuilder: (_, i) => SizedBox(
                            height: 48,
                            child: Center(child: Text('Sheet Item $i')),
                          ),
                        );
                      },
                    );
                  },
                  child: const Text('Open Scrollable Sheet'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Scrollable Sheet'));
      await tester.pumpAndSettle();

      expect(attachedScrollController, isNotNull);
      final initialSheetRect = tester.getRect(find.byType(BottomSheet));
      // useSafeArea reserves 48px top status bar -> 0.5 * (800 - 48) = 376px height -> top = 424.
      expect(initialSheetRect.top, closeTo(424, 20));
      expect(initialSheetRect.bottom, 800);

      // Dragging up on the scrollable list expands the DraggableScrollableSheet first.
      await tester.drag(find.byType(ListView), const Offset(0, -260));
      await tester.pumpAndSettle();
      final expandedSheetRect = tester.getRect(find.byType(BottomSheet));
      expect(expandedSheetRect.top, lessThan(200));

      // Scroll to the very bottom and confirm the final item clears the 34px gesture bar.
      attachedScrollController!.jumpTo(attachedScrollController!.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final lastItemRect = tester.getRect(find.text('Sheet Item 29'));
      expect(lastItemRect.bottom, lessThanOrEqualTo(800 - 34));

      // Scroll back to top (offset == 0) and drag down to shrink the sheet.
      attachedScrollController!.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 260));
      await tester.pumpAndSettle();
      final shrunkSheetRect = tester.getRect(find.byType(BottomSheet));
      expect(shrunkSheetRect.top, greaterThan(expandedSheetRect.top + 100));
    });

    testWidgets('FindMyPage phone DraggableScrollableSheet expands/shrinks with scroll and clears floating nav pill + gesture bar', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.reset();
      });
      configureEdgeToEdgeView(tester);

      if (!GetIt.I.isRegistered<HttpService>()) {
        GetIt.I.registerSingleton<HttpService>(HttpService());
      }

      final ctrl = Get.put(FindMyController(autoFetch: false));
      addTearDown(() {
        if (Get.isRegistered<FindMyController>()) {
          Get.delete<FindMyController>(force: true);
        }
      });

      final friends = List.generate(
        14,
        (i) => FindMyFriend(
          latitude: 37.3349 + i * 0.001,
          longitude: -122.009,
          longAddress: null,
          shortAddress: 'Cupertino, CA',
          title: 'Friend $i',
          subtitle: null,
          handle: null,
          handleAddress: 'friend$i@example.com',
          lastUpdated: DateTime(2026, 11, 20, 1, 0),
          status: LocationStatus.shallow,
          locatingInProgress: false,
          horizontalAccuracy: 10,
          isOld: false,
        ),
      );
      ctrl.friends.addAll(friends);
      ctrl.friendsWithLocation.addAll(friends);
      ctrl.fetching2.value = false;

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemesService.materialYouTheme(Brightness.light),
          home: const FindMyPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(ctrl.sheetController.isAttached, isTrue);
      expect(ctrl.sheetController.size, closeTo(0.48, 0.02));
      expect(ctrl.activeSheetScrollController, isNotNull);

      final pillRect = tester.getRect(find.byType(FindMyFloatingNavPill));
      expect(pillRect.bottom, lessThanOrEqualTo(800 - 34));

      // Dragging up expands the sheet above the 48% snap point.
      await tester.drag(find.byKey(const ValueKey('tabs-view')), const Offset(0, -220));
      await tester.pumpAndSettle();
      expect(ctrl.sheetController.size, greaterThan(0.65));

      // Scrolling to maxScrollExtent leaves the last row completely above the floating nav pill.
      final sheetScroll = ctrl.activeSheetScrollController!;
      sheetScroll.jumpTo(sheetScroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final lastFriendRect = tester.getRect(find.text('Friend 13'));
      expect(lastFriendRect.bottom, lessThanOrEqualTo(pillRect.top));

      // Scrolling back to top and dragging down snaps back to 48%, then a second drag shrinks to minChildSize.
      sheetScroll.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const ValueKey('tabs-view')), const Offset(0, 260));
      await tester.pumpAndSettle();
      expect(ctrl.sheetController.size, closeTo(0.48, 0.02));

      await tester.drag(find.byKey(const ValueKey('tabs-view')), const Offset(0, 220));
      await tester.pumpAndSettle();
      expect(ctrl.sheetController.size, lessThan(0.30));
    });
  });
}
