import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/actions/contact_v2_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;

class _SilentLogger extends BaseLogger {
  @override
  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void error(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

class _FakePrefsThemeActions extends SharedPreferencesThemeActions {
  _FakePrefsThemeActions(super.service);

  @override
  String? getSelectedLightTheme() => null;

  @override
  String? getSelectedDarkTheme() => null;
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    theme = _FakePrefsThemeActions(this);
  }
}

class _FakeContactServiceV2 extends ContactServiceV2 {
  final Map<String, ContactV2> byAddress = {};

  @override
  ContactV2? findContactForAddressSync(String address) {
    final norm = address.contains('@') ? ContactV2.normalizeEmail(address) : ContactV2.normalizePhoneNumber(address);
    return byAddress[norm];
  }
}

// Valid 1x1 transparent PNG so Flutter's Image widget decodes cleanly if needed.
final Uint8List _png1x1A = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

final Uint8List _png1x1B = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
  0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

late Directory _tempAppDir;
late _FakeContactServiceV2 _fakeContactsSvc;

void _registerTestServices() {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
  }
  if (!GetIt.I.isRegistered<SharedPreferencesService>()) {
    GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  }
  if (!GetIt.I.isRegistered<ThemesService>()) {
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  }
  if (!GetIt.I.isRegistered<HandleService>()) {
    GetIt.I.registerSingleton<HandleService>(HandleService());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = _tempAppDir);
  } else {
    FilesystemSvc.appDocDir = _tempAppDir;
  }
  if (!GetIt.I.isRegistered<ContactServiceV2>()) {
    _fakeContactsSvc = _FakeContactServiceV2();
    GetIt.I.registerSingleton<ContactServiceV2>(_fakeContactsSvc);
  }
}

