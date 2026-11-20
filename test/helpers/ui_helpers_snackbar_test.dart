import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _FakeSettingsService extends SettingsService {}

void main() {
  setUp(() {
    Get.testMode = true;
    if (GetIt.I.isRegistered<SettingsService>()) {
      GetIt.I.unregister<SettingsService>();
    }
    GetIt.I.registerSingleton<SettingsService>(_FakeSettingsService()..settings = Settings());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('PonnamKarthik/fluttertoast'), null);
    Get.reset();
    if (GetIt.I.isRegistered<SettingsService>()) {
      GetIt.I.unregister<SettingsService>();
    }
  });

  test('shouldUseNativeErrorToast routes only native mobile errors to Fluttertoast', () {
    // Regression: on web, showSnackbar and showToast previously disagreed and ping-ponged infinitely.
    expect(shouldUseNativeErrorToast(isWeb: true, isDesktop: false, isError: true), isFalse);
    expect(shouldUseNativeErrorToast(isWeb: true, isDesktop: false, isError: false), isFalse);
    expect(shouldUseNativeErrorToast(isWeb: false, isDesktop: true, isError: true), isFalse);
    expect(shouldUseNativeErrorToast(isWeb: false, isDesktop: true, isError: false), isFalse);
    expect(shouldUseNativeErrorToast(isWeb: false, isDesktop: false, isError: false), isFalse);
    expect(shouldUseNativeErrorToast(isWeb: false, isDesktop: false, isError: true), isTrue);
  });

  testWidgets('showToast(isError: false) routes to Get.snackbar without recursing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox.shrink())));

      await showToast('Saved changes', isError: false);
      await tester.pump();
      expect(find.text('Saved changes'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('showSnackbar(error) on mobile calls Fluttertoast once without recursing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final toastCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('PonnamKarthik/fluttertoast'), (call) async {
        toastCalls.add('${call.method}:${(call.arguments as Map)['msg']}');
        return true;
      });

      await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox.shrink())));
      showSnackbar('Error', 'Mobile toast error', type: SnackbarType.error);
      await tester.pump();

      expect(toastCalls, ['showToast:Mobile toast error']);
      await tester.pump(const Duration(seconds: 2));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
