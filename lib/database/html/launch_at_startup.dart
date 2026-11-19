class LaunchAtStartup {
  static String? get shortcutPath => null;

  static Future<bool> enable() async => false;

  static Future<bool> disable() async => false;

  static Future<void> revealShortcut() async => throw Exception('Not supported on Web!');

  static Never setup(String appName, bool minimized) => throw Exception('Not supported on Web!');
}
