import 'dart:async';
import 'dart:convert';
import 'package:universal_io/io.dart';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:bluebubbles/platform/shims/native_misc.dart' as fc;
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;

/// ContactV2Actions - Isolate-side logic for the new contact service
/// All operations here run in the GlobalIsolate to prevent UI jank
/// This follows the architecture outlined in FR-1.md
class ContactV2Actions {
  /// Completer to ensure syncContactsToHandles only runs once at a time
  static Completer<_ContactSyncStats>? _syncCompleter;

  /// Generate multiple normalized variants of a phone number to handle country code mismatches
  ///
  /// Returns a set of normalized phone numbers including:
  /// - The original normalized number (digits + plus sign only)
  /// - Variant without country code (if one exists)
  /// - Variant with country code removed but assuming it started with +
  ///
  /// This handles cases where:
  /// - Contact has "1234567890" but Handle has "+11234567890"
  /// - Contact has "+11234567890" but Handle has "1234567890"
  /// - Works with any country code, not just +1
  static Set<String> phoneNumberVariants(String phone) {
    final variants = <String>{};
    final normalized = ContactV2.normalizePhoneNumber(phone);

    if (normalized.isEmpty) return variants;

    // Always include the base normalized version
    variants.add(normalized);

    // If it starts with +, add variant without the +
    if (normalized.startsWith('+')) {
      variants.add(normalized.substring(1));

      // Also try removing common country codes (1-3 digits after +)
      // Country codes can be 1-3 digits (e.g., +1, +44, +852, +1246)
      for (int i = 1; i <= 3 && i < normalized.length; i++) {
        final withoutCountryCode = normalized.substring(i + 1);
        if (withoutCountryCode.isNotEmpty) {
          variants.add(withoutCountryCode);
        }
      }
    } else {
      // If no +, try adding + and common country code lengths
      // This handles cases where the stored number doesn't have + but the contact does
      variants.add('+$normalized');

      // Try removing 1-3 digit prefixes as potential country codes
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

  /// Find the best matching [ContactV2] for [address] across [contacts].
  /// Symmetrically compares phone variants on both sides and prefers a match
  /// that already has an avatar path when multiple contacts match.
  static ContactV2? matchContactForAddress(Iterable<ContactV2> contacts, String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return null;

    final isEmail = trimmed.contains('@');
    final normalizedEmail = isEmail ? ContactV2.normalizeEmail(trimmed) : null;
    final queryVariants = isEmail ? const <String>{} : phoneNumberVariants(trimmed);
    if (!isEmail && queryVariants.isEmpty) return null;

    ContactV2? firstMatch;
    for (final contact in contacts) {
      bool matched = false;
      if (isEmail) {
        matched = contact.addresses.contains(normalizedEmail);
      } else {
        for (final contactAddr in contact.addresses) {
          if (contactAddr.contains('@')) continue;
          if (queryVariants.contains(contactAddr) || phoneNumberVariants(contactAddr).any(queryVariants.contains)) {
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

  /// Link [handles] to matching existing [ContactV2] records inside an active
  /// write transaction. Returns the IDs of handles that were newly linked.
  static List<int> linkHandlesToContactsInTx(List<Handle> handles) {
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
          for (final variant in phoneNumberVariants(addr)) {
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
        for (final variant in phoneNumberVariants(handle.address)) {
          matchedContacts.addAll(phoneContactMap[variant] ?? const []);
        }
        if (handle.formattedAddress != null) {
          for (final variant in phoneNumberVariants(handle.formattedAddress!)) {
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

  /// Fetch all contacts from device and match them to existing handles
  /// This is the main operation described in Section II.A of FR-1.md
  ///
  /// Returns only the affected handle IDs — the shape every existing caller
  /// depends on. Use [syncContactsToHandlesWithStats] for the fetch/match
  /// counts as well (e.g. for diagnostic display).
  static Future<List<int>> syncContactsToHandles(dynamic data) async {
    final stats = await _syncContactsToHandlesInternal(data);
    return stats.affectedHandleIds;
  }

  /// Same operation as [syncContactsToHandles], but also returns the device
  /// contact count and matched-contact count — used by the Contacts
  /// Management page's manual refresh to show live diagnostic feedback.
  static Future<Map<String, dynamic>> syncContactsToHandlesWithStats(dynamic data) async {
    final stats = await _syncContactsToHandlesInternal(data);
    return stats.toMap();
  }

  static Future<_ContactSyncStats> _syncContactsToHandlesInternal(dynamic data) async {
    // If already processing, wait for the existing operation to complete
    if (_syncCompleter != null && !_syncCompleter!.isCompleted) {
      Logger.info('[ContactV2] Sync already in progress, waiting for completion...');
      return await _syncCompleter!.future;
    }

    // Create a new completer for this sync operation
    _syncCompleter = Completer<_ContactSyncStats>();

    // Optional account filter — set via the Contacts Management page. Null
    // means "all accounts" (the default, unfiltered behavior).
    final dataMap = data is Map ? data : const {};
    final includeDeviceContacts = dataMap['includeDeviceContacts'] != false;
    final accountName = dataMap['accountName'] as String?;
    final accountType = dataMap['accountType'] as String?;
    final account =
        (accountName != null && accountType != null) ? fc.Account(id: '', name: accountName, type: accountType) : null;

    final startTime = DateTime.now().millisecondsSinceEpoch;
    final affectedHandleIds = <int>[];
    int matchedContactCount = 0;

    try {
      List<fc.Contact> deviceContacts = [];
      List<ContactV2> networkContacts = [];
      final avatarPaths = <String, String?>{};
      final failedDeviceAvatarIds = <String>{};

      if (!kIsDesktop && !kIsWeb && includeDeviceContacts) {
        // Step 1: Fetch contacts using flutter_contacts (include thumbnails in the bulk query
        // so unmatched contacts don't need N+1 per-contact fetches, and matched contacts have
        // an immediate fallback if full-res fetch fails).
        Logger.info('[ContactV2] Starting contact fetch from device (flutter_contacts)'
            '${account != null ? ' for account ${account.name} (${account.type})' : ''}...');
        bool fetchedThumbnailsInBulk = true;
        try {
          try {
            deviceContacts = await fc.FlutterContacts.getAll(
              properties: {...fc.ContactProperties.allProperties, fc.ContactProperty.photoThumbnail},
              account: account,
            );
          } catch (e) {
            fetchedThumbnailsInBulk = false;
            Logger.warn('[ContactV2] Bulk contact fetch with thumbnails failed, retrying without thumbnails: $e');
            deviceContacts =
                await fc.FlutterContacts.getAll(properties: fc.ContactProperties.allProperties, account: account);
          }
        } catch (e) {
          Logger.warn('[ContactV2] Device contact fetch skipped/failed: $e');
          deviceContacts = [];
        }
        Logger.info('[ContactV2] Fetched ${deviceContacts.length} contacts from device');
        if (deviceContacts.isEmpty) {
          Logger.warn('[ContactV2] 0 device contacts returned (permission denied, empty address book, or contact scoping).');
        }

        // Identify contacts matching existing handles so only matched contacts pay for
        // full-res photo fetches; unmatched contacts keep their bulk thumbnail.
        final matchedContactIds = <String>{};
        if (deviceContacts.isNotEmpty) {
          final (handleEmails, handlePhoneVariants) = Database.runInTransaction(TxMode.read, () {
            final emails = <String>{};
            final phones = <String>{};
            for (final h in Database.handles.getAll()) {
              if (h.address.contains('@')) {
                emails.add(ContactV2.normalizeEmail(h.address));
                if (h.formattedAddress != null) {
                  emails.add(ContactV2.normalizeEmail(h.formattedAddress!));
                }
              } else {
                phones.addAll(phoneNumberVariants(h.address));
                if (h.formattedAddress != null) {
                  phones.addAll(phoneNumberVariants(h.formattedAddress!));
                }
              }
            }
            return (emails, phones);
          });

          for (final rawContact in deviceContacts) {
            final id = rawContact.id;
            if (id == null) continue;
            final emailHit = rawContact.emails.any((e) => handleEmails.contains(ContactV2.normalizeEmail(e.address)));
            final phoneHit = !emailHit &&
                rawContact.phones.any((p) => phoneNumberVariants(p.number).any(handlePhoneVariants.contains));
            if (emailHit || phoneHit) matchedContactIds.add(id);
          }

          // Step 1.5: Pre-fetch and save contact avatars (async operations must be done BEFORE transaction).
          // Upgrade handle-matched contacts to full-res in bounded parallel batches.
          const int photoBatchSize = 8;
          final matchedForFullRes =
              deviceContacts.where((c) => c.id != null && matchedContactIds.contains(c.id)).toList();
          for (int i = 0; i < matchedForFullRes.length; i += photoBatchSize) {
            final batch = matchedForFullRes.sublist(i, (i + photoBatchSize).clamp(0, matchedForFullRes.length));
            await Future.wait(batch.map((rawContact) async {
              final id = rawContact.id!;
              final bulkThumb = rawContact.photo?.thumbnail;
              try {
                final contactWithPhoto = await fc.FlutterContacts.get(
                  id,
                  properties: {fc.ContactProperty.photoFullRes, fc.ContactProperty.photoThumbnail},
                );
                final avatarData = contactWithPhoto?.photo?.fullSize ?? contactWithPhoto?.photo?.thumbnail ?? bulkThumb;
                if (avatarData != null && avatarData.isNotEmpty) {
                  final savedPath = await _saveContactAvatar(id, avatarData);
                  if (savedPath != null) {
                    avatarPaths[id] = savedPath;
                  } else {
                    failedDeviceAvatarIds.add(id);
                  }
                } else if (contactWithPhoto != null || fetchedThumbnailsInBulk) {
                  avatarPaths[id] = null;
                } else {
                  failedDeviceAvatarIds.add(id);
                }
              } catch (_) {
                if (bulkThumb != null && bulkThumb.isNotEmpty) {
                  final savedPath = await _saveContactAvatar(id, bulkThumb);
                  if (savedPath != null) {
                    avatarPaths[id] = savedPath;
                  } else {
                    failedDeviceAvatarIds.add(id);
                  }
                } else {
                  failedDeviceAvatarIds.add(id);
                }
              }
            }));
          }

          for (final rawContact in deviceContacts) {
            final id = rawContact.id;
            if (id == null || matchedContactIds.contains(id)) continue;
            final bulkThumb = rawContact.photo?.thumbnail;
            if (bulkThumb != null && bulkThumb.isNotEmpty) {
              final savedPath = await _saveContactAvatar(id, bulkThumb);
              if (savedPath != null) {
                avatarPaths[id] = savedPath;
              } else {
                failedDeviceAvatarIds.add(id);
              }
            } else if (fetchedThumbnailsInBulk) {
              avatarPaths[id] = null;
            }
          }
        }
      }

      // Fetch macOS server contacts when configured (sole source on desktop, merged complement on mobile).
      var hasServerUrl = false;
      try {
        hasServerUrl = GetIt.I.isRegistered<HttpService>() && HttpSvc.origin.isNotEmpty;
      } catch (e) {
        Logger.warn('[ContactV2] Invalid server URL during contact sync (skipping server fetch): $e');
      }
      var serverFetchAttempted = false;
      var serverFetchSucceeded = false;
      final dedupedServerIds = <String>{};
      if (kIsDesktop || kIsWeb || hasServerUrl) {
        serverFetchAttempted = true;
        try {
          Logger.info('[ContactV2] Starting contact fetch from server...');
          final response = await HttpSvc.contact.fetchAll(withAvatars: true);
          if (response.statusCode == 200 && response.data is Map && response.data['data'] is List) {
            serverFetchSucceeded = true;
            final rawList = response.data['data'] as List<dynamic>;
            if (rawList.isNotEmpty) {
              final serverMaps = rawList
                  .whereType<Map>()
                  .map((m) => m is Map<String, dynamic> ? m : Map<String, dynamic>.from(m))
                  .toList();
              networkContacts = await _mergeServerContactMaps(
                serverMaps: serverMaps,
                deviceContacts: deviceContacts,
                avatarPaths: avatarPaths,
                failedDeviceAvatarIds: failedDeviceAvatarIds,
                dedupedServerIdsOut: dedupedServerIds,
                prefixServerIds: !kIsDesktop && !kIsWeb,
              );
              Logger.info(
                  '[ContactV2] Merged ${serverMaps.length} server contacts (${networkContacts.length} server-only)');
            } else {
              Logger.info('[ContactV2] No server contacts found!');
            }
          } else {
            Logger.warn('[ContactV2] Unexpected server contacts response (${response.statusCode})');
          }
        } catch (e) {
          Logger.warn('[ContactV2] Server contact fetch failed (continuing with local contacts): $e');
        }
      }

      // Step 2: Process and normalize contacts within a transaction (synchronous only!)
      Database.runInTransaction(TxMode.write, () {
        final contactsBox = Database.contactsV2;
        final handlesBox = Database.handles;
        final allHandles = handlesBox.getAll();

        // Clean up any stale server-only ContactV2 rows that now match a device contact.
        if (dedupedServerIds.isNotEmpty) {
          for (final existing in contactsBox.getAll()) {
            if (!existing.isNative && dedupedServerIds.contains(existing.nativeContactId)) {
              affectedHandleIds.addAll(existing.handles.map((h) => h.id).whereType<int>());
              if (existing.id != 0) contactsBox.remove(existing.id);
            }
          }
        }

        final emailHandleMap = <String, List<Handle>>{};
        final phoneHandleMap = <String, List<Handle>>{};

        for (final handle in allHandles) {
          final isEmail = handle.address.contains('@');

          if (isEmail) {
            final normalized = ContactV2.normalizeEmail(handle.address);
            emailHandleMap.putIfAbsent(normalized, () => []).add(handle);

            if (handle.formattedAddress != null) {
              final formattedNormalized = ContactV2.normalizeEmail(handle.formattedAddress!);
              if (formattedNormalized != normalized) {
                emailHandleMap.putIfAbsent(formattedNormalized, () => []).add(handle);
              }
            }
          } else {
            // For phones, generate all variants and map them
            final variants = phoneNumberVariants(handle.address);
            for (final variant in variants) {
              phoneHandleMap.putIfAbsent(variant, () => []).add(handle);
            }

            if (handle.formattedAddress != null) {
              final formattedVariants = phoneNumberVariants(handle.formattedAddress!);
              for (final variant in formattedVariants) {
                phoneHandleMap.putIfAbsent(variant, () => []).add(handle);
              }
            }
          }
        }

        Logger.info(
            '[ContactV2] Built lookup maps: ${emailHandleMap.length} email keys, ${phoneHandleMap.length} phone variant keys');

        for (final rawContact in [...deviceContacts, ...networkContacts]) {
          // Normalize addresses
          final normalizedAddresses = <String>{};

          // Different data objects for desktop/mobile
          if (rawContact is fc.Contact) {
            // Add normalized phone numbers
            for (final phone in rawContact.phones) {
              final normalized = ContactV2.normalizePhoneNumber(phone.number);
              if (normalized.isNotEmpty) {
                normalizedAddresses.add(normalized);
              }
            }

            // Add normalized emails
            for (final email in rawContact.emails) {
              final normalized = ContactV2.normalizeEmail(email.address);
              if (normalized.isNotEmpty) {
                normalizedAddresses.add(normalized);
              }
            }
          } else if (rawContact is ContactV2) {
            // Add normalized phone numbers
            for (final phone in rawContact.phoneNumbers) {
              final normalized = ContactV2.normalizePhoneNumber(phone.number);
              if (normalized.isNotEmpty) {
                normalizedAddresses.add(normalized);
              }
            }

            // Add normalized emails
            for (final email in rawContact.emailAddresses) {
              final normalized = ContactV2.normalizeEmail(email.address);
              if (normalized.isNotEmpty) {
                normalizedAddresses.add(normalized);
              }
            }
          }

          if (normalizedAddresses.isEmpty) continue;

          String contactId = "";
          String displayName = "";
          String? firstName, lastName, middleName, namePrefix, nameSuffix, nickname, company;
          List<ContactPhone> contactPhones = [];
          List<ContactEmail> contactEmails = [];

          if (rawContact is fc.Contact) {
            if (rawContact.id == null) {
              continue;
            }

            contactId = rawContact.id!;
            final trimmedDisplay = rawContact.displayName?.trim();
            final name = rawContact.name;
            if (trimmedDisplay != null && trimmedDisplay.isNotEmpty) {
              displayName = trimmedDisplay;
            } else {
              final constructed = getDisplayName(null, name?.first, name?.last).trim();
              displayName = constructed.isNotEmpty
                  ? constructed
                  : (rawContact.organizations.firstOrNull?.name?.trim().isNotEmpty == true
                      ? rawContact.organizations.firstOrNull!.name!.trim()
                      : (rawContact.phones.firstOrNull?.number ?? rawContact.emails.firstOrNull?.address ?? ''));
            }

            firstName = name?.first;
            lastName = name?.last;
            middleName = name?.middle;
            namePrefix = name?.prefix;
            nameSuffix = name?.suffix;
            nickname = name?.nickname;

            if (rawContact.organizations.isNotEmpty) {
              final orgCompany = rawContact.organizations.first.name;
              if (orgCompany != null) company = orgCompany;
            }

            for (final phone in rawContact.phones) {
              final label =
                  phone.label.label == fc.PhoneLabel.custom ? phone.label.customLabel ?? '' : phone.label.label.name;
              contactPhones.add(ContactPhone(number: phone.number, label: label));
            }
            for (final email in rawContact.emails) {
              final label =
                  email.label.label == fc.EmailLabel.custom ? email.label.customLabel ?? '' : email.label.label.name;
              contactEmails.add(ContactEmail(address: email.address, label: label));
            }
          } else if (rawContact is ContactV2) {
            contactId = rawContact.nativeContactId;
            displayName = rawContact.displayName;
            firstName = rawContact.firstName;
            lastName = rawContact.lastName;
            contactPhones = rawContact.phoneNumbers;
            contactEmails = rawContact.emailAddresses;
          }

          // Get pre-fetched avatar path
          final avatarPath = avatarPaths[contactId];

          // Check if contact already exists
          final existingQuery = contactsBox.query(ContactV2_.nativeContactId.equals(contactId)).build();
          final existingContact = existingQuery.findFirst();
          existingQuery.close();

          ContactV2 contact;
          Set<int> existingHandleIds = {};

          if (existingContact != null) {
            // Update existing contact
            contact = existingContact;
            final oldComputedName = contact.computedDisplayName;
            final oldAvatarPath = contact.avatarPath;
            contact.displayName = displayName;
            contact.addresses = normalizedAddresses.toList();
            contact.avatarPath = resolveUpdatedAvatarPath(
              existingAvatarPath: oldAvatarPath,
              hasPrefetchedEntry: avatarPaths.containsKey(contactId),
              prefetchedAvatarPath: avatarPath,
              isServerContact: rawContact is ContactV2,
              serverFetchAttempted: serverFetchAttempted,
              serverFetchSucceeded: serverFetchSucceeded,
            );
            contact.firstName = firstName;
            contact.lastName = lastName;
            contact.middleName = middleName;
            contact.namePrefix = namePrefix;
            contact.nameSuffix = nameSuffix;
            contact.nickname = nickname;
            contact.company = company;
            contact.phoneNumbers = contactPhones;
            contact.emailAddresses = contactEmails;

            // Track existing handles to detect changes
            existingHandleIds = contact.handles.map((h) => h.id).whereType<int>().toSet();

            if (oldComputedName != contact.computedDisplayName || oldAvatarPath != contact.avatarPath) {
              // Mark all existing handles for this contact as affected (computed name or avatar changed)
              affectedHandleIds.addAll(existingHandleIds);
            }
          } else {
            // Create new contact
            contact = ContactV2(
              displayName: displayName,
              nativeContactId: contactId,
              avatarPath: avatarPath,
              addresses: normalizedAddresses.toList(),
              firstName: firstName,
              lastName: lastName,
              middleName: middleName,
              namePrefix: namePrefix,
              nameSuffix: nameSuffix,
              nickname: nickname,
              company: company,
            );
            contact.phoneNumbers = contactPhones;
            contact.emailAddresses = contactEmails;
          }

          // Mark contact as native only when it originates from flutter_contacts
          contact.isNative = rawContact is fc.Contact;

          // Step 3: Match contact to handles using lookup maps (O(addresses) instead of O(addresses × handles))
          final matchedHandles = <Handle>{};

          for (final address in normalizedAddresses) {
            final isEmail = address.contains('@');

            if (isEmail) {
              // Direct lookup for emails
              final handles = emailHandleMap[address];
              if (handles != null) {
                matchedHandles.addAll(handles);
              }
            } else {
              // For phones, check all variants
              final variants = phoneNumberVariants(address);
              for (final variant in variants) {
                final handles = phoneHandleMap[variant];
                if (handles != null) {
                  matchedHandles.addAll(handles);
                }
              }
            }
          }

          if (matchedHandles.isNotEmpty) matchedContactCount++;

          // Compare new handles with existing handles to detect changes
          final newHandleIds = matchedHandles.map((h) => h.id).whereType<int>().toSet();
          final handlesChanged = existingContact == null ||
              existingHandleIds.length != newHandleIds.length ||
              !existingHandleIds.containsAll(newHandleIds);

          // Always update handles on the in-memory object so the put below persists them.
          contact.handles.clear();
          contact.handles.addAll(matchedHandles);

          // Always persist the contact — this ensures phone/email JSON columns are
          // written to the DB regardless of whether handle assignments changed.
          try {
            contactsBox.put(contact);
          } on UniqueViolationException catch (e) {
            Logger.warn('[ContactV2] Unique violation for contact ${contact.nativeContactId}: $e');
          }

          if (handlesChanged) {
            // Mark all affected handles (both old and new) for UI refresh
            affectedHandleIds.addAll(existingHandleIds);
            affectedHandleIds.addAll(newHandleIds);

            // Link handles to chats without handles
            final chatsToUpdate = <Chat>{};
            for (final handle in matchedHandles) {
              final chatQuery = Database.chats.query(Chat_.guid.contains(';-;${handle.address}')).build();
              final chats = chatQuery.find();
              chatQuery.close();

              for (final chat in chats) {
                if (chat.handles.isEmpty) {
                  chat.handles.add(handle);
                  chatsToUpdate.add(chat);
                }
              }
            }

            if (chatsToUpdate.isNotEmpty) {
              Logger.info('[ContactV2] Updating ${chatsToUpdate.length} chats to link matched handles');
              Database.chats.putMany(chatsToUpdate.toList());
            }
          }
        }
      });

      final endTime = DateTime.now().millisecondsSinceEpoch;
      // De-duplicate — a handle can be marked affected by both a name/avatar
      // change and a handle-link change within the same sync.
      final uniqueAffected = affectedHandleIds.toSet().toList();
      Logger.info('[ContactV2] Contact fetch and match completed in ${endTime - startTime}ms');
      Logger.info('[ContactV2] Affected ${uniqueAffected.length} handles');

      final stats = _ContactSyncStats(
        affectedHandleIds: uniqueAffected,
        deviceContactCount: deviceContacts.length,
        matchedContactCount: matchedContactCount,
      );

      // Complete the completer with the result
      _syncCompleter?.complete(stats);
      return stats;
    } catch (e, stack) {
      // Logged with the exception's runtimeType called out explicitly so this is
      // distinguishable in exported logs from the "0 contacts, no exception" case
      // logged above — both currently end in an empty sync result, but only one
      // of them is an actual failure.
      Logger.error('[ContactV2] Error fetching and matching contacts (${e.runtimeType}): $e',
          error: e, trace: stack);

      // Complete the completer with an empty result on error
      const stats = _ContactSyncStats(affectedHandleIds: [], deviceContactCount: 0, matchedContactCount: 0);
      _syncCompleter?.complete(stats);
      return stats;
    }
  }

  @visibleForTesting
  static String? resolveUpdatedAvatarPath({
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

  @visibleForTesting
  static Future<List<ContactV2>> mergeServerContactMapsForTest({
    required List<Map<String, dynamic>> serverMaps,
    required List<fc.Contact> deviceContacts,
    required Map<String, String?> avatarPaths,
    Set<String> failedDeviceAvatarIds = const {},
    Set<String>? dedupedServerIdsOut,
    bool prefixServerIds = true,
  }) =>
      _mergeServerContactMaps(
        serverMaps: serverMaps,
        deviceContacts: deviceContacts,
        avatarPaths: avatarPaths,
        failedDeviceAvatarIds: failedDeviceAvatarIds,
        dedupedServerIdsOut: dedupedServerIdsOut,
        prefixServerIds: prefixServerIds,
      );

  /// Merges server contacts against [deviceContacts]. Any server contact sharing an email
  /// or phone variant with a device contact enriches [avatarPaths] on that device ID when
  /// missing rather than producing a duplicate [ContactV2]; unmatched server contacts are
  /// returned for persistence with `isNative == false`.
  static Future<List<ContactV2>> _mergeServerContactMaps({
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
        for (final variant in phoneNumberVariants(phone.number)) {
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
          for (final variant in phoneNumberVariants(phone.number)) {
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
            final savedPath = await _saveContactAvatar(matchedDeviceId, base64Decode(map['avatar'].toString()));
            if (savedPath != null) avatarPaths[matchedDeviceId] = savedPath;
          } catch (_) {}
        }
        continue;
      }

      if (!isNullOrEmpty(map['avatar'])) {
        try {
          final savedPath = await _saveContactAvatar(contactId, base64Decode(map['avatar'].toString()));
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

  @visibleForTesting
  static bool hasNativeContactChanges(Iterable<String?> currentDeviceIds, Iterable<ContactV2> storedContacts) {
    final currentIds = currentDeviceIds.whereType<String>().toSet();
    // Exclude server-fetched contacts (isNative == false) so they don't trigger infinite sync loops.
    final storedIds = storedContacts.where((c) => c.isNative).map((c) => c.nativeContactId).toSet();
    return currentIds.length != storedIds.length ||
        !currentIds.containsAll(storedIds) ||
        !storedIds.containsAll(currentIds);
  }

  /// Check for contact database changes by comparing native contact IDs
  /// This is used by the periodic background task (Section II.B of FR-1.md)
  static Future<bool> checkContactChanges(dynamic data) async {
    if (kIsWeb || kIsDesktop) return false;
    try {
      Logger.info('[ContactV2] Checking for contact changes...');

      // Get current device contact IDs (only fetch minimal data)
      final currentContacts = await fc.FlutterContacts.getAll(); // IDs only by default

      // Compare against stored native contacts only (skip server-fetched isNative == false rows).
      final hasChanges = Database.runInTransaction(TxMode.read, () {
        return hasNativeContactChanges(currentContacts.map((c) => c.id), Database.contactsV2.getAll());
      });

      if (hasChanges) {
        Logger.info('[ContactV2] Contact changes detected, triggering refresh');
        await syncContactsToHandles(<String, dynamic>{});
        return true;
      }

      Logger.info('[ContactV2] No contact changes detected');
      return false;
    } catch (e, stack) {
      Logger.error('[ContactV2] Error checking contact changes', error: e, trace: stack);
      return false;
    }
  }

  /// Get all stored ContactV2 IDs for comparison
  static Future<List<String>> getStoredContactIds(dynamic data) async {
    return await Database.runInTransaction(TxMode.read, () {
      final contactsBox = Database.contactsV2;
      final allContacts = contactsBox.getAll();
      return allContacts.map((c) => c.nativeContactId).toList();
    });
  }

  /// Find a single ContactV2 by native contact ID
  /// Returns the ObjectBox ID of the matching contact, or null if not found.
  static Future<int?> findOneContact(dynamic data) async {
    final dataMap = data as Map<dynamic, dynamic>;
    final nativeContactId = dataMap['nativeContactId'] as String;

    return await Database.runInTransaction(TxMode.read, () {
      final contactsBox = Database.contactsV2;
      final query = contactsBox.query(ContactV2_.nativeContactId.equals(nativeContactId)).build();
      query.limit = 1;
      final contact = query.findFirst();
      query.close();

      return contact?.id;
    });
  }

  /// Get ContactV2 IDs for a list of Handle IDs.
  /// Returns de-duplicated ObjectBox IDs so the interface can hydrate full objects.
  static Future<List<int>> getContactsForHandles(dynamic data) async {
    final dataMap = data as Map<dynamic, dynamic>;
    final handleIds = (dataMap['handleIds'] as List).cast<int>();

    return await Database.runInTransaction(TxMode.read, () {
      final handlesBox = Database.handles;
      final uniqueIds = <int>{};

      for (final handleId in handleIds) {
        final handle = handlesBox.get(handleId);
        if (handle != null) {
          for (final contact in handle.contactsV2) {
            if (contact.id != 0) uniqueIds.add(contact.id);
          }
        }
      }

      return uniqueIds.toList();
    });
  }

  /// Manually trigger a contact refresh
  static Future<List<int>> refreshContacts(dynamic data) async {
    return await syncContactsToHandles(data);
  }

  @visibleForTesting
  static Future<String?> saveContactAvatarForTest(String contactId, Uint8List avatarData) =>
      _saveContactAvatar(contactId, avatarData);

  static String _webAvatarCacheKey(String contactId) => 'contact_avatar:${sanitizeFileName(contactId)}';

  /// Save a contact avatar to disk under a content-hashed filename and return the path.
  /// Content-hashing ensures changed photos get a new path (busting Flutter's
  /// ImageCache and HandleState equality checks), while unchanged photos hit
  /// an O(1) exists+length check without rewriting.
  static Future<String?> _saveContactAvatar(String contactId, Uint8List avatarData) async {
    try {
      if (kIsWeb) {
        await WebMediaCache.instance.put(
          WebMediaCache.attachmentsStore,
          _webAvatarCacheKey(contactId),
          avatarData,
        );
        // Leave ContactV2.avatarPath null on web while ContactAvatarWidget uses FileImage.
        return null;
      }

      final avatarsDir = Directory(FilesystemSvc.contactAvatarsPath);

      if (!await avatarsDir.exists()) {
        await avatarsDir.create(recursive: true);
      }

      // Sanitize the contact ID because it isn't ours (macOS `<uuid>:ABPerson`, etc.)
      final safeId = sanitizeFileName(contactId);
      final shortHash = sha256.convert(avatarData).toString().substring(0, 12);
      final targetName = '${safeId}_$shortHash.jpg';
      final avatarFile = File(p.join(avatarsDir.path, targetName));

      if (await avatarFile.exists() && await avatarFile.length() == avatarData.length) {
        return avatarFile.path;
      }

      // Write atomically so concurrent UI Image decoders never read a partial file.
      final tmpFile = File('${avatarFile.path}.tmp');
      await tmpFile.writeAsBytes(avatarData, flush: true);
      await tmpFile.rename(avatarFile.path);

      // Remove superseded avatar files for this contact (older hashes or legacy unsuffixed file).
      try {
        await for (final entity in avatarsDir.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (name == targetName) continue;
          if (name == '$safeId.jpg' || (name.startsWith('${safeId}_') && name.endsWith('.jpg'))) {
            await entity.delete();
          }
        }
      } catch (_) {}

      return avatarFile.path;
    } catch (e, stack) {
      Logger.error('[ContactV2] Error saving avatar for contact $contactId', error: e, trace: stack);
      return null;
    }
  }

  /// Get a contact by address (email or phone number).
  /// Returns the ObjectBox ID of the matching contact, or null if not found.
  static Future<int?> getContactByAddress(dynamic data) async {
    final dataMap = data as Map<dynamic, dynamic>;
    final address = dataMap['address'] as String;

    return await Database.runInTransaction(TxMode.read, () {
      return matchContactForAddress(Database.contactsV2.getAll(), address)?.id;
    });
  }

  /// Get all contacts from the database.
  /// Returns a list of ObjectBox IDs so the interface can hydrate full objects.
  static Future<List<int>> getAllContacts(dynamic data) async {
    return await Database.runInTransaction(TxMode.read, () {
      final contactsBox = Database.contactsV2;
      final query = (contactsBox.query()..order(ContactV2_.displayName)).build();
      final allContacts = query.find();
      return allContacts.map((c) => c.id).toList();
    });
  }

  /// Get avatar data for a contact by native contact ID
  static Future<Uint8List?> getContactAvatar(dynamic data) async {
    final dataMap = data as Map<dynamic, dynamic>;
    final nativeContactId = dataMap['nativeContactId'] as String;

    try {
      if (kIsWeb) {
        return await WebMediaCache.instance.get(
          WebMediaCache.attachmentsStore,
          _webAvatarCacheKey(nativeContactId),
        );
      }

      // Check stored ContactV2.avatarPath first (already content-hashed on disk).
      final storedPath = Database.runInTransaction(TxMode.read, () {
        final q = Database.contactsV2.query(ContactV2_.nativeContactId.equals(nativeContactId)).build();
        q.limit = 1;
        final c = q.findFirst();
        q.close();
        return c?.avatarPath;
      });
      if (!isNullOrEmpty(storedPath)) {
        final storedFile = File(storedPath!);
        if (await storedFile.exists()) {
          return await storedFile.readAsBytes();
        }
      }

      // Fall back to scanning contactAvatarsPath for legacy or hashed files.
      final avatarsDir = Directory(FilesystemSvc.contactAvatarsPath);
      final safeId = sanitizeFileName(nativeContactId);
      final legacyFile = File(p.join(avatarsDir.path, '$safeId.jpg'));
      if (await legacyFile.exists()) {
        return await legacyFile.readAsBytes();
      }
      if (await avatarsDir.exists()) {
        await for (final entity in avatarsDir.list(followLinks: false)) {
          if (entity is File) {
            final name = p.basename(entity.path);
            if (name.startsWith('${safeId}_') && name.endsWith('.jpg')) {
              return await entity.readAsBytes();
            }
          }
        }
      }

      // If not on disk, try to fetch it fresh (native device contacts only)
      if (!kIsWeb && !kIsDesktop && !nativeContactId.startsWith('server:')) {
        Uint8List? avatar;

        try {
          final contact = await fc.FlutterContacts.get(
            nativeContactId,
            properties: {fc.ContactProperty.photoFullRes, fc.ContactProperty.photoThumbnail},
          );
          avatar = contact?.photo?.fullSize ?? contact?.photo?.thumbnail;
        } catch (e) {
          Logger.warn('[ContactV2] Failed to get avatar for ID $nativeContactId: $e');
        }

        // Save it to disk for future use
        if (avatar != null) {
          await _saveContactAvatar(nativeContactId, avatar);
        }

        return avatar;
      }

      return null;
    } catch (e, stack) {
      Logger.error('[ContactV2] Error getting contact avatar for $nativeContactId', error: e, trace: stack);
      return null;
    }
  }

  /// Uploads contacts to the server
  static Future<void> uploadContacts(dynamic data) async {
    final contacts = data['contacts'] as List<Map<String, dynamic>>;

    try {
      await HttpSvc.contact.create(contacts);
      Logger.info('[ContactV2] Successfully uploaded ${contacts.length} contacts to server');
    } catch (err, stack) {
      if (err is Response) {
        Logger.error(err.data["error"]["message"].toString(), error: err, trace: stack, tag: 'ContactV2Actions');
      } else {
        Logger.error('Failed to upload contacts!', error: err, trace: stack, tag: 'ContactV2Actions');
      }
    }
  }

  /// Returns each on-device account with contacts, plus a live contact count
  /// per account. Used by the Contacts Management page's account selector.
  /// Mobile only — desktop has no device accounts.
  static Future<List<Map<String, dynamic>>> getAccountContactCounts(dynamic data) async {
    if (kIsWeb || kIsDesktop) return [];

    try {
      final accounts = await fc.FlutterContacts.accounts.getAll();
      final results = <Map<String, dynamic>>[];

      for (final account in accounts) {
        final contacts = await fc.FlutterContacts.getAll(account: account);
        results.add({'name': account.name, 'type': account.type, 'count': contacts.length});
      }

      return results;
    } catch (e, stack) {
      Logger.error('[ContactV2] Error getting account contact counts', error: e, trace: stack);
      return [];
    }
  }
}

/// Result of a device/network contact fetch-and-match pass. Kept isolate-internal
/// (not returned directly across the isolate boundary — see
/// [ContactV2Actions.syncContactsToHandles] vs
/// [ContactV2Actions.syncContactsToHandlesWithStats]).
class _ContactSyncStats {
  final List<int> affectedHandleIds;
  final int deviceContactCount;
  final int matchedContactCount;

  const _ContactSyncStats({
    required this.affectedHandleIds,
    required this.deviceContactCount,
    required this.matchedContactCount,
  });

  Map<String, dynamic> toMap() => {
        'affectedHandleIds': affectedHandleIds,
        'deviceContactCount': deviceContactCount,
        'matchedContactCount': matchedContactCount,
      };
}
