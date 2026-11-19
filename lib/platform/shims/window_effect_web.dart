import 'package:flutter/material.dart';

enum WindowEffect {
  disabled,
  solid,
  transparent,
  aero,
  acrylic,
  mica,
  tabbed,
}

class Window {
  static Future<void> initialize() async {}
  static Future<void> hideWindowControls() async {}
  static Future<void> setEffect({
    required WindowEffect effect,
    Color color = Colors.transparent,
    bool dark = false,
  }) async {}
}
