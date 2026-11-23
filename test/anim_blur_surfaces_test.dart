import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/app/components/avatars/contact_avatar_group_widget.dart';
import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/app/layouts/conversation_list/dialogs/conversation_peek_view.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/cupertino_header.dart'
    as list_cupertino_header;
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/material_header.dart'
    as list_material_header;
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/pinned_tile_text_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/cupertino_header.dart'
    as view_cupertino_header;
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/material_header.dart'
    as view_material_header;
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/ui/route_transition_helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_server_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';

final Uint8List _kSamplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

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

class _FakeSettingsService extends SettingsService {
  _FakeSettingsService({
    int serverVersionCode = 20000,
    int macOSVersion = 15,
  }) : _details = ServerDetails(
          macOSVersion: macOSVersion,
          macOSMinorVersion: 0,
          serverVersion: serverVersionCode >= 20000 ? '2.0.0' : '1.9.0',
          serverVersionCode: serverVersionCode,
          apiVersions: serverVersionCode >= 20000 ? const [1, 2] : const [1],
        );

  final ServerDetails _details;

  @override
  ServerDetails get serverDetails => _details;
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

  @override
  Future<void> setLastOpenedChat(String? guid) async {}

  @override
  Future<void> clearLastOpenedChat() async {}
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    theme = _FakePrefsThemeActions(this);
    server = _FakePrefsServerActions(this);
    messaging = _FakePrefsMessagingActions(this);
  }
}

void _registerCoreServices() {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    final svc = _FakeSettingsService()..settings = _TestSettings();
    GetIt.I.registerSingleton<SettingsService>(svc);
  }
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
  if (!GetIt.I.isRegistered<SocketService>()) {
    GetIt.I.registerSingleton<SocketService>(SocketService());
  }
  if (!GetIt.I.isRegistered<HttpService>()) {
    GetIt.I.registerSingleton<HttpService>(HttpService());
  }
  if (!GetIt.I.isRegistered<StickerLibraryService>()) {
    GetIt.I.registerSingleton<StickerLibraryService>(StickerLibraryService()..useMemoryCache = true);
  }
  if (!GetIt.I.isRegistered<CustomGroupsService>()) {
    GetIt.I.registerSingleton<CustomGroupsService>(CustomGroupsService());
  }
}

int _activeBackdropFilterCount(WidgetTester tester) {
  return tester
      .widgetList<BackdropFilter>(find.byType(BackdropFilter))
      .where((w) => w.enabled)
      .length;
}

class _MountCounterChild extends StatefulWidget {
  final VoidCallback onInit;
  const _MountCounterChild({required this.onInit});

  @override
  State<_MountCounterChild> createState() => _MountCounterChildState();
}

class _MountCounterChildState extends State<_MountCounterChild> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 40, height: 40);
}

