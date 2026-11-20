/// Helpers for extracting and tracking iOS/macOS Messages per-chat wallpaper
/// identifiers (`trabaid` / `backgroundChannelGUID`) from `chat.properties`.
library;

final RegExp _safeBackgroundGuidRe = RegExp(r'^[A-Za-z0-9-]+$');
const String _serverBackgroundPrefix = 'background-server-';

/// Extracts the current wallpaper GUID (`trabaid` or `backgroundChannelGUID`)
/// from a chat's decoded `properties` plist list or dictionary.
String? backgroundGuidInProperties(dynamic properties) {
  final entries = properties is List ? properties : (properties is Map ? [properties] : const []);
  String? found;
  for (final entry in entries) {
    if (entry is! Map) continue;
    final bgProps = entry['backgroundProperties'];
    final trabaid = bgProps is Map ? bgProps['trabaid'] : null;
    final candidate = (trabaid is String && trabaid.isNotEmpty)
        ? trabaid
        : (entry['backgroundChannelGUID'] is String && (entry['backgroundChannelGUID'] as String).isNotEmpty
            ? entry['backgroundChannelGUID'] as String
            : null);
    if (candidate != null && _safeBackgroundGuidRe.hasMatch(candidate)) {
      found = candidate;
    }
  }
  return found;
}

String serverBackgroundFilename(String backgroundGuid, {String ext = 'jpg'}) =>
    '$_serverBackgroundPrefix$backgroundGuid.$ext';

/// Returns the synced wallpaper GUID if [filePath] was written by server sync
/// (`background-server-<guid>.<ext>`), or `null` for local/absent backgrounds.
String? serverBackgroundGuidFromPath(String? filePath) {
  if (filePath == null || filePath.isEmpty) return null;
  final name = filePath.split('?').first.split(RegExp(r'[/\\]')).last;
  if (!name.startsWith(_serverBackgroundPrefix)) return null;
  final dot = name.lastIndexOf('.');
  if (dot <= _serverBackgroundPrefix.length) return null;
  final guid = name.substring(_serverBackgroundPrefix.length, dot);
  return _safeBackgroundGuidRe.hasMatch(guid) ? guid : null;
}

/// Returns whether server wallpaper sync should proceed (download or clear)
/// without clobbering a locally-picked image or dynamic wallpaper.
bool shouldSyncServerBackground({
  required String? serverGuid,
  required bool hasServerProperties,
  required String? existingPath,
  required String? wallpaperType,
}) {
  if (wallpaperType == 'dynamic') return false;
  final existingServerGuid = serverBackgroundGuidFromPath(existingPath);
  if (existingPath != null && existingServerGuid == null) return false;
  if (serverGuid == null) {
    return hasServerProperties && existingServerGuid != null;
  }
  return existingServerGuid != serverGuid;
}
