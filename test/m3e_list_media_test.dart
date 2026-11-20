import 'dart:io';

import 'package:bluebubbles/app/components/m3e/m3e.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/material_header.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/material_conversation_tile.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_image.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
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

void _registerServices(_FakeSettingsService settingsService) {
  Get.testMode = true;
  if (GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.unregister<SettingsService>();
  }
  GetIt.I.registerSingleton<SettingsService>(settingsService);
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
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
}

void main() {
  late _FakeSettingsService settingsService;

  setUp(() {
    settingsService = _FakeSettingsService()..settings = Settings();
    settingsService.settings.skin.value = Skins.Material;
    _registerServices(settingsService);
  });

  test('M3E motion and shape tokens expose P1-1 and P1-2 symbols', () {
    expect(M3EMotion.spatialOvershoot, const Cubic(0.38, 1.21, 0.22, 1.0));
    expect(M3EMotion.springSpatialFast.stiffness, 800);
    expect(M3EMotion.springSpatialDefault.stiffness, 380);
    expect(M3EMotion.springSpatialSlow.stiffness, 200);
    expect(M3EMotion.springEffectsFast.stiffness, 3800);
    expect(M3EMotion.springEffectsDefault.stiffness, 1600);
    expect(M3EMotion.springEffectsSlow.stiffness, 800);
    expect(M3EMotion.springSlow.duration.inMilliseconds, greaterThan(400));

    expect(M3EShapes.lgIncreased, 20);
    expect(M3EShapes.xlIncreased, 32);
    expect(M3EShapes.radiusLgIncreased, const BorderRadius.all(Radius.circular(20)));
    expect(M3EShapes.radiusXlIncreased, const BorderRadius.all(Radius.circular(32)));
  });

  testWidgets('MaterialHeader renders top OpenSearchBar trigger and switches to selection bar', (tester) async {
    final controller = ConversationListController(showArchivedChats: false, showUnknownSenders: false);

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: MaterialHeader(parentController: controller),
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search BlueBubbles'), findsOneWidget);
    expect(find.byTooltip('Search'), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);

    controller.selectedChats.add(Chat(guid: 'chat-1', chatIdentifier: 'chat-1'));
    controller.updateSelectedChats();
    await tester.pumpAndSettle();

    expect(find.text('Search BlueBubbles'), findsNothing);
    expect(find.text('1'), findsOneWidget);

    controller.materialScrollController.dispose();
    controller.iosScrollController.dispose();
    controller.samsungScrollController.dispose();
  });

  testWidgets('MaterialConversationTile applies 20dp->9999 pill radius, 11sp unread badge, and 8dp unread dot',
      (tester) async {
    final chat = Chat(guid: 'chat-tile-1', chatIdentifier: 'chat-tile-1', displayName: 'Alice')
      ..hasUnreadMessage = true;
    final listController = ConversationListController(showArchivedChats: false, showUnknownSenders: false);
    final chatState = ChatsSvc.getOrCreateChatState(chat)..hasUnreadMessage.value = true;
    final tileController = ConversationTileController(
      chatState: chatState,
      listController: listController,
      subtitle: const Text('Hey there'),
    );

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: MaterialConversationTile(parentController: tileController),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final badgeText = tester.widget<Text>(find.text('1'));
    expect(badgeText.style?.fontSize, 11);
    expect(badgeText.style?.fontWeight, FontWeight.w600);

    final animatedContainer = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer).first);
    final decoration = animatedContainer.decoration! as BoxDecoration;
    expect(decoration.borderRadius, M3EShapes.radiusLgIncreased);
    expect(animatedContainer.duration, M3EMotion.spatialFast.duration);

    listController.selectedChats.add(chat);
    tileController.updateWidgets<MaterialConversationTile>(null);
    await tester.pumpAndSettle();

    final selectedContainer = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer).first);
    final selectedDecoration = selectedContainer.decoration! as BoxDecoration;
    expect(selectedDecoration.borderRadius, const BorderRadius.all(Radius.circular(9999)));
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    listController.materialScrollController.dispose();
    listController.iosScrollController.dispose();
    listController.samsungScrollController.dispose();
  });

  testWidgets('FullscreenMediaActionPill renders dark tonal radius-28 pill with Save, Share, Details',
      (tester) async {
    var saved = 0;
    var shared = 0;
    var detailed = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        home: Scaffold(
          body: Center(
            child: FullscreenMediaActionPill(
              onSave: () => saved++,
              onShare: () => shared++,
              onDetails: () => detailed++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final material = tester.widget<Material>(
      find.ancestor(of: find.text('Save'), matching: find.byType(Material)).first,
    );
    expect(material.borderRadius, M3EShapes.radiusXl);

    await tester.tap(find.text('Save'));
    await tester.tap(find.text('Share'));
    await tester.tap(find.text('Details'));
    await tester.pump();

    expect(saved, 1);
    expect(shared, 1);
    expect(detailed, 1);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: FullscreenMediaActionPill(
            onSave: () {},
            onShare: null,
            onDetails: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Share'), findsNothing);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
  });
}
