import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/conversation_list_fab.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/header_widgets.dart';
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

  testWidgets('Material lower FAB bar right-aligns Start chat with Find My and moves Search out of FAB',
      (tester) async {
    final controller = ConversationListController(showArchivedChats: false, showUnknownSenders: false);

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
          floatingActionButton: ConversationListFAB(parentController: controller),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scaffoldRect = tester.getRect(find.byType(Scaffold));
    final searchFinder = find.byTooltip('Search');
    final composeFinder = find.byTooltip('Start chat');
    final findMyFinder = find.byTooltip('Find My');

    expect(searchFinder, findsNothing);
    expect(composeFinder, findsOneWidget);
    expect(findMyFinder, findsOneWidget);

    // Extended state: Find My sits to the left of right-aligned Start chat.
    final composeRect = tester.getRect(composeFinder);
    final findMyRect = tester.getRect(findMyFinder);
    expect(findMyRect.right, lessThan(composeRect.left));
    expect(composeRect.right, closeTo(scaffoldRect.right - 24, 1.0));

    // Collapsed (on scroll): Start chat becomes a 56x56 circle with the icon dead center and ScrollToTop aligned above.
    controller.showMaterialFABText = false;
    controller.updateMaterialFAB();
    await tester.pumpAndSettle();

    final collapsedComposeRect = tester.getRect(composeFinder);
    final chatIconRect = tester.getRect(find.byIcon(Icons.chat_outlined));
    final scrollTopRect = tester.getRect(find.byIcon(Icons.arrow_upward));

    expect(collapsedComposeRect.size, const Size(56, 56));
    expect(collapsedComposeRect.right, closeTo(scaffoldRect.right - 24, 1.0));
    expect((chatIconRect.center.dx - collapsedComposeRect.center.dx).abs(), lessThan(0.01));
    expect((chatIconRect.center.dy - collapsedComposeRect.center.dy).abs(), lessThan(0.01));
    expect((scrollTopRect.center.dx - collapsedComposeRect.center.dx).abs(), lessThan(0.01));

    controller.materialScrollController.dispose();
    controller.iosScrollController.dispose();
    controller.samsungScrollController.dispose();
  });

  testWidgets('MaterialAvatarMenu omits Find My on Material skin unless extraItems is true, and keeps it on Samsung',
      (tester) async {
    Future<void> openMenu({required Skins skin, required bool extraItems}) async {
      settingsService.settings.skin.value = skin;
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          theme: ThemeData(useMaterial3: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(0.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: MaterialAvatarMenu(controller: null, extraItems: extraItems),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MaterialAvatarMenu));
      await tester.pumpAndSettle();
    }

    await openMenu(skin: Skins.Material, extraItems: false);
    expect(find.text('Find My'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);

    await openMenu(skin: Skins.Material, extraItems: true);
    expect(find.text('Find My'), findsOneWidget);

    await openMenu(skin: Skins.Samsung, extraItems: false);
    expect(find.text('Find My'), findsOneWidget);
  });
}
