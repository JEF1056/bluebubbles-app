import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/hover_action_bar.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/reply_bubble_section.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/actions/media_actions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_line_painter.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_map_widget.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/conversation_fullscreen_holder.dart';
import 'package:bluebubbles/app/layouts/settings/pages/server/server_management_panel.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/settings_leading_icon.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/settings_tile.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/wrappers/tablet_mode_wrapper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/models/models.dart' show ServerDetails;
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/network/api/attachment_api.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/chat_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide FormData, Response;
import 'package:get_it/get_it.dart';
import 'package:latlong2/latlong.dart';

class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;
  List<int> lastBodyBytes = const [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    final chunks = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        chunks.addAll(chunk);
      }
    }
    lastBodyBytes = chunks;
    return ResponseBody.fromString(
      jsonEncode({'status': 200, 'data': {'path': '/tmp/staged.png'}}),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeBaseApi implements BaseApi {
  _FakeBaseApi(this.adapter)
      : dio = Dio(BaseOptions(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ))..httpClientAdapter = adapter;

  final _CapturingAdapter adapter;

  @override
  final Dio dio;

  @override
  String get origin => 'https://mock.bluebubbles.local';

  @override
  String get apiRoot => '$origin/api/v1';

  @override
  String get apiRootV2 => '$origin/api/v2';

  @override
  Map<String, String> get headers => const {};

  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const {}]) =>
      {'guid': 'test-guid', ...params};

  @override
  Future<Response> runApiGuarded(Future<Response> Function() func, {bool checkOrigin = true}) => func();

  @override
  Future<Response> returnSuccessOrError(Response r) async => r;
}

class _FakeSettingsService extends SettingsService {
  final Rx<ServerDetails> _details = const ServerDetails(
    macOSVersion: 14,
    macOSMinorVersion: 0,
    serverVersion: '1.9.0',
    serverVersionCode: 10900,
  ).obs;

  @override
  ServerDetails get serverDetails => _details.value;
}

class _FakeLogger extends BaseLogger {
  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

class _FakeDesktopPrefs extends SharedPreferencesDesktopActions {
  _FakeDesktopPrefs(super.service);
  double? _ratio;

  @override
  double? getSplitRatio() => _ratio;

