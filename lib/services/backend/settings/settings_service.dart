import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' show join;

import 'package:bluebubbles/app/layouts/settings/pages/advanced/private_api_panel.dart';
import 'package:bluebubbles/app/layouts/settings/settings_page.dart';
import 'package:bluebubbles/app/wrappers/scrollbar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/interfaces/app_interface.dart';
import 'package:bluebubbles/services/backend/interfaces/server_interface.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:get/get.dart';
import 'package:github/github.dart' hide Source;
import 'package:in_app_update/in_app_update.dart' as play;
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:store_checker/store_checker.dart';
import 'package:bluebubbles/models/models.dart' show ServerDetails, AppUpdateInfo, ServerUpdateInfo;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:version/version.dart';
import 'package:get_it/get_it.dart';

// ignore: non_constant_identifier_names
SettingsService get SettingsSvc => GetIt.I<SettingsService>();

class SettingsService {
  late Settings settings;
  late FCMData fcmData;
  bool _canAuthenticate = false;
  bool _showingPapiPopup = false;
  Completer<void> initCompleted = Completer<void>();

  /// Cached server details. Populated from [PrefsSvc] on startup and refreshed
  /// in the background via [refreshServerDetails]. Access via the [serverDetails]
  /// getter; use [_serverDetails] within this class for reactive ([Obx]) access.
  final Rx<ServerDetails> _serverDetails = const ServerDetails.empty().obs;

  /// Cross-platform cached self-avatar bytes (populated on Web & IO when
  /// fetching `/icloud/contact` or hydrating from `WebMediaCache`).
  final Rxn<Uint8List> userAvatarBytes = Rxn<Uint8List>();
  final RxList<String> iCloudAliases = <String>[].obs;
  final RxString iCloudActiveAlias = ''.obs;
  final RxMap<String, dynamic> iCloudAccountInfo = <String, dynamic>{}.obs;
  final RxMap<String, dynamic> iCloudContactInfo = <String, dynamic>{}.obs;

  Future<void>? _icloudProfileRefreshFuture;
  DateTime? _lastIcloudProfileRefresh;

  /// Returns the user's configured display name, falling back to `'You'`.
  String get effectiveUserName {
    final name = settings.userName.value.trim();
    return name.isNotEmpty ? name : 'You';
  }

  bool get canAuthenticate =>
      _canAuthenticate && !kIsWeb && (Platform.isWindows || (FilesystemSvc.androidInfo?.version.sdkInt ?? 0) > 28);

