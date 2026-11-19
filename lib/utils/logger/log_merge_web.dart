Future<void> writeMergedLogInIsolate(
  String logDir,
  String outPath,
  Future<void> Function(String logDir, String outPath) writeMergedLog,
  Duration timeout,
) async {}
