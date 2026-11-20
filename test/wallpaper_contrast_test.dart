import 'package:bluebubbles/app/components/wallpaper/wallpaper_contrast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WallpaperContrast Google Messages tokens', () {
    test('scrimColor matches decompiled custom_wallpaper_scrim_alpha (0.2 light, 0.4 dark)', () {
      final lightScrim = WallpaperContrast.scrimColor(Brightness.light);
      final darkScrim = WallpaperContrast.scrimColor(Brightness.dark);

      expect(lightScrim.a, closeTo(0.2, 0.001));
      expect(lightScrim.r, 0.0);
      expect(lightScrim.g, 0.0);
      expect(lightScrim.b, 0.0);

      expect(darkScrim.a, closeTo(0.4, 0.001));
      expect(darkScrim.r, 0.0);
      expect(darkScrim.g, 0.0);
      expect(darkScrim.b, 0.0);
    });

    test('unbubbledStyle applies pure white + 3dp 0.4-alpha black shadow only when hasWallpaper is true', () {
      const base = TextStyle(fontSize: 12);
      const fallback = Color(0xFF49454F);

      final overWallpaper = WallpaperContrast.unbubbledStyle(
        base,
        hasWallpaper: true,
        fallbackColor: fallback,
      );
      expect(overWallpaper.color, Colors.white);
      expect(overWallpaper.shadows, isNotNull);
      expect(overWallpaper.shadows!.single.blurRadius, 3.0);
      expect(overWallpaper.shadows!.single.offset, Offset.zero);
      expect(overWallpaper.shadows!.single.color.a, closeTo(0.4, 0.005));

      final plainChat = WallpaperContrast.unbubbledStyle(
        base,
        hasWallpaper: false,
        fallbackColor: fallback,
      );
      expect(plainChat.color, fallback);
      expect(plainChat.shadows, isNull);
    });
  });

  group('WCAG 4.5:1 & scrim/pill verification across #FFFFFF, busy, and #000000 wallpapers', () {
    final lightScheme = ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.light);
    final darkScheme = ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark);

    test('full-canvas scrim darkens #FFFFFF and preserves >= 4.5:1 on #000000 for white + error text', () {
      for (final brightness in Brightness.values) {
        final scrim = WallpaperContrast.scrimColor(brightness);
        final darkenedWhite = WallpaperContrast.compositeOver(scrim, Colors.white);
        expect(WallpaperContrast.relativeLuminance(darkenedWhite), lessThan(0.7));

        final darkenedBlack = WallpaperContrast.compositeOver(scrim, Colors.black);
        expect(
          WallpaperContrast.wcagContrastRatio(WallpaperContrast.unbubbledTextColor, darkenedBlack),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          WallpaperContrast.wcagContrastRatio(WallpaperContrast.unbubbledErrorColor, darkenedBlack),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('pill-backed elements (ChatEvent 0.86, Header/Composer 0.86, CupertinoHeader 0.72) >= 4.5:1 on #FFFFFF and #000000', () {
      final wallpapers = [Colors.white, const Color(0xFF808080), Colors.black];
      final schemes = [
        (brightness: Brightness.light, scheme: lightScheme),
        (brightness: Brightness.dark, scheme: darkScheme),
      ];

      for (final entry in schemes) {
        final scrim = WallpaperContrast.scrimColor(entry.brightness);
        for (final wp in wallpapers) {
          final scrimmedWp = WallpaperContrast.compositeOver(scrim, wp);

          // ChatEvent pill: surfaceContainerHighest @ 0.86 with onSurface
          final chatEventBg = WallpaperContrast.compositeOver(
            entry.scheme.surfaceContainerHighest.withValues(alpha: 0.86),
            scrimmedWp,
          );
          expect(
            WallpaperContrast.wcagContrastRatio(entry.scheme.onSurface, chatEventBg),
            greaterThanOrEqualTo(4.5),
            reason: '${entry.brightness} ChatEvent on $wp',
          );

          // MaterialHeader & TextFieldComponent pill: surfaceContainer @ 0.86
          final barBg = WallpaperContrast.compositeOver(
            entry.scheme.surfaceContainer.withValues(alpha: 0.86),
            scrimmedWp,
          );
          expect(
            WallpaperContrast.wcagContrastRatio(entry.scheme.onSurface, barBg),
            greaterThanOrEqualTo(4.5),
            reason: '${entry.brightness} bar on $wp',
          );

          // CupertinoHeader bottom edge over wallpaper: surfaceContainerHighest @ 0.72
          final cupertinoEdgeBg = WallpaperContrast.compositeOver(
            entry.scheme.surfaceContainerHighest.withValues(alpha: 0.72),
            scrimmedWp,
          );
          expect(
            WallpaperContrast.wcagContrastRatio(entry.scheme.onSurface, cupertinoEdgeBg),
            greaterThanOrEqualTo(4.5),
            reason: '${entry.brightness} CupertinoHeader on $wp',
          );
        }
      }
    });
  });

  group('Widget rendering of scrim + unbubbled text over #FFFFFF wallpaper', () {
    for (final brightness in Brightness.values) {
      testWidgets('renders black scrim and white shadowed unbubbled text in $brightness mode', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Builder(
              builder: (context) => Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: Colors.white)),
                  Positioned.fill(
                    child: ColoredBox(
                      key: const Key('wallpaper_scrim'),
                      color: WallpaperContrast.scrimColor(Theme.of(context).brightness),
                    ),
                  ),
                  Center(
                    child: Text(
                      'Today 9:41 AM',
                      style: WallpaperContrast.unbubbledStyle(
                        const TextStyle(fontSize: 12),
                        hasWallpaper: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        final scrimBox = tester.widget<ColoredBox>(find.byKey(const Key('wallpaper_scrim')));
        expect(scrimBox.color, WallpaperContrast.scrimColor(brightness));

        final textWidget = tester.widget<Text>(find.text('Today 9:41 AM'));
        expect(textWidget.style?.color, Colors.white);
        expect(textWidget.style?.shadows, WallpaperContrast.unbubbledTextShadows);
      });
    }
  });
}
