import 'dart:isolate';
import 'dart:ui';

ReceivePort? _fakeBgIsolatePort;

void createFakeBgIsolatePort() {
  _fakeBgIsolatePort?.close();
  final port = ReceivePort();
  _fakeBgIsolatePort = port;
  IsolateNameServer.removePortNameMapping('bg_isolate');
  IsolateNameServer.registerPortWithName(port.sendPort, 'bg_isolate');
}
