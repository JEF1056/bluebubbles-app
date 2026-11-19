import 'package:bluebubbles/app/components/custom/custom_cupertino_alert_dialog.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart' hide CupertinoAlertDialog, CupertinoDialogAction;
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

Widget _wrapApp(Widget child, {bool disableAnimations = false, Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF), brightness: brightness),
    ),
    builder: (context, appChild) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
      child: appChild!,
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('showBBDialog Material renders 28dp tonal surface, icon badge, and >=48dp pill CTAs', (tester) async {
    _registerSettings(Skins.Material);
    String? result;

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showBBDialog<String>(
                context: context,
                icon: Icons.info_outline,
                title: 'Delete Thread',
                body: 'This action cannot be undone.',
                actions: [
                  BBDialogAction(text: 'Cancel', onPressed: () => Navigator.of(context, rootNavigator: true).pop('cancel')),
                  BBDialogAction(
                    text: 'Delete',
                    isDefault: true,
                    isDestructive: true,
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop('delete'),
                  ),
                ],
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final alert = tester.widget<AlertDialog>(find.byType(AlertDialog));
    final shape = alert.shape as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(28));
    expect(find.byIcon(Icons.info_outline), findsOneWidget);

    final deleteBtnSize = tester.getSize(find.widgetWithText(FilledButton, 'Delete'));
    final cancelBtnSize = tester.getSize(find.widgetWithText(TextButton, 'Cancel'));
    expect(deleteBtnSize.height, greaterThanOrEqualTo(48));
    expect(cancelBtnSize.height, greaterThanOrEqualTo(48));

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(result, 'delete');
  });

  testWidgets('showBBDialog honors MediaQuery.disableAnimations', (tester) async {
    _registerSettings(Skins.Material);

    await tester.pumpWidget(
      _wrapApp(
        disableAnimations: true,
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showBBDialog<void>(
              context: context,
              title: 'Instant',
              body: 'No animation',
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(find.text('Instant'), findsOneWidget);
    final alert = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(alert.contentPadding, const EdgeInsets.fromLTRB(24, 12, 24, 24));
  });

  testWidgets('showBBDialog iOS renders frosted CupertinoAlertDialog', (tester) async {
    _registerSettings(Skins.iOS);

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showBBDialog<void>(
              context: context,
              title: 'iOS Alert',
              body: 'Frosted glass',
              actions: [
                BBDialogAction(text: 'OK', isDefault: true, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
              ],
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final cupertinoDialog = tester.widget<CupertinoAlertDialog>(find.byType(CupertinoAlertDialog));
    expect(cupertinoDialog.backgroundColor.a, lessThan(1.0));
    expect(find.byType(BackdropFilter), findsAtLeastNWidgets(1));
  });

  testWidgets('showAreYouSure invokes onYes and onNo', (tester) async {
    _registerSettings(Skins.Samsung);
    var confirmed = false;

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAreYouSure(
              context,
              yesIsDestructive: true,
              onNo: () => Navigator.of(context, rootNavigator: true).pop(),
              onYes: () {
                confirmed = true;
                Navigator.of(context, rootNavigator: true).pop();
              },
            ),
            child: const Text('Confirm'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('showBBListSelector returns selected value on Material and iOS', (tester) async {
    _registerSettings(Skins.Material);
    int? selected;

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              selected = await showBBListSelector<int>(
                context: context,
                title: 'Pick one',
                options: const [
                  BBListSelectorOption(label: 'First', value: 1),
                  BBListSelectorOption(label: 'Second', value: 2, isDestructive: true),
                ],
              );
            },
            child: const Text('Select'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ListTile).first).height, greaterThanOrEqualTo(48));

    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(selected, 2);

    // Switch to iOS actionSheet
    SettingsSvc.settings.skin.value = Skins.iOS;
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsOneWidget);
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();
    expect(selected, 1);
  });

  testWidgets('BBProgressDialog renders M3 on Material and frosted Cupertino on iOS', (tester) async {
    _registerSettings(Skins.Material);
    await tester.pumpWidget(_wrapApp(const BBProgressDialog(title: 'Syncing', progress: 0.5)));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    SettingsSvc.settings.skin.value = Skins.iOS;
    await tester.pumpWidget(_wrapApp(const BBProgressDialog(title: 'Syncing')));
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
  });

  testWidgets('showBBBottomSheet renders M3 sheet on Material and frosted sheet on iOS', (tester) async {
    _registerSettings(Skins.Material);
    String? sheetResult;

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              sheetResult = await showBBBottomSheet<String>(
                context: context,
                icon: Icons.tune,
                title: 'Options',
                subtitle: 'Configure chat',
                builder: (ctx) => const Text('Sheet Body'),
                actions: [
                  BBDialogAction(
                    text: 'Apply',
                    isDefault: true,
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop('applied'),
                  ),
                ],
              );
            },
            child: const Text('Sheet'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Options'), findsOneWidget);
    expect(find.text('Configure chat'), findsOneWidget);
    expect(find.text('Sheet Body'), findsOneWidget);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(sheetResult, 'applied');

    // iOS frosted sheet
    SettingsSvc.settings.skin.value = Skins.iOS;
    await tester.tap(find.text('Sheet'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('Sheet Body'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(sheetResult, 'applied');
  });

  testWidgets('showBBInputDialog validates and returns entered text on Material and iOS', (tester) async {
    _registerSettings(Skins.Material);
    String? entered;

    await tester.pumpWidget(
      _wrapApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              entered = await showBBInputDialog(
                context: context,
                title: 'Rename Chat',
                hintText: 'Chat name',
                validator: (val) => (val == null || val.trim().isEmpty) ? 'Required' : null,
              );
            },
            child: const Text('Rename'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    // Empty submit triggers validator error
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Family Group');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(entered, 'Family Group');

    // iOS skin uses CupertinoAlertDialog + CupertinoDialogAction + CupertinoTextField
    SettingsSvc.settings.skin.value = Skins.iOS;
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsOneWidget);
    expect(find.byType(CupertinoDialogAction), findsNWidgets(2));

    await tester.enterText(find.byType(CupertinoTextField), 'iOS Group');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(entered, 'iOS Group');
  });
}
