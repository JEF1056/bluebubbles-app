import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/network/api/icloud_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';

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

class _FakeICloudApi extends iCloudApi {
  _FakeICloudApi(super.svc, {this.accountResponse, this.contactResponse, this.throwAccount = false, this.throwContact = false});

  final Map<String, dynamic>? accountResponse;
  final Map<String, dynamic>? contactResponse;
  final bool throwAccount;
  final bool throwContact;

  int accountCalls = 0;
  int contactCalls = 0;

  @override
  Future<Response> getAccountInfo({CancelToken? cancelToken}) async {
    accountCalls++;
    if (throwAccount) throw DioException(requestOptions: RequestOptions(path: '/icloud/account'));
    return Response(
      requestOptions: RequestOptions(path: '/icloud/account'),
      statusCode: 200,
      data: {'data': accountResponse},
    );
  }

  @override
  Future<Response> getAccountContact({String? address, CancelToken? cancelToken}) async {
    contactCalls++;
    if (throwContact) throw DioException(requestOptions: RequestOptions(path: '/icloud/contact'));
    return Response(
      requestOptions: RequestOptions(path: '/icloud/contact'),
      statusCode: 200,
      data: {'data': contactResponse},
    );
  }
}

class _FakeHttpService extends HttpService {
  _FakeHttpService({
    Map<String, dynamic>? accountResponse,
    Map<String, dynamic>? contactResponse,
    bool throwAccount = false,
    bool throwContact = false,
  }) {
    fakeIcloud = _FakeICloudApi(
      this,
      accountResponse: accountResponse,
      contactResponse: contactResponse,
      throwAccount: throwAccount,
      throwContact: throwContact,
    );
  }

  late final _FakeICloudApi fakeIcloud;

  @override
  iCloudApi get icloud => fakeIcloud;
}

class _FakeSettingsService extends SettingsService {}

// 1x1 transparent PNG
const _samplePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await GetIt.I.reset();
    Get.reset();
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
    final settingsSvc = _FakeSettingsService()..settings = Settings();
    settingsSvc.settings.finishedSetup.value = true;
    GetIt.I.registerSingleton<SettingsService>(settingsSvc);
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  });

  tearDown(() async {
    await GetIt.I.reset();
    Get.reset();
  });

  group('SettingsService iCloud profile helpers', () {
    test('decodeAvatarBase64 handles raw base64, data URIs, and invalid input', () {
      final raw = SettingsService.decodeAvatarBase64(_samplePngBase64);
      expect(raw, isNotNull);
      expect(raw!.isNotEmpty, isTrue);

      final withPrefix = SettingsService.decodeAvatarBase64('data:image/png;base64,$_samplePngBase64');
      expect(withPrefix, equals(raw));

      expect(SettingsService.decodeAvatarBase64(null), isNull);
      expect(SettingsService.decodeAvatarBase64('   '), isNull);
      expect(SettingsService.decodeAvatarBase64('not-valid-base64!!!'), isNull);
    });

    test('extractDisplayName prefers real names and ignores generic You', () {
      expect(SettingsService.extractDisplayName({'name': 'You', 'account_name': 'Jane Doe'}), 'Jane Doe');
      expect(SettingsService.extractDisplayName({'first_name': 'Jane', 'last_name': 'Doe'}), 'Jane Doe');
      expect(SettingsService.extractDisplayName({'name': 'You'}), isNull);
      expect(SettingsService.extractDisplayName(null), isNull);
    });

    test('applyIcloudProfileData populates userName, iCloudAccount, aliases, and avatar bytes', () async {
      await SettingsSvc.applyIcloudProfileData(
        persist: false,
        account: {
          'apple_id': 'jane@icloud.com',
          'account_name': 'Jane Account',
          'active_alias': 'jane@icloud.com',
          'vetted_aliases': [
            {'Alias': 'jane@icloud.com', 'Status': 3},
            {'Alias': '+15551234567', 'Status': 3},
          ],
        },
        contact: {
          'name': 'Jane Doe',
          'avatar': _samplePngBase64,
        },
      );

      expect(SettingsSvc.settings.userName.value, 'Jane Doe');
      expect(SettingsSvc.effectiveUserName, 'Jane Doe');
      expect(SettingsSvc.settings.iCloudAccount.value, 'jane@icloud.com');
      expect(SettingsSvc.iCloudActiveAlias.value, 'jane@icloud.com');
      expect(SettingsSvc.iCloudAliases, ['jane@icloud.com', '+15551234567']);
      expect(SettingsSvc.userAvatarBytes.value, equals(base64Decode(_samplePngBase64)));
    });

    test('applyIcloudProfileData preserves custom userName when already customized', () async {
      SettingsSvc.settings.userName.value = 'My Custom Name';
      await SettingsSvc.applyIcloudProfileData(
        persist: false,
        contact: {'name': 'Jane Doe'},
      );
      expect(SettingsSvc.settings.userName.value, 'My Custom Name');
    });

    test('refreshIcloudProfile fetches account and contact and silently swallows errors', () async {
      final http = _FakeHttpService(
        throwAccount: true,
        contactResponse: {'name': 'Alex Smith', 'avatar': _samplePngBase64},
      );
      GetIt.I.registerSingleton<HttpService>(http);

      // Should not throw even though /icloud/account failed
      await SettingsSvc.refreshIcloudProfile(force: true);
      expect(http.fakeIcloud.accountCalls, 1);
      expect(http.fakeIcloud.contactCalls, 1);
      expect(SettingsSvc.settings.userName.value, 'Alex Smith');
      expect(SettingsSvc.userAvatarBytes.value, isNotNull);
    });
  });

  group('ContactAvatarWidget self avatar & initials', () {
    testWidgets('renders CircleAvatar with MemoryImage from userAvatarBytes when handle is null', (tester) async {
      SettingsSvc.userAvatarBytes.value = Uint8List.fromList(base64Decode(_samplePngBase64));

      await tester.pumpWidget(
        const GetMaterialApp(
          home: Scaffold(
            body: ContactAvatarWidget(
              handle: null,
              size: 40,
              editable: false,
            ),
          ),
        ),
      );

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundImage, isA<MemoryImage>());
    });

    testWidgets('renders self initials when handle is null, no avatar, and userName is set', (tester) async {
      SettingsSvc.settings.userName.value = 'Jessica Fan';
      SettingsSvc.settings.skin.value = Skins.iOS;

      await tester.pumpWidget(
        const GetMaterialApp(
          home: Scaffold(
            body: ContactAvatarWidget(
              handle: null,
              size: 40,
              editable: false,
            ),
          ),
        ),
      );

      expect(find.text('JF'), findsOneWidget);
    });
  });
}
