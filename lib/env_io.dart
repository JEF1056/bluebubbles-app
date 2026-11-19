import 'dart:isolate';
import 'env.dart';

String? getIsolateDebugName() => isolateNameOverride ?? Isolate.current.debugName;