  Future<void> init({bool headless = false}) async {
    settings = Settings.getSettings();
    // Populate server details from prefs so sync getters are usable immediately.
    _serverDetails.value = ServerDetails(
      macOSVersion: PrefsSvc.server.getMacOSVersion() ?? 11,
      macOSMinorVersion: PrefsSvc.server.getMacOSMinorVersion() ?? 0,
      serverVersion: PrefsSvc.server.getServerVersion() ?? "0.0.0",
      serverVersionCode: PrefsSvc.server.getServerVersionCode() ?? 0,
      apiVersions: PrefsSvc.server.getApiVersions(),
      serverBuildVersion: PrefsSvc.server.getServerBuildVersion(),
      supportsFaceTimeCallsFlag: PrefsSvc.server.getSupportsFaceTimeCalls(),
    );
    if (!headless &&
        settings.serverPrivateAPI.value == true &&
        !settings.enablePrivateAPI.value &&
        !PrefsSvc.server.isPrivateApiDisabledByUser()) {
      settings.enablePrivateAPI.value = true;
      settings.privateAPISend.value = true;
    }

    if (!headless && !kIsWeb && !kIsDesktop) {
      // Parallelize independent operations
      try {
        await Future.wait([
          LocalAuthentication().isDeviceSupported().then((value) => _canAuthenticate = value),
          settings.getDisplayMode().then((mode) {
            if (mode != DisplayMode.auto) {
              FlutterDisplayMode.setPreferredMode(mode);
            }
          }),
        ]);
      } catch (e, s) {
        Logger.warn("Failed to apply display mode or biometric check at startup",
            error: e, trace: s, tag: 'SettingsService');
      }
      // system appearance
      if (settings.immersiveMode.value) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeRight,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.portraitUp,
        if (settings.allowUpsideDownRotation.value) DeviceOrientation.portraitDown,
      ]);
    }
    // launch at startup - defer this so it doesn't block startup.
    // Main isolate only: the engine aborts if a background isolate exits before Windows Hello replies
    if (kIsDesktop && !headless) {
      Future.microtask(() async {
        if (Platform.isWindows) {
          try {
            _canAuthenticate = await LocalAuthentication().isDeviceSupported();
          } catch (_) {}
        }
        settings.launchAtStartup.value =
            await setupLaunchAtStartup(settings.launchAtStartup.value, settings.launchAtStartupMinimized.value);
      });
    }

    initCompleted.complete();
  }

  /// Returns true if LaunchAtStartup is enabled and false if it is disabled
  Future<bool> setupLaunchAtStartup(bool launchAtStartup, bool minimized) async {
    // Can't use fs here because it hasn't been initialized yet
    LaunchAtStartup.setup((await PackageInfo.fromPlatform()).appName, minimized);
    try {
      if (launchAtStartup) {
        return await LaunchAtStartup.enable();
      }
      await LaunchAtStartup.disable();
    } catch (e, s) {
      Logger.error('Failed to set launch at startup', error: e, trace: s, tag: 'SettingsService');
    }
    return false;
  }

  void loadFcmDataFromDatabase() {
    fcmData = FCMData.getFCM();
  }

  Future<void> updateDisplayMode() async {
    if (!kIsWeb && !kIsDesktop) {
      try {
        final mode = await settings.getDisplayMode();
        FlutterDisplayMode.setPreferredMode(mode);
      } catch (e, s) {
        Logger.warn("Failed to update display mode", error: e, trace: s, tag: 'SettingsService');
      }
    }
  }

  Future<void> saveFCMData(FCMData data) async {
    fcmData = data;
    await fcmData.save(wait: true);
  }

  Future<Map<String, dynamic>> getServerDetailsDict() async {
    final response = await HttpSvc.server.info();
    if (response.statusCode == 200) {
      final List<String> toSave = [];
      if (settings.iCloudAccount.isEmpty && response.data['data']['detected_icloud'] is String) {
        settings.iCloudAccount.value = response.data['data']['detected_icloud'];
        toSave.add('iCloudAccount');
      }

      if (response.data['data']['private_api'] is bool) {
        settings.serverPrivateAPI.value = response.data['data']['private_api'];
        toSave.add('serverPrivateAPI');
      }

      final details = ServerDetails.fromServerInfo(response.data['data']);
      await _syncServerPrivateApi(details.privateApiEnabled, toSave: toSave);
      await _saveServerDetails(details);

      if (toSave.isNotEmpty) {
        await settings.saveManyAsync(toSave);
      }

      return details.toMap();
    }

    // Empty rather than defaults, which would overwrite what's known about the server
    return {};
  }

  /// Fetches server details via HTTP (main isolate), updates [serverDetails],
  /// and persists values to [PrefsSvc]. Also handles [iCloudAccount] and
  /// [serverPrivateAPI] side effects.
  /// Used during the first-time setup flow.
  Future<ServerDetails> fetchServerDetails() async {
    final detailsDict = await getServerDetailsDict();
    final details = detailsDict.isEmpty
        ? const ServerDetails(macOSVersion: 11, macOSMinorVersion: 0, serverVersion: "0.0.0", serverVersionCode: 0)
        : ServerDetails.fromMap(detailsDict);
    _serverDetails.value = details;
    return details;
  }

  /// Offers to turn on Private API features, once, when the server has them set up but the client doesn't.
  ///
  /// Called from the conversation list rather than during setup, because the popup needs a finished setup
  /// and a conversation list to navigate back from.
  Future<void> showPrivateApiTipIfNeeded() async {
    if (!settings.finishedSetup.value ||
        settings.enablePrivateAPI.value ||
        settings.serverPrivateAPI.value != true ||
        PrefsSvc.server.isPrivateApiDisabledByUser() ||
        PrefsSvc.server.hasSeenPrivateApiEnableTip() ||
        _showingPapiPopup) {
      return;
    }
    await _showPapiPopup();
  }

  /// Refreshes [serverDetails] in the background via [ServerInterface]
  /// (routes through the GlobalIsolate on all platforms). Updates [serverDetails]
  /// and persists the new values to [PrefsSvc]. Safe to call fire-and-forget.
  Future<void> refreshServerDetails() async {
    try {
      await updateServerDetails(await ServerInterface.getServerDetails());
    } catch (e, s) {
      Logger.warn("Failed to refresh server details", error: e, trace: s, tag: 'SettingsService');
    }
  }

  /// Decodes base64 avatar data (stripping optional `data:image/...;base64,` URI prefix).
  static Uint8List? decodeAvatarBase64(String? raw) {
    if (raw == null) return null;
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final commaIdx = trimmed.indexOf(',');
    if (trimmed.startsWith('data:') && commaIdx != -1) {
      trimmed = trimmed.substring(commaIdx + 1).trim();
    }
    if (trimmed.isEmpty) return null;
    try {
      final bytes = base64Decode(trimmed);
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// Extracts a non-generic display name from an iCloud account or contact payload.
  static String? extractDisplayName(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) return null;
    for (final key in const ['name', 'full_name', 'fullName', 'display_name', 'displayName', 'account_name', 'accountName']) {
      final val = map[key]?.toString().trim();
      if (val != null && val.isNotEmpty && val != 'You') return val;
    }
    final first = (map['first_name'] ?? map['firstName'])?.toString().trim() ?? '';
    final last = (map['last_name'] ?? map['lastName'])?.toString().trim() ?? '';
    final combined = '$first $last'.trim();
    if (combined.isNotEmpty && combined != 'You') return combined;
    return null;
  }

  /// Fetches `/api/v1/icloud/account` and `/api/v1/icloud/contact` on all platforms
  /// (including Web) and populates `userName`, `iCloudAccount`, aliases, and self avatar.
  /// Errors are silently swallowed without snackbars.
  Future<void> refreshIcloudProfile({bool force = false}) {
    if (_icloudProfileRefreshFuture != null) return _icloudProfileRefreshFuture!;
    final future = _refreshIcloudProfileImpl(force: force).whenComplete(() {
      _icloudProfileRefreshFuture = null;
    });
    _icloudProfileRefreshFuture = future;
    return future;
  }

  Future<void> _refreshIcloudProfileImpl({bool force = false}) async {
    if (!force && !settings.finishedSetup.value) return;
    final now = DateTime.now();
    if (!force && _lastIcloudProfileRefresh != null && now.difference(_lastIcloudProfileRefresh!).inSeconds < 60) {
      return;
    }

    // Hydrate in-memory web avatar bytes if already cached from a prior session.
    if (kIsWeb && userAvatarBytes.value == null && settings.userAvatarPath.value != null) {
      userAvatarBytes.value = FilesystemSvc.getCachedWebAvatarByPath(settings.userAvatarPath.value!);
    }

    Map<String, dynamic>? accountData;
    Map<String, dynamic>? contactData;

    try {
      final res = await HttpSvc.icloud.getAccountInfo();
      final data = res.data is Map ? res.data['data'] : null;
      if (data is Map) {
        accountData = Map<String, dynamic>.from(data);
      }
    } catch (_) {
      // Silently swallow per requirement (no snackbar on startup/socket connect).
    }

    try {
      final res = await HttpSvc.icloud.getAccountContact();
      final data = res.data is Map ? res.data['data'] : null;
      if (data is Map) {
        contactData = Map<String, dynamic>.from(data);
      }
    } catch (_) {
      // Silently swallow per requirement.
    }

    if (accountData != null || contactData != null) {
      _lastIcloudProfileRefresh = now;
      await applyIcloudProfileData(account: accountData, contact: contactData);
    }
  }

  /// Applies fetched `/icloud/account` and `/icloud/contact` payloads into [settings]
  /// and reactive profile fields, persisting `userName`, `iCloudAccount`, and `userAvatarPath`.
  Future<void> applyIcloudProfileData({
    Map<String, dynamic>? account,
    Map<String, dynamic>? contact,
    bool persist = true,
  }) async {
    final List<String> toSave = [];

    if (account != null && account.isNotEmpty) {
      iCloudAccountInfo.assignAll(account);
      final activeAlias =
          (account['active_alias'] ?? account['activeAlias'] ?? contact?['active_alias'] ?? contact?['activeAlias'])
                  ?.toString()
                  .trim() ??
              '';
      if (activeAlias.isNotEmpty) {
        iCloudActiveAlias.value = activeAlias;
      }
      final rawAliases = account['vetted_aliases'] ??
          account['vettedAliases'] ??
          account['aliases'] ??
          account['active_aliases'] ??
          contact?['aliases'] ??
          contact?['active_aliases'];
      if (rawAliases is List) {
        final parsed = rawAliases
            .map((e) => e is Map ? (e['Alias'] ?? e['alias'])?.toString().trim() : e?.toString().trim())
            .whereType<String>()
            .where((e) => e.isNotEmpty)
            .toList();
        iCloudAliases.assignAll(parsed);
      }
      final appleId =
          (account['apple_id'] ?? account['appleId'] ?? account['email'] ?? contact?['apple_id'] ?? contact?['appleId'])
                  ?.toString()
                  .trim() ??
              '';
      final preferredAccount = appleId.isNotEmpty ? appleId : activeAlias;
      if (preferredAccount.isNotEmpty && settings.iCloudAccount.value != preferredAccount) {
        settings.iCloudAccount.value = preferredAccount;
        toSave.add('iCloudAccount');
      }
    }

    if (contact != null && contact.isNotEmpty) {
      iCloudContactInfo.assignAll(contact);
    }

    final fetchedName = extractDisplayName(contact) ?? extractDisplayName(account);
    final currentName = settings.userName.value.trim();
    if (fetchedName != null && (currentName.isEmpty || currentName == 'You')) {
      settings.userName.value = fetchedName;
      toSave.add('userName');
    }

    final avatarBytes = decodeAvatarBase64((contact?['avatar'] ?? account?['avatar'])?.toString());
    if (avatarBytes != null) {
      userAvatarBytes.value = avatarBytes;
      final existingPath = settings.userAvatarPath.value;
      final bool hasExistingAvatar = existingPath != null &&
          existingPath.isNotEmpty &&
          (kIsWeb ? FilesystemSvc.getCachedWebAvatarByPath(existingPath) != null : File(existingPath).existsSync());
      if (!hasExistingAvatar && persist) {
        if (kIsWeb) {
          if (GetIt.I.isRegistered<FilesystemService>()) {
            final webPath = await FilesystemSvc.saveWebAvatar('you', avatarBytes);
            settings.userAvatarPath.value = webPath;
            toSave.add('userAvatarPath');
          }
        } else if (GetIt.I.isRegistered<FilesystemService>()) {
          try {
            final file = File(join(FilesystemSvc.avatarsPath, 'you', 'avatar-icloud.jpg'));
            await file.create(recursive: true);
            await file.writeAsBytes(avatarBytes, flush: true);
            settings.userAvatarPath.value = file.path;
            toSave.add('userAvatarPath');
          } catch (e, s) {
            Logger.warn("Failed to persist iCloud avatar file", error: e, trace: s, tag: 'SettingsService');
          }
        }
      }
    }

    if (persist && toSave.isNotEmpty) {
      try {
        await settings.saveManyAsync(toSave);
      } catch (_) {
        // Silently ignore persistence errors when isolate/DB is not initialized (e.g. unit tests).
      }
    }
  }

  /// Caches and persists [details] fetched elsewhere, so the cache doesn't keep showing the previous server.
  Future<void> updateServerDetails(ServerDetails details) async {
    _serverDetails.value = details;
    final List<String> toSave = [];
    await _syncServerPrivateApi(details.privateApiEnabled, toSave: toSave);
    if (toSave.isNotEmpty) {
      await settings.saveManyAsync(toSave);
    }
    await _saveServerDetails(details);
  }

  Future<void> _syncServerPrivateApi(bool? serverPrivateApi, {List<String>? toSave}) async {
    if (serverPrivateApi == null) return;
    if (settings.serverPrivateAPI.value != serverPrivateApi) {
      settings.serverPrivateAPI.value = serverPrivateApi;
      toSave?.add('serverPrivateAPI');
    }
    if (!serverPrivateApi || PrefsSvc.server.isPrivateApiDisabledByUser()) return;

    if (!settings.enablePrivateAPI.value) {
      settings.enablePrivateAPI.value = true;
      toSave?.add('enablePrivateAPI');
      if (!settings.privateAPISend.value) {
        settings.privateAPISend.value = true;
        toSave?.add('privateAPISend');
      }
    }
    if (!PrefsSvc.server.hasSeenPrivateApiEnableTip()) {
      await PrefsSvc.server.markPrivateApiEnableTipShown();
    }
  }

  Future<void> _saveServerDetails(ServerDetails details) async {
    await PrefsSvc.server.setServerDetails(
      macOSVersion: details.macOSVersion,
      macOSMinorVersion: details.macOSMinorVersion,
      serverVersion: details.serverVersion,
      serverVersionCode: details.serverVersionCode,
      apiVersions: details.apiVersions,
      serverBuildVersion: details.serverBuildVersion ?? "",
      supportsFaceTimeCalls: details.supportsFaceTimeCallsFlag,
    );
  }

  /// Returns the current cached [ServerDetails].
  ServerDetails getServerDetails() => _serverDetails.value;

  Future<void> _showPapiPopup() async {
    final ScrollController controller = ScrollController();
    if (_showingPapiPopup) Navigator.of(Get.context!).pop();
    _showingPapiPopup = true;
    await showBBDialog(
      context: Get.context!,
      barrierDismissible: false,
      title: "Private API Features",
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: min(Get.context!.height / 3, Get.context!.height - 300)),
            child: ScrollbarWrapper(
              controller: controller,
              showScrollbar: true,
              child: SingleChildScrollView(
                controller: controller,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("You've enabled Private API Features on your server!"),
                    const SizedBox(height: 10),
                    const Text("Private API features give you the ability to:"),
                    const Text(" - Send & Receive typing indicators"),
                    const Text(" - Send tapbacks, effects, and mentions"),
                    const Text(" - Send messages with subject lines"),
                    if (_serverDetails.value.isMinBigSur) const Text(" - Send replies"),
                    if (_serverDetails.value.isMinVentura) const Text(" - Edit & Unsend messages"),
                    const SizedBox(height: 10),
                    const Text(" - Mark chats read on the Mac server"),
                    if (_serverDetails.value.isMinVentura) const Text(" - Mark chats as unread on the Mac server"),
                    const SizedBox(height: 10),
                    const Text(" - Rename group chats"),
                    const Text(" - Add & remove people from group chats"),
                    if (_serverDetails.value.isMinBigSur) const Text(" - Change the group chat photo"),
                    if (_serverDetails.value.isMinBigSur) const SizedBox(height: 10),
                    if (_serverDetails.value.isMinMonterey) const Text(" - View Focus statuses"),
                    if (_serverDetails.value.isMinBigSur) const Text(" - Use Find My Friends"),
                    if (_serverDetails.value.isMinBigSur) const Text(" - Be notified of incoming FaceTime calls"),
                    if (_serverDetails.value.isMinVentura) const Text(" - Answer FaceTime calls (experimental)"),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.center,
                child: ElevatedButton(
                  onPressed: () async {
                    await PrefsSvc.server.markPrivateApiEnableTipShown();
                    if (Get.context == null) return;
                    Navigator.of(Get.context!, rootNavigator: true).pop();
                    NavigationSvc.closeSettings(Get.context!);
                    NavigationSvc.closeAllConversationView(Get.context!);
                    await ChatsSvc.setAllInactive();
                    await Navigator.of(Get.context!).push(
                      ThemeSwitcher.buildPageRoute(
                        builder: (BuildContext context) {
                          return SettingsPage(
                            initialPage: PrivateAPIPanel(
                              enablePrivateAPIonInit: true,
                            ),
                          );
                        },
                      ),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      "Enable Private API Features",
                      textScaler: TextScaler.linear(1.2),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.center,
                child: TextButton(
                  onPressed: () async {
                    await PrefsSvc.server.markPrivateApiEnableTipShown();
                    if (Get.context == null) return;
                    Navigator.of(Get.context!, rootNavigator: true).pop();
                  },
                  child: const Text("Don't ask again"),
                ),
              )
            ],
          ),
        ],
      ),
    );
    _showingPapiPopup = false;
  }

  /// Returns the current cached [ServerDetails].
  ServerDetails get serverDetails => _serverDetails.value;

  /// Several attachments can go as one message: the server takes attachment parts, and they need the Private API.
  bool get canSendAttachmentsTogether =>
      serverDetails.supportsMultiAttachmentSend &&
      settings.enablePrivateAPI.value &&
      settings.privateAPIAttachmentSend.value;

  /// Group chats can be created on macOS <= Catalina or
  /// if the Private API is enabled, and the server supports it (v1.8.0).
  bool canCreateGroupChat() {
    return canCreateGroupChatSync();
  }

  /// Group chats can be created on macOS <= Catalina or
  /// if the Private API is enabled, and the server supports it (v1.8.0).
  bool canCreateGroupChatSync() {
    bool papiEnabled = settings.enablePrivateAPI.value;
    return (_serverDetails.value.supportsCreateGroupChat && papiEnabled) || !_serverDetails.value.isMinBigSur;
  }

  Future<Map<String, dynamic>> getServerUpdateDict() async {
    final response = await HttpSvc.server.checkUpdate();
    if (response.statusCode == 200) {
      bool available = response.data['data']['available'] ?? false;
      Map<String, dynamic> metadata = response.data['data']['metadata'] ?? {};

      return {
        'available': available,
        'metadata': metadata,
      };
    }

    return {
      'available': false,
      'metadata': <String, dynamic>{},
    };
  }

  Future<ServerUpdateInfo> checkForServerUpdate() async {
    final updateDict = await getServerUpdateDict();
    final metadata = updateDict['metadata'] as Map<String, dynamic>;

    return ServerUpdateInfo(
      available: updateDict['available'] as bool,
      version: metadata['version'] as String?,
      releaseDate: metadata['release_date'] as String?,
      releaseName: metadata['release_name'] as String?,
    );
  }

  Future<void> checkServerUpdate() async {
    late ServerUpdateInfo updateInfo;
    if (!kIsWeb && Platform.isAndroid) {
      updateInfo = await ServerInterface.checkForServerUpdate();
    } else {
      updateInfo = await checkForServerUpdate();
    }

    if (!updateInfo.available ||
        (updateInfo.version != null && PrefsSvc.server.getServerUpdateCheckVersion() == updateInfo.version)) {
      return;
    }

    showBBDialog(
      context: Get.context!,
      title: "Server Update Check",
      content: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 15.0),
          Text(updateInfo.available ? "Updates available:" : "Your server is up-to-date!"),
          const SizedBox(height: 15.0),
          if (updateInfo.version != null)
            Text(
              "Version: ${updateInfo.version ?? "Unknown"}\nRelease Date: ${updateInfo.releaseDate ?? "Unknown"}\nRelease Name: ${updateInfo.releaseName ?? "Unknown"}\n\nWarning: Installing the update will briefly disconnect you.",
            )
        ],
      ),
      actions: [
        BBDialogAction(
          text: "OK",
          onPressed: () async {
            if (updateInfo.version != null) {
              await PrefsSvc.server.setServerUpdateCheckVersion(updateInfo.version!);
            }
            Navigator.of(Get.context!, rootNavigator: true).pop();
          },
        ),
        BBDialogAction(
          text: "Install",
          isDefault: true,
          onPressed: () async {
            if (updateInfo.version != null) {
              await PrefsSvc.server.setServerUpdateCheckVersion(updateInfo.version!);
            }
            HttpSvc.server.installUpdate();
            Navigator.of(Get.context!, rootNavigator: true).pop();
          },
        ),
      ],
    );
  }

  Future<Map<String, dynamic>> getAppUpdateDict() async {
    bool available = true;
    if (!kIsDesktop && (kIsWeb || (await StoreChecker.getSource) != Source.IS_INSTALLED_FROM_LOCAL_SOURCE)) {
      available = false;
    }
    if (kIsDesktop) {
      available = false;
    }

    final github = GitHub();
    final stream = github.repositories.listReleases(RepositorySlug('bluebubblesapp', 'bluebubbles-app'));
    // Platform-only tags (v2.1.3+desktop.93, v2.1.5+android.95) are skipped by the other platform.
    final release = await stream.firstWhere((element) =>
        !(element.isDraft ?? false) &&
        !(element.isPrerelease ?? false) &&
        element.tagName != null &&
        !(!kIsWeb && Platform.isAndroid && element.tagName!.split('+').last.contains('desktop')) &&
        !(kIsDesktop && element.tagName!.split('+').last.contains('android')));
    final version = release.tagName!.split("+").first.replaceAll("v", "");
    // The build after the "+", without a platform prefix: v2.1.5+95 and v2.1.5+android.95 are both 95
    final code = release.tagName!.split("+").last.split('-').first.split('.').last;
    final isDesktopRelease = release.tagName!.split('+').last.contains('desktop');

    String buildNumber = "";
    if (!kIsWeb && Platform.isAndroid) {
      buildNumber =
          FilesystemSvc.packageInfo.buildNumber.lastChars(min(4, FilesystemSvc.packageInfo.buildNumber.length));
      if (int.parse(code) <= int.parse(buildNumber) || PrefsSvc.server.getClientUpdateCheckCode() == code) {
        available = false;
      }
    } else {
      final latestRelease = Version(
        int.parse(version.split(".")[0]),
        int.parse(version.split(".")[1]),
        int.parse(version.split(".")[2]),
      );
      final current = Version(
        int.parse(FilesystemSvc.packageInfo.version.split(".")[0]),
        int.parse(FilesystemSvc.packageInfo.version.split(".")[1]),
        int.parse(FilesystemSvc.packageInfo.version.split(".")[2]),
      );
      if (current.compareTo(latestRelease) < 0 &&
          PrefsSvc.server.getClientUpdateCheckCode() != code &&
          await _isReleaseInStore(latestRelease)) {
        available = true;
      }
    }

    return {
      'available': available,
      'latestRelease': release,
      'isDesktopRelease': isDesktopRelease,
      'parsedVersion': {
        'version': version,
        'code': code,
        'build': buildNumber,
      }
    };
  }

  /// Store listings lag behind GitHub releases, so only report an update once the install's store has it.
  Future<bool> _isReleaseInStore(Version release) async {
    if (!isSnap && !isFlatpak) return true;
    try {
      final dio = Dio();
      String? storeVersion;
      if (isSnap) {
        final res = await dio.get("https://api.snapcraft.io/v2/snaps/info/bluebubbles?fields=version",
            options: Options(headers: {'Snap-Device-Series': '16'}));
        storeVersion = (res.data['channel-map'] as List)
            .firstWhere((e) => e['channel']['name'] == 'stable')['version'] as String;
      } else {
        final res = await dio.get("https://flathub.org/api/v2/appstream/app.bluebubbles.BlueBubbles");
        storeVersion = res.data['releases'][0]['version'] as String;
      }
      final parts = storeVersion.split('.').map(int.parse).toList();
      return Version(parts[0], parts[1], parts[2]) >= release;
    } catch (e, s) {
      Logger.warn("Failed to check store version", error: e, trace: s);
      return false;
    }
  }

  /// Play installs can't use GitHub releases, so Play downloads the update in the background instead.
  Future<void> _checkPlayUpdate() async {
    try {
      final info = await play.InAppUpdate.checkForUpdate();
      final versionCode = info.availableVersionCode;
      if (info.updateAvailability != play.UpdateAvailability.updateAvailable ||
          !info.flexibleUpdateAllowed ||
          versionCode == null ||
          PrefsSvc.server.getClientUpdateCheckCode() == versionCode.toString()) {
        return;
      }
      // Play only reports a version code, not a version name.
      _showUpdateDialog(
        code: versionCode.toString(),
        version: null,
        release: null,
        actionText: "Install",
        onAction: () async {
          try {
            if (await play.InAppUpdate.startFlexibleUpdate() != play.AppUpdateResult.success) return;
            showSnackbar(
              "Update Downloaded",
              "Restart BlueBubbles to finish updating",
              durationMs: 10000,
              actionLabel: "Restart",
              onAction: () => play.InAppUpdate.completeFlexibleUpdate(),
            );
          } catch (e, s) {
            Logger.warn("Failed to start Play Store update", error: e, trace: s);
          }
        },
      );
    } catch (e, s) {
      Logger.warn("Failed to check Play Store for updates", error: e, trace: s);
    }
  }

  /// Store-signed MSIX installs can't upgrade from GitHub builds, so hand the update to the Store's install dialog.
  Future<void> _checkMsStoreUpdate() async {
    const channel = MethodChannel('bluebubbles/store');
    try {
      final storeVersion = await channel.invokeMethod<String>('checkUpdate');
      if (storeVersion == null || PrefsSvc.server.getClientUpdateCheckCode() == storeVersion) return;
      _showUpdateDialog(
        code: storeVersion,
        version: storeVersion.split('.').take(3).join('.'),
        release: null,
        actionText: "Install",
        onAction: () async {
          try {
            await channel.invokeMethod('installUpdate');
          } catch (e, s) {
            Logger.warn("Failed to start Microsoft Store update", error: e, trace: s);
          }
        },
      );
    } catch (e, s) {
      Logger.warn("Failed to check Microsoft Store for updates", error: e, trace: s);
    }
  }

  /// [code] is saved on either button so each version is only offered once. [onAction] runs after the dialog closes.
  void _showUpdateDialog({
    required String code,
    required String? version,
    required Release? release,
    required String actionText,
    required Future<void> Function() onAction,
  }) {
    showBBDialog(
      context: Get.context!,
      title: "App Update Check",
      content: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 15.0),
          const Text("Updates available:"),
          const SizedBox(height: 15.0),
          Text(
            [
              if (version != null) "Version: $version",
              if (release != null) "Release Date: ${buildDate(release.createdAt)}",
              if (release != null) "Release Name: ${release.name}",
            ].join("\n"),
          ),
        ],
      ),
      actions: [
        BBDialogAction(
          text: actionText,
          onPressed: () async {
            await PrefsSvc.server.setClientUpdateCheckCode(code);
            Navigator.of(Get.context!, rootNavigator: true).pop();
            await onAction();
          },
        ),
        BBDialogAction(
          text: "OK",
          isDefault: true,
          onPressed: () async {
            await PrefsSvc.server.setClientUpdateCheckCode(code);
            Navigator.of(Get.context!, rootNavigator: true).pop();
          },
        ),
      ],
    );
  }

  Future<AppUpdateInfo> checkForUpdate() async {
    final updateDict = await getAppUpdateDict();
    return AppUpdateInfo(
      available: updateDict['available'] as bool,
      latestRelease: updateDict['latestRelease'] as Release,
      isDesktopRelease: updateDict['isDesktopRelease'] as bool,
      version: (updateDict['parsedVersion'] as Map<String, String>)['version']!,
      code: (updateDict['parsedVersion'] as Map<String, String>)['code']!,
      buildNumber: (updateDict['parsedVersion'] as Map<String, String>)['build']!,
    );
  }

  Future<void> checkClientUpdate() async {
    if (kIsWeb) return;
    if (Platform.isAndroid && await StoreChecker.getSource == Source.IS_INSTALLED_FROM_PLAY_STORE) {
      return _checkPlayUpdate();
    }
    if (isStoreMsix) return _checkMsStoreUpdate();
    late AppUpdateInfo updateInfo;
    if (Platform.isAndroid) {
      updateInfo = await AppInterface.checkForUpdate();
    } else {
      updateInfo = await checkForUpdate();
    }
    if (!updateInfo.available) return;

    _showUpdateDialog(
      code: updateInfo.code,
      version: updateInfo.version,
      release: updateInfo.latestRelease,
      actionText: "Download",
      onAction: () async {
        final url = isSnap
            ? "https://snapcraft.io/bluebubbles"
            : isFlatpak
            ? "https://flathub.org/apps/app.bluebubbles.BlueBubbles"
            : updateInfo.latestRelease.htmlUrl ?? "https://github.com/BlueBubblesApp/bluebubbles-app/releases";
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      },
    );
  }
}
