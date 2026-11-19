export 'web_audio_player_stub.dart'
    if (dart.library.js_interop) 'web_audio_player_web.dart';

bool isCafAudio({
  String? mimeType,
  String? fileName,
  String? transferName,
}) {
  final mimeLower = mimeType?.toLowerCase() ?? '';
  if (mimeLower == 'audio/x-caf' || mimeLower == 'audio/caf') return true;
  final fLower = fileName?.toLowerCase() ?? '';
  if (fLower.endsWith('.caf')) return true;
  final tLower = transferName?.toLowerCase() ?? '';
  return tLower.endsWith('.caf');
}

/// Builds a direct attachment streaming URL for HTML5 `<audio>`.
/// Requests `?format=m4a` for Apple CAF voice notes so browsers decode AAC cleanly.
String buildWebAudioStreamUrl({
  required String apiRoot,
  required String guid,
  required String authGuid,
  bool isCaf = false,
}) {
  final base = Uri.parse('$apiRoot/attachment/${Uri.encodeComponent(guid)}/download');
  final params = <String, String>{
    'guid': authGuid,
    if (isCaf) 'format': 'm4a',
  };
  return base.replace(queryParameters: params).toString();
}
