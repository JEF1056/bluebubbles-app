import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_library_dialog.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_library_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/text_field_attachment_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/buttons/text_field_button.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_icon_bar.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/library_sticker.dart';
import 'package:bluebubbles/models/models.dart' show ServerDetails;
import 'package:bluebubbles/services/network/api/sticker_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/send_data.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart' as dio;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

final Uint8List _kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

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

class _FakeSettingsService extends SettingsService {
  ServerDetails fakeDetails = const ServerDetails(
    macOSVersion: 15,
    macOSMinorVersion: 0,
    serverVersion: '2.0.0',
    serverVersionCode: 200,
    privateApiEnabled: true,
    apiVersions: [1, 2],
    supportsStickersFlag: true,
  );

  @override
  ServerDetails getServerDetails() => fakeDetails;
}

class _FakeStickerApi extends StickerApi {
  _FakeStickerApi() : super(HttpService());

  List<LibrarySticker> serverStickers = [];
  final List<(String id, bool thumbnail)> imageRequests = [];
  final List<(Uint8List bytes, String fileName)> savedStickers = [];
  final List<String> deletedIds = [];

  @override
  Future<({List<LibrarySticker> stickers, String? reason})> library({dio.CancelToken? cancelToken}) async =>
      (stickers: List<LibrarySticker>.from(serverStickers), reason: null);

  @override
  Future<Uint8List> image(String identifier, {bool thumbnail = false, dio.CancelToken? cancelToken}) async {
    imageRequests.add((identifier, thumbnail));
    return _kPng1x1;
  }

  @override
  Future<LibrarySticker?> save({
    required Uint8List bytes,
    required String fileName,
    String? name,
    dio.CancelToken? cancelToken,
  }) async {
    savedStickers.add((bytes, fileName));
    final added = LibrarySticker(
      identifier: 'added-${savedStickers.length}',
      shelf: 'recent',
      name: fileName,
      mimeType: 'image/png',
      longestSide: 120,
    );
    serverStickers = [added, ...serverStickers];
    return added;
  }

  @override
  Future<dio.Response> delete(String identifier, {dio.CancelToken? cancelToken}) async {
    deletedIds.add(identifier);
    serverStickers.removeWhere((s) => s.identifier == identifier);
    return dio.Response(requestOptions: dio.RequestOptions(path: '/api/v2/sticker/$identifier'), statusCode: 200);
  }
}

class _FakeHttpService extends HttpService {
  _FakeHttpService(this.fakeSticker);

  final _FakeStickerApi fakeSticker;

  @override
  StickerApi get sticker => fakeSticker;
}

class _FakeFilesystemService extends FilesystemService {
  _FakeFilesystemService(this._dir);
  final Directory _dir;

  @override
  Directory get appDocDir => _dir;
}

void _resetSingleton<T extends Object>(T instance) {
  if (GetIt.I.isRegistered<T>()) {
    GetIt.I.unregister<T>();
  }
  GetIt.I.registerSingleton<T>(instance);
}

({
  _FakeSettingsService settings,
  _FakeStickerApi stickerApi,
  StickerLibraryService stickerSvc,
  Directory tempDir,
}) _registerStickerTestServices({Skins skin = Skins.Material}) {
  Get.testMode = true;
  final tempDir = Directory.systemTemp.createTempSync('bb_sticker_picker_test_');

  _resetSingleton<BaseLogger>(_SilentLogger());

  final settingsSvc = _FakeSettingsService()..settings = Settings();
  settingsSvc.settings.skin.value = skin;
  settingsSvc.settings.enablePrivateAPI.value = true;
  _resetSingleton<SettingsService>(settingsSvc);

  _resetSingleton<FilesystemService>(_FakeFilesystemService(tempDir));

  final fakeStickerApi = _FakeStickerApi();
  _resetSingleton<HttpService>(_FakeHttpService(fakeStickerApi));

  final stickerSvc = StickerLibraryService()..useMemoryCache = true;
  _resetSingleton<StickerLibraryService>(stickerSvc);

  return (
    settings: settingsSvc,
    stickerApi: fakeStickerApi,
    stickerSvc: stickerSvc,
    tempDir: tempDir,
  );
}

