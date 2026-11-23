import 'dart:io';

import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/layout/settings_scaffold.dart';
import 'package:bluebubbles/app/wrappers/tablet_mode_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart' show Skins;
import 'package:bluebubbles/main.dart' show AppShellFrame;
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/network/api/server_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
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
  double? _ratio = 0.35;

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

class _TestFindMyController extends FindMyController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  // ignore: must_call_super
  void onReady() {}
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

class _TestTransitionRoute extends PageRouteBuilder<void> {
  _TestTransitionRoute({
    super.opaque = true,
    Duration duration = const Duration(milliseconds: 300),
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          pageBuilder: (_, _, _) => const SizedBox.expand(),
        );
}

void main() {
  setUp(() async {
    await GetIt.I.reset();
    Get.reset();
    _registerTestServices();
  });

  tearDown(() async {
    Get.delete<FindMyController>(force: true);
    Get.reset();
    await GetIt.I.reset();
  });

  group('P0-1: SettingsScaffold lazy CustomScrollView & owned ScrollController', () {
    testWidgets('disables shrinkWrap inside Expanded and preserves single ScrollController across rebuilds',
        (tester) async {
      tester.view.physicalSize = const Size(480, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SettingsSvc.settings.skin.value = Skins.Material;
      final builtIndices = <int>{};
      final tick = 0.obs;

      await tester.pumpWidget(
        GetMaterialApp(
          home: Obx(() {
            tick.value;
            return SettingsScaffold(
              title: 'Settings',
              initialHeader: null,
              iosSubtitle: null,
              materialSubtitle: null,
              headerColor: Colors.white,
              tileColor: Colors.grey.shade100,
              bodySlivers: [
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      builtIndices.add(index);
                      return SizedBox(height: 100, child: Text('Item $index'));
                    },
                    childCount: 100,
                  ),
                ),
              ],
            );
          }),
        ),
      );
      await tester.pump();

      final scrollView = tester.widget<CustomScrollView>(find.byType(CustomScrollView).first);
      expect(scrollView.shrinkWrap, isFalse);
      final initialController = scrollView.controller;
      expect(initialController, isNotNull);

      // SliverList is lazily virtualized: only viewport + cache items are built, not all 100.
      expect(builtIndices.length, lessThan(25));

      // Scroll down, rebuild parent, and verify the exact same ScrollController & offset survive.
      initialController!.jumpTo(250);
      await tester.pump();
      tick.value++;
      await tester.pump();

      final rebuiltScrollView = tester.widget<CustomScrollView>(find.byType(CustomScrollView).first);
      expect(rebuiltScrollView.controller, same(initialController));
      expect(rebuiltScrollView.controller!.offset, 250);

      // Unmount disposes the controller cleanly.
      await tester.pumpWidget(const SizedBox.shrink());
      expect(() => initialController.addListener(() {}), throwsFlutterError);
    });
  });

  group('P0-2: PaneObserver splits open from covered and keeps left pane visible during transitions/back drags', () {
    testWidgets('covered waits for opaque route completion and clears immediately on gesture/pop/remove',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SettingsSvc.settings.tabletMode.value = false;
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final navKey = GlobalKey<NavigatorState>();
      // Mirrors SettingsPage's PaneObserver(NavigationSvc.settingsPaneOpen) without passing covered explicitly.
      final observer = PaneObserver(NavigationSvc.settingsPaneOpen);

      await tester.pumpWidget(
        GetMaterialApp(
          home: TabletModeWrapper(
            rightOpen: NavigationSvc.settingsPaneOpen,
            left: const Text('Left List'),
            right: Navigator(
              key: navKey,
              observers: [observer],
              onDidRemovePage: (_) {},
              pages: const [MaterialPage<void>(child: SizedBox.shrink())],
            ),
          ),
        ),
      );
      await tester.pump();

      Offstage leftOffstage() => tester.widget<Offstage>(
            find
                .ancestor(
                  of: find.text('Left List', skipOffstage: false),
                  matching: find.byType(Offstage),
                )
                .first,
          );
      IgnorePointer rightGate() => tester.widget<IgnorePointer>(
            find.ancestor(of: find.byType(Navigator), matching: find.byType(IgnorePointer)).first,
          );

      expect(NavigationSvc.settingsPaneOpen.value, isFalse);
      expect(NavigationSvc.settingsPaneCovered.value, isFalse);
      expect(leftOffstage().offstage, isFalse);
      expect(rightGate().ignoring, isTrue);

      // Push opaque route with 300ms transition.
      final opaqueRoute = _TestTransitionRoute(opaque: true);
      navKey.currentState!.push(opaqueRoute);
      await tester.pump(); // Frame 1: PaneObserver post-frame sets open.value = true
      await tester.pump(); // Frame 2: Obx rebuilds IgnorePointer with open.value == true (still t = 0ms)

      // open is true immediately for pointer gating, while covered stays false mid-transition.
      expect(NavigationSvc.settingsPaneOpen.value, isTrue);
      expect(NavigationSvc.settingsPaneCovered.value, isFalse);
      expect(rightGate().ignoring, isFalse);
      expect(leftOffstage().offstage, isFalse);

      // Mid-transition: still uncovered so left stays visible.
      await tester.pump(const Duration(milliseconds: 120));
      expect(NavigationSvc.settingsPaneCovered.value, isFalse);
      expect(leftOffstage().offstage, isFalse);

      // Once transition completes, covered becomes true and left goes Offstage.
      await tester.pumpAndSettle();
      expect(NavigationSvc.settingsPaneCovered.value, isTrue);
      expect(leftOffstage().offstage, isTrue);

      // Predictive-back / swipe gesture start immediately uncovers left.
      observer.didStartUserGesture(opaqueRoute, null);
      await tester.pump();
      expect(NavigationSvc.settingsPaneCovered.value, isFalse);
      expect(leftOffstage().offstage, isFalse);

      // Cancelled gesture re-covers once animation is completed and gesture stops.
      observer.didStopUserGesture();
      await tester.pump();
      expect(NavigationSvc.settingsPaneCovered.value, isTrue);
      expect(leftOffstage().offstage, isTrue);

      // Non-gesture pop immediately uncovers on Frame 0 (AnimationStatus.reverse + didPop).
      navKey.currentState!.pop();
      await tester.pump();
      expect(NavigationSvc.settingsPaneCovered.value, isFalse);
      expect(leftOffstage().offstage, isFalse);
      await tester.pumpAndSettle();
      expect(NavigationSvc.settingsPaneOpen.value, isFalse);
      expect(NavigationSvc.settingsPaneCovered.value, isFalse);
    });

    testWidgets('non-opaque routes never set covered, and didRemove detaches status listeners cleanly',
        (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      final open = false.obs;
      final covered = false.obs;
      final observer = PaneObserver(open, covered: covered);

      await tester.pumpWidget(
        MaterialApp(
          home: Navigator(
            key: navKey,
            observers: [observer],
            onDidRemovePage: (_) {},
            pages: const [MaterialPage<void>(child: SizedBox.shrink())],
          ),
        ),
      );

      final transparentRoute = _TestTransitionRoute(opaque: false);
      navKey.currentState!.push(transparentRoute);
      await tester.pumpAndSettle();
      expect(open.value, isTrue);
      expect(covered.value, isFalse);

      navKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(open.value, isFalse);
      expect(covered.value, isFalse);

      // Push opaque route, complete, then remove via didRemove: listener must be detached.
      final opaqueRoute = _TestTransitionRoute(opaque: true);
      navKey.currentState!.push(opaqueRoute);
      await tester.pumpAndSettle();
      expect(covered.value, isTrue);

      navKey.currentState!.removeRoute(opaqueRoute);
      await tester.pump();
      expect(covered.value, isFalse);
      expect(open.value, isFalse);

      // Even if a standalone observer receives a removed route's late status callback, listener is detached.
      final standaloneOpen = false.obs;
      final standaloneCovered = false.obs;
      final standaloneObserver = PaneObserver(standaloneOpen, covered: standaloneCovered);
      final controller = AnimationController(vsync: const TestVSync(), duration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);
      final fakeRoute = _FakeTransitionRoute(controller);
      standaloneObserver.didPush(fakeRoute, null);
      controller.value = 1.0;
      expect(standaloneCovered.value, isTrue);

      standaloneObserver.didRemove(fakeRoute, null);
      expect(standaloneCovered.value, isFalse);
      controller.value = 0.0;
      controller.value = 1.0;
      expect(standaloneCovered.value, isFalse, reason: 'removed route status listener must be detached');
    });
  });

  group('W-P1-1: TabletModeWrapper keeps right pane layout width fixed during inspector animation', () {
    testWidgets('opening and closing inspector does not re-layout right pane on every frame', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final chat = Chat(guid: 'iMessage;-;+15551234567', chatIdentifier: '+15551234567');
      Get.put<FindMyController>(_TestFindMyController());
      ChatsSvc.activeChat = ChatsSvc.getOrCreateChatState(chat);
      ChatsSvc.activeChatGuid.value = chat.guid;
      NavigationSvc.showInspectorDrawer.value = false;

      final recordedWidths = <double>[];
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: TabletModeWrapper(
              initialRatio: 0.3,
              minRatio: 0.2,
              maxRatio: 0.45,
              enableInspector: true,
              left: const SizedBox.expand(child: Text('Left')),
              right: LayoutBuilder(
                builder: (context, constraints) {
                  recordedWidths.add(constraints.maxWidth);
                  return const SizedBox.expand(child: Text('Right'));
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      recordedWidths.clear();

      // Open inspector: step through 240ms animation in 30ms increments.
      NavigationSvc.showInspectorDrawer.value = true;
      await tester.pump();
      for (int i = 0; i < 7; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      // Mid-animation (210ms): right pane has NOT re-laid out across all 7 ticks.
      expect(recordedWidths, isEmpty);

      await tester.pumpAndSettle();
      // Snaps once at settled open (t == 1.0).
      expect(recordedWidths.length, 1);
      expect(tester.takeException(), isNull);
      recordedWidths.clear();

      // Close inspector: snaps once back to closed width at start, then 0 re-layouts across animation frames.
      NavigationSvc.showInspectorDrawer.value = false;
      await tester.pump();
      expect(recordedWidths.length, 1);
      recordedWidths.clear();

      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pumpAndSettle();
      expect(recordedWidths, isEmpty);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      ChatsSvc.activeChat = null;
      ChatsSvc.activeChatGuid.value = null;
    });
  });

  group('W-P1-2: TabletModeWrapper split-divider drag refreshes listener only on avatar-only flip + pan end', () {
    testWidgets('skips refresh during drag when isAvatarOnly stays constant, refreshes on flip and onPanEnd',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SettingsSvc.settings.tabletMode.value = true;
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      int refreshCount = 0;
      final sub = NavigationSvc.listener.listen((_) => refreshCount++);
      addTearDown(sub.cancel);

      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: TabletModeWrapper(
              initialRatio: 0.4,
              minRatio: 0.15,
              maxRatio: 0.6,
              enableInspector: false,
              left: LayoutBuilder(
                builder: (context, constraints) {
                  NavigationSvc.maxWidthLeft = constraints.maxWidth;
                  return const SizedBox.expand(child: Text('Left'));
                },
              ),
              right: const SizedBox.expand(child: Text('Right')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      refreshCount = 0;

      // Divider sits at leftWidth (~397px -> isAvatarOnly == false).
      final dividerFinder = find.byWidgetPredicate(
        (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeLeftRight,
      );
      expect(dividerFinder, findsOneWidget);

      // Drag +60px right across multiple move events (always >= 300px, never flips isAvatarOnly).
      final start = tester.getCenter(dividerFinder);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      expect(refreshCount, 0);

      await gesture.up();
      await tester.pump();
      expect(refreshCount, 1, reason: 'onPanEnd refreshes once');

      // Now drag -200px left across the 300px threshold (457 -> 257).
      refreshCount = 0;
      final start2 = tester.getCenter(dividerFinder);
      final gesture2 = await tester.startGesture(start2);
      await gesture2.moveBy(const Offset(-50, 0));
      await tester.pump();
      await gesture2.moveBy(const Offset(-50, 0));
      await tester.pump();
      await gesture2.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(refreshCount, 1, reason: 'refreshes once when isAvatarOnly flips across 300px');

      await gesture2.up();
      await tester.pump();
      expect(refreshCount, 2, reason: 'onPanEnd refreshes once after drag ends');

      // Flush the 800ms split-ratio persistence debounce timer before teardown.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    });
  });

  group('W-P1-3: AppShellFrame preserves shell-body Column element on syncing -> failed transition', () {
    testWidgets('ValueKey shell-body keeps Column element and AnimatedSize running', (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SettingsSvc.settings.finishedSetup.value = true;
      SyncSvc.status.value = const SyncStatusSnapshot(
        kind: SyncStatusKind.syncing,
        issueKey: 'syncing',
        message: 'Syncing...',
      );

      await tester.pumpWidget(
        GetMaterialApp(
          navigatorKey: NavigationSvc.key,
          builder: (context, child) => AppShellFrame(
            showSyncIndicatorOverride: true,
            navigator: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: Center(child: Text('Home'))),
        ),
      );
      await tester.pump();

      final bodyFinder = find.byKey(const ValueKey('shell-body'));
      expect(bodyFinder, findsOneWidget);
      final syncingColumnElement = tester.element(bodyFinder);
      final animatedSizeFinder = find.descendant(of: bodyFinder, matching: find.byType(AnimatedSize)).first;
      final syncingAnimatedSizeState = tester.state(animatedSizeFinder);

      // Transition syncing -> failed: Positioned.fill is inserted at index 0 of Stack and hairline drops off.
      SyncSvc.status.value = const SyncStatusSnapshot(
        kind: SyncStatusKind.failed,
        issueKey: 'sync-failed',
        message: 'Connection failed',
      );
      await tester.pump();

      expect(tester.element(bodyFinder), same(syncingColumnElement));
      expect(tester.state(animatedSizeFinder), same(syncingAnimatedSizeState));

      // Mid-animation (90ms of 180ms): AnimatedSize should still be animating smoothly (0 < height < finalHeight).
      await tester.pump(const Duration(milliseconds: 90));
      final midHeight = tester.getSize(animatedSizeFinder).height;
      await tester.pumpAndSettle();
      final finalHeight = tester.getSize(animatedSizeFinder).height;
      expect(midHeight, greaterThan(0));
      expect(midHeight, lessThan(finalHeight));
    });
  });
}

class _FakeTransitionRoute extends PageRouteBuilder<void> {
  _FakeTransitionRoute(this._controller)
      : super(pageBuilder: (_, _, _) => const SizedBox.shrink());

  final AnimationController _controller;

  @override
  Animation<double>? get animation => _controller;

  @override
  bool get opaque => true;
}
