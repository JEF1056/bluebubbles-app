import 'dart:async';
import 'dart:isolate';

/// Runs [writeMergedLog] in a short-lived isolate of its own, which exits once it's done.
/// Throws a [TimeoutException] after [timeout], once the isolate is killed.
Future<void> writeMergedLogInIsolate(
  String logDir,
  String outPath,
  Future<void> Function(String logDir, String outPath) writeMergedLog,
  Duration timeout,
) async {
  final port = ReceivePort();
  final Isolate isolate;
  try {
    isolate = await Isolate.spawn(
      _mergeLogEntry,
      (port.sendPort, logDir, outPath, writeMergedLog),
      onExit: port.sendPort,
      debugName: 'LogExport',
    );
  } catch (_) {
    port.close();
    rethrow;
  }
  try {
    // The entry point's result, or the onExit null if the isolate died first.
    final result = port.first;
    final Object? message;
    try {
      message = await result.timeout(timeout);
    } on TimeoutException {
      isolate.kill(priority: Isolate.immediate);
      // Wait for it to exit, so the caller can delete the half-written file.
      await result.timeout(const Duration(seconds: 5), onTimeout: () => null);
      rethrow;
    }
    if (message is (String, String)) throw RemoteError(message.$1, message.$2);
    if (message != true) throw StateError("The log merge isolate exited without finishing");
  } finally {
    port.close();
  }
}

/// The merge isolate's entry point: reports `true` on success, or the error and stack trace as strings.
Future<void> _mergeLogEntry(
  (SendPort, String, String, Future<void> Function(String, String)) args,
) async {
  final (resultPort, logDir, outPath, writeMergedLog) = args;
  Object result = true;
  try {
    await writeMergedLog(logDir, outPath);
  } catch (e, stackTrace) {
    result = ('$e', '$stackTrace');
  }
  Isolate.exit(resultPort, result);
}
