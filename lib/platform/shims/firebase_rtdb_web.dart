import 'package:dio/dio.dart';

void setupFirebaseRtdb() {}

Future<String?> fetchFirebaseServerUrl({
  required String apiKey,
  required String appId,
  required String projectId,
  String? databaseUrl,
}) async {
  final dio = Dio();
  if (databaseUrl != null && databaseUrl.isNotEmpty) {
    final base = databaseUrl.replaceFirst(RegExp(r'/$'), '');
    final res = await dio.get('$base/config/serverUrl.json');
    return res.data?.toString();
  }
  if (projectId.isEmpty) return null;
  final res = await dio.get(
    'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/server/config',
    queryParameters: apiKey.isNotEmpty ? {'key': apiKey} : null,
  );
  return (res.data?['fields']?['serverUrl']?['stringValue'])?.toString();
}

Future<void> setFirebaseNextRestart({
  required String databaseUrl,
  required int timestampMs,
}) async {
  final base = databaseUrl.replaceFirst(RegExp(r'/$'), '');
  await Dio().put('$base/config/nextRestart.json', data: timestampMs);
}
