import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/delivered_indicator.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _FakeLogger extends BaseLogger {
  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

void main() {
  late SettingsService settingsService;

  setUpAll(() {
    Get.testMode = true;
    if (!GetIt.I.isRegistered<FilesystemService>()) {
      final fs = FilesystemService()..appDocDir = Directory.systemTemp;
      GetIt.I.registerSingleton<FilesystemService>(fs);
    }
    if (!GetIt.I.isRegistered<BaseLogger>()) {
      GetIt.I.registerSingleton<BaseLogger>(_FakeLogger());
    }
    if (!GetIt.I.isRegistered<LifecycleService>()) {
      GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
    }
    if (!GetIt.I.isRegistered<ChatsService>()) {
      GetIt.I.registerSingleton<ChatsService>(ChatsService());
    }
    if (!GetIt.I.isRegistered<ThemesService>()) {
      GetIt.I.registerSingleton<ThemesService>(ThemesService());
    }
    settingsService = SettingsService()..settings = Settings();
    if (GetIt.I.isRegistered<SettingsService>()) {
      GetIt.I.unregister<SettingsService>();
    }
    GetIt.I.registerSingleton<SettingsService>(settingsService);
  });

  tearDown(() {
    Get.reset();
  });

  testWidgets('DeliveredIndicator shows Notify Anyway for quietly delivered unread outgoing message',
      (tester) async {
    settingsService.settings.skin.value = Skins.Material;
    settingsService.settings.showDeliveryTimestamps.value = false;

    final tDelivered = DateTime.now().subtract(const Duration(minutes: 5));
    final state = MessageState(Message(
      guid: 'm-quiet-1',
      text: 'Quiet',
      isFromMe: true,
      dateCreated: tDelivered,
      dateDelivered: tDelivered,
      wasDeliveredQuietly: true,
      didNotifyRecipient: false,
    ))
      ..showDeliveredIndicator.value = true;

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MessageStateScope(
          messageState: state,
          child: const Scaffold(
            body: DeliveredIndicator(forceShow: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Notify Anyway'), findsOneWidget);
    expect(find.textContaining('has notifications silenced'), findsNothing);

    // Updating didNotifyRecipient hides Notify Anyway.
    state.updateDidNotifyRecipientInternal(true);
    await tester.pumpAndSettle();
    expect(find.text('Notify Anyway'), findsNothing);

    // Reset and verify dateRead also hides Notify Anyway.
    state.didNotifyRecipient.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Notify Anyway'), findsOneWidget);

    state.updateDateReadInternal(DateTime.now());
    await tester.pumpAndSettle();
    expect(find.text('Notify Anyway'), findsNothing);
  });
}
