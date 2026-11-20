import 'package:bluebubbles/app/wrappers/tablet_mode_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:universal_io/io.dart';

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

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    desktop = _FakeDesktopPrefs(this);
  }
}

void _registerMinimalServices() {
  Get.testMode = true;
  GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
  GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  GetIt.I.registerSingleton<SocketService>(SocketService());
  GetIt.I.registerSingleton<ChatsService>(ChatsService());
  GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    Get.reset();
    await GetIt.I.reset();
  });

  group('Web hash URL sync', () {
    test('parseWebHashRoute parses chat, settings, and home routes', () {
      final chatTarget = parseWebHashRoute('#/chat/iMessage%3B-%3B%2B15551234567');
      expect(chatTarget.kind, WebHashRouteKind.chat);
      expect(chatTarget.chatGuid, 'iMessage;-;+15551234567');

      final rawChatTarget = parseWebHashRoute('/chat/SMS;-;+15550001111');
      expect(rawChatTarget.kind, WebHashRouteKind.chat);
      expect(rawChatTarget.chatGuid, 'SMS;-;+15550001111');

      expect(parseWebHashRoute('#/settings').kind, WebHashRouteKind.settings);
      expect(parseWebHashRoute('/settings/server').kind, WebHashRouteKind.settings);
      expect(parseWebHashRoute('#/').kind, WebHashRouteKind.home);
      expect(parseWebHashRoute('/').kind, WebHashRouteKind.home);
      expect(parseWebHashRoute('').kind, WebHashRouteKind.home);
      expect(parseWebHashRoute('#/chat/').kind, WebHashRouteKind.home);
    });

    test('buildWebHashRouteUri prioritizes settings, then active chat, then home', () {
      expect(
        buildWebHashRouteUri(settingsOpen: true, activeChatGuid: 'iMessage;-;+15551234567').path,
        '/settings',
      );
      expect(
        buildWebHashRouteUri(settingsOpen: false, activeChatGuid: 'iMessage;-;+15551234567').path,
        '/chat/iMessage%3B-%3B%2B15551234567',
      );
      expect(
        buildWebHashRouteUri(settingsOpen: false, activeChatGuid: null).path,
        '/',
      );
    });
  });

  group('NavigatorService responsive & inspector state', () {
    test('toggleInspectorDrawer flips showInspectorDrawer (closed by default on web)', () {
      _registerMinimalServices();

      expect(NavigationSvc.showInspectorDrawer.value, equals(!kIsWeb));
      final initial = NavigationSvc.showInspectorDrawer.value;
      NavigationSvc.toggleInspectorDrawer();
      expect(NavigationSvc.showInspectorDrawer.value, equals(!initial));
      NavigationSvc.toggleInspectorDrawer();
      expect(NavigationSvc.showInspectorDrawer.value, equals(initial));
    });

    testWidgets('pushAndRemoveSettingsUntil preserves activeSettingsWidget in narrow mode until popped or closed',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      _registerMinimalServices();
      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late BuildContext capturedContext;
      await tester.pumpWidget(
        GetMaterialApp(
          navigatorKey: NavigationSvc.key,
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const Scaffold(body: Text('Settings Root'));
            },
          ),
        ),
      );

      const detailPage = Scaffold(body: Text('Server Panel'));
      NavigationSvc.pushAndRemoveSettingsUntil(
        capturedContext,
        detailPage,
        (route) => route.isFirst,
      );
      await tester.pumpAndSettle();

      expect(find.text('Server Panel'), findsOneWidget);
      expect(NavigationSvc.activeSettingsPage.value, Scaffold);
      expect(NavigationSvc.activeSettingsWidget, detailPage);
      expect(NavigationSvc.hasNarrowSettingsRoute, isTrue);

      NavigationSvc.closeSettings(capturedContext);
      await tester.pumpAndSettle();

      expect(find.text('Settings Root'), findsOneWidget);
      expect(NavigationSvc.activeSettingsPage.value, isNull);
      expect(NavigationSvc.activeSettingsWidget, isNull);
      expect(NavigationSvc.hasNarrowSettingsRoute, isFalse);
    });
  });

  group('TabletModeWrapper zero-state-loss resize across 600px', () {
    testWidgets('wide -> narrow -> wide preserves active state and fires transition hooks',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      _registerMinimalServices();
      SettingsSvc.settings.tabletMode.value = true;

      final chat = Chat(guid: 'iMessage;-;+15551234567');
      ChatsSvc.activeChat = ChatsSvc.getOrCreateChatState(chat);

      var narrowTransitions = 0;
      var wideTransitions = 0;

      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        GetMaterialApp(
          navigatorKey: NavigationSvc.key,
          home: Scaffold(
            body: TabletModeWrapper(
              initialRatio: 0.35,
              minRatio: 0.2,
              maxRatio: 0.5,
              enableInspector: false,
              onNarrowTransition: () => narrowTransitions++,
              onWideTransition: () => wideTransitions++,
              left: const Text('Left Pane'),
              right: const Text('Right Pane'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Left Pane'), findsOneWidget);
      expect(find.text('Right Pane'), findsOneWidget);
      expect(narrowTransitions, 0);
      expect(wideTransitions, 0);

      // Shrink below 600px threshold: activeChat must remain intact (no destructive close).
      tester.view.physicalSize = const Size(480, 700);
      await tester.pumpAndSettle();

      expect(find.text('Left Pane'), findsOneWidget);
      expect(find.text('Right Pane'), findsNothing);
      expect(narrowTransitions, 1);
      expect(ChatsSvc.activeChat?.chat.guid, 'iMessage;-;+15551234567');

      // Expand back above 600px threshold.
      tester.view.physicalSize = const Size(900, 700);
      await tester.pumpAndSettle();

      expect(find.text('Left Pane'), findsOneWidget);
      expect(find.text('Right Pane'), findsOneWidget);
      expect(wideTransitions, 1);
      expect(ChatsSvc.activeChat?.chat.guid, 'iMessage;-;+15551234567');
    });
  });
}
