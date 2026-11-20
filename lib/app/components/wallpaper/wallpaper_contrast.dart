import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shared wallpaper contrast tokens matching Google Messages' decompiled
/// custom-wallpaper readability system (`apmr.java`, `fbfi.java`, `fbfd.java`).
abstract final class WallpaperContrast {
  /// Full-canvas black scrim alpha in light theme (`custom_wallpaper_scrim_alpha`).
  static const double lightScrimAlpha = 0.2;

  /// Full-canvas black scrim alpha in dark theme (`custom_wallpaper_scrim_alpha`).
  static const double darkScrimAlpha = 0.4;

  /// Pure white text/icon override over custom wallpapers (`fbfd.a` / `#FFFFFFFF`).
  static const Color unbubbledTextColor = Colors.white;

  /// Dark-mode error color for unbubbled status labels over wallpapers (`ambx`/`fbfi.b`).
  static const Color unbubbledErrorColor = Color(0xFFF2B8B5);

  /// Uniform drop shadow for unbubbled text over wallpapers (`fbfd.b`: Black @ 0.4, 3dp blur).
  static const Shadow unbubbledTextShadow = Shadow(
    color: Color(0x66000000),
    offset: Offset.zero,
    blurRadius: 3.0,
  );

  static const List<Shadow> unbubbledTextShadows = [unbubbledTextShadow];

  /// Full-canvas scrim color composited over custom wallpapers.
  static Color scrimColor(Brightness brightness) =>
      Colors.black.withValues(alpha: brightness == Brightness.dark ? darkScrimAlpha : lightScrimAlpha);

  /// Applies [unbubbledTextColor] and [unbubbledTextShadows] when [hasWallpaper] is true.
  static TextStyle unbubbledStyle(
    TextStyle base, {
    required bool hasWallpaper,
    Color? fallbackColor,
  }) {
    if (!hasWallpaper) {
      return fallbackColor != null ? base.copyWith(color: fallbackColor) : base;
    }
    return base.copyWith(
      color: unbubbledTextColor,
      shadows: unbubbledTextShadows,
    );
  }

  /// Resolves unbubbled foreground color over [hasWallpaper].
  static Color unbubbledColor({
    required bool hasWallpaper,
    required Color fallback,
  }) =>
      hasWallpaper ? unbubbledTextColor : fallback;

  /// Resolves error text/icon color over [hasWallpaper].
  static Color errorColor(BuildContext context, {required bool hasWallpaper}) =>
      hasWallpaper ? unbubbledErrorColor : Theme.of(context).colorScheme.error;

  /// Resolves reply-thread connector line color over [hasWallpaper].
  static Color replyLineColor(
    BuildContext context, {
    required bool hasWallpaper,
    required bool isIOS,
  }) {
    if (hasWallpaper) return Colors.white.withValues(alpha: 0.48);
    final cs = Theme.of(context).colorScheme;
    return isIOS ? cs.surfaceContainerHighest : cs.outlineVariant;
  }

  /// Alpha-composites [foreground] over opaque [background] using SrcOver.
  static Color compositeOver(Color foreground, Color background) {
    final a = foreground.a;
    final invA = 1.0 - a;
    return Color.from(
      alpha: 1.0,
      red: foreground.r * a + background.r * invA,
      green: foreground.g * a + background.g * invA,
      blue: foreground.b * a + background.b * invA,
    );
  }

  /// W3C WCAG 2.x relative luminance in [0.0, 1.0].
  static double relativeLuminance(Color color) {
    double linearize(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * linearize(color.r) + 0.7152 * linearize(color.g) + 0.0722 * linearize(color.b);
  }

  /// W3C WCAG 2.x contrast ratio between [foreground] and [background].
  static double wcagContrastRatio(Color foreground, Color background) {
    final fg = foreground.a < 1.0 ? compositeOver(foreground, background) : foreground;
    final l1 = relativeLuminance(fg);
    final l2 = relativeLuminance(background);
    final lighter = math.max(l1, l2);
    final darker = math.min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
  }
}
