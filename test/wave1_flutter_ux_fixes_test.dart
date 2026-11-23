import 'dart:io';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/cupertino_header.dart';
import 'package:bluebubbles/app/layouts/settings/settings_page.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/search/settings_search_bar.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/search/settings_search_empty_result.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/tablet_mode_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart' show Skins;
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/network/api/server_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _FakeSettingsService extends SettingsService {
  final Rx<ServerDetails> fakeDetails = const ServerDetails(
    macOSVersion: 14,
    macOSMinorVersion: 0,
    serverVersion: '1.9.0',
    serverVersionCode: 10900,
  ).obs;

  @override
  ServerDetails get serverDetails => fakeDetails.value;
}

class _FakeHttpService extends HttpService {
  _FakeHttpService() {
    dio = Dio();
    server = ServerApi(this);
  }

  @override
  String get origin => SettingsSvc.settings.serverAddress.value;
}

class _FakeLogger extends BaseLogger {
  @override
  Future<void> init() async {}
}

class _FakeDesktopPrefs extends SharedPreferencesDesktopActions {
  _FakeDesktopPrefs(super.service);

  @override
  double? getSplitRatio() => 0.35;
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

void _registerTestServices() {
  Get.testMode = true;
  SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  final settingsService = _FakeSettingsService()
    ..settings = Settings()
    ..fcmData = FCMData();
  final fsService = FilesystemService()
    ..appDocDir = Directory.systemTemp
    ..packageInfo = PackageInfo(
      appName: 'BlueBubbles',
      packageName: 'com.bluebubbles.messaging',
      version: '1.0.0',
      buildNumber: '1',
    );
  GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  GetIt.I.registerSingleton<SettingsService>(settingsService);
  GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  GetIt.I.registerSingleton<ThemesService>(ThemesService());
  GetIt.I.registerSingleton<HttpService>(_FakeHttpService());
  GetIt.I.registerSingleton<SocketService>(SocketService());
  GetIt.I.registerSingleton<ChatsService>(ChatsService());
  GetIt.I.registerSingleton<HandleService>(HandleService());
  GetIt.I.registerSingleton<SyncService>(SyncService());
  GetIt.I.registerSingleton<AttachmentDownloadService>(AttachmentDownloadService());
  GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  GetIt.I.registerSingleton<FilesystemService>(fsService);
  GetIt.I.registerSingleton<BaseLogger>(_FakeLogger());
  GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
}

void main() {
  setUp(() async {
    await GetIt.I.reset();
    Get.reset();
    _registerTestServices();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    Get.reset();
    await GetIt.I.reset();
  });

  testWidgets('P0-1: SettingsPage shows single-match search results instead of EmptySearchResult', (tester) async {
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('A RenderFlex overflowed')) return;
      prevOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = prevOnError);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SettingsSvc.settings.tabletMode.value = false;
    SettingsSvc.settings.skin.value = Skins.iOS;
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      AdaptiveTheme(
        light: ThemeData.light(),
        dark: ThemeData.dark(),
        initial: AdaptiveThemeMode.light,
        builder: (theme, darkTheme) => GetMaterialApp(
          theme: theme,
          darkTheme: darkTheme,
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final searchField = find.descendant(
      of: find.byType(SettingsSearchBar),
      matching: find.byType(EditableText),
    );
    expect(searchField, findsOneWidget);

    await tester.enterText(searchField, 'About');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pumpAndSettle();

    expect(find.byType(EmptySearchResult), findsNothing);
    expect(find.text('About'), findsWidgets);

    await tester.enterText(searchField, 'zzzz_nonexistent_setting_xyz');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pumpAndSettle();

    expect(find.byType(EmptySearchResult), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('P1-3: SetupView PopScope steps back on page > 0 and disposes SocketSvc worker', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const GetMaterialApp(
        home: SetupView(),
      ),
    );
    await tester.pump(const Duration(seconds: 2));

    final controller = Get.find<SetupViewController>();
    expect(controller.pageController.hasClients, isTrue);
    controller.pageController.jumpToPage(1);
    await tester.pump();
    expect(controller.pageController.page?.round(), 1);

    final popScope = tester.widget<PopScope>(find.byWidgetPredicate((w) => w is PopScope).first);
    popScope.onPopInvokedWithResult?.call(false, null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(controller.pageController.page?.round(), 0);
    await tester.pump(const Duration(seconds: 2));

    // Jumping to pageOfNoReturn (e.g. SyncProgress) blocks system back
    controller.pageController.jumpToPage(controller.pageOfNoReturn);
    await tester.pump();
    expect(controller.pageController.page?.round(), controller.pageOfNoReturn);
    popScope.onPopInvokedWithResult?.call(false, null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(controller.pageController.page?.round(), controller.pageOfNoReturn);

    // Unmount SetupView and verify SocketSvc.state change does not throw
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const GetMaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 2));
    SocketSvc.state.value = SocketState.error;
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('P1-7: CupertinoHeader action buttons have >=44x44 tap targets', (tester) async {
    SettingsSvc.settings.moveChatCreatorToHeader.value = true;
    final convController = Get.put(ConversationListController(showArchivedChats: false, showUnknownSenders: false));

    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: convController.iosScrollController,
            slivers: [
              CupertinoHeader(controller: convController),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final searchInkWell = find.ancestor(
      of: find.byIcon(CupertinoIcons.search),
      matching: find.byType(InkWell),
    );
    expect(searchInkWell, findsOneWidget);
    final searchSize = tester.getSize(searchInkWell);
    expect(searchSize.width, greaterThanOrEqualTo(44.0));
    expect(searchSize.height, greaterThanOrEqualTo(44.0));

    final pencilInkWell = find.ancestor(
      of: find.byIcon(CupertinoIcons.pencil),
      matching: find.byType(InkWell),
    );
    expect(pencilInkWell, findsOneWidget);
    final pencilSize = tester.getSize(pencilInkWell);
    expect(pencilSize.width, greaterThanOrEqualTo(44.0));
    expect(pencilSize.height, greaterThanOrEqualTo(44.0));
  });

  testWidgets('P1-7: TabletModeWrapper collapsed inspector toggle has >=44px height', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final chat = Chat(guid: 'iMessage;-;+15551234567', chatIdentifier: '+15551234567', displayName: 'Test');
    ChatsSvc.allChats.add(chat);
    ChatsSvc.activeChat = ChatsSvc.getOrCreateChatState(chat);
    NavigationSvc.showInspectorDrawer.value = false;

    await tester.pumpWidget(
      const GetMaterialApp(
        home: Scaffold(
          body: TabletModeWrapper(
            left: SizedBox.expand(),
            right: SizedBox.expand(),
            enableInspector: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final toggleBtn = find.ancestor(
      of: find.byIcon(Icons.chevron_left_rounded),
      matching: find.byType(IconButton),
    );
    expect(toggleBtn, findsOneWidget);
    expect(tester.getSize(toggleBtn).height, greaterThanOrEqualTo(44.0));
    debugDefaultTargetPlatformOverride = null;
  });
}
