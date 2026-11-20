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

    testWidgets('settings pane and section observers sync isSettingsOpen and clear on closeSections',
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
          navigatorObservers: [NavigationSvc.sectionObserver],
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const Scaffold(body: Text('Home Root'));
            },
          ),
        ),
      );

      NavigationSvc.key.currentState!.push(
        MaterialPageRoute(
          settings: RouteSettings(name: AppSection.settings.name),
          builder: (_) => Navigator(
            key: Get.nestedKey(3),
            observers: [PaneObserver(NavigationSvc.settingsPaneOpen)],
            pages: const [MaterialPage(child: Scaffold(body: Text('Settings Root')))],
            onDidRemovePage: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(NavigationSvc.openSection.value, AppSection.settings);
      expect(NavigationSvc.isSettingsOpen.value, isTrue);
      expect(NavigationSvc.settingsPaneOpen.value, isFalse);

      const detailPage = Scaffold(body: Text('Server Panel'));
      NavigationSvc.pushAndRemoveSettingsUntil(
        capturedContext,
        detailPage,
        (route) => route.isFirst,
      );
      await tester.pumpAndSettle();

      expect(find.text('Server Panel'), findsOneWidget);
      expect(NavigationSvc.settingsPaneOpen.value, isTrue);

      NavigationSvc.closeSections();
      await tester.pumpAndSettle();

      expect(find.text('Home Root'), findsOneWidget);
      expect(NavigationSvc.openSection.value, isNull);
      expect(NavigationSvc.isSettingsOpen.value, isFalse);
      expect(NavigationSvc.activeSettingsPage.value, isNull);
    });
  });

  group('TabletModeWrapper zero-state-loss resize across 600px', () {
    testWidgets('wide -> narrow -> wide preserves active state and switches via rightOpen',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      _registerMinimalServices();
      SettingsSvc.settings.tabletMode.value = true;

      final chat = Chat(guid: 'iMessage;-;+15551234567');
      ChatsSvc.activeChat = ChatsSvc.getOrCreateChatState(chat);
      final rightOpen = false.obs;

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
              rightOpen: rightOpen,
              left: const Text('Left Pane'),
              right: const Text('Right Pane'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Left Pane'), findsOneWidget);
      expect(find.text('Right Pane'), findsOneWidget);

      // Shrink below 600px threshold: both panes stay mounted (zero state loss),
      // activeChat remains intact, and rightOpen gates right-pane hit testing.
      tester.view.physicalSize = const Size(480, 700);
      await tester.pumpAndSettle();

      IgnorePointer rightGate() => tester.widget<IgnorePointer>(
            find.ancestor(of: find.text('Right Pane'), matching: find.byType(IgnorePointer)).first,
          );

      expect(find.text('Left Pane'), findsOneWidget);
      expect(find.text('Right Pane'), findsOneWidget);
      expect(rightGate().ignoring, isTrue);
      expect(ChatsSvc.activeChat?.chat.guid, 'iMessage;-;+15551234567');

      rightOpen.value = true;
      await tester.pumpAndSettle();
      expect(rightGate().ignoring, isFalse);

      // Expand back above 600px threshold.
      tester.view.physicalSize = const Size(900, 700);
      await tester.pumpAndSettle();

      expect(find.text('Left Pane'), findsOneWidget);
      expect(find.text('Right Pane'), findsOneWidget);
      expect(ChatsSvc.activeChat?.chat.guid, 'iMessage;-;+15551234567');
    });
  });
}
