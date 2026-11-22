import 'package:bluebubbles/app/components/custom/custom_cupertino_alert_dialog.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/timeframe_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_icon_bar.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _FakeSettingsService extends SettingsService {}

void _registerSettings(Skins skin) {
  Get.testMode = true;
  if (GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.unregister<SettingsService>();
  }
  final svc = _FakeSettingsService()..settings = Settings();
  svc.settings.skin.value = skin;
  GetIt.I.registerSingleton<SettingsService>(svc);
}

Widget _wrapApp(Widget child) {
  return GetMaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF)),
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('showWebAttachmentMenu renders unified Attach dialog and Cancel dismisses', (tester) async {
    _registerSettings(Skins.Material);
    final chat = Chat(guid: 'iMessage;-;+15550001234');
    final controller = ConversationViewController(chat);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
    });

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showWebAttachmentMenu(context, controller),
            child: const Text('Open Menu'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Menu'));
    await tester.pumpAndSettle();

    expect(find.text('Attach'), findsOneWidget);
    expect(find.text('Upload file'), findsOneWidget);
    expect(find.text('GIF'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Handwritten'), findsOneWidget);
    expect(find.text('Send location'), findsOneWidget);

    final alert = tester.widget<AlertDialog>(find.byType(AlertDialog));
    final shape = alert.shape as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(28));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Attach'), findsNothing);
  });

  testWidgets('showTimeframePicker renders presets, returns selected DateTime, and does not mutate defaultTimeframes',
      (tester) async {
    _registerSettings(Skins.Material);
    DateTime? picked;
    final originalKeys = Map<String, int>.from(defaultTimeframes);

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              picked = await showTimeframePicker(
                'Pick date and time',
                context,
                presetsAhead: true,
                additionalTimeframes: const {'2 Days': 48},
              );
            },
            child: const Text('Open Timeframe'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Timeframe'));
    await tester.pumpAndSettle();

    expect(defaultTimeframes, equals(originalKeys));
    expect(find.text('Pick date and time'), findsOneWidget);
    expect(find.text('1 Hour'), findsOneWidget);
    expect(find.text('2 Days'), findsOneWidget);
    expect(find.text('Custom Date'), findsOneWidget);

    final beforeTap = DateTime.now();
    await tester.tap(find.text('1 Hour'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.isAfter(beforeTap.add(const Duration(minutes: 55))), isTrue);
  });

  testWidgets('showTimeframePicker Cancel returns null', (tester) async {
    _registerSettings(Skins.Material);
    DateTime? picked = DateTime(2000);

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              picked = await showTimeframePicker('Schedule', context, presetsAhead: true);
            },
            child: const Text('Open Timeframe'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Timeframe'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });

  testWidgets('showTimeframePicker renders frosted CupertinoAlertDialog on iOS skin', (tester) async {
    _registerSettings(Skins.iOS);
    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showTimeframePicker('Schedule', context, presetsAhead: true),
            child: const Text('Open iOS Timeframe'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open iOS Timeframe'));
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.text('1 Hour'), findsOneWidget);
    expect(find.text('Custom Date'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
