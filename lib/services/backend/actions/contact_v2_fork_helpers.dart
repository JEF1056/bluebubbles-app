part of 'contact_v2_actions.dart';

Set<String> _phoneNumberVariants(String phone) {
  final variants = <String>{};
  final normalized = ContactV2.normalizePhoneNumber(phone);

  if (normalized.isEmpty) return variants;

  variants.add(normalized);

  if (normalized.startsWith('+')) {
    variants.add(normalized.substring(1));

    for (int i = 1; i <= 3 && i < normalized.length; i++) {
      final withoutCountryCode = normalized.substring(i + 1);
      if (withoutCountryCode.isNotEmpty) {
        variants.add(withoutCountryCode);
      }
    }
  } else {
    variants.add('+$normalized');

    for (int i = 1; i <= 3 && i < normalized.length; i++) {
      final withoutPrefix = normalized.substring(i);
      if (withoutPrefix.isNotEmpty) {
        variants.add(withoutPrefix);
        variants.add('+$withoutPrefix');
      }
    }
  }

  return variants;
}

ContactV2? _matchContactForAddress(Iterable<ContactV2> contacts, String address) {
  final trimmed = address.trim();
  if (trimmed.isEmpty) return null;

  final isEmail = trimmed.contains('@');
  final normalizedEmail = isEmail ? ContactV2.normalizeEmail(trimmed) : null;
  final queryVariants = isEmail ? const <String>{} : _phoneNumberVariants(trimmed);
  if (!isEmail && queryVariants.isEmpty) return null;

  ContactV2? firstMatch;
  for (final contact in contacts) {
    bool matched = false;
    if (isEmail) {
      matched = contact.addresses.contains(normalizedEmail);
    } else {
      for (final contactAddr in contact.addresses) {
        if (contactAddr.contains('@')) continue;
        if (queryVariants.contains(contactAddr) || _phoneNumberVariants(contactAddr).any(queryVariants.contains)) {
          matched = true;
          break;
        }
      }
    }
    if (!matched) continue;
    if (!isNullOrEmpty(contact.avatarPath)) return contact;
    firstMatch ??= contact;
  }
  return firstMatch;
}

List<int> _linkHandlesToContactsInTx(List<Handle> handles) {
  if (handles.isEmpty) return const [];

  final allContacts = Database.contactsV2.getAll();
  if (allContacts.isEmpty) return const [];

  final emailContactMap = <String, List<ContactV2>>{};
  final phoneContactMap = <String, List<ContactV2>>{};

  for (final contact in allContacts) {
    for (final addr in contact.addresses) {
      if (addr.contains('@')) {
        emailContactMap.putIfAbsent(addr, () => []).add(contact);
      } else {
        for (final variant in _phoneNumberVariants(addr)) {
          phoneContactMap.putIfAbsent(variant, () => []).add(contact);
        }
      }
    }
  }

  final updatedContacts = <ContactV2>{};
  final affectedHandleIds = <int>{};

  for (final handle in handles) {
    final handleId = handle.id;
    if (handleId == null || handleId == 0) continue;

    final matchedContacts = <ContactV2>{};
    if (handle.address.contains('@')) {
      matchedContacts.addAll(emailContactMap[ContactV2.normalizeEmail(handle.address)] ?? const []);
      if (handle.formattedAddress != null) {
        matchedContacts.addAll(emailContactMap[ContactV2.normalizeEmail(handle.formattedAddress!)] ?? const []);
      }
    } else {
      for (final variant in _phoneNumberVariants(handle.address)) {
        matchedContacts.addAll(phoneContactMap[variant] ?? const []);
      }
      if (handle.formattedAddress != null) {
        for (final variant in _phoneNumberVariants(handle.formattedAddress!)) {
          matchedContacts.addAll(phoneContactMap[variant] ?? const []);
        }
      }
    }

    for (final contact in matchedContacts) {
      if (!contact.handles.any((existing) => existing.id == handleId)) {
        contact.handles.add(handle);
        updatedContacts.add(contact);
        affectedHandleIds.add(handleId);
      }
    }
  }

  if (updatedContacts.isNotEmpty) {
    Database.contactsV2.putMany(updatedContacts.toList());
  }
  return affectedHandleIds.toList();
}

String? _resolveUpdatedAvatarPath({
  required String? existingAvatarPath,
  required bool hasPrefetchedEntry,
  required String? prefetchedAvatarPath,
  required bool isServerContact,
  required bool serverFetchAttempted,
  required bool serverFetchSucceeded,
}) {
  if (!hasPrefetchedEntry) return existingAvatarPath;
  if (prefetchedAvatarPath != null) return prefetchedAvatarPath;
  // Prefetched entry is null: preserve previously server-enriched device avatars
  // when a server fetch was attempted but failed (offline / non-200 / invalid payload).
  if (isServerContact || !serverFetchAttempted || serverFetchSucceeded) {
    return null;
  }
  return existingAvatarPath;
}

