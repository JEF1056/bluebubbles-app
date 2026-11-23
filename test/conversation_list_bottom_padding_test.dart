import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/cupertino_conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/material_conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/samsung_conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/cupertino_conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/material_conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/samsung_conversation_tile.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

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

void _registerServices(_FakeSettingsService settingsService, ChatsService chatsService) {
  Get.testMode = true;
  if (GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.unregister<SettingsService>();
  }
  GetIt.I.registerSingleton<SettingsService>(settingsService);
  if (GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.unregister<ChatsService>();
  }
  GetIt.I.registerSingleton<ChatsService>(chatsService);
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (!GetIt.I.isRegistered<ThemesService>()) {
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  }
  if (!GetIt.I.isRegistered<SyncService>()) {
    GetIt.I.registerSingleton<SyncService>(SyncService());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
  if (!GetIt.I.isRegistered<CustomGroupsService>()) {
    GetIt.I.registerSingleton<CustomGroupsService>(CustomGroupsService());
  }
}

void _populateChats(ChatsService chatsService, {int count = 20}) {
  chatsService.loadedFirstChatBatch.value = true;
  for (var i = 0; i < count; i++) {
    final chat = Chat(
      guid: 'any;-;+1555000${i.toString().padLeft(4, '0')}',
      chatIdentifier: '+1555000${i.toString().padLeft(4, '0')}',
      displayName: 'Chat $i',
    );
    chatsService.allChats.add(chat);
    chatsService.getOrCreateChatState(chat);
  }
}

void main() {
  late _FakeSettingsService settingsService;
  late ChatsService chatsService;

  setUp(() {
    settingsService = _FakeSettingsService()..settings = Settings();
    settingsService.settings.showCustomGroupFilterChips.value = false;
    chatsService = ChatsService();
    _registerServices(settingsService, chatsService);
    _populateChats(chatsService);
  });

  void configureEdgeToEdgeView(WidgetTester tester, {double bottomInset = 34}) {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(top: 48, bottom: bottomInset);
    tester.view.viewPadding = FakeViewPadding(top: 48, bottom: bottomInset);
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.reset();
    });
  }

  testWidgets('MaterialConversationList bottoms out at system nav inset without extra 88dp FAB gap', (tester) async {
    configureEdgeToEdgeView(tester, bottomInset: 34);
    settingsService.settings.skin.value = Skins.Material;
    final controller = ConversationListController(showArchivedChats: false, showUnknownSenders: false);
    addTearDown(() {
      controller.materialScrollController.dispose();
      controller.iosScrollController.dispose();
      controller.samsungScrollController.dispose();
    });

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MaterialConversationList(parentController: controller),
      ),
    );
    await tester.pumpAndSettle();

    controller.materialScrollController.jumpTo(controller.materialScrollController.position.maxScrollExtent);
    await tester.pumpAndSettle();

    final lastTile = find.byType(MaterialConversationTile).last;
    expect(tester.getRect(lastTile).bottom, closeTo(800 - 34, 1.0));
  });

  testWidgets('CupertinoConversationList bottoms out at system nav inset without extra 36dp spacer', (tester) async {
    configureEdgeToEdgeView(tester, bottomInset: 34);
    settingsService.settings.skin.value = Skins.iOS;
    final controller = ConversationListController(showArchivedChats: false, showUnknownSenders: false);
    addTearDown(() {
      controller.materialScrollController.dispose();
      controller.iosScrollController.dispose();
      controller.samsungScrollController.dispose();
    });

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: CupertinoConversationList(parentController: controller),
      ),
    );
    await tester.pumpAndSettle();

    controller.iosScrollController.jumpTo(controller.iosScrollController.position.maxScrollExtent);
    await tester.pumpAndSettle();

    final lastTile = find.byType(CupertinoConversationTile).last;
    expect(tester.getRect(lastTile).bottom, closeTo(800 - 34, 1.0));
  });

  testWidgets('SamsungConversationList bottoms out at system nav inset without extra 15dp padding', (tester) async {
    configureEdgeToEdgeView(tester, bottomInset: 34);
    settingsService.settings.skin.value = Skins.Samsung;
    final controller = ConversationListController(showArchivedChats: false, showUnknownSenders: false);
    addTearDown(() {
      controller.materialScrollController.dispose();
      controller.iosScrollController.dispose();
      controller.samsungScrollController.dispose();
    });

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: SamsungConversationList(parentController: controller),
      ),
    );
    await tester.pumpAndSettle();

    controller.samsungScrollController.jumpTo(controller.samsungScrollController.position.maxScrollExtent);
    await tester.pumpAndSettle();

    final lastTile = find.byType(SamsungConversationTile).last;
    expect(tester.getRect(lastTile).bottom, closeTo(800 - 34, 1.0));
  });
}
