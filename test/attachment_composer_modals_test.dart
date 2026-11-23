import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/attachment_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/composer_popover.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/genmoji_dialog.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/media_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/details_menu_action.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_action_context.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_suffix.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/genmoji.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/network/api/attachment_api.dart';
import 'package:bluebubbles/services/network/api/genmoji_api.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:dio/dio.dart' as dio;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:hand_signature/signature.dart';

// 1x1 transparent PNG
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

class _FakeSettingsService extends SettingsService {}

class _FakeDesktopPrefs extends SharedPreferencesDesktopActions {
  _FakeDesktopPrefs(super.service);
  @override
  double? getSplitRatio() => null;
  @override
  Future<void> setSplitRatio(double ratio) async {}
}

class _FakeThemePrefs extends SharedPreferencesThemeActions {
  _FakeThemePrefs(super.service);
  @override
  String? getSelectedLightTheme() => null;
  @override
  String? getSelectedDarkTheme() => null;
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    desktop = _FakeDesktopPrefs(this);
    theme = _FakeThemePrefs(this);
  }
}

class _FakeChatsService extends ChatsService {
  @override
  Future<void> setChatTextFieldText(Chat chat, String? value, {List<Run> runs = const []}) async {
    chat.textFieldText = value;
  }

  @override
  Future<void> setChatTextFieldAttachments(Chat chat, List<String> attachments) async {
    chat.textFieldAttachments = attachments;
  }
}

class _FakeOutgoingMessageHandler extends OutgoingMessageHandler {
  @override
  Future<void> queue(OutgoingQueueItem item) async {}
}

class _FakeAttachmentsService extends AttachmentsService {
  final List<String> savedFiles = [];

  @override
  Future<void> saveToDisk(
    PlatformFile file, {
    Attachment? attachment,
    bool isAutoDownload = false,
    bool isDocument = false,
  }) async {
    savedFiles.add(file.name);
  }
}

class _FakeGenmojiApi extends GenmojiApi {
  _FakeGenmojiApi(super.svc);

  Completer<List<GenmojiImage>>? pendingCreate;

  @override
  Future<GenmojiSupport> status({dio.CancelToken? cancelToken}) async =>
      const GenmojiSupport(available: true, reason: 'available');

  @override
  Future<List<GenmojiImage>> create(String description, {int count = 1, dio.CancelToken? cancelToken}) async {
    final completer = pendingCreate;
    if (completer != null) return completer.future;
    return [
      GenmojiImage(png: Uint8List.fromList(_tinyPng), width: 1, height: 1),
    ];
  }
}

class _FakeMessageApi extends MessageApi {
  _FakeMessageApi(super.svc);

  int callCount = 0;
  Completer<dio.Response<dynamic>>? pendingCompleter;

  @override
  Future<dio.Response> createScheduled(
    String chatGuid,
    String message,
    DateTime date,
    Map<String, dynamic> schedule, {
    dio.CancelToken? cancelToken,
  }) {
    callCount++;
    final completer = pendingCompleter;
    if (completer != null) return completer.future;
    return Future.value(
      dio.Response(
        requestOptions: dio.RequestOptions(path: '/message/schedule'),
        statusCode: 200,
        data: {'status': 200},
      ),
    );
  }
}

class _FakeAttachmentApi extends AttachmentApi {
  _FakeAttachmentApi(super.svc);

  int downloadCalls = 0;
  int livePhotoCalls = 0;

  @override
  Future<dio.Response> download(
    String guid, {
    void Function(int, int)? onReceiveProgress,
    bool original = false,
    String? mimeType,
    int? width,
    String? quality,
    String? savePath,
    dio.CancelToken? cancelToken,
  }) async {
    downloadCalls++;
    return dio.Response(
      requestOptions: dio.RequestOptions(path: '/attachment/$guid/download'),
      statusCode: 200,
      data: Uint8List.fromList(_tinyPng),
    );
  }

  @override
  Future<dio.Response> downloadLivePhoto(
    String guid, {
    void Function(int, int)? onReceiveProgress,
    String? savePath,
    dio.CancelToken? cancelToken,
  }) async {
    livePhotoCalls++;
    return dio.Response(
      requestOptions: dio.RequestOptions(path: '/attachment/$guid/live'),
      statusCode: 200,
      data: Uint8List.fromList(_tinyPng),
    );
  }
}