Future<List<ContactV2>> _mergeServerContactMapsHelper({
  required List<Map<String, dynamic>> serverMaps,
  required List<fc.Contact> deviceContacts,
  required Map<String, String?> avatarPaths,
  Set<String> failedDeviceAvatarIds = const {},
  Set<String>? dedupedServerIdsOut,
  bool prefixServerIds = true,
}) async {
  final networkContacts = <ContactV2>[];
  final deviceEmailToId = <String, String>{};
  final devicePhoneVariantToId = <String, String>{};

  for (final dc in deviceContacts) {
    final id = dc.id;
    if (id == null) continue;
    for (final email in dc.emails) {
      final norm = ContactV2.normalizeEmail(email.address);
      if (norm.isNotEmpty) deviceEmailToId.putIfAbsent(norm, () => id);
    }
    for (final phone in dc.phones) {
      for (final variant in _phoneNumberVariants(phone.number)) {
        devicePhoneVariantToId.putIfAbsent(variant, () => id);
      }
    }
  }

  for (final map in serverMaps) {
    final displayName = getDisplayName(map['displayName'], map['firstName'], map['lastName']);
    final emails = (map['emails'] is List ? map['emails'] as List<dynamic> : const <dynamic>[])
        .whereType<Map>()
        .map((e) {
          final addr = e['address']?.toString().trim() ?? '';
          return addr.isEmpty ? null : ContactEmail(address: addr, label: e['label']?.toString() ?? '');
        })
        .whereType<ContactEmail>()
        .toList();
    final phones = (map['phoneNumbers'] is List ? map['phoneNumbers'] as List<dynamic> : const <dynamic>[])
        .whereType<Map>()
        .map((e) {
          final num = e['address']?.toString().trim() ?? '';
          return num.isEmpty ? null : ContactPhone(number: num, label: e['label']?.toString() ?? '');
        })
        .whereType<ContactPhone>()
        .toList();

    String? matchedDeviceId;
    for (final email in emails) {
      final norm = ContactV2.normalizeEmail(email.address);
      if (norm.isNotEmpty && deviceEmailToId.containsKey(norm)) {
        matchedDeviceId = deviceEmailToId[norm];
        break;
      }
    }
    if (matchedDeviceId == null) {
      for (final phone in phones) {
        for (final variant in _phoneNumberVariants(phone.number)) {
          if (devicePhoneVariantToId.containsKey(variant)) {
            matchedDeviceId = devicePhoneVariantToId[variant];
            break;
          }
        }
        if (matchedDeviceId != null) break;
      }
    }

    final rawId = (map['id'] ?? displayName).toString();
    final contactId = prefixServerIds ? 'server:$rawId' : rawId;

    if (matchedDeviceId != null) {
      dedupedServerIdsOut?.add(contactId);
      if (!failedDeviceAvatarIds.contains(matchedDeviceId) &&
          avatarPaths[matchedDeviceId] == null &&
          !isNullOrEmpty(map['avatar'])) {
        try {
          final savedPath = await ContactV2Actions._saveContactAvatar(
              matchedDeviceId, base64Decode(map['avatar'].toString()));
          if (savedPath != null) avatarPaths[matchedDeviceId] = savedPath;
        } catch (_) {}
      }
      continue;
    }

    if (!isNullOrEmpty(map['avatar'])) {
      try {
        final savedPath = await ContactV2Actions._saveContactAvatar(
            contactId, base64Decode(map['avatar'].toString()));
        if (savedPath != null) avatarPaths[contactId] = savedPath;
      } catch (_) {}
    } else {
      avatarPaths.putIfAbsent(contactId, () => null);
    }

    final normalizedAddresses = <String>{
      for (final p in phones)
        if (ContactV2.normalizePhoneNumber(p.number).isNotEmpty) ContactV2.normalizePhoneNumber(p.number),
      for (final e in emails)
        if (ContactV2.normalizeEmail(e.address).isNotEmpty) ContactV2.normalizeEmail(e.address),
    };

    final nc = ContactV2(
      nativeContactId: contactId,
      displayName: displayName,
      avatarPath: avatarPaths[contactId],
      addresses: normalizedAddresses.toList(),
      firstName: map['firstName']?.toString(),
      lastName: map['lastName']?.toString(),
    );
    nc.phoneNumbers = phones;
    nc.emailAddresses = emails;
    nc.isNative = false;
    networkContacts.add(nc);
  }

  return networkContacts;
}

bool _hasNativeContactChanges(Iterable<String?> currentDeviceIds, Iterable<ContactV2> storedContacts) {
  final currentIds = currentDeviceIds.whereType<String>().toSet();
  // Exclude server-fetched contacts (isNative == false) so they don't trigger infinite sync loops.
  final storedIds = storedContacts.where((c) => c.isNative).map((c) => c.nativeContactId).toSet();
  return currentIds.length != storedIds.length ||
      !currentIds.containsAll(storedIds) ||
      !storedIds.containsAll(currentIds);
}

String _webAvatarCacheKeyHelper(String contactId) => 'contact_avatar:${sanitizeFileName(contactId)}';