void main() {
  setUpAll(() {
    _tempAppDir = Directory.systemTemp.createTempSync('bb_contact_photos_test_');
    _registerTestServices();
  });

  tearDownAll(() {
    if (_tempAppDir.existsSync()) {
      _tempAppDir.deleteSync(recursive: true);
    }
  });

  group('ContactV2Actions address matching', () {
    test('matches phone numbers symmetrically across country-code formats', () {
      final contactWithPlus = ContactV2(
        nativeContactId: 'c1',
        displayName: 'Alice',
        addresses: [ContactV2.normalizePhoneNumber('+1 (555) 123-4567')],
        avatarPath: '/tmp/alice.jpg',
      );
      final contactLocalOnly = ContactV2(
        nativeContactId: 'c2',
        displayName: 'Bob',
        addresses: [ContactV2.normalizePhoneNumber('(415) 888-9999')],
        avatarPath: '/tmp/bob.jpg',
      );

      // Handle lacks +1, contact has +1
      expect(ContactV2Actions.matchContactForAddress([contactWithPlus], '5551234567')?.nativeContactId, 'c1');
      // Handle has +1, contact lacks +1
      expect(ContactV2Actions.matchContactForAddress([contactLocalOnly], '+14158889999')?.nativeContactId, 'c2');
      // Email case-insensitive match
      final emailContact = ContactV2(
        nativeContactId: 'c3',
        displayName: 'Carol',
        addresses: [ContactV2.normalizeEmail('Carol@Example.com')],
      );
      expect(ContactV2Actions.matchContactForAddress([emailContact], 'carol@example.com')?.nativeContactId, 'c3');
    });

    test('prefers duplicate contact that has an avatarPath', () {
      final noAvatar = ContactV2(
        nativeContactId: 'c-no-pic',
        displayName: 'Alice',
        addresses: ['+15551234567'],
      );
      final withAvatar = ContactV2(
        nativeContactId: 'c-with-pic',
        displayName: 'Alice',
        addresses: ['+15551234567'],
        avatarPath: '/tmp/alice.jpg',
      );
      expect(
        ContactV2Actions.matchContactForAddress([noAvatar, withAvatar], '5551234567')?.nativeContactId,
        'c-with-pic',
      );
    });
  });

  group('ContactV2Actions avatar persistence', () {
    test('writes content-hashed paths atomically and rotates on photo change', () async {
      final avatarsDir = Directory(FilesystemSvc.contactAvatarsPath);
      if (avatarsDir.existsSync()) avatarsDir.deleteSync(recursive: true);
      avatarsDir.createSync(recursive: true);

      // Seed a legacy unsuffixed file to confirm cleanup.
      final legacyFile = File(p.join(avatarsDir.path, 'uuid_ABPerson.jpg'));
      await legacyFile.writeAsBytes(_png1x1A);

      final path1 = await ContactV2Actions.saveContactAvatarForTest('uuid:ABPerson', _png1x1A);
      expect(path1, isNotNull);
      expect(File(path1!).existsSync(), isTrue);
      expect(p.basename(path1), startsWith('uuid_ABPerson_'));
      expect(legacyFile.existsSync(), isFalse);
      expect(File('$path1.tmp').existsSync(), isFalse);

      // Unchanged photo reuses the exact same path.
      final path1Repeat = await ContactV2Actions.saveContactAvatarForTest('uuid:ABPerson', _png1x1A);
      expect(path1Repeat, path1);

      // Changed photo gets a new path (busting ImageCache & HandleState) and cleans up path1.
      final path2 = await ContactV2Actions.saveContactAvatarForTest('uuid:ABPerson', _png1x1B);
      expect(path2, isNotNull);
      expect(path2, isNot(path1));
      expect(File(path2!).existsSync(), isTrue);
      expect(File(path1).existsSync(), isFalse);
    });
  });

  group('ContactAvatarWidget reactivity and transient handles', () {
    testWidgets('updates Image when HandleState avatarPath rotates or transient handle syncs', (tester) async {
      final (pathA, pathB) = (await tester.runAsync(() async {
        final a = await ContactV2Actions.saveContactAvatarForTest('widget-c1', _png1x1A);
        final b = await ContactV2Actions.saveContactAvatarForTest('widget-c2', _png1x1B);
        return (a, b);
      }))!;
      expect(pathA, isNotNull);
      expect(pathB, isNotNull);

      final handle = Handle(id: 42, address: '+15551112222');
      final handleState = HandleSvc.getOrCreateHandleState(handle);
      handleState.avatarPath.value = null;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContactAvatarWidget(handle: handle, size: 40),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);

      // Simulate contact sync updating HandleState to pathA, then rotating to pathB.
      handleState.avatarPath.value = pathA;
      await tester.pump();
      expect(find.byKey(ValueKey(pathA)), findsOneWidget);

      handleState.avatarPath.value = pathB;
      await tester.pump();
      expect(find.byKey(ValueKey(pathB)), findsOneWidget);
      expect(find.byKey(ValueKey(pathA)), findsNothing);

      // Transient Find My handle (id == null) resolves via ContactServiceV2 and rebuilds on cacheVersion++.
      _fakeContactsSvc.byAddress.clear();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContactAvatarWidget(handle: Handle(address: '+15559990000'), size: 40),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);

      _fakeContactsSvc.byAddress['+15559990000'] = ContactV2(
        nativeContactId: 'findmy-c1',
        displayName: 'FindMy Friend',
        addresses: ['+15559990000'],
        avatarPath: pathA,
      );
      _fakeContactsSvc.cacheVersion.value++;
      await tester.pump();
      expect(find.byKey(ValueKey(pathA)), findsOneWidget);

      // didUpdateWidget reacts to transient handle address change.
      _fakeContactsSvc.byAddress['+15559990001'] = ContactV2(
        nativeContactId: 'findmy-c2',
        displayName: 'Other Friend',
        addresses: ['+15559990001'],
        avatarPath: pathB,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContactAvatarWidget(handle: Handle(address: '+15559990001'), size: 40),
          ),
        ),
      );
      expect(find.byKey(ValueKey(pathB)), findsOneWidget);
    });
  });

  group('Server/device contact merge & native change detection', () {
    test('dedups matching device contacts, enriches missing avatar, and keeps server-only fallback', () async {
      final serverAvatarB64 = base64Encode(_png1x1A);
      final existingDevicePhoto = await ContactV2Actions.saveContactAvatarForTest('dev-with-photo', _png1x1B);

      final deviceContacts = [
        const fc.Contact(
          id: 'dev-no-photo',
          displayName: 'Alice Local',
          phones: [fc.Phone(number: '4085958701')],
        ),
        const fc.Contact(
          id: 'dev-with-photo',
          displayName: 'Bob Local',
          emails: [fc.Email(address: 'Bob@Example.com')],
        ),
      ];
      final avatarPaths = <String, String?>{
        'dev-no-photo': null,
        'dev-with-photo': existingDevicePhoto,
      };

      final serverMaps = [
        {
          'id': 'mac-1',
          'displayName': 'Alice Server',
          'phoneNumbers': [
            {'address': '+1 (408) 595-8701', 'label': 'mobile'},
          ],
          'emails': <dynamic>[],
          'avatar': serverAvatarB64,
        },
        {
          'id': 'mac-2',
          'displayName': 'Bob Server',
          'phoneNumbers': <dynamic>[],
          'emails': [
            {'address': 'bob@example.com', 'label': 'home'},
          ],
          'avatar': serverAvatarB64,
        },
        {
          'id': 'mac-3',
          'displayName': 'Charlie ServerOnly',
          'firstName': 'Charlie',
          'lastName': 'ServerOnly',
          'phoneNumbers': [
            {'address': '+15550009999', 'label': 'mobile'},
          ],
          'emails': <dynamic>[],
          'avatar': serverAvatarB64,
        },
      ];

      final networkContacts = await ContactV2Actions.mergeServerContactMapsForTest(
        serverMaps: serverMaps,
        deviceContacts: deviceContacts,
        avatarPaths: avatarPaths,
      );

      // Matched device contacts must NOT create duplicate networkContacts entries.
      expect(networkContacts.length, 1);
      final charlie = networkContacts.single;
      expect(charlie.nativeContactId, 'server:mac-3');
      expect(charlie.displayName, 'Charlie ServerOnly');
      expect(charlie.isNative, isFalse);
      expect(charlie.avatarPath, isNotNull);
      expect(File(charlie.avatarPath!).existsSync(), isTrue);

      // Photo-less device contact gets enriched with server avatar.
      expect(avatarPaths['dev-no-photo'], isNotNull);
      expect(File(avatarPaths['dev-no-photo']!).existsSync(), isTrue);

      // Device contact with existing photo keeps its own photo.
      expect(avatarPaths['dev-with-photo'], existingDevicePhoto);
    });

    test('falls back to all server contacts when deviceContacts is empty (permission denied)', () async {
      final serverAvatarB64 = base64Encode(_png1x1A);
      final avatarPaths = <String, String?>{};
      final networkContacts = await ContactV2Actions.mergeServerContactMapsForTest(
        serverMaps: [
          {
            'id': 'srv-10',
            'displayName': 'DeniedPerm User',
            'phoneNumbers': [
              {'address': '+14155551234', 'label': 'mobile'},
            ],
            'emails': <dynamic>[],
            'avatar': serverAvatarB64,
          },
        ],
        deviceContacts: const [],
        avatarPaths: avatarPaths,
      );

      expect(networkContacts.length, 1);
      expect(networkContacts.single.nativeContactId, 'server:srv-10');
      expect(networkContacts.single.isNative, isFalse);
      expect(avatarPaths['server:srv-10'], isNotNull);
    });

    test('hasNativeContactChanges ignores server-fetched (isNative == false) contacts', () {
      final stored = [
        ContactV2(nativeContactId: '1', displayName: 'Device', isNative: true),
        ContactV2(nativeContactId: 'server:mac-1', displayName: 'Server', isNative: false),
      ];

      expect(ContactV2Actions.hasNativeContactChanges(['1'], stored), isFalse);
      expect(ContactV2Actions.hasNativeContactChanges(['1', '2'], stored), isTrue);
      expect(ContactV2Actions.hasNativeContactChanges([], stored), isTrue);
    });

    test('resolveUpdatedAvatarPath preserves enriched device avatar when server fetch fails', () {
      // Server attempted & failed -> keep existing server-enriched device avatar
      expect(
        ContactV2Actions.resolveUpdatedAvatarPath(
          existingAvatarPath: '/tmp/enriched.jpg',
          hasPrefetchedEntry: true,
          prefetchedAvatarPath: null,
          isServerContact: false,
          serverFetchAttempted: true,
          serverFetchSucceeded: false,
        ),
        '/tmp/enriched.jpg',
      );
      // Server succeeded & still no avatar -> clear avatar
      expect(
        ContactV2Actions.resolveUpdatedAvatarPath(
          existingAvatarPath: '/tmp/enriched.jpg',
          hasPrefetchedEntry: true,
          prefetchedAvatarPath: null,
          isServerContact: false,
          serverFetchAttempted: true,
          serverFetchSucceeded: true,
        ),
        isNull,
      );
      // No server attempted & device photo confirmed gone -> clear avatar
      expect(
        ContactV2Actions.resolveUpdatedAvatarPath(
          existingAvatarPath: '/tmp/old.jpg',
          hasPrefetchedEntry: true,
          prefetchedAvatarPath: null,
          isServerContact: false,
          serverFetchAttempted: false,
          serverFetchSucceeded: false,
        ),
        isNull,
      );
      // Device photo fetch failed (no prefetched entry) -> preserve existing avatar
      expect(
        ContactV2Actions.resolveUpdatedAvatarPath(
          existingAvatarPath: '/tmp/old.jpg',
          hasPrefetchedEntry: false,
          prefetchedAvatarPath: null,
          isServerContact: false,
          serverFetchAttempted: true,
          serverFetchSucceeded: true,
        ),
        '/tmp/old.jpg',
      );
    });

    test('merge protects failedDeviceAvatarIds, tracks dedupedServerIds, and handles malformed/duplicate entries',
        () async {
      final serverAvatarB64 = base64Encode(_png1x1A);
      final avatarPaths = <String, String?>{};
      final dedupedServerIds = <String>{};

      final deviceContacts = [
        const fc.Contact(
          id: 'dev-failed-photo',
          displayName: 'Failed Device Photo',
          phones: [fc.Phone(number: '4085551111')],
        ),
      ];

      final networkContacts = await ContactV2Actions.mergeServerContactMapsForTest(
        serverMaps: [
          {
            'id': 'mac-match',
            'displayName': 'Matched Server',
            'phoneNumbers': [
              'not-a-map',
              {'address': null, 'label': 'mobile'},
              {'address': '+1 (408) 555-1111', 'label': 'mobile'},
            ],
            'emails': [null, {'address': '  '}],
            'avatar': serverAvatarB64,
          },
          {
            'id': 'dup-srv',
            'displayName': 'Dup First',
            'phoneNumbers': [
              {'address': '+14155550000', 'label': 'mobile'},
            ],
            'emails': <dynamic>[],
            'avatar': serverAvatarB64,
          },
          {
            'id': 'dup-srv',
            'displayName': 'Dup Second No Avatar',
            'phoneNumbers': [
              {'address': '+14155550000', 'label': 'mobile'},
            ],
            'emails': <dynamic>[],
            'avatar': null,
          },
        ],
        deviceContacts: deviceContacts,
        avatarPaths: avatarPaths,
        failedDeviceAvatarIds: {'dev-failed-photo'},
        dedupedServerIdsOut: dedupedServerIds,
      );

      // Matched device contact is tracked for stale server-row cleanup, and failedDeviceAvatarIds prevents overwrite.
      expect(dedupedServerIds, {'server:mac-match'});
      expect(avatarPaths.containsKey('dev-failed-photo'), isFalse);

      // Second duplicate server ID with avatar: null does NOT clobber the first entry's saved avatar.
      expect(networkContacts.length, 2);
      expect(avatarPaths['server:dup-srv'], isNotNull);
    });
  });
}