class _FakeHttpService extends HttpService {
  late final _FakeGenmojiApi fakeGenmoji = _FakeGenmojiApi(this);
  late final _FakeMessageApi fakeMessage = _FakeMessageApi(this);
  late final _FakeAttachmentApi fakeAttachment = _FakeAttachmentApi(this);

  _FakeHttpService() {
    dioInstance();
    genmoji = fakeGenmoji;
    message = fakeMessage;
    attachment = fakeAttachment;
  }

  void dioInstance() {
    super.dio = dio.Dio();
  }
}

void _registerTestServices(_FakeHttpService httpSvc, _FakeAttachmentsService attachmentsSvc) {
  Get.testMode = true;
  void register<T extends Object>(T instance) {
    if (GetIt.I.isRegistered<T>()) GetIt.I.unregister<T>();
    GetIt.I.registerSingleton<T>(instance);
  }

  final settings = _FakeSettingsService()..settings = Settings();
  settings.settings.skin.value = Skins.Material;
  register<SettingsService>(settings);
  register<SharedPreferencesService>(_FakePrefsService());
  register<NavigatorService>(NavigatorService());
  register<ChatsService>(_FakeChatsService());
  register<HandleService>(HandleService());
  register<ThemesService>(ThemesService());
  register<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  register<bb_events.EventDispatcher>(bb_events.EventDispatcher());
  register<SyncService>(SyncService());
  register<LifecycleService>(LifecycleService());
  register<SocketService>(SocketService());
  register<OutgoingMessageHandler>(_FakeOutgoingMessageHandler());
  register<HttpService>(httpSvc);
  AttachmentsSvc = attachmentsSvc;
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _harness({required Size size, required Widget child, Chat? chat}) {
  final body = chat == null ? child : ChatStateScope(chatState: ChatState(chat), child: child);
  return MediaQuery(
    data: MediaQueryData(size: size),
    child: GetMaterialApp(
      useInheritedMediaQuery: true,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
      ),
      home: Scaffold(body: body),
    ),
  );
}

