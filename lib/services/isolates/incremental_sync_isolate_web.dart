import 'package:bluebubbles/services/isolates/global_isolate.dart';

/// Web stub for [IncrementalSyncIsolate] — executes dispatched actions inline via [GlobalIsolate].
class IncrementalSyncIsolate extends GlobalIsolate {
  IncrementalSyncIsolate({
    super.taskTimeout = const Duration(minutes: 5),
    super.startupTimeout = const Duration(seconds: 30),
    super.idleTimeout = Duration.zero,
  });

  @override
  String get isolatePortName => 'IncrementalSyncIsolate';

  @override
  String get isolateDebugName => 'IncrementalSyncIsolate';
}
