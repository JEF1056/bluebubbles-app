import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/cupertino_header.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/header_widgets.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/material_header.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/tablet_mode_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
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

class _TestFindMyController extends FindMyController {
  _TestFindMyController() : super(autoFetch: false);

  Chat? openedChat;
  int openCalls = 0;

  @override
  void activatePage() {}

  @override
  Future<void> ensureFriendsLoaded({Duration maxAge = const Duration(minutes: 2)}) async {}

  @override
  Future<void> openForChat(BuildContext context, Chat chat) async {
    openCalls++;
    openedChat = chat;
  }
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

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

ThemeData _testTheme({Brightness brightness = Brightness.light}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1A73E8),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
  );
}

Chat _dmChat({String name = 'Bob', String address = '+15551112222'}) {
  final handle = Handle(address: address);
  final chat = Chat(
    guid: 'iMessage;-;$address',
    chatIdentifier: address,
    displayName: name,
  );
  chat.handles.add(handle);
  return chat;
}

FindMyFriend _friend({String address = '+15551112222', String shortAddress = 'Mountain View, CA'}) {
  return FindMyFriend(
    latitude: 37.4220,
    longitude: -122.0841,
    longAddress: '1600 Amphitheatre Pkwy, $shortAddress',
    shortAddress: shortAddress,
    title: 'Bob',
    subtitle: shortAddress,
    handle: Handle(address: address),
    handleAddress: address,
    lastUpdated: DateTime.now(),
    status: null,
    isLive: true,
    locatingInProgress: false,
  );
}

AnimatedContainer _findAnimatedContainer(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  final widget = tester.widget(finder);
  if (widget is AnimatedContainer) return widget;
  return tester.widget<AnimatedContainer>(
    find.descendant(of: finder, matching: find.byType(AnimatedContainer)).first,
  );
}

Color? _animatedContainerColor(WidgetTester tester, Key key) {
  final container = _findAnimatedContainer(tester, key);
  final decoration = container.decoration as BoxDecoration?;
  return decoration?.color;
}

Duration _animatedContainerDuration(WidgetTester tester, Key key) {
  return _findAnimatedContainer(tester, key).duration;
}

Widget _buildHeaderHarness({
  required Chat chat,
  required ChatState chatState,
  required ConversationViewController controller,
  required bool useCupertino,
  required NavigatorObserver observer,
  Brightness brightness = Brightness.light,
  bool wrapInTabletMode = true,
}) {
  final appBar = useCupertino
      ? PreferredSize(
          preferredSize: const Size.fromHeight(90),
          child: CupertinoHeader(controller: controller),
        )
      : MaterialHeader(controller: controller) as PreferredSizeWidget;

  final scaffold = ChatStateScope(
    chatState: chatState,
    child: Scaffold(
      appBar: appBar,
      body: const SizedBox.expand(),
    ),
  );

  return GetMaterialApp(
    theme: _testTheme(brightness: brightness),
    navigatorObservers: [observer],
    home: wrapInTabletMode
        ? TabletModeWrapper(
            initialRatio: 0.3,
            minRatio: 0.2,
            maxRatio: 0.45,
            left: const SizedBox.expand(),
            right: scaffold,
          )
        : scaffold,
  );
}

_TestFindMyController _putTestFindMyController() {
  final fm = _TestFindMyController();
  Get.put<FindMyController>(fm);
  addTearDown(() {
    if (Get.isRegistered<FindMyController>()) {
      Get.delete<FindMyController>(force: true);
    }
  });
  return fm;
}

