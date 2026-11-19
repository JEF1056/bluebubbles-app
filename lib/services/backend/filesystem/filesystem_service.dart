import 'dart:async';

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/backend/filesystem/web_media_cache.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/method_channel_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:idb_shim/idb.dart' as idb;
import 'package:idb_shim/idb_browser.dart' hide Database;
import 'package:io/io.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:slugify/slugify.dart';
import 'package:universal_io/io.dart';
import 'package:get_it/get_it.dart';

export 'web_media_cache.dart';

// ignore: non_constant_identifier_names
FilesystemService get FilesystemSvc => GetIt.I<FilesystemService>();

class FilesystemService {
  /// The default Android downloads directory path.
  static const String androidDownloadsPath = '/storage/emulated/0/Download/';

  late Directory appDocDir;
  late final PackageInfo packageInfo;
  late Directory _sysTemp;
  AndroidDeviceInfo? androidInfo;
  late final idb.Database webDb;
  late final Uint8List unplayableVideoIcon;
  final RxBool fontExistsOnDisk = false.obs;
  final Map<String, Uint8List> _webChatBackgrounds = {};
  final Map<String, String> _webChatBackgroundPaths = {};
  final Map<String, Uint8List> _webAvatars = {};
  int _webAssetSeq = 0;

  static final Uint8List transparent1x1Png = Uint8List.fromList(const [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  static String stripWebPathVersion(String path) {
    final q = path.indexOf('?');
    return q == -1 ? path : path.substring(0, q);
  }

  /// The platform downloads directory. On Android returns [androidDownloadsPath];
  /// on desktop resolves via path_provider.
  Future<String> get downloadsDirectory async {
    if (kIsWeb) throw "Cannot get downloads directory on web!";

    String filePath = androidDownloadsPath;
    if (kIsDesktop) {
      filePath = (await getDownloadsDirectory())!.path;
    }

    return filePath;
  }

  /// The OS-managed system temporary directory (cached at init time).
  Directory get sysTemp => _sysTemp;
  String get sysTempPath => _sysTemp.path;

  /// The app-scoped temporary directory inside [appDocDir].
  String get appTempPath => join(appDocDir.path, 'temp');
  Directory get appTemp => Directory(appTempPath);

  // ---------------------------------------------------------------------------
  // Named app-doc sub-directory paths
  // ---------------------------------------------------------------------------

  String get attachmentsPath => join(appDocDir.path, 'attachments');
  String get avatarsPath => join(appDocDir.path, 'avatars');
  String get messagesPath => join(appDocDir.path, 'messages');
  String get fontPath => join(appDocDir.path, 'font');
  String get soundsPath => join(appDocDir.path, 'sounds');
  String get logsPath => join(appDocDir.path, 'logs');
  String get contactAvatarsPath => join(appDocDir.path, 'contact_avatars');
  String get customBackgroundsPath => join(appDocDir.path, 'custom_backgrounds');
  String get urlPreviewsPath => join(appDocDir.path, 'url_previews');

  /// Returns the path for a cached URL preview image identified by its content
  /// hash. Accepts hashes written by older versions too, since the filename is
  /// whatever was persisted on the message.
  String urlPreviewImagePath(String hash) => join(urlPreviewsPath, hash);

  /// Caches a URL preview image, keyed by the SHA-256 of its bytes.
  ///
  /// Content addressing means identical images shared across messages occupy a
  /// single file. SHA-256 rather than MD5 because these bytes come from
  /// attacker-influenced markup: chosen-prefix MD5 collisions are practical, and
  /// the cache is shared across senders, so a collision would let one sender
  /// control what renders in another's preview.
  ///
  /// Nothing is evicted automatically. A link preview is part of how a message
  /// reads, so it persists like the message does — the user reclaims the space
  /// deliberately from the Storage Analyzer, the same way attachments (which
  /// are far larger) already work. Existing MD5-named files stay valid; they
  /// are simply content the messages referencing them still point at.
  Future<String> saveUrlPreviewImage(Uint8List bytes) async {
    if (kIsWeb) throw 'saveUrlPreviewImage is not supported on web';
    final hash = sha256.convert(bytes).toString();
    final dir = Directory(urlPreviewsPath);
    await dir.create(recursive: true);
    final file = File(join(urlPreviewsPath, hash));
    if (!file.existsSync()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return hash;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Strips non-alphanumeric characters from [guid] so it is safe for use as
  /// a filesystem path component (matches the pattern used by AvatarCrop, etc.).
  static String sanitizeGuid(String guid) => guid.characters.where((c) => c.isAlphabetOnly || c.isNumericOnly).join();

  /// Returns the canonical path where a chat's group avatar is stored.
  /// The file does not necessarily exist yet; callers must create it if needed.
  String chatAvatarPath(String chatGuid) => join(avatarsPath, sanitizeGuid(chatGuid), 'avatar.jpg');

  /// Resolves an existing custom background for a chat using the same folder
  /// layout as the background cropper.
  String? getExistingChatBackgroundPath(String chatGuid) {
    if (kIsWeb) {
      return _webChatBackgroundPaths[chatGuid] ??
          (_webChatBackgrounds.containsKey(chatGuid) ? 'web-bg://${sanitizeGuid(chatGuid)}' : null);
    }

    final sanitizedGuid = sanitizeGuid(chatGuid);
    final directory = Directory(join(customBackgroundsPath, sanitizedGuid));
    if (!directory.existsSync()) return null;

    final candidates = directory
        .listSync()
        .whereType<File>()
        .where((file) => basename(file.path).startsWith('background'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    return candidates.isEmpty ? null : candidates.first.path;
  }

  Uint8List? getCachedChatBackgroundByPath(String path) {
    final base = stripWebPathVersion(path);
    if (!base.startsWith('web-bg://')) return null;
    final sanitized = base.substring('web-bg://'.length);
    for (final entry in _webChatBackgrounds.entries) {
      if (sanitizeGuid(entry.key) == sanitized) return entry.value;
    }
    return null;
  }

  Uint8List? getCachedWebAvatarByPath(String path) {
    final base = stripWebPathVersion(path);
    if (!base.startsWith('web-avatar://')) return null;
    return _webAvatars['avatar_${base.substring('web-avatar://'.length)}'];
  }

  Future<String> saveWebAvatar(String id, Uint8List bytes) async {
    final key = 'avatar_$id';
    _webAvatars[key] = bytes;
    await WebMediaCache.instance.put(WebMediaCache.attachmentsStore, key, bytes);
    return 'web-avatar://$id?v=${++_webAssetSeq}';
  }

  Future<void> deleteWebAvatar(String path) async {
    final base = stripWebPathVersion(path);
    if (!base.startsWith('web-avatar://')) return;
    final key = 'avatar_${base.substring('web-avatar://'.length)}';
    _webAvatars.remove(key);
    await WebMediaCache.instance.delete(WebMediaCache.attachmentsStore, key);
  }

  Future<String> saveChatBackground(String chatGuid, Uint8List bytes) async {
    if (kIsWeb) {
      _webChatBackgrounds[chatGuid] = bytes;
      final versioned = 'web-bg://${sanitizeGuid(chatGuid)}?v=${++_webAssetSeq}';
      _webChatBackgroundPaths[chatGuid] = versioned;
      await WebMediaCache.instance.put(WebMediaCache.chatBackgroundsStore, chatGuid, bytes);
      return versioned;
    }
    final sanitizedGuid = sanitizeGuid(chatGuid);
    final dir = Directory(join(customBackgroundsPath, sanitizedGuid));
    await dir.create(recursive: true);
    final file = File(join(dir.path, 'background-${bytes.length}.jpg'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Uint8List?> loadChatBackground(String chatGuid) async {
    if (kIsWeb) {
      final cached = _webChatBackgrounds[chatGuid];
      if (cached != null) return cached;
      final bytes = await WebMediaCache.instance.get(WebMediaCache.chatBackgroundsStore, chatGuid);
      if (bytes != null) _webChatBackgrounds[chatGuid] = bytes;
      return bytes;
    }
    final path = getExistingChatBackgroundPath(chatGuid);
    if (path == null) return null;
    return File(path).readAsBytes();
  }

  Future<void> deleteChatBackground(String chatGuid) async {
    if (kIsWeb) {
      _webChatBackgrounds.remove(chatGuid);
      _webChatBackgroundPaths.remove(chatGuid);
      await WebMediaCache.instance.delete(WebMediaCache.chatBackgroundsStore, chatGuid);
      return;
    }
    final dir = Directory(join(customBackgroundsPath, sanitizeGuid(chatGuid)));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Strips the Android internal storage prefix from [path] for display.
  /// Returns [path] unchanged on non-Android platforms.
  String toDisplayPath(String path) {
    if (!kIsWeb && Platform.isAndroid) {
      return path.replaceAll('/storage/emulated/0/', '');
    }
    return path;
  }

  Future<void> init({bool headless = false}) async {
    if (!kIsWeb) {
      //ignore: unnecessary_cast, we need this as a workaround
      appDocDir = (kIsDesktop ? await getApplicationSupportDirectory() : await getApplicationDocumentsDirectory());
      if (isMsix) {
        final String appDataRoot = joinAll(split(appDocDir.absolute.path).slice(0, 4));
        // Family name (Name_PublisherHash) from the install dir; hash varies per variant.
        final exeSegments = split(Platform.resolvedExecutable);
        final fullNameParts = exeSegments[exeSegments.indexOf('WindowsApps') + 1].split('_');
        final packageFamilyName = '${fullNameParts.first}_${fullNameParts.last}';
        final Directory msixLocation = Directory(join(appDataRoot, "Local", "Packages", packageFamilyName, "LocalCache",
            "Roaming", "BlueBubbles", "bluebubbles"));
        // Check if the non-msix directory exists
        final Directory nonMsixLocation = Directory(join(appDataRoot, "Roaming", "BlueBubbles", "bluebubbles"));
        if (!msixLocation.existsSync() && nonMsixLocation.existsSync()) {
          if (!headless) await StartupTasks.setSplashStatus("Copying data from previous version...");
          await copyPath(nonMsixLocation.path, msixLocation.path);
        }
        appDocDir = msixLocation;
      }
      if (!headless) {
        final file2 = await rootBundle.load("assets/images/unplayable-video.png");
        unplayableVideoIcon = file2.buffer.asUint8List();
      }
      _sysTemp = await getTemporaryDirectory();
    } else {
      try {
        _webChatBackgrounds
          ..clear()
          ..addAll(await WebMediaCache.instance.getAllEntries(WebMediaCache.chatBackgroundsStore));
        final avatarEntries = await WebMediaCache.instance.getAllEntries(
          WebMediaCache.attachmentsStore,
          keyPrefix: 'avatar_',
        );
        _webAvatars
          ..clear()
          ..addAll(avatarEntries);
      } catch (_) {}
    }
    packageInfo = await PackageInfo.fromPlatform();
    if (!kIsWeb && !headless && Platform.isAndroid) {
      androidInfo = await DeviceInfoPlugin().androidInfo;
    }
  }

  void checkFont() async {
    if (!kIsWeb) {
      final file = File(join(fontPath, 'apple.ttf'));
      final exists = await file.exists();
      if (exists) {
        final bytes = await file.readAsBytes();
        fontExistsOnDisk.value = true;
        final fontLoader = FontLoader("Apple Color Emoji");
        final cachedFontBytes = ByteData.view(bytes.buffer);
        fontLoader.addFont(
          Future<ByteData>.value(cachedFontBytes),
        );
        await fontLoader.load();
      }
    } else {
      Uint8List? bytes;
      try {
        bytes = await WebMediaCache.instance.get(WebMediaCache.fontsStore, 'iosFont');
      } catch (e, s) {
        Logger.warn("WebMediaCache font lookup failed", error: e, trace: s);
      }
      final idbFactory = idbFactoryBrowser;
      idbFactory.open("BlueBubbles.db", version: 1, onUpgradeNeeded: (idb.VersionChangeEvent e) {
        final db = (e.target as idb.OpenDBRequest).result;
        if (!db.objectStoreNames.contains("BBStore")) {
          db.createObjectStore("BBStore");
        }
      }).then((_db) async {
        webDb = _db;
        if (isNullOrEmpty(bytes)) {
          final txn = webDb.transaction("BBStore", idb.idbModeReadOnly);
          final store = txn.objectStore("BBStore");
          final legacyBytes = await store.getObject("iosFont") as Uint8List?;
          await txn.completed;
          if (!isNullOrEmpty(legacyBytes)) {
            bytes = legacyBytes;
            try {
              await WebMediaCache.instance.put(WebMediaCache.fontsStore, 'iosFont', legacyBytes!);
            } catch (e, s) {
              Logger.warn("WebMediaCache font migration failed", error: e, trace: s);
            }
          }
        }

        if (!isNullOrEmpty(bytes)) {
          fontExistsOnDisk.value = true;
          final fontLoader = FontLoader("Apple Color Emoji");
          final cachedFontBytes = ByteData.view(bytes!.buffer);
          fontLoader.addFont(
            Future<ByteData>.value(cachedFontBytes),
          );
          await fontLoader.load();
        }
      });
    }
  }

  void deleteDB() {
    Database.reset();
    if (kIsWeb) {
      unawaited(Database.clearWebPersistence().catchError((Object e, StackTrace s) {
        Logger.warn("Failed to clear web persistence", error: e, trace: s);
      }));
    }
    // Contacts are now managed by ContactServiceV2 and don't need manual clearing
  }

  /// Deletes all on-disk cache directories: attachments (originals/thumbnails/live-photo
  /// .mov), per-chat avatars, per-chat custom backgrounds, per-message balloon bundle
  /// directories, cached URL preview images, and cached contact avatars.
  Future<void> deleteCacheDirectories() async {
    if (kIsWeb) {
      await WebMediaCache.instance.clearStore(WebMediaCache.attachmentsStore);
      await WebMediaCache.instance.clearStore(WebMediaCache.chatBackgroundsStore);
      _webChatBackgrounds.clear();
      _webChatBackgroundPaths.clear();
      _webAvatars.clear();
      return;
    }
    final paths = [attachmentsPath, avatarsPath, customBackgroundsPath, messagesPath, urlPreviewsPath, contactAvatarsPath];
    for (final path in paths) {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  String uriToFilename(String? uri, String? mimeType) {
    // Handle any unknown cases
    String? ext = mimeType != null ? mimeType.split('/')[1] : null;
    ext = (ext != null && ext.contains('+')) ? ext.split('+')[0] : ext;
    if (uri == null) return (ext != null) ? 'unknown.$ext' : 'unknown';

    // Get the filename
    String filename = uri;
    if (filename.contains('/')) {
      filename = filename.split('/').last;
    }

    // Get the extension
    if (filename.contains('.')) {
      List<String> split = filename.split('.');
      ext = split[1];
      filename = split[0];
    }

    // Slugify the filename
    filename = slugify(filename, delimiter: '_');

    // Rebuild the filename
    return (ext != null && ext.isNotEmpty) ? '$filename.$ext' : filename;
  }

  Future<String> saveToDownloads(File file, {String mimeType = 'application/octet-stream'}) async {
    if (kIsWeb) throw "Cannot save file on web!";

    final String filename = basename(file.path);

    if (kIsDesktop) {
      // On desktop, path_provider resolves the real OS Downloads folder.
      final String downloadsDir = await downloadsDirectory;
      final String newPath = join(downloadsDir, filename);
      await file.copy(newPath);
      return newPath;
    } else {
      // On Android, use MediaStore.Downloads (API 29+) or direct file copy (older).
      try {
        await MethodChannelSvc.actions.saveFileToDownloads(
          filePath: file.path,
          fileName: filename,
          mimeType: mimeType,
        );
        return filename;
      } catch (_) {
        // Fallback: direct file copy to the public Downloads directory.
        final String newPath = join(androidDownloadsPath, filename);
        await file.copy(newPath);
        return newPath;
      }
    }
  }
}
