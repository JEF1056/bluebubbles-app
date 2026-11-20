import 'package:flutter/material.dart';

class WindowsToastTheme {
  const WindowsToastTheme({
    required this.background,
    required this.button,
    required this.border,
    required this.text,
    required this.subtext,
  });

  final Color background;
  final Color button;
  final Color border;
  final Color text;
  final Color subtext;

  static WindowsToastTheme read() => WindowsToastTheme(
        background: const Color(0xFF2C2C2C),
        button: Color.alphaBlend(Colors.white.withValues(alpha: 0.065), const Color(0xFF2C2C2C)),
        border: Color.alphaBlend(Colors.white.withValues(alpha: 0.125), const Color(0xFF2C2C2C)),
        text: Colors.white,
        subtext: Colors.white.withValues(alpha: 0.78),
      );
}
