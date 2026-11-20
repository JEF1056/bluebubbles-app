import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class DebugConsoleOutput extends LogOutput {
  DebugConsoleOutput({this.minLevel = Level.all});

  final Level minLevel;

  @override
  void output(OutputEvent event) {
    if (event.level.value < minLevel.value) return;
    event.lines.forEach(debugPrint);
  }
}
