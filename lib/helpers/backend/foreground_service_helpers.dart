import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:universal_io/io.dart';

import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';

Future<void> runForegroundService() async {
  try {
    if (kIsWeb) return;
    if (Platform.isAndroid && SettingsSvc.settings.keepAppAlive.value && !LifecycleSvc.isAlive) {
      await MethodChannelSvc.actions.startForegroundService();
    } else if (Platform.isAndroid && !SettingsSvc.settings.keepAppAlive.value) {
      await MethodChannelSvc.actions.stopForegroundService();
    }
  } catch (e, stack) {
    Logger.error("Failed to start foreground service!", error: e, trace: stack);
  }
}

Future<void> restartForegroundService() async {
  try {
    if (kIsWeb) return;
    if (Platform.isAndroid && SettingsSvc.settings.keepAppAlive.value && !LifecycleSvc.isAlive) {
      await MethodChannelSvc.actions.stopForegroundService();
      await MethodChannelSvc.actions.startForegroundService();
    }
  } catch (e, stack) {
    Logger.error("Failed to restart foreground service!", error: e, trace: stack);
  }
}
