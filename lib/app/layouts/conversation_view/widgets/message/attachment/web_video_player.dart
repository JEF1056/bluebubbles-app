export 'web_video_player_stub.dart'
    if (dart.library.js_interop) 'web_video_player_web.dart';

/// Builds a direct attachment streaming URL for HTML5 `<video>` (supports HTTP Range seeking).
String buildWebAttachmentStreamUrl({
  required String apiRoot,
  required String guid,
  required String authGuid,
  bool formatM4a = false,
}) {
  final base = Uri.parse('$apiRoot/attachment/${Uri.encodeComponent(guid)}/download');
  final params = <String, String>{
    'guid': authGuid,
    if (formatM4a) 'format': 'm4a',
  };
  return base.replace(queryParameters: params).toString();
}
