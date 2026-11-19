import 'dart:isolate';
import 'dart:ui';

void createFakeBgIsolatePort() {
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping('bg_isolate');
  IsolateNameServer.registerPortWithName(port.sendPort, 'bg_isolate');
}