  @override
  Future<void> setSplitRatio(double ratio) async {
    _ratio = ratio;
  }
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

void _registerBaseServices() {
  Get.testMode = true;
  final settings = _FakeSettingsService()..settings = Settings();
  settings.settings.skin.value = Skins.Material;
  settings.settings.tabletMode.value = true;
  GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  GetIt.I.registerSingleton<SettingsService>(settings);
  GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  GetIt.I.registerSingleton<HttpService>(HttpService());
  GetIt.I.registerSingleton<AttachmentDownloadService>(AttachmentDownloadService());
  GetIt.I.registerSingleton<SocketService>(SocketService());
  GetIt.I.registerSingleton<ChatsService>(ChatsService());
  GetIt.I.registerSingleton<HandleService>(HandleService());
  GetIt.I.registerSingleton<ThemesService>(ThemesService());
  GetIt.I.registerSingleton<BaseLogger>(_FakeLogger());
  GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
}

void main() {
  tearDown(() async {
    Get.reset();
    await GetIt.I.reset();
  });

  group('Web attachment upload bytes', () {
    test('AttachmentApi.upload posts MultipartFile.fromBytes without touching disk', () async {
      final adapter = _CapturingAdapter();
      final api = AttachmentApi(_FakeBaseApi(adapter));
      final payload = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

      final res = await api.upload('', 'photo.png', bytes: payload);

      expect(res.statusCode, 200);
      expect(adapter.lastOptions?.uri.path, '/api/v1/attachment/upload');
      final form = adapter.lastOptions?.data as FormData;
      expect(form.files.single.key, 'attachment');
      expect(form.files.single.value.filename, 'photo.png');
      expect(form.files.single.value.length, payload.length);
      expect(utf8.decode(adapter.lastBodyBytes, allowMalformed: true), contains('photo.png'));
    });

    test('ChatApi.setIcon posts MultipartFile.fromBytes without touching disk', () async {
      final adapter = _CapturingAdapter();
      final api = ChatApi(_FakeBaseApi(adapter));
      final payload = Uint8List.fromList([9, 8, 7, 6]);

      final res = await api.setIcon('iMessage;-;chat1', 'folder/group-icon.png', bytes: payload);

      expect(res.statusCode, 200);
      expect(adapter.lastOptions?.uri.path, '/api/v1/chat/iMessage;-;chat1/icon');
      final form = adapter.lastOptions?.data as FormData;
      expect(form.files.single.key, 'icon');
      expect(form.files.single.value.filename, 'group-icon.png');
      expect(form.files.single.value.length, payload.length);
    });
  });

  group('Safe Notification interop', () {
    test('web_interop getters and permission request never throw on non-Notification contexts', () async {
      expect(isWebDocumentHidden, isFalse);
      expect(webNotificationPermission, isIn(['default', 'denied', 'granted', 'unsupported']));
      final requested = await requestWebNotificationPermission();
      expect(requested, isIn(['default', 'denied', 'granted', 'unsupported']));
    });
  });

  group('TabletModeWrapper inspector clamp', () {
    test('computePaneWidths clamps leftWidth so left + right + inspector <= maxWidth with minimum right pane', () {
      final open = TabletModeWrapper.computePaneWidths(
        maxWidth: 1095,
        desiredLeftWidth: 900,
        showInspectorPane: true,
        showInspectorToggle: false,
      );
      expect(open.inspectorReserved, 321.0);
      expect(open.rightWidth, 360.0);
      expect(open.leftWidth, 1095.0 - 321.0 - 360.0);
      expect(open.leftWidth + open.rightWidth + open.inspectorReserved, 1095.0);

      final collapsed = TabletModeWrapper.computePaneWidths(
        maxWidth: 1095,
        desiredLeftWidth: 400,
        showInspectorPane: false,
        showInspectorToggle: true,
      );
      expect(collapsed.inspectorReserved, 29.0);
      expect(collapsed.leftWidth, 400.0);
      expect(collapsed.rightWidth, 1095.0 - 400.0 - 29.0);
    });

    testWidgets('wide viewport with inspector toggle clamps oversized left pane without overflow',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      _registerBaseServices();
      final chat = Chat(guid: 'iMessage;-;+15550001');
      ChatsSvc.activeChat = ChatsSvc.getOrCreateChatState(chat);
      NavigationSvc.showInspectorDrawer.value = false;

      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        GetMaterialApp(
          navigatorKey: NavigationSvc.key,
          home: const Scaffold(
            body: TabletModeWrapper(
              initialRatio: 0.9,
              minRatio: 0.2,
              maxRatio: 0.95,
              minWidthLeft: 200,
              maxWidthLeft: 1080,
              enableInspector: true,
              left: SizedBox(key: Key('left-pane'), child: Text('Left')),
              right: SizedBox(key: Key('right-pane'), child: Text('Right')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final leftBox = tester.getSize(find.byKey(const Key('left-pane')));
      expect(leftBox.width, lessThanOrEqualTo(1100 * 0.95));
      expect(find.byKey(const Key('right-pane')), findsOneWidget);
    });
  });

  group('GMsg tokens & gmsgOutgoingGradient', () {
    test('ThemesService fallback base palette uses GMsg gm3-bc25-active tokens', () {
      final light = ThemesService.materialYouTheme(Brightness.light).colorScheme;
      expect(light.primary, const Color(0xFF0B57D0));
      expect(light.surface, const Color(0xFFFFFFFF));
      expect(light.surfaceContainer, const Color(0xFFF0F4F9));
      expect(light.error, const Color(0xFFBA1A1A));
      expect(light.onError, Colors.white);
      expect(light.errorContainer, const Color(0xFFFFDAD6));
      expect(light.onErrorContainer, const Color(0xFF410002));

      final dark = ThemesService.materialYouTheme(Brightness.dark).colorScheme;
      expect(dark.primary, const Color(0xFFA8C7FA));
      expect(dark.surface, const Color(0xFF111318));
      expect(dark.surfaceContainer, const Color(0xFF1E1F20));
      expect(dark.error, const Color(0xFFFFB4AB));
      expect(dark.onError, const Color(0xFF690005));
      expect(dark.errorContainer, const Color(0xFF93000A));
      expect(dark.onErrorContainer, const Color(0xFFFFDAD6));
    });

    testWidgets('gmsgOutgoingGradient returns gradient for GMsg light/dark and null for SMS or custom', (tester) async {
      LinearGradient? lightGrad;
      LinearGradient? smsGrad;
      LinearGradient? darkGrad;
      LinearGradient? customGrad;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemesService.materialYouTheme(Brightness.light),
          home: Builder(builder: (ctx) {
            lightGrad = gmsgOutgoingGradient(ctx, isSms: false);
            smsGrad = gmsgOutgoingGradient(ctx, isSms: true);
            return const SizedBox.shrink();
          }),
        ),
      );
      expect(lightGrad?.colors, const [Color(0xFF1B79F3), Color(0xFF0B57D0)]);
      expect(smsGrad, isNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Theme(
            data: ThemesService.materialYouTheme(Brightness.dark),
            child: Builder(builder: (ctx) {
              darkGrad = gmsgOutgoingGradient(ctx, isSms: false);
              return const SizedBox.shrink();
            }),
          ),
        ),
      );
      expect(darkGrad?.colors, const [Color(0xFF0842A0), Color(0xFF07347E)]);

      await tester.pumpWidget(
        MaterialApp(
          home: Theme(
            data: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
            child: Builder(builder: (ctx) {
              customGrad = gmsgOutgoingGradient(ctx, isSms: false);
              return const SizedBox.shrink();
            }),
          ),
        ),
      );
      expect(customGrad, isNull);
    });
  });

  group('Hover action bar', () {
    test('formatHoverTimestampTooltip returns empty for null/epoch and formatted string otherwise', () {
      _registerBaseServices();
      expect(formatHoverTimestampTooltip(null), isEmpty);
      expect(formatHoverTimestampTooltip(DateTime.fromMillisecondsSinceEpoch(0)), isEmpty);
      final ts = formatHoverTimestampTooltip(DateTime(2025, 4, 10, 14, 35));
      expect(ts, isNotEmpty);
      expect(ts, contains(','));
    });

    testWidgets('MessageHoverBar toggles opacity/pointer ignoring with hovered state', (tester) async {
      _registerBaseServices();
      final chat = Chat(guid: 'iMessage;-;+15551112222');
      final msg = Message(
        guid: 'msg-hover-1',
        text: 'Hello',
        dateCreated: DateTime(2025, 4, 10, 14, 35),
        isFromMe: false,
      );
      final cvController = ConversationViewController(chat);
      final service = MessagesService(chat.guid);
      final msgState = MessageState(msg);
      addTearDown(() {
        msgState.dispose();
        service.dispose();
        cvController.dispose();
      });

      Widget wrapBar(bool hovered) => GetMaterialApp(
            home: Scaffold(
              body: MessageHoverBar(
                controller: msgState,
                part: MessagePart(part: 0, text: 'Hello'),
                cvController: cvController,
                service: service,
                hovered: hovered,
                isReplyThread: false,
              ),
            ),
          );

      await tester.pumpWidget(wrapBar(false));
      final hiddenOpacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(hiddenOpacity.opacity, 0.0);

      await tester.pumpWidget(wrapBar(true));
      await tester.pumpAndSettle();
      final shownOpacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(shownOpacity.opacity, 1.0);
      expect(find.byIcon(Icons.add_reaction_outlined), findsOneWidget);
      expect(find.byIcon(Icons.reply_rounded), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });
  });

  group('Lightbox KeyDownEvent single-step', () {
    testWidgets('arrowRight steps once on KeyDownEvent and ignores KeyRepeatEvent/KeyUpEvent',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      _registerBaseServices();
      SettingsSvc.settings.autoDownload.value = false;
      SettingsSvc.settings.fullscreenViewerSwipeDir.value = SwipeDirection.LEFT;
      final attachments = [
        Attachment(guid: 'att-1', mimeType: 'application/pdf', transferName: 'a.pdf', bytes: Uint8List.fromList([1])),
        Attachment(guid: 'att-2', mimeType: 'application/pdf', transferName: 'b.pdf', bytes: Uint8List.fromList([2])),
        Attachment(guid: 'att-3', mimeType: 'application/pdf', transferName: 'c.pdf', bytes: Uint8List.fromList([3])),
      ];

      await tester.pumpWidget(
        GetMaterialApp(
          home: ConversationFullscreenHolder(
            attachment: attachments.first,
            showInteractions: true,
            currentChat: Chat(guid: 'iMessage;-;+15553334444'),
            galleryAttachments: attachments,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<ConversationFullscreenHolderState>(
        find.byType(ConversationFullscreenHolder),
      );
      expect(state.currentIndex, 0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(state.currentIndex, 1);

      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(state.currentIndex, 1);
    });
  });

  group('Web attachment drafts', () {
    test('syncWebAttachmentDraft stores, overwrites, and clears per-chat drafts when isWeb is true', () {
      const chatA = 'iMessage;-;draft-a';
      const chatB = 'iMessage;-;draft-b';
      ConversationTextFieldState.syncWebAttachmentDraft(chatA, const [], isWeb: true);
      ConversationTextFieldState.syncWebAttachmentDraft(chatB, const [], isWeb: true);

      final fileA = PlatformFile(name: 'a.png', size: 3, bytes: Uint8List.fromList([1, 2, 3]));
      ConversationTextFieldState.syncWebAttachmentDraft(chatA, [fileA], isWeb: false);
      expect(ConversationTextFieldState.webAttachmentDraftFor(chatA), isNull);

      ConversationTextFieldState.syncWebAttachmentDraft(chatA, [fileA], isWeb: true);
      expect(ConversationTextFieldState.webAttachmentDraftFor(chatA)?.single.name, 'a.png');
      expect(ConversationTextFieldState.webAttachmentDraftFor(chatB), isNull);

      ConversationTextFieldState.syncWebAttachmentDraft(chatA, const [], isWeb: true);
      expect(ConversationTextFieldState.webAttachmentDraftFor(chatA), isNull);
    });
  });

  group('URL-encoded openAttachmentWeb', () {
    test('buildAttachmentWebUri appends and URL-encodes guid while preserving existing query params', () {
      final uri = buildAttachmentWebUri(
        'https://bb.example.com:8443/api/v1/attachment/att-1/download?original=true',
        'p@ss+w/rd&1=',
      );
      expect(uri, isNotNull);
      expect(uri!.queryParameters['original'], 'true');
      expect(uri.queryParameters['guid'], 'p@ss+w/rd&1=');
      expect(uri.query, contains('guid=p%40ss%2Bw%2Frd%261%3D'));

      expect(buildAttachmentWebUri(null, 'abc'), isNull);
      expect(buildAttachmentWebUri('', 'abc'), isNull);
    });
  });

  group('Email and phone regex detection', () {
    testWidgets('buildMessageSpans linkifies email, phone, and URL without splitting URLs', (tester) async {
      _registerBaseServices();
      final chat = Chat(guid: 'iMessage;-;+15559998888');
      final msg = Message(guid: 'msg-links-1', isFromMe: false);
      final part = MessagePart(
        part: 0,
        text: 'Mail alice@example.com or call (415) 555-1212 or visit https://user@example.com/path',
      );
      late List<InlineSpan> spans;

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemeData.light().copyWith(
            extensions: const [
              BubbleColors(),
              BubbleText(bubbleText: TextStyle(fontSize: 15)),
            ],
          ),
          home: Builder(builder: (context) {
            spans = buildMessageSpans(context, part, msg);
            return const SizedBox.shrink();
          }),
        ),
      );
      // Keep chat referenced in scope for lint cleanliness.
      expect(chat.guid, isNotEmpty);

      final textSpans = spans.whereType<TextSpan>().toList();
      final clickableTexts = textSpans
          .where((s) => s.recognizer is TapGestureRecognizer)
          .map((s) => s.text)
          .toList();
      expect(
        clickableTexts,
        equals(['alice@example.com', '(415) 555-1212', 'https://user@example.com/path']),
      );
    });
  });

  group('Reply thread and elbow alignment fixes', () {
    testWidgets('Material/Web ReplyBubble and ReplyBubbleSection always open thread view (no jumpToMessage)',
        (tester) async {
      _registerBaseServices();
      GetIt.I.registerSingleton<CacheService>(CacheService());
      final chat = Chat(guid: 'iMessage;-;web-thread-open', chatIdentifier: 'web-thread-open');
      final msgSvc = ensureMessagesSvc(chat.guid);
      final jumpedGuids = <String>[];
      msgSvc.jumpToMessage = jumpedGuids.add;
      final cvController = cvc(chat);
      final chatState = ChatsSvc.getOrCreateChatState(chat);
      ChatsSvc.activeChat = chatState;

      final t0 = DateTime(2026, 11, 19, 10, 0, 0);
      final orig = Message(
        guid: 'orig-web-1',
        text: 'Original message',
        dateCreated: t0,
        isFromMe: false,
      );
      final unrelated = Message(
        guid: 'unrelated-web-1',
        text: 'Unrelated middle message',
        dateCreated: t0.add(const Duration(seconds: 30)),
        isFromMe: false,
      );
      final reply = Message(
        guid: 'reply-web-1',
        text: 'Reply text',
        dateCreated: t0.add(const Duration(minutes: 1)),
        isFromMe: true,
        threadOriginatorGuid: 'orig-web-1',
        threadOriginatorPart: '0:0:0',
      );
      msgSvc.struct.addMessages([orig, unrelated, reply]);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemesService.materialYouTheme(Brightness.light),
          home: ChatStateScope(
            chatState: chatState,
            child: Scaffold(
              body: ListView(
                children: [
                  MessageHolder(cvController: cvController, message: orig, newMessage: unrelated),
                  MessageHolder(cvController: cvController, message: unrelated, oldMessage: orig, newMessage: reply),
                  MessageHolder(cvController: cvController, message: reply, oldMessage: unrelated),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tapping the "1 Reply" indicator opens thread view directly instead of jumpToMessage.
      await tester.tap(find.text('1 Reply'));
      await tester.pumpAndSettle();
      expect(jumpedGuids, isEmpty);
      expect(find.byTooltip('Close thread'), findsOneWidget);

      // Esc key dismisses thread popup cleanly.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsNothing);

      // Tapping ReplyBubbleSection quote opens thread view too and backdrop dismisses it.
      final quotedSection = find.byType(ReplyBubbleSection);
      expect(quotedSection, findsOneWidget);
      await tester.tap(find.descendant(
        of: quotedSection,
        matching: find.textContaining('Original message', findRichText: true),
      ));
      await tester.pumpAndSettle();
      expect(jumpedGuids, isEmpty);
      expect(find.byTooltip('Close thread'), findsOneWidget);

      await tester.tapAt(const Offset(6, 6));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close thread'), findsNothing);

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });

    testWidgets('ReplyLineBox measures ReplyBubbleBounds width excluding sibling hover bar', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                height: 40,
                child: ReplyLineBox(
                  enabled: true,
                  isFromMe: true,
                  connectUpper: true,
                  connectLower: false,
                  color: Colors.white,
                  compactHook: true,
                  onTapLine: () => tapped = true,
                  child: const Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: 90, height: 40),
                        ReplyBubbleBounds(
                          child: SizedBox(width: 110, height: 40),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Bubble width is 110 (ignoring 90px hover bar): arm reaches 600 - 110 - 8 = 482.
      final tipX = ReplyLinePainter.compactHookTipX(
        Offset.zero,
        const Size(600, 40),
        isFromMe: true,
        bubbleWidth: 110,
      );
      expect(tipX, closeTo(482.0, 0.01));

      // Tapping near x=478 (at row center Y) hits the extended compact hook arm (beyond old 28px cap
      // and beyond the 90px hover-bar offset if hover bar had been included in bubbleWidth).
      final box = tester.getRect(find.byType(ReplyLineBox));
      await tester.tapAt(Offset(box.left + 478, box.center.dy));
      await tester.pump();
      expect(tapped, isTrue);

      // Tapping inside the bubble itself (x=540) does NOT hit the connector.
      tapped = false;
      await tester.tapAt(Offset(box.left + 540, box.center.dy));
      await tester.pump();
      expect(tapped, isFalse);
    });

    test('ReplyQuoteHookPainter reaches quotedBubbleEdge +/- 4px and overhangs +4px past height', () {
      const size = Size(400, 44);
      const quotedH = 36.0;

      // Cross-side: left quoted bubble (width 140), right reply stem (400 - 18 = 382).
      final rightToLeft = ReplyQuoteHookPainter.buildHookPath(
        size,
        quotedFromMe: false,
        replyFromMe: true,
        quotedBubbleWidth: 140,
        quotedBubbleHeight: quotedH,
      ).getBounds();
      expect(rightToLeft.left, closeTo(144.0, 0.01));
      expect(rightToLeft.right, closeTo(382.0, 0.01));
      expect(rightToLeft.bottom, closeTo(size.height + 4.0, 0.01));

      // Hit test covers the extended horizontal arm at x=160, y=midY=18.
      expect(
        ReplyQuoteHookPainter.hitTestHook(
          const Offset(160, 18),
          size,
          quotedFromMe: false,
          replyFromMe: true,
          quotedBubbleWidth: 140,
          quotedBubbleHeight: quotedH,
        ),
        isTrue,
      );
      expect(
        ReplyQuoteHookPainter.hitTestHook(
          const Offset(100, 18),
          size,
          quotedFromMe: false,
          replyFromMe: true,
          quotedBubbleWidth: 140,
          quotedBubbleHeight: quotedH,
        ),
        isFalse,
      );
    });
  });

  group('Visual & layout parity fixes', () {
    double contrastRatio(Color fg, Color bg) {
      final l1 = fg.computeLuminance();
      final l2 = bg.computeLuminance();
      final lighter = l1 > l2 ? l1 : l2;
      final darker = l1 > l2 ? l2 : l1;
      return (lighter + 0.05) / (darker + 0.05);
    }

    test('ThemesService tertiary text meets WCAG AA contrast on Light and Dark surfaces', () {
      final themes = <String, ThemeData>{
        'whiteLight': ThemesService.whiteLightTheme,
        'materialYouLight': ThemesService.materialYouTheme(Brightness.light),
        'oledDark': ThemesService.oledDarkTheme,
        'nordDark': ThemesService.nordDarkTheme,
        'materialYouDark': ThemesService.materialYouTheme(Brightness.dark),
      };
      for (final entry in themes.entries) {
        final cs = entry.value.colorScheme;
        expect(
          contrastRatio(cs.tertiary, cs.surface),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} tertiary=${cs.tertiary} on surface=${cs.surface}',
        );
      }
    });

    test('orderFindMyMarkers places active-tab markers above inactive markers and selected highest', () {
      Marker m(String key) => Marker(
            key: ValueKey(key),
            point: const LatLng(37.87, -122.27),
            child: const SizedBox.shrink(),
          );
      final markers = [
        m('device-mac'),
        m('device-airtag'),
        m('current'),
        m('friend-alice'),
      ];
      List<String> keysOf(List<Marker> list) => [
            for (final item in list) (item.key as ValueKey<String>).value,
          ];

      expect(
        keysOf(orderFindMyMarkers(markers, tabIndex: 0, accessoryIds: {'airtag'})),
        ['device-mac', 'device-airtag', 'current', 'friend-alice'],
      );
      expect(
        keysOf(orderFindMyMarkers(markers, tabIndex: 1, accessoryIds: {'airtag'})),
        ['device-airtag', 'friend-alice', 'current', 'device-mac'],
      );
      expect(
        keysOf(orderFindMyMarkers(markers, tabIndex: 2, accessoryIds: {'airtag'})),
        ['device-mac', 'friend-alice', 'current', 'device-airtag'],
      );
      expect(
        keysOf(
          orderFindMyMarkers(
            markers,
            tabIndex: 0,
            selectedKey: 'device-mac',
            accessoryIds: {'airtag'},
          ),
        ),
        ['device-airtag', 'current', 'friend-alice', 'device-mac'],
      );
    });

    test('TabletModeWrapper.computePaneWidths reserves 0 when showInspectorToggle is false', () {
      final flush = TabletModeWrapper.computePaneWidths(
        maxWidth: 1095,
        desiredLeftWidth: 400,
        showInspectorPane: false,
        showInspectorToggle: false,
      );
      expect(flush.inspectorReserved, 0.0);
      expect(flush.leftWidth + flush.rightWidth, 1095.0);
    });

    testWidgets('active SettingsTile styles SettingsLeadingIcon with onPrimary', (tester) async {
      _registerBaseServices();
      NavigationSvc.activeSettingsPage.value = ServerManagementPanel;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: ThemesService.whiteLightTheme,
          home: const Scaffold(
            body: SettingsTile(
              title: 'Connection & Server',
              activePage: ServerManagementPanel,
              leading: SettingsLeadingIcon(
                iosIcon: Icons.cloud,
                materialIcon: Icons.cloud,
                containerColor: Colors.green,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final icon = tester.widget<Icon>(find.byIcon(Icons.cloud));
      expect(icon.color, ThemesService.whiteLightTheme.colorScheme.onPrimary);
    });

    test('FindMyController.ensure() registers permanently so SmartManagement does not dispose it', () async {
      await Get.delete<FindMyController>(force: true);
      final ctrl = FindMyController.ensure();
      addTearDown(() => Get.delete<FindMyController>(force: true));

      expect(ctrl.isBackgroundShared, isTrue);
      expect(await Get.delete<FindMyController>(), isFalse);
      expect(Get.isRegistered<FindMyController>(), isTrue);
    });
  });
}