void main() {
  late _FakeHttpService httpSvc;
  late _FakeAttachmentsService attachmentsSvc;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('flutter_keyboard_visibility'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  setUp(() {
    httpSvc = _FakeHttpService();
    attachmentsSvc = _FakeAttachmentsService();
    _registerTestServices(httpSvc, attachmentsSvc);
  });

  testWidgets('A1 handwritten opens ComposerPopoverCard on wide viewport and attaches PNG', (tester) async {
    _setViewport(tester, const Size(1000, 800));
    final chat = Chat(guid: 'iMessage;-;+15551110001');
    final controller = ConversationViewController(chat);
    Get.put(controller, tag: chat.guid);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
    });

    await tester.pumpWidget(
      _harness(
        size: const Size(1000, 800),
        chat: chat,
        child: Builder(
          builder: (ctx) => Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ElevatedButton(
                key: controller.textFieldKey,
                onPressed: () => AttachmentActions.handwritten(ctx, controller),
                child: const Text('Draw'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    expect(find.byType(ComposerPopoverCard), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Draw Handwritten Message'), findsOneWidget);
    expect(find.byType(HandSignature), findsOneWidget);

    // Attach starts disabled before any ink stroke.
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Attach')).onPressed, isNull);

    // Select a non-black swatch (last swatch = scheme.error) so exported PNG preserves chosen ink color.
    await tester.tap(find.byTooltip('Ink color').last);
    await tester.pump();

    // Draw a stroke on the canvas.
    await tester.drag(find.byType(HandSignature), const Offset(50, 50));
    await tester.pumpAndSettle();

    final attachBtn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Attach'));
    expect(attachBtn.onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Attach'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(controller.pickedAttachments.length, 1);
    expect(controller.pickedAttachments.first.balloonBundleId, 'com.apple.Handwriting.HandwritingProvider');
    expect(find.byType(ComposerPopoverCard), findsNothing);

    // Verify exported PNG contains colored (non-black) pixels matching the chosen error swatch.
    final exportedBytes = controller.pickedAttachments.first.bytes!;
    final hasColoredPixel = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(exportedBytes);
      final frame = await codec.getNextFrame();
      final rgba = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      for (var i = 0; i < rgba.lengthInBytes; i += 4) {
        final r = rgba.getUint8(i);
        final g = rgba.getUint8(i + 1);
        final b = rgba.getUint8(i + 2);
        final a = rgba.getUint8(i + 3);
        if (a > 0 && r > g + 30 && r > b + 30) return true;
      }
      return false;
    });
    expect(hasColoredPixel, isTrue);
  });

  testWidgets('A1 handwritten opens 28dp rounded BottomSheet on narrow mobile viewport', (tester) async {
    _setViewport(tester, const Size(400, 800));
    final chat = Chat(guid: 'iMessage;-;+15551110002');
    final controller = ConversationViewController(chat);
    Get.put(controller, tag: chat.guid);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
    });

    await tester.pumpWidget(
      _harness(
        size: const Size(400, 800),
        chat: chat,
        child: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => AttachmentActions.handwritten(ctx, controller),
              child: const Text('Draw'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Draw Handwritten Message'), findsOneWidget);
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.showDragHandle, isTrue);
    expect((sheet.shape as RoundedRectangleBorder).borderRadius, const BorderRadius.vertical(top: Radius.circular(28)));

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(controller.pickedAttachments, isEmpty);
  });

  testWidgets('A3 showGenmojiDialog uses 28dp BottomSheet on mobile and returns GenmojiImage', (tester) async {
    _setViewport(tester, const Size(400, 800));
    GenmojiImage? result;

    await tester.pumpWidget(
      _harness(
        size: const Size(400, 800),
        child: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showGenmojiDialog(ctx, isIMessage: true);
              },
              child: const Text('Open Genmoji'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Genmoji'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(find.text('Genmoji'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'happy cat');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Attach'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.png, isNotEmpty);
  });

  testWidgets('A3 showGenmojiDialog uses ComposerPopoverCard on wide viewport without Route<void> TypeError', (tester) async {
    _setViewport(tester, const Size(1000, 800));
    final chat = Chat(guid: 'iMessage;-;+15551110003');
    final controller = ConversationViewController(chat);
    Get.put(controller, tag: chat.guid);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
    });

    GenmojiImage? result;
    await tester.pumpWidget(
      _harness(
        size: const Size(1000, 800),
        chat: chat,
        child: Builder(
          builder: (ctx) => Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ElevatedButton(
                key: controller.textFieldKey,
                onPressed: () async {
                  result = await showGenmojiDialog(ctx, isIMessage: true);
                },
                child: const Text('Open Genmoji'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Genmoji'));
    await tester.pumpAndSettle();

    expect(find.byType(ComposerPopoverCard), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.enterText(find.byType(TextField), 'rocket');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Attach'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(find.byType(ComposerPopoverCard), findsNothing);
  });

  testWidgets('A3 showGenmojiDialog wide popover ignores outside barrier tap and Escape while generating', (
    tester,
  ) async {
    _setViewport(tester, const Size(1000, 800));
    final chat = Chat(guid: 'iMessage;-;+15551110005');
    final controller = ConversationViewController(chat);
    Get.put(controller, tag: chat.guid);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
    });

    final pending = Completer<List<GenmojiImage>>();
    httpSvc.fakeGenmoji.pendingCreate = pending;

    GenmojiImage? result;
    await tester.pumpWidget(
      _harness(
        size: const Size(1000, 800),
        chat: chat,
        child: Builder(
          builder: (ctx) => Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ElevatedButton(
                key: controller.textFieldKey,
                onPressed: () async {
                  result = await showGenmojiDialog(ctx, isIMessage: true);
                },
                child: const Text('Open Genmoji'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Genmoji'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nebula');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pump();

    expect(find.widgetWithText(TextButton, 'Stop'), findsOneWidget);
    expect(find.byType(ComposerPopoverCard), findsOneWidget);

    // Outside barrier tap must not dismiss while generating.
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    expect(find.byType(ComposerPopoverCard), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Stop'), findsOneWidget);

    // Escape must not bypass PopScope / dismiss ComposerPopoverCard while generating.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(ComposerPopoverCard), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Stop'), findsOneWidget);

    pending.complete([GenmojiImage(png: Uint8List.fromList(_tinyPng), width: 1, height: 1)]);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Attach'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(find.byType(ComposerPopoverCard), findsNothing);
  });

  testWidgets('A6 scheduled send displays inline spinner instead of BBProgressDialog and blocks double-submit', (tester) async {
    final chat = Chat(guid: 'iMessage;-;+15551110004');
    final controller = ConversationViewController(chat);
    Get.put(controller, tag: chat.guid);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
    });

    final fieldKey = GlobalKey<ConversationTextFieldState>();
    controller.textController.text = 'Hello later';
    controller.scheduledDate.value = DateTime.now().add(const Duration(hours: 2));

    final completer = Completer<dio.Response<dynamic>>();
    httpSvc.fakeMessage.pendingCompleter = completer;

    await tester.pumpWidget(
      _harness(
        size: const Size(420, 800),
        chat: chat,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConversationTextField(
            key: fieldKey,
            parentController: controller,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(TextFieldSuffix), findsOneWidget);

    // Start scheduled send and trigger a second call concurrently.
    final sendFuture = fieldKey.currentState!.sendMessage();
    unawaited(fieldKey.currentState!.sendMessage());
    await tester.pump();

    expect(httpSvc.fakeMessage.callCount, 1);
    expect(find.byTooltip('Scheduling message…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(TextFieldSuffix), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);

    completer.complete(
      dio.Response(
        requestOptions: dio.RequestOptions(path: '/message/schedule'),
        statusCode: 200,
        data: {'status': 200},
      ),
    );
    await sendFuture;
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Scheduling message…'), findsNothing);
    expect(find.byType(TextFieldSuffix), findsOneWidget);
  });

  testWidgets('A7 downloadOriginalAttachments and downloadLivePhoto emit snackbars without dialogs', (tester) async {
    final chat = Chat(guid: 'iMessage;-;+15551110005');
    final controller = ConversationViewController(chat);
    Get.put(controller, tag: chat.guid);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
    });

    final attachment = Attachment(
      guid: 'att-1',
      uti: 'public.heic',
      mimeType: 'image/heic',
      transferName: 'IMG_0001.heic',
      totalBytes: 123,
      hasLivePhoto: true,
    );
    final msg = Message(guid: 'msg-1', text: '');
    final part = MessagePart(part: 0, attachments: [attachment]);

    var poppedCount = 0;
    final snacks = <({String title, String body, SnackbarType type})>[];

    await tester.pumpWidget(
      _harness(
        size: const Size(420, 800),
        chat: chat,
        child: Builder(
          builder: (ctx) => Column(
            children: [
              ElevatedButton(
                onPressed: () {
                  final actionCtx = MessagePopupActionContext(
                    context: ctx,
                    widthContext: ctx,
                    cvController: controller,
                    messageState: MessageState(msg),
                    message: msg,
                    part: part,
                    chat: chat,
                    service: MessagesService(chat.guid),
                    serverDetails: const MessagePopupServerDetails(
                      minSierra: true,
                      minBigSur: true,
                      supportsOriginalDownload: true,
                    ),
                    action: DetailsMenuAction.SaveOriginal,
                    popDetails: ({bool returnVal = true}) => poppedCount++,
                    showSnack: (title, body, {SnackbarType type = SnackbarType.info}) =>
                        snacks.add((title: title, body: body, type: type)),
                    dmChat: null,
                    isEmbeddedMedia: false,
                  );
                  downloadOriginalAttachments(actionCtx);
                },
                child: const Text('Orig'),
              ),
              ElevatedButton(
                onPressed: () {
                  final actionCtx = MessagePopupActionContext(
                    context: ctx,
                    widthContext: ctx,
                    cvController: controller,
                    messageState: MessageState(msg),
                    message: msg,
                    part: part,
                    chat: chat,
                    service: MessagesService(chat.guid),
                    serverDetails: const MessagePopupServerDetails(
                      minSierra: true,
                      minBigSur: true,
                      supportsOriginalDownload: true,
                    ),
                    action: DetailsMenuAction.SaveLivePhoto,
                    popDetails: ({bool returnVal = true}) => poppedCount++,
                    showSnack: (title, body, {SnackbarType type = SnackbarType.info}) =>
                        snacks.add((title: title, body: body, type: type)),
                    dmChat: null,
                    isEmbeddedMedia: false,
                  );
                  downloadLivePhoto(actionCtx);
                },
                child: const Text('Live'),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Orig'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(poppedCount, 2);
    expect(httpSvc.fakeAttachment.downloadCalls, 1);
    expect(httpSvc.fakeAttachment.livePhotoCalls, 1);
    expect(attachmentsSvc.savedFiles, ['IMG_0001.heic', 'IMG_0001.mov']);
    expect(snacks.map((s) => s.title).toList(), [
      'Downloading',
      'Download Complete',
      'Downloading',
      'Download Complete',
    ]);
  });
}
