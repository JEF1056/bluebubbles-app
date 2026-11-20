import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

SystemUiOverlayStyle buildSystemUiOverlayStyle({
  required Color surfaceColor,
  required bool immersiveMode,
  Color? systemNavigationBarColor,
  Color statusBarColor = Colors.transparent,
  Brightness? backgroundBrightness,
  Brightness? systemNavigationBarIconBrightness,
  Brightness? statusBarIconBrightness,
}) {
  final brightness = backgroundBrightness ?? ThemeData.estimateBrightnessForColor(surfaceColor);
  final foregroundBrightness = _oppositeBrightness(brightness);

  return SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: systemNavigationBarIconBrightness ?? foregroundBrightness,
    systemNavigationBarContrastEnforced: false,
    statusBarColor: Colors.transparent,
    statusBarBrightness: brightness,
    statusBarIconBrightness: statusBarIconBrightness ?? foregroundBrightness,
    systemStatusBarContrastEnforced: false,
  );
}

Brightness _oppositeBrightness(Brightness brightness) {
  return brightness == Brightness.light ? Brightness.dark : Brightness.light;
}