Widget _wrapApp(Widget child) {
  return GetMaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF)),
    ),
    home: Scaffold(body: child),
  );
}

void main() {
  test('ServerDetails parses supports_stickers and TextFieldButton.Stickers gates on it', () {
    final explicitlySupported = ServerDetails.fromServerInfo({
      'os_version': '15.0',
      'server_version': '2.0.0',
      'api_versions': [1, 2],
      'supports_stickers': true,
    });
    expect(explicitlySupported.supportsStickers, isTrue);

    final explicitlyDisabled = ServerDetails.fromServerInfo({
      'os_version': '15.0',
      'server_version': '2.0.0',
      'api_versions': [1, 2],
      'supports_stickers': false,
    });
    expect(explicitlyDisabled.supportsStickers, isFalse);

    final fallbackV2 = ServerDetails.fromServerInfo({
      'os_version': '15.0',
      'server_version': '2.0.0',
      'api_versions': [1, 2],
    });
    expect(fallbackV2.supportsStickers, isTrue);

    final env = _registerStickerTestServices();
    addTearDown(() => env.tempDir.deleteSync(recursive: true));
    expect(TextFieldButton.Stickers.isPlatformSupported, isTrue);
    env.settings.fakeDetails = explicitlyDisabled;
    expect(TextFieldButton.Stickers.isPlatformSupported, isFalse);
  });

  testWidgets('AttachmentPicker replaces Video with Stickers on Material and iOS skins', (tester) async {
    final env = _registerStickerTestServices(skin: Skins.Material);
    env.stickerSvc.loaded.value = true;
    final chat = Chat(guid: 'iMessage;-;+15550001234');
    final controller = ConversationViewController(chat);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
      env.tempDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(_wrapApp(AttachmentPicker(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('Stickers'), findsOneWidget);
    expect(find.text('Video'), findsNothing);

    await tester.tap(find.text('Stickers'));
    await tester.pumpAndSettle();
    expect(find.text('Actions'), findsOneWidget);
    expect(find.text('Add Sticker'), findsWidgets);

    // Verify iOS / Cupertino quick-action list also replaced Video with a single Stickers item.
    env.settings.settings.skin.value = Skins.iOS;
    await tester.pumpWidget(_wrapApp(AttachmentPicker(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('Stickers'), findsOneWidget);
    expect(find.text('Video'), findsNothing);
  });

  testWidgets('showWebAttachmentMenu shows Stickers entry and opens StickerLibraryView popover', (tester) async {
    final env = _registerStickerTestServices(skin: Skins.Material);
    env.stickerApi.serverStickers = [
      const LibrarySticker(
        identifier: 'rec-1',
        shelf: 'recent',
        name: 'Wave',
        mimeType: 'image/png',
        longestSide: 120,
      ),
      const LibrarySticker(
        identifier: 'sav-1',
        shelf: 'saved',
        name: 'Star',
        mimeType: 'image/png',
        longestSide: 120,
      ),
    ];
    final chat = Chat(guid: 'iMessage;-;+15550001234');
    final controller = ConversationViewController(chat);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
      env.tempDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      _wrapApp(
        Center(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showWebAttachmentMenu(context, controller),
              child: const Text('Open Web Menu'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Web Menu'));
    await tester.pumpAndSettle();

    expect(find.text('Attach'), findsOneWidget);
    expect(find.text('Stickers'), findsOneWidget);
    expect(find.text('Video'), findsNothing);

    await tester.tap(find.text('Stickers'));
    await tester.pumpAndSettle();

    expect(find.text('Recents'), findsOneWidget);
    expect(find.text('All Stickers'), findsOneWidget);
    expect(find.text('Add Sticker'), findsOneWidget);
    expect(env.stickerApi.imageRequests, containsAll([('rec-1', true), ('sav-1', true)]));
  });

  testWidgets('StickerLibraryView loads shelves, adds sticker, sends standalone, and deletes on long-press',
      (tester) async {
    final env = _registerStickerTestServices(skin: Skins.Material);
    env.stickerApi.serverStickers = [
      const LibrarySticker(
        identifier: 'rec-1',
        shelf: 'recent',
        name: 'Wave',
        mimeType: 'image/png',
        longestSide: 120,
      ),
      const LibrarySticker(
        identifier: 'sav-1',
        shelf: 'saved',
        name: 'Star',
        mimeType: 'image/png',
        longestSide: 120,
      ),
    ];
    await env.stickerSvc.sync();

    final chat = Chat(guid: 'iMessage;-;+15550001234');
    final sentPayloads = <SendData>[];
    final controller = ConversationViewController(chat)
      ..sendFunc = (data) async {
        sentPayloads.add(data);
      };
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
      env.tempDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      _wrapApp(
        SizedBox(
          width: 400,
          height: 500,
          child: StickerLibraryView(
            controller: controller,
            draggable: false,
            onAddSticker: () => pickAndAddSticker(
              onPickImage: () async => (bytes: _kPng1x1, name: 'new_sticker.png'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Recents & All Stickers shelves loaded from GET /api/v2/sticker with role=keyboard thumbnails.
    expect(find.text('Recents'), findsOneWidget);
    expect(find.text('All Stickers'), findsOneWidget);
    expect(find.byType(StickerLibraryTile), findsNWidgets(2));
    expect(env.stickerApi.imageRequests, containsAll([('rec-1', true), ('sav-1', true)]));

    // + Add Sticker uploads via POST /api/v2/sticker and refreshes shelves.
    await tester.tap(find.text('Add Sticker'));
    await tester.pumpAndSettle();
    expect(env.stickerApi.savedStickers.length, 1);
    expect(env.stickerApi.savedStickers.first.$2, 'new_sticker.png');
    expect(find.byType(StickerLibraryTile), findsNWidgets(3));

    // Tap to send standalone sticker fetches full image and invokes controller.send.
    await tester.tap(find.byKey(const ValueKey('sticker-tile-sav-1')));
    await tester.pumpAndSettle();
    expect(env.stickerApi.imageRequests, contains(('sav-1', false)));
    expect(sentPayloads.length, 1);
    expect(sentPayloads.first.attachments.single.name, 'sticker-sav-1.png');

    // Long-press opens confirmation dialog and deletes via DELETE /api/v2/sticker/:id.
    await tester.longPress(find.byKey(const ValueKey('sticker-tile-rec-1')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Sticker?'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(env.stickerApi.deletedIds, ['rec-1']);
    expect(find.byKey(const ValueKey('sticker-tile-rec-1')), findsNothing);
  });

  test('StickerLibraryService syncs and caches role=keyboard thumbnails and full images on disk', () async {
    final env = _registerStickerTestServices();
    env.stickerSvc.useMemoryCache = false;
    addTearDown(() => env.tempDir.deleteSync(recursive: true));

    env.stickerApi.serverStickers = [
      const LibrarySticker(
        identifier: 'disk-1',
        shelf: 'saved',
        name: 'Disk Sticker',
        mimeType: 'image/png',
        longestSide: 120,
      ),
    ];

    await env.stickerSvc.sync();
    expect(env.stickerSvc.entries.map((e) => e.identifier), ['disk-1']);
    expect(env.stickerSvc.thumbnailFile('disk-1').existsSync(), isTrue);
    expect(env.stickerApi.imageRequests, contains(('disk-1', true)));

    final sentBytes = await env.stickerSvc.imageForSending(env.stickerSvc.entries.single);
    expect(sentBytes, _kPng1x1);
    expect(env.stickerApi.imageRequests, contains(('disk-1', false)));
  });
}
