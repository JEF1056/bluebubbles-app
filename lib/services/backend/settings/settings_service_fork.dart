part of 'settings_service.dart';

/// Decodes base64 avatar data (stripping optional `data:image/...;base64,` URI prefix and whitespace).
Uint8List? _decodeIcloudAvatarBase64(String? raw) {
  if (raw == null) return null;
  var trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final commaIdx = trimmed.indexOf(',');
  if (trimmed.startsWith('data:') && commaIdx != -1) {
    trimmed = trimmed.substring(commaIdx + 1);
  }
  final compact = trimmed.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return null;
  try {
    final bytes = base64Decode(base64.normalize(compact));
    if (bytes.length < 8) return null;
    // Reject accidental JSON/HTML error strings masquerading as base64.
    if (bytes[0] == 0x7B || bytes[0] == 0x5B || bytes[0] == 0x3C) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Extracts a non-generic display name from an iCloud account or contact payload.
String? _extractIcloudDisplayName(Map<String, dynamic>? map) {
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

extension SettingsServiceFork on SettingsService {
  /// Populates [userAvatarBytes] from persisted local/Web cache on startup so the
  /// user's avatar renders immediately before network profile refresh completes.
  Future<void> hydrateCachedUserAvatar() async {
    if (userAvatarBytes.value != null) return;
    final path = settings.userAvatarPath.value?.trim();
    if (path == null || path.isEmpty) return;
    if (kIsWeb) {
      if (!GetIt.I.isRegistered<FilesystemService>()) return;
      final cached = FilesystemSvc.getCachedWebAvatarByPath(path);
      if (cached != null && cached.isNotEmpty) {
        userAvatarBytes.value = cached;
      }
      return;
    }
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        userAvatarBytes.value = bytes;
      }
    } catch (_) {}
  }

  /// Fetches `/api/v1/icloud/account` and `/api/v1/icloud/contact` on all platforms
  /// (including Web) and populates `userName`, `iCloudAccount`, aliases, and self avatar.
  /// Errors are silently swallowed without snackbars.
  Future<void> refreshIcloudProfile({bool force = false}) {
    if (_icloudProfileRefreshFuture != null && (!force || _icloudProfileRefreshForced)) {
      return _icloudProfileRefreshFuture!;
    }
    final generation = ++_icloudProfileGeneration;
    _icloudProfileRefreshForced = force;
    final future = _refreshIcloudProfileImpl(force: force, generation: generation).whenComplete(() {
      if (_icloudProfileGeneration == generation) {
        _icloudProfileRefreshFuture = null;
        _icloudProfileRefreshForced = false;
      }
    });
    _icloudProfileRefreshFuture = future;
    return future;
  }

  Future<void> _refreshIcloudProfileImpl({bool force = false, int? generation}) async {
    if (!force && !settings.finishedSetup.value) return;
    final now = DateTime.now();
    if (!force && _lastIcloudProfileRefresh != null && now.difference(_lastIcloudProfileRefresh!).inSeconds < 60) {
      return;
    }

    await hydrateCachedUserAvatar();

    // Silently swallow errors per requirement (no snackbar on startup/socket connect).
    Future<Map<String, dynamic>?> fetchMap(Future<dynamic> Function() call) async {
      try {
        final res = await call();
        final data = res.data is Map ? res.data['data'] : null;
        return data is Map ? Map<String, dynamic>.from(data) : null;
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait([
      fetchMap(HttpSvc.icloud.getAccountInfo),
      fetchMap(HttpSvc.icloud.getAccountContact),
    ]);
    if (generation != null && generation != _icloudProfileGeneration) return;

    final accountData = results[0];
    final contactData = results[1];

    if (accountData != null || contactData != null) {
      await applyIcloudProfileData(account: accountData, contact: contactData);
      // Only throttle subsequent unforced refreshes once contactData succeeded (or an avatar is present),
      // so startup races before localhost/socket/auth settles still retry on onConnect.
      if (contactData != null || userAvatarBytes.value != null) {
        _lastIcloudProfileRefresh = now;
      }
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

    final fetchedName = _extractIcloudDisplayName(contact) ?? _extractIcloudDisplayName(account);
    final currentName = settings.userName.value.trim();
    if (fetchedName != null && (currentName.isEmpty || currentName == 'You')) {
      settings.userName.value = fetchedName;
      toSave.add('userName');
    }

    final avatarBytes =
        _decodeIcloudAvatarBase64(contact?['avatar']?.toString()) ?? _decodeIcloudAvatarBase64(account?['avatar']?.toString());
    if (avatarBytes != null) {
      final existingPath = settings.userAvatarPath.value;
      final bool isWebPath = existingPath != null && existingPath.startsWith('web-avatar://');
      final bool hasCustomWebAvatar = (kIsWeb || isWebPath) &&
          existingPath != null &&
          FilesystemService.stripWebPathVersion(existingPath) != 'web-avatar://you-icloud' &&
          GetIt.I.isRegistered<FilesystemService>() &&
          (FilesystemSvc.getCachedWebAvatarByPath(existingPath)?.isNotEmpty ?? false);
      final bool hasCustomIoAvatar = !kIsWeb &&
          !isWebPath &&
          existingPath != null &&
          existingPath.isNotEmpty &&
          !existingPath.endsWith('avatar-icloud.jpg') &&
          File(existingPath).existsSync() &&
          File(existingPath).lengthSync() > 0;
      if (!hasCustomWebAvatar && !hasCustomIoAvatar) {
        if (!listEquals(userAvatarBytes.value, avatarBytes)) {
          userAvatarBytes.value = avatarBytes;
        }
        if (persist && GetIt.I.isRegistered<FilesystemService>()) {
          if (kIsWeb || isWebPath) {
            final cachedBytes =
                existingPath != null ? FilesystemSvc.getCachedWebAvatarByPath(existingPath) : null;
            if (cachedBytes == null || !listEquals(cachedBytes, avatarBytes)) {
              settings.userAvatarPath.value = await FilesystemSvc.saveWebAvatar('you-icloud', avatarBytes);
              toSave.add('userAvatarPath');
            }
          } else {
            try {
              final file = File(join(FilesystemSvc.avatarsPath, 'you', 'avatar-icloud.jpg'));
              final existingFileBytes = await file.exists() ? await file.readAsBytes() : null;
              if (existingFileBytes == null || !listEquals(existingFileBytes, avatarBytes)) {
                await file.create(recursive: true);
                await file.writeAsBytes(avatarBytes, flush: true);
                try {
                  await FileImage(file).evict();
                  await ResizeImage(FileImage(file), width: 256, height: 256, policy: ResizeImagePolicy.fit).evict();
                } catch (_) {}
              }
              if (settings.userAvatarPath.value != file.path) {
                settings.userAvatarPath.value = file.path;
                toSave.add('userAvatarPath');
              }
            } catch (e, s) {
              Logger.warn("Failed to persist iCloud avatar file", error: e, trace: s, tag: 'SettingsService');
            }
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
}