void main() {
  late _FakeSettingsService settingsService;

  setUp(() {
    settingsService = _FakeSettingsService()..settings = Settings();
    settingsService.settings.skin.value = Skins.Material;
    settingsService.settings.tabletMode.value = true;
    settingsService.settings.avatarScale.value = 1.0;
    _registerBaseServices(settingsService);
    NavigationSvc.showInspectorDrawer.value = false;
    webHeaderIsWebOverride = true;
  });

  tearDown(() async {
    webHeaderIsWebOverride = null;
    webHeaderDetailsBuilderOverride = null;
    if (Get.isRegistered<FindMyController>()) {
      Get.delete<FindMyController>(force: true);
    }
    GetIt.I<ChatsService>().activeChat = null;
    GetIt.I<ChatsService>().activeChatGuid.value = null;
  });

  group('1. Web duplicate Info button removed & non-web preserved', () {
    testWidgets('Web hides duplicate Info button across Material, Samsung, and Cupertino skins', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      webHeaderIsWebOverride = true;
      _putTestFindMyController();

      for (final skin in [Skins.Material, Skins.Samsung, Skins.iOS]) {
        settingsService.settings.skin.value = skin;
        final chat = _dmChat();
        final chatState = ChatState(chat);
        final controller = ConversationViewController(chat, tag_: 'dup-web-${skin.name}');
        final observer = _RecordingNavigatorObserver();

        await tester.pumpWidget(
          _buildHeaderHarness(
            chat: chat,
            chatState: chatState,
            controller: controller,
            useCupertino: skin == Skins.iOS,
            observer: observer,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.info), findsNothing, reason: 'skin=$skin');
        expect(find.byIcon(Icons.info_outlined), findsNothing, reason: 'skin=$skin');
        expect(find.byIcon(CupertinoIcons.info_circle), findsNothing, reason: 'skin=$skin');
        expect(find.byIcon(CupertinoIcons.info_circle_fill), findsNothing, reason: 'skin=$skin');
        expect(find.byTooltip('Show chat details (Alt+I)'), findsNothing, reason: 'skin=$skin');
        expect(find.byTooltip('Hide chat details (Alt+I)'), findsNothing, reason: 'skin=$skin');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });

    testWidgets('Non-web desktop keeps Info button and toggles inspector', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      webHeaderIsWebOverride = false;
      _putTestFindMyController();

      // Material / Samsung desktop Info button
      settingsService.settings.skin.value = Skins.Material;
      final matChat = _dmChat();
      final matController = ConversationViewController(matChat, tag_: 'desktop-mat');
      await tester.pumpWidget(
        _buildHeaderHarness(
          chat: matChat,
          chatState: ChatState(matChat),
          controller: matController,
          useCupertino: false,
          observer: _RecordingNavigatorObserver(),
        ),
      );
      await tester.pumpAndSettle();

      if (kIsDesktop) {
        expect(find.byIcon(Icons.info_outlined), findsOneWidget);
        await tester.tap(find.byIcon(Icons.info_outlined));
        await tester.pumpAndSettle();
        expect(NavigationSvc.showInspectorDrawer.value, isTrue);
      }

      // Cupertino desktop Info button
      NavigationSvc.showInspectorDrawer.value = false;
      settingsService.settings.skin.value = Skins.iOS;
      final iosChat = _dmChat(address: '+15552223333');
      final iosController = ConversationViewController(iosChat, tag_: 'desktop-ios');
      await tester.pumpWidget(
        _buildHeaderHarness(
          chat: iosChat,
          chatState: ChatState(iosChat),
          controller: iosController,
          useCupertino: true,
          observer: _RecordingNavigatorObserver(),
        ),
      );
      await tester.pumpAndSettle();

      if (kIsDesktop) {
        expect(find.byIcon(CupertinoIcons.info_circle), findsOneWidget);
        await tester.tap(find.byIcon(CupertinoIcons.info_circle));
        await tester.pumpAndSettle();
        expect(NavigationSvc.showInspectorDrawer.value, isTrue);
      }
    });
  });

  group('2. Web name card click toggles inspector (wide) or opens ConversationDetails (narrow)', () {
    testWidgets('Wide web toggles inspector drawer on name card tap across Material, Samsung, and Cupertino',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      webHeaderIsWebOverride = true;
      _putTestFindMyController();

      for (final skin in [Skins.Material, Skins.Samsung, Skins.iOS]) {
        settingsService.settings.skin.value = skin;
        NavigationSvc.showInspectorDrawer.value = false;
        final chat = _dmChat(address: '+1555000${skin.index}');
        final controller = ConversationViewController(chat, tag_: 'wide-${skin.name}');
        final observer = _RecordingNavigatorObserver();

        await tester.pumpWidget(
          _buildHeaderHarness(
            chat: chat,
            chatState: ChatState(chat),
            controller: controller,
            useCupertino: skin == Skins.iOS,
            observer: observer,
          ),
        );
        await tester.pumpAndSettle();
        final initialRoutes = observer.pushed.length;

        final cardKey = ValueKey(skin == Skins.iOS ? 'cupertino_header_name_card' : 'material_header_name_card');
        await tester.tap(find.byKey(cardKey));
        await tester.pumpAndSettle();
        expect(NavigationSvc.showInspectorDrawer.value, isTrue, reason: 'skin=$skin');
        expect(observer.pushed.length, initialRoutes, reason: 'wide web should toggle inspector, not push route');

        await tester.tap(find.byKey(cardKey));
        await tester.pumpAndSettle();
        expect(NavigationSvc.showInspectorDrawer.value, isFalse, reason: 'skin=$skin');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });

    testWidgets('Narrow web pushes ConversationDetails instead of toggling inspector', (tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      webHeaderIsWebOverride = true;
      webHeaderDetailsBuilderOverride = (chat) => Scaffold(body: Text('details:${chat.guid}'));
      _putTestFindMyController();

      for (final skin in [Skins.Material, Skins.iOS]) {
        settingsService.settings.skin.value = skin;
        NavigationSvc.showInspectorDrawer.value = false;
        final chat = _dmChat(address: '+1555999${skin.index}');
        final controller = ConversationViewController(chat, tag_: 'narrow-${skin.name}');
        final observer = _RecordingNavigatorObserver();

        await tester.pumpWidget(
          _buildHeaderHarness(
            chat: chat,
            chatState: ChatState(chat),
            controller: controller,
            useCupertino: skin == Skins.iOS,
            observer: observer,
          ),
        );
        await tester.pumpAndSettle();
        final initialRoutes = observer.pushed.length;

        final cardKey = ValueKey(skin == Skins.iOS ? 'cupertino_header_name_card' : 'material_header_name_card');
        await tester.tap(find.byKey(cardKey));
        await tester.pumpAndSettle();

        expect(NavigationSvc.showInspectorDrawer.value, isFalse, reason: 'narrow web must not toggle desktop inspector');
        expect(observer.pushed.length, greaterThan(initialRoutes), reason: 'narrow web pushes ConversationDetails');
        expect(find.text('details:${chat.guid}'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  });

  group('3. Tight bounds, cursor, 140ms hover/press transitions & zero double hover', () {
    testWidgets('Material header hugs name card tightly without full-width bleed and isolates location hover/tap',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fm = _putTestFindMyController();
      fm.friends.add(_friend());

      final chat = _dmChat(name: 'Bob');
      final controller = ConversationViewController(chat, tag_: 'mat-hover');
      final observer = _RecordingNavigatorObserver();

      await tester.pumpWidget(
        _buildHeaderHarness(
          chat: chat,
          chatState: ChatState(chat),
          controller: controller,
          useCupertino: false,
          observer: observer,
        ),
      );
      await tester.pumpAndSettle();

      const nameCardKey = ValueKey('material_header_name_card');
      const titleTargetKey = ValueKey('material_header_title_target');
      const locationKey = ValueKey('material_header_location_chip');

      final cardRect = tester.getRect(find.byKey(nameCardKey));
      final chipRect = tester.getRect(find.byKey(locationKey));

      // Tight content-hugging bounds: short name + location chip must not stretch across the 1440px AppBar.
      expect(cardRect.width, lessThan(320));
      expect(chipRect.width, lessThan(260));
      expect(cardRect.height, lessThanOrEqualTo(56));

      // Click cursor check on both hit targets.
      final titleMouse = tester.widget<MouseRegion>(
        find.descendant(of: find.byKey(titleTargetKey), matching: find.byType(MouseRegion)).first,
      );
      final chipMouse = tester.widget<MouseRegion>(
        find.descendant(of: find.byKey(locationKey), matching: find.byType(MouseRegion)).first,
      );
      expect(titleMouse.cursor, SystemMouseCursors.click);
      expect(chipMouse.cursor, SystemMouseCursors.click);

      // Quiet ~140ms transition duration on both surfaces.
      expect(_animatedContainerDuration(tester, nameCardKey), const Duration(milliseconds: 140));
      expect(_animatedContainerDuration(tester, locationKey), const Duration(milliseconds: 140));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      // 1. Hover empty space to the right of the name card -> NO full-width bleed highlight.
      await gesture.moveTo(Offset(cardRect.right + 120, cardRect.center.dy));
      await tester.pumpAndSettle();
      expect(_animatedContainerColor(tester, nameCardKey), Colors.transparent);
      expect(_animatedContainerColor(tester, locationKey), Colors.transparent);

      // 2. Hover name title -> ONLY name card highlights (~7% onSurface); location chip stays transparent.
      final titleCenter = tester.getCenter(find.byKey(titleTargetKey));
      await gesture.moveTo(titleCenter);
      await tester.pumpAndSettle();
      final nameHoverColor = _animatedContainerColor(tester, nameCardKey);
      expect(nameHoverColor, isNotNull);
      expect(nameHoverColor!.a, closeTo(0.07, 0.01));
      expect(_animatedContainerColor(tester, locationKey), Colors.transparent);

      // 3. Move onto location chip -> ONLY location chip highlights; name card clears (zero double hover).
      final chipCenter = tester.getCenter(find.byKey(locationKey));
      await gesture.moveTo(chipCenter);
      await tester.pumpAndSettle();
      expect(_animatedContainerColor(tester, nameCardKey), Colors.transparent);
      final chipHoverColor = _animatedContainerColor(tester, locationKey);
      expect(chipHoverColor, isNotNull);
      expect(chipHoverColor!.a, closeTo(0.07, 0.01));

      // 4. Press location chip -> deeper ~11% tint while name card stays transparent.
      await gesture.down(chipCenter);
      await tester.pumpAndSettle();
      final chipPressColor = _animatedContainerColor(tester, locationKey);
      expect(chipPressColor!.a, closeTo(0.11, 0.01));
      expect(_animatedContainerColor(tester, nameCardKey), Colors.transparent);
      await gesture.up();
      await tester.pumpAndSettle();

      // Tapping location chip opened Find My without toggling Details inspector.
      expect(fm.openCalls, 1);
      expect(fm.openedChat?.guid, chat.guid);
      expect(NavigationSvc.showInspectorDrawer.value, isFalse);

      // 5. Tapping name title toggles Details inspector without triggering Find My again.
      await tester.tapAt(titleCenter);
      await tester.pumpAndSettle();
      expect(NavigationSvc.showInspectorDrawer.value, isTrue);
      expect(fm.openCalls, 1);
    });

    testWidgets('Cupertino header hugs name card & location pill tightly with independent hover and click',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      settingsService.settings.skin.value = Skins.iOS;
      final fm = _putTestFindMyController();
      fm.friends.add(_friend());

      final chat = _dmChat(name: 'Bob');
      final controller = ConversationViewController(chat, tag_: 'ios-hover');

      await tester.pumpWidget(
        _buildHeaderHarness(
          chat: chat,
          chatState: ChatState(chat),
          controller: controller,
          useCupertino: true,
          observer: _RecordingNavigatorObserver(),
        ),
      );
      await tester.pumpAndSettle();

      const nameCardKey = ValueKey('cupertino_header_name_card');
      const locationKey = ValueKey('cupertino_header_location_chip');

      final cardRect = tester.getRect(find.byKey(nameCardKey));
      final chipRect = tester.getRect(find.byKey(locationKey));
      expect(cardRect.width, lessThan(220));
      expect(chipRect.width, lessThan(260));
      expect(cardRect.overlaps(chipRect), isFalse);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      // Hover name card -> location stays unhovered.
      await gesture.moveTo(cardRect.center);
      await tester.pumpAndSettle();
      expect(_animatedContainerColor(tester, nameCardKey)!.a, closeTo(0.07, 0.01));
      expect(_animatedContainerColor(tester, locationKey), Colors.transparent);

      // Hover location pill -> name card clears, location highlights.
      await gesture.moveTo(chipRect.center);
      await tester.pumpAndSettle();
      expect(_animatedContainerColor(tester, nameCardKey), Colors.transparent);
      expect(_animatedContainerColor(tester, locationKey)!.a, closeTo(0.07, 0.01));

      // Click location -> Find My only; click name -> Details inspector only.
      await tester.tap(find.byKey(locationKey));
      await tester.pumpAndSettle();
      expect(fm.openCalls, 1);
      expect(NavigationSvc.showInspectorDrawer.value, isFalse);

      await tester.tap(find.byKey(nameCardKey));
      await tester.pumpAndSettle();
      expect(NavigationSvc.showInspectorDrawer.value, isTrue);
      expect(fm.openCalls, 1);
    });
  });

  group('4. Chat wallpaper crisp white-alpha hover variant', () {
    testWidgets('Custom wallpaper uses white-alpha hover/press tint on Material and Cupertino headers',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fm = _putTestFindMyController();
      fm.friends.add(_friend());

      for (final brightness in [Brightness.light, Brightness.dark]) {
        final chat = _dmChat(name: 'Alice');
        final chatState = ChatState(chat)..customBackgroundPath.value = '/tmp/custom-wallpaper.jpg';
        final controller = ConversationViewController(chat, tag_: 'wall-${brightness.name}');

        await tester.pumpWidget(
          _buildHeaderHarness(
            chat: chat,
            chatState: chatState,
            controller: controller,
            useCupertino: false,
            observer: _RecordingNavigatorObserver(),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();

        const titleTargetKey = ValueKey('material_header_title_target');
        const nameCardKey = ValueKey('material_header_name_card');
        const locationKey = ValueKey('material_header_location_chip');

        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);

        await gesture.moveTo(tester.getCenter(find.byKey(titleTargetKey)));
        await tester.pumpAndSettle();
        final hoverColor = _animatedContainerColor(tester, nameCardKey)!;
        expect(hoverColor.r, closeTo(1.0, 0.01));
        expect(hoverColor.g, closeTo(1.0, 0.01));
        expect(hoverColor.b, closeTo(1.0, 0.01));
        expect(hoverColor.a, greaterThanOrEqualTo(0.10));

        final chipCenter = tester.getCenter(find.byKey(locationKey));
        await gesture.moveTo(chipCenter);
        await tester.pumpAndSettle();
        final chipHover = _animatedContainerColor(tester, locationKey)!;
        expect(chipHover.r, closeTo(1.0, 0.01));
        expect(chipHover.g, closeTo(1.0, 0.01));
        expect(chipHover.b, closeTo(1.0, 0.01));

        await gesture.down(chipCenter);
        await tester.pumpAndSettle();
        final chipPress = _animatedContainerColor(tester, locationKey)!;
        expect(chipPress.a, greaterThan(chipHover.a));
        await gesture.up();
        await tester.pumpAndSettle();

        await gesture.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  });
}
