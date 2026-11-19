import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

/// A web implementation of the SecureApplication plugin.
class SecureApplicationWeb {
  bool secured = false;
  StreamSubscription<web.Event>? onVC;
  final MethodChannel _channel;
  SecureApplicationWeb(this._channel);

  void secureApplication() {
    onVC?.cancel();
    onVC = web.document.onVisibilityChange.listen(visibilityEvent);
    secured = true;
  }

  void visibilityEvent(web.Event e) {
    if (web.document.visibilityState == 'hidden') {
      _channel.invokeMethod('lock', 'web');
    }
  }

  void unsecureApplication() {
    onVC?.cancel();
    secured = false;
  }

  static void registerWith(Registrar registrar) {
    final MethodChannel channel = MethodChannel(
      'secure_application',
      const StandardMethodCodec(),
      registrar,
    );

    final pluginInstance = SecureApplicationWeb(channel);
    channel.setMethodCallHandler(pluginInstance.handleMethodCall);
  }

  /// Handles method calls over the MethodChannel of this plugin.
  /// Note: Check the "federated" architecture for a new way of doing this:
  /// https://flutter.dev/go/federated-plugins
  Future<dynamic> handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'secure':
        secureApplication();
        return true;
      case 'open':
        unsecureApplication();
        return true;
      default:
        return true;
    }
  }

  /// Returns a [String] containing the version of the platform.
  Future<String> getPlatformVersion() {
    final version = web.window.navigator.userAgent;
    return Future.value(version);
  }
}