void main() {
  setUp(() async {
    Get.reset();
    await GetIt.I.reset();
    _registerCoreServices();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await GetIt.I.reset();
    Get.reset();
  });

  group('P0-3: Transitioning headers use RouteSettledBackdropFilter & avoid Opacity saveLayer', () {
    testWidgets('RouteSettledBackdropFilter toggles BackdropFilter.enabled without remounting stateful child',
        (tester) async {
      var initCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).push(
                    PageRouteBuilder<void>(
                      transitionDuration: const Duration(milliseconds: 300),
                      pageBuilder: (_, _, _) => Scaffold(
                        body: RouteSettledBackdropFilter(
                          filter: ColorFilter.mode(Colors.transparent, BlendMode.dst),
                          child: _MountCounterChild(onInit: () => initCount++),
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('Push Filter'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Push Filter'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(initCount, 1);
      expect(_activeBackdropFilterCount(tester), 0);

      // Settle route -> blur enables without remounting child.
      await tester.pump(const Duration(milliseconds: 300));
      expect(initCount, 1);
      expect(_activeBackdropFilterCount(tester), 1);

      // Start pop -> blur disables without remounting child.
      Navigator.of(tester.element(find.byType(RouteSettledBackdropFilter))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(initCount, 1);
      expect(_activeBackdropFilterCount(tester), 0);

      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('conversation_view CupertinoHeader & MaterialHeader suppress blur mid-transition and restore when settled',
        (tester) async {
      SettingsSvc.settings.skin.value = Skins.iOS;
      SettingsSvc.settings.highPerfMode.value = false;
      SettingsSvc.settings.skin.value = Skins.iOS;

      final chat = Chat(guid: 'iMessage;-;+14085550100', chatIdentifier: '+14085550100');
      final cvController = ConversationViewController(chat, tag_: chat.guid);
      Get.put<ConversationViewController>(cvController, tag: chat.guid);
      addTearDown(() async {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        if (Get.isRegistered<FindMyController>()) {
          Get.delete<FindMyController>(force: true);
        }
      });
      final chatState = ChatsSvc.getOrCreateChatState(chat);

      await tester.pumpWidget(
        GetMaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Column(
                children: [
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(ctx).push(
                        PageRouteBuilder<void>(
                          transitionDuration: const Duration(milliseconds: 300),
                          pageBuilder: (_, _, _) => ChatStateScope(
                            chatState: chatState,
                            child: Scaffold(
                              appBar: PreferredSize(
                                preferredSize: const Size.fromHeight(96),
                                child: view_cupertino_header.CupertinoHeader(controller: cvController),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Push Cupertino'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(ctx).push(
                        PageRouteBuilder<void>(
                          transitionDuration: const Duration(milliseconds: 300),
                          pageBuilder: (_, _, _) => ChatStateScope(
                            chatState: chatState,
                            child: Scaffold(
                              appBar: view_material_header.MaterialHeader(controller: cvController),
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Push Material'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Push CupertinoHeader route and inspect mid-transition.
      await tester.tap(find.text('Push Cupertino'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(RouteSettledBackdropFilter), findsOneWidget);
      expect(_activeBackdropFilterCount(tester), 0);

      // Finish transition -> blur restores.
      await tester.pump(const Duration(milliseconds: 300));
      expect(_activeBackdropFilterCount(tester), 1);

      // highPerfMode disables blur even when settled.
      SettingsSvc.settings.highPerfMode.value = true;
      await tester.pump();
      expect(_activeBackdropFilterCount(tester), 0);

      // Pop and test MaterialHeader curved blur.
      Navigator.of(tester.element(find.byType(view_cupertino_header.CupertinoHeader))).pop();
      await tester.pumpAndSettle();

      SettingsSvc.settings.skin.value = Skins.iOS;
      SettingsSvc.settings.highPerfMode.value = false;
      SettingsSvc.settings.skin.value = Skins.Material;
      await tester.tap(find.text('Push Material'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(RouteSettledBackdropFilter), findsOneWidget);
      expect(_activeBackdropFilterCount(tester), 0);

      await tester.pump(const Duration(milliseconds: 300));
      expect(_activeBackdropFilterCount(tester), 1);
    });

    testWidgets('conversation_list MaterialHeader & CupertinoMiniHeader suppress blur mid-transition and avoid Opacity over BackdropFilter',
        (tester) async {
      SettingsSvc.settings.skin.value = Skins.iOS;
      SettingsSvc.settings.highPerfMode.value = false;
      SettingsSvc.settings.skin.value = Skins.iOS;

      final listController = Get.put(ConversationListController(showArchivedChats: false, showUnknownSenders: false));
      addTearDown(() => Get.delete<ConversationListController>(force: true));

      await tester.pumpWidget(
        GetMaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Column(
                children: [
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(ctx).push(
                        PageRouteBuilder<void>(
                          transitionDuration: const Duration(milliseconds: 300),
                          pageBuilder: (_, _, _) => Scaffold(
                            body: Stack(
                              children: [
                                CustomScrollView(
                                  controller: listController.iosScrollController,
                                  slivers: const [
                                    SliverToBoxAdapter(
                                      child: SizedBox(height: 1500),
                                    ),
                                  ],
                                ),
                                list_cupertino_header.CupertinoMiniHeader(controller: listController),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Push Mini'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(ctx).push(
                        PageRouteBuilder<void>(
                          transitionDuration: const Duration(milliseconds: 300),
                          pageBuilder: (_, _, _) => Scaffold(
                            appBar: PreferredSize(
                              preferredSize: const Size.fromHeight(64),
                              child: list_material_header.MaterialHeader(parentController: listController),
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Push List Material'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Push CupertinoMiniHeader, scroll past 0, and verify no active BackdropFilter mid-transition.
      await tester.tap(find.text('Push Mini'));
      await tester.pump();
      listController.iosScrollController.jumpTo(120);
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(RouteSettledBackdropFilter), findsOneWidget);
      expect(_activeBackdropFilterCount(tester), 0);

      // Settle route -> BackdropFilter restores with NO Opacity ancestor (avoids saveLayer).
      await tester.pump(const Duration(milliseconds: 300));
      expect(_activeBackdropFilterCount(tester), 1);
      expect(
        find.ancestor(of: find.byType(BackdropFilter), matching: find.byType(Opacity)),
        findsNothing,
      );

      // highPerfMode disables blur on CupertinoMiniHeader.
      SettingsSvc.settings.highPerfMode.value = true;
      await tester.pump();
      expect(_activeBackdropFilterCount(tester), 0);

      Navigator.of(tester.element(find.byType(list_cupertino_header.CupertinoMiniHeader))).pop();
      await tester.pumpAndSettle();

      // Push conversation_list MaterialHeader -> mid-transition suppresses blur, settled restores.
      SettingsSvc.settings.skin.value = Skins.iOS;
      SettingsSvc.settings.highPerfMode.value = false;
      await tester.tap(find.text('Push List Material'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(RouteSettledBackdropFilter), findsOneWidget);
      expect(_activeBackdropFilterCount(tester), 0);

      await tester.pump(const Duration(milliseconds: 300));
      expect(_activeBackdropFilterCount(tester), 1);
    });
  });

  group('P1-1: Call screens wrap full-screen avatar blur in RepaintBoundary with cacheWidth: 96', () {
    testWidgets('InAppCallScreen wraps ImageFiltered in RepaintBoundary and sets cacheWidth: 96', (tester) async {
      final controller = ActiveCallController();
      addTearDown(controller.dispose);
      controller.startOutgoing(
        callUuid: 'call-blur-1',
        callerName: 'Maya Lin',
        avatarBytes: _kSamplePng,
        isVideo: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: InAppCallScreen(controller: controller),
        ),
      );
      await tester.pump();

      final filteredFinder = find.byType(ImageFiltered);
      expect(filteredFinder, findsOneWidget);
      expect(
        find.ancestor(of: filteredFinder, matching: find.byType(RepaintBoundary)),
        findsAtLeastNWidgets(1),
      );

      final imageFinder = find.descendant(of: filteredFinder, matching: find.byType(Image));
      expect(imageFinder, findsOneWidget);
      final imageWidget = tester.widget<Image>(imageFinder);
      expect(imageWidget.image, isA<ResizeImage>());
      expect((imageWidget.image as ResizeImage).width, 96);
    });

    testWidgets('IncomingFaceTimeScreen wraps ImageFiltered in RepaintBoundary and sets cacheWidth: 96', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: IncomingFaceTimeScreen(
                callUuid: 'call-blur-2',
                callerName: 'Maya Lin',
                avatarBytes: _kSamplePng,
                isAudio: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final filteredFinder = find.byType(ImageFiltered);
      expect(filteredFinder, findsOneWidget);
      expect(
        find.ancestor(of: filteredFinder, matching: find.byType(RepaintBoundary)),
        findsAtLeastNWidgets(1),
      );

      final imageFinder = find.descendant(of: filteredFinder, matching: find.byType(Image));
      expect(imageFinder, findsOneWidget);
      final imageWidget = tester.widget<Image>(imageFinder);
      expect(imageWidget.image, isA<ResizeImage>());
      expect((imageWidget.image as ResizeImage).width, 96);
    });
  });

  group('P1-2: MessagePopup & ConversationPeekView cap backdrop sigma, wrap in RepaintBoundary, drop nested blurs', () {
    testWidgets('iOS MessagePopup has single RepaintBoundary-wrapped BackdropFilter with sigma <= 20', (tester) async {
      SettingsSvc.settings.skin.value = Skins.iOS;
      SettingsSvc.settings.skin.value = Skins.iOS;
      SettingsSvc.settings.highPerfMode.value = false;
      SettingsSvc.settings.enablePrivateAPI.value = true;

      final chat = Chat(guid: 'iMessage;-;+14085550199', chatIdentifier: '+14085550199');
      final service = ensureMessagesSvc(chat.guid);
      final cvController = ConversationViewController(chat, tag_: chat.guid);
      Get.put<ConversationViewController>(cvController, tag: chat.guid);
      addTearDown(() async {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      });

      final msg = Message.fromMap({
        'guid': 'popup-blur-msg',
        'text': 'Hello',
        'service': 'iMessage',
        'dateCreated': DateTime(2026, 11, 22, 10, 0).millisecondsSinceEpoch,
        'isFromMe': false,
        'handleId': 1,
        'hasAttachments': false,
      });
      service.struct.addMessages([msg]);
      final msgState = service.getOrCreateState(msg);
      final chatState = ChatsSvc.getOrCreateChatState(chat);

      await tester.pumpWidget(
        GetMaterialApp(
          home: ChatStateScope(
            chatState: chatState,
            child: Builder(
              builder: (ctx) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).push(
                      PageRouteBuilder<void>(
                        opaque: false,
                        pageBuilder: (_, _, _) => MessagePopup(
                          childPosition: const Offset(20, 260),
                          size: const Size(160, 44),
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
                          child: const SizedBox(width: 160, height: 44, child: Text('Hello')),
                        ),
                      ),
                    );
                  },
                  child: const Text('Open Popup'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Popup'));
      await tester.pumpAndSettle();

      // Only the full-screen backdrop has a BackdropFilter; nested tapback pill, add-emoji circle, and details menu have none.
      final backdropFinder = find.descendant(
        of: find.byType(MessagePopup),
        matching: find.byType(BackdropFilter),
      );
      expect(backdropFinder, findsOneWidget);
      expect(
        find.ancestor(of: backdropFinder, matching: find.byType(RepaintBoundary)),
        findsAtLeastNWidgets(1),
      );
      final filterStr = tester.widget<BackdropFilter>(backdropFinder).filter.toString();
      expect(filterStr, contains('18.0'));
      expect(filterStr, isNot(contains('30.0')));
    });

    testWidgets('ConversationPeekView has single RepaintBoundary-wrapped BackdropFilter with sigma <= 20', (tester) async {
      final chat = Chat(guid: 'iMessage;-;+14085550155', chatIdentifier: '+14085550155');
      final chatState = ChatsSvc.getOrCreateChatState(chat);
      addTearDown(() async {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      });

      await tester.pumpWidget(
        GetMaterialApp(
          home: ChatStateScope(
            chatState: chatState,
            child: Scaffold(
              body: ConversationPeekView(
                position: const Offset(20, 120),
                chat: chat,
                messages: const [],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final backdropFinder = find.descendant(
        of: find.byType(ConversationPeekView),
        matching: find.byType(BackdropFilter),
      );
      expect(backdropFinder, findsOneWidget);
      expect(
        find.ancestor(of: backdropFinder, matching: find.byType(RepaintBoundary)),
        findsAtLeastNWidgets(1),
      );
      final filterStr = tester.widget<BackdropFilter>(backdropFinder).filter.toString();
      expect(filterStr, contains('18.0'));
      expect(filterStr, isNot(contains('30.0')));
    });
  });

  group('P1-4: FindMy uses RouteSettledBackdropFilter & defers initial auto-fit until route settles', () {
    testWidgets('FindMyPage suppresses its 3 blurs and initial auto-fit mid-transition, restores both when settled',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      SettingsSvc.settings.skin.value = Skins.iOS;
      SettingsSvc.settings.highPerfMode.value = false;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;

      final streamController = StreamController<Position>.broadcast();
      final now = DateTime(2026, 11, 22, 12, 0);
      final userPos = Position(
        longitude: -122.4194,
        latitude: 37.7749,
        timestamp: now,
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
      final ctrl = Get.put(FindMyController(
        autoFetch: false,
        fetchCurrentPosition: () async => userPos,
        positionStream: () => streamController.stream,
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async => Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
          statusCode: 200,
          data: {'data': []},
        ),
        refreshDevicesRequest: ({deviceId, force = false}) async => Response(
          requestOptions: RequestOptions(path: '/icloud/findmy/devices/refresh'),
          statusCode: 200,
          data: {'data': []},
        ),
      )..isBackgroundShared = true);

      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await streamController.close();
        if (Get.isRegistered<FindMyController>()) {
          Get.delete<FindMyController>(force: true);
        }
      });

      final zoomBeforePush = ctrl.cameraZoom.value;

      await tester.pumpWidget(
        GetMaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).push(
                    PageRouteBuilder<void>(
                      transitionDuration: const Duration(milliseconds: 300),
                      pageBuilder: (_, _, _) => const FindMyPage(),
                    ),
                  );
                },
                child: const Text('Open FindMy'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open FindMy'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      // Mid-transition: all 3 RouteSettledBackdropFilters suppress BackdropFilter and auto-fit is deferred.
      expect(find.byType(RouteSettledBackdropFilter), findsNWidgets(3));
      expect(_activeBackdropFilterCount(tester), 0);
      expect(ctrl.cameraZoom.value, zoomBeforePush);
      expect(ctrl.hasMovedToCurrentLocation.value, isFalse);

      // Route settles -> all 3 blurs restore and initial auto-fit runs.
      await tester.pump(const Duration(milliseconds: 350));
      expect(_activeBackdropFilterCount(tester), 3);
      expect(ctrl.hasMovedToCurrentLocation.value, isTrue);
      expect(ctrl.cameraZoom.value, greaterThanOrEqualTo(15.5));

      // Pop FindMyPage mid-animation and confirm clean disposal.
      Navigator.of(tester.element(find.byType(FindMyPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  });

  group('Web / highPerfMode P2 tile blur guard', () {
    testWidgets('ContactAvatarGroupWidget skips BackdropFilter when highPerfMode is true', (tester) async {
      final handles = List.generate(
        6,
        (i) => Handle(address: '+1408555010$i'),
      );

      SettingsSvc.settings.skin.value = Skins.iOS;
      SettingsSvc.settings.highPerfMode.value = false;
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: ContactAvatarGroupWidget(handles: handles, size: 50, editable: false),
          ),
        ),
      );
      await tester.pump();
      if (!kIsWeb) {
        expect(
          find.descendant(of: find.byType(ContactAvatarGroupWidget), matching: find.byType(BackdropFilter)),
          findsOneWidget,
        );
      }

      SettingsSvc.settings.highPerfMode.value = true;
      await tester.pump();
      expect(
        find.descendant(of: find.byType(ContactAvatarGroupWidget), matching: find.byType(BackdropFilter)),
        findsNothing,
      );
    });

    testWidgets('PinnedTileTextBubble skips BackdropFilter when highPerfMode is true', (tester) async {
      final chat = Chat(guid: 'iMessage;-;+14085550188', chatIdentifier: '+14085550188', hasUnreadMessage: true);
      final chatState = ChatsSvc.getOrCreateChatState(chat);
      chatState.hasUnreadMessage.value = true;
      chatState.subtitle.value = 'Pinned preview';
      chatState.latestMessage.value = Message.fromMap({
        'guid': 'pinned-msg-1',
        'text': 'Pinned preview',
        'service': 'iMessage',
        'dateCreated': DateTime(2026, 11, 22, 11, 0).millisecondsSinceEpoch,
        'isFromMe': false,
        'handleId': 1,
        'hasAttachments': false,
      });

      final listController = Get.put(ConversationListController(showArchivedChats: false, showUnknownSenders: false));
      addTearDown(() => Get.delete<ConversationListController>(force: true));
      final tileController = ConversationTileController(
        chatState: chatState,
        listController: listController,
      );
      addTearDown(tileController.dispose);

      SettingsSvc.settings.skin.value = Skins.iOS;
      SettingsSvc.settings.highPerfMode.value = false;
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: PinnedTileTextBubble(
              chat: chat,
              size: 80,
              parentController: tileController,
            ),
          ),
        ),
      );
      await tester.pump();
      if (!kIsWeb) {
        expect(
          find.descendant(of: find.byType(PinnedTileTextBubble), matching: find.byType(BackdropFilter)),
          findsOneWidget,
        );
      }

      SettingsSvc.settings.highPerfMode.value = true;
      await tester.pump();
      expect(
        find.descendant(of: find.byType(PinnedTileTextBubble), matching: find.byType(BackdropFilter)),
        findsNothing,
      );
    });
  });
}
