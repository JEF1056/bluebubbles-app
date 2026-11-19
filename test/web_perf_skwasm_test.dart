import 'package:bluebubbles/app/components/wallpaper/dynamic_wallpaper_view.dart';
import 'package:bluebubbles/app/components/wallpaper/moving_background_wallpaper.dart';
import 'package:bluebubbles/app/components/wallpaper/particles_wallpaper.dart';
import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  group('Wave 5 Skwasm perf helpers', () {
    test('effectiveBlurSigma caps blur at 8.0 on web only', () {
      expect(MovingBackgroundWallpaperDefinition.effectiveBlurSigma(15.0, isWeb: true), 8.0);
      expect(MovingBackgroundWallpaperDefinition.effectiveBlurSigma(4.0, isWeb: true), 4.0);
      expect(MovingBackgroundWallpaperDefinition.effectiveBlurSigma(15.0, isWeb: false), 15.0);
    });

    test('effectiveCount caps particle count on low-core web only', () {
      expect(
        ParticlesWallpaperDefinition.effectiveCount(120, isWeb: true, hardwareConcurrency: 2),
        45,
      );
      expect(
        ParticlesWallpaperDefinition.effectiveCount(120, isWeb: true, hardwareConcurrency: 4),
        45,
      );
      expect(
        ParticlesWallpaperDefinition.effectiveCount(25, isWeb: true, hardwareConcurrency: 4),
        25,
      );
      expect(
        ParticlesWallpaperDefinition.effectiveCount(120, isWeb: true, hardwareConcurrency: 8),
        120,
      );
      expect(
        ParticlesWallpaperDefinition.effectiveCount(120, isWeb: false, hardwareConcurrency: 2),
        120,
      );
    });

    testWidgets('DynamicWallpaperView disables tickers when disableAnimations is true', (tester) async {
      Widget buildApp({required bool disableAnimations}) {
        return GetMaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: const Scaffold(
              body: DynamicWallpaperView(
                wallpaperId: 'wave',
                config: {'amplitude': 10.0, 'frequency': 1.2, 'speed': 0.2, 'opacity': 0.5, 'layerCount': 2},
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildApp(disableAnimations: true));
      final disabledTickerMode = tester.widget<TickerMode>(
        find.descendant(of: find.byType(DynamicWallpaperView), matching: find.byType(TickerMode)),
      );
      expect(disabledTickerMode.enabled, isFalse);

      await tester.pumpWidget(buildApp(disableAnimations: false));
      final enabledTickerMode = tester.widget<TickerMode>(
        find.descendant(of: find.byType(DynamicWallpaperView), matching: find.byType(TickerMode)),
      );
      expect(enabledTickerMode.enabled, isTrue);
    });

    test('StartupTasks.configureWebImageCache is safe to call', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      StartupTasks.configureWebImageCache();
    });
  });
}
