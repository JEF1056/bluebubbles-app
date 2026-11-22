import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/app/components/facetime/ongoing_call_pill.dart';
import 'package:bluebubbles/app/components/facetime/outgoing_facetime_sheet.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/timeframe_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/genmoji_dialog.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_library_dialog.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/text_field_attachment_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_icon_bar.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:bluebubbles/app/layouts/setup/dialogs/failed_to_connect_dialog.dart';
import 'package:bluebubbles/app/layouts/setup/dialogs/manual_entry_dialog.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/models/genmoji.dart';
import 'package:bluebubbles/models/library_sticker.dart';
import 'package:bluebubbles/models/models.dart' show ServerDetails;
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_admin_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/network/api/facetime_api.dart';
import 'package:bluebubbles/services/network/api/genmoji_api.dart';
import 'package:bluebubbles/services/network/api/sticker_api.dart';
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart' as dio;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:integration_test/integration_test.dart';

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
    macOSMinorVersion: 4,
    serverVersion: '2.0.0',
    serverVersionCode: 200,
    privateApiEnabled: true,
    apiVersions: [1, 2],
    supportsStickersFlag: true,
  );

  @override
  ServerDetails getServerDetails() => fakeDetails;

  @override
  ServerDetails get serverDetails => fakeDetails;
}

class _FakeSocketService extends SocketService {}

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

class _FakeAdminPrefs extends SharedPreferencesAdminActions {
  _FakeAdminPrefs(super.service);
  final Map<String, Object?> _store = {};
  @override
  Object? get(String key) => _store[key];
  @override
  Future<void> setString(String key, String value) async => _store[key] = value;
  @override
  Future<void> setBool(String key, bool value) async => _store[key] = value;
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    admin = _FakeAdminPrefs(this);
    desktop = _FakeDesktopPrefs(this);
    theme = _FakeThemePrefs(this);
  }
}

class _FakeOutgoingMessageHandler extends OutgoingMessageHandler {
  @override
  Future<void> queue(OutgoingQueueItem item) async {}
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

class _FakeFilesystemService extends FilesystemService {
  _FakeFilesystemService(this._dir);
  final Directory _dir;

  @override
  Directory get appDocDir => _dir;
}

class _FakeStickerApi extends StickerApi {
  _FakeStickerApi() : super(HttpService());

  final List<LibrarySticker> serverStickers = const [
    LibrarySticker(identifier: 'stk-1', shelf: 'recent', name: 'Rocket', mimeType: 'image/png', longestSide: 128),
    LibrarySticker(identifier: 'stk-2', shelf: 'recent', name: 'Sparkle', mimeType: 'image/png', longestSide: 128),
    LibrarySticker(identifier: 'stk-3', shelf: 'saved', name: 'Wave', mimeType: 'image/png', longestSide: 128),
    LibrarySticker(identifier: 'stk-4', shelf: 'saved', name: 'Coffee', mimeType: 'image/png', longestSide: 128),
    LibrarySticker(identifier: 'stk-5', shelf: 'saved', name: 'Heart', mimeType: 'image/png', longestSide: 128),
  ];

  @override
  Future<({List<LibrarySticker> stickers, String? reason})> library({dio.CancelToken? cancelToken}) async =>
      (stickers: List<LibrarySticker>.from(serverStickers), reason: null);

  @override
  Future<Uint8List> image(String identifier, {bool thumbnail = false, dio.CancelToken? cancelToken}) async =>
      _samplePng;
}

class _FakeGenmojiApi extends GenmojiApi {
  _FakeGenmojiApi() : super(HttpService());

  @override
  Future<GenmojiSupport> status({dio.CancelToken? cancelToken}) async =>
      const GenmojiSupport(available: true, reason: 'available', maximumDescriptionLength: 100);
}

class _FakeFaceTimeApi extends FaceTimeApi {
  _FakeFaceTimeApi() : super(HttpService());

  @override
  Future<dio.Response> dtmf(String callUuid, String digit, {dio.CancelToken? cancelToken}) async =>
      dio.Response(requestOptions: dio.RequestOptions(path: '/facetime/dtmf'), statusCode: 200);
}

class _FakeHttpService extends HttpService {
  _FakeHttpService(this.fakeSticker, this.fakeGenmoji, this.fakeFaceTime);
  final _FakeStickerApi fakeSticker;
  final _FakeGenmojiApi fakeGenmoji;
  final _FakeFaceTimeApi fakeFaceTime;

  @override
  StickerApi get sticker => fakeSticker;

  @override
  GenmojiApi get genmoji => fakeGenmoji;

  @override
  FaceTimeApi get faceTime => fakeFaceTime;
}

void _resetSingleton<T extends Object>(T instance) {
  if (GetIt.I.isRegistered<T>()) {
    GetIt.I.unregister<T>();
  }
  GetIt.I.registerSingleton<T>(instance);
}

final Uint8List _samplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Directory? _vqaTempDir;

void _registerServices(Skins skin) {
  Get.testMode = true;
  _vqaTempDir ??= Directory.systemTemp.createTempSync('bb_vqa_');
  _resetSingleton<BaseLogger>(_SilentLogger());

  final svc = _FakeSettingsService()..settings = Settings();
  svc.settings.skin.value = skin;
  svc.settings.enablePrivateAPI.value = true;
  svc.settings.privateSendTypingIndicators.value = false;
  _resetSingleton<SettingsService>(svc);

  _resetSingleton<SocketService>(_FakeSocketService());
  _resetSingleton<SharedPreferencesService>(_FakePrefsService());
  _resetSingleton<NavigatorService>(NavigatorService());
  _resetSingleton<ChatsService>(_FakeChatsService());
  _resetSingleton<HandleService>(HandleService());
  _resetSingleton<ThemesService>(ThemesService());
  _resetSingleton<FilesystemService>(_FakeFilesystemService(_vqaTempDir!));
  _resetSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
  _resetSingleton<SyncService>(SyncService());
  _resetSingleton<LifecycleService>(LifecycleService());
  _resetSingleton<OutgoingMessageHandler>(_FakeOutgoingMessageHandler());
  _resetSingleton<HttpService>(_FakeHttpService(_FakeStickerApi(), _FakeGenmojiApi(), _FakeFaceTimeApi()));
  _resetSingleton<StickerLibraryService>(StickerLibraryService()..useMemoryCache = true);
}

Widget _appShell({
  required Brightness brightness,
  required WidgetBuilder bodyBuilder,
  Widget? overlay,
}) {
  final isDark = brightness == Brightness.dark;
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF0A84FF),
      brightness: brightness,
    ),
    extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
  );
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Stack(
      children: [
        Scaffold(
          appBar: AppBar(title: const Text('Messages')),
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? const [Color(0xFF0F172A), Color(0xFF1E293B), Color(0xFF0B3B5A)]
                    : const [Color(0xFFE0F2FE), Color(0xFFF8FAFC), Color(0xFFDBEAFE)],
              ),
            ),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _MockBubble('Alex Lin', 'Just landed! Meet at Gate B12?', true, isDark),
                _MockBubble('Maya Jordan', 'Can you review the PR before 5pm?', false, isDark),
                _MockBubble('Samira Patel', 'Dinner at 7:30 sounds great', true, isDark),
                const SizedBox(height: 24),
                Builder(builder: bodyBuilder),
              ],
            ),
          ),
        ),
        if (overlay != null) overlay,
      ],
    ),
  );
}

class _MockBubble extends StatelessWidget {
  const _MockBubble(this.name, this.text, this.isMe, this.isDark);
  final String name;
  final String text;
  final bool isMe;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe
              ? const Color(0xFF0A84FF)
              : (isDark ? const Color(0xFF2C2C2E) : Colors.white),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isMe ? Colors.white70 : (isDark ? Colors.white60 : Colors.black54),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              text,
              style: TextStyle(
                fontSize: 15,
                color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black87),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var converted = false;
  setUp(() => converted = false);

  Future<void> snap(WidgetTester tester, String name, {bool settle = true}) async {
    if (settle) {
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
    } else {
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (!converted) {
      await binding.convertFlutterSurfaceToImage();
      converted = true;
    }
    await tester.pump(const Duration(milliseconds: 200));
    await binding.takeScreenshot(name);
  }

  Future<void> closeModal(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final nav = Navigator.of(tester.element(find.byType(Scaffold)), rootNavigator: true);
    if (nav.canPop()) {
      nav.pop();
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
    }
  }

  testWidgets('Visual QA: Material Dark & Light Modals', (tester) async {
    _registerServices(Skins.Material);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      final tag = brightness == Brightness.dark ? 'm3_dark' : 'm3_light';
      late BuildContext ctx;
      await tester.pumpWidget(_appShell(
        brightness: brightness,
        bodyBuilder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        },
      ));
      await tester.pumpAndSettle();

      // 1. showBBDialog
      unawaited(showBBDialog<void>(
        context: ctx,
        icon: Icons.mark_chat_read_outlined,
        title: 'Mark All as Read?',
        body: 'This will clear unread badges across 14 conversations.',
        actions: [
          BBDialogAction(text: 'Cancel', onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
          BBDialogAction(text: 'Mark Read', isDefault: true, onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
        ],
      ));
      await snap(tester, '${tag}_dialog');
      await closeModal(tester);

      // 2. showAreYouSure destructive
      unawaited(showAreYouSure(
        ctx,
        title: 'Delete Conversation?',
        content: const Text('All messages and attachments in this thread will be permanently removed.'),
        yesText: 'Delete',
        noText: 'Cancel',
        yesIsDestructive: true,
        onNo: () => Navigator.of(ctx, rootNavigator: true).pop(),
        onYes: () => Navigator.of(ctx, rootNavigator: true).pop(),
      ));
      await snap(tester, '${tag}_are_you_sure');
      await closeModal(tester);

      // 3. showBBInputDialog with validation error
      unawaited(showBBInputDialog(
        context: ctx,
        title: 'Rename Group Chat',
        body: 'Choose a name visible to all participants.',
        hintText: 'Weekend Trip',
        labelText: 'Group Name',
        validator: (v) => (v == null || v.trim().length < 3) ? 'Enter at least 3 characters.' : null,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await snap(tester, '${tag}_input_error');
      await closeModal(tester);

      // 4. showBBBottomSheet
      unawaited(showBBBottomSheet<void>(
        context: ctx,
        title: 'Chat Actions',
        subtitle: 'Alex Lin • iMessage',
        builder: (_) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('Mute Alerts'),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: const Text('Pin Conversation'),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('Delete Thread', style: TextStyle(color: Colors.redAccent)),
              onTap: () {},
            ),
          ],
        ),
      ));
      await snap(tester, '${tag}_bottom_sheet');
      await closeModal(tester);
    }

    // Material-only extras: showBBListSelector + BBProgressDialog
    late BuildContext ctx;
    await tester.pumpWidget(_appShell(
      brightness: Brightness.dark,
      bodyBuilder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      },
    ));
    await tester.pumpAndSettle();

    unawaited(showBBListSelector<String>(
      context: ctx,
      title: 'Send As',
      message: 'Choose which service to use for this message.',
      options: const [
        BBListSelectorOption(label: 'iMessage', value: 'imessage', icon: Icons.chat_bubble_outline),
        BBListSelectorOption(label: 'SMS / Text', value: 'sms', icon: Icons.sms_outlined),
        BBListSelectorOption(label: 'Cancel Draft', value: 'cancel', icon: Icons.delete_outline, isDestructive: true),
      ],
    ));
    await snap(tester, 'm3_dark_list_selector');
    await closeModal(tester);

    unawaited(showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => BBProgressDialog(
        title: 'Syncing Attachments…',
        progress: 0.65,
        actions: [
          BBDialogAction(text: 'Hide', onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
        ],
      ),
    ));
    await snap(tester, 'm3_dark_progress_dialog');
    await closeModal(tester);
  });

  testWidgets('Visual QA: iOS Frosted Glass Modals', (tester) async {
    _registerServices(Skins.iOS);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      final tag = brightness == Brightness.dark ? 'ios_dark' : 'ios_light';
      late BuildContext ctx;
      await tester.pumpWidget(_appShell(
        brightness: brightness,
        bodyBuilder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        },
      ));
      await tester.pumpAndSettle();

      unawaited(showBBDialog<void>(
        context: ctx,
        title: 'Mark All as Read?',
        body: 'This will clear unread badges across 14 conversations.',
        actions: [
          BBDialogAction(text: 'Cancel', onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
          BBDialogAction(text: 'Mark Read', isDefault: true, onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
        ],
      ));
      await snap(tester, '${tag}_dialog');
      await closeModal(tester);

      if (brightness == Brightness.dark) {
        unawaited(showAreYouSure(
          ctx,
          title: 'Delete Conversation?',
          content: const Text('All messages and attachments in this thread will be permanently removed.'),
          yesText: 'Delete',
          noText: 'Cancel',
          yesIsDestructive: true,
          onNo: () => Navigator.of(ctx, rootNavigator: true).pop(),
          onYes: () => Navigator.of(ctx, rootNavigator: true).pop(),
        ));
        await snap(tester, '${tag}_are_you_sure');
        await closeModal(tester);

        unawaited(showBBInputDialog(
          context: ctx,
          title: 'Rename Group Chat',
          body: 'Choose a name visible to all participants.',
          hintText: 'Weekend Trip',
          validator: (v) => (v == null || v.trim().length < 3) ? 'Enter at least 3 characters.' : null,
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await snap(tester, '${tag}_input_error');
        await closeModal(tester);

        unawaited(showBBBottomSheet<void>(
          context: ctx,
          title: 'Chat Actions',
          subtitle: 'Alex Lin • iMessage',
          builder: (_) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('Mute Alerts'),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('Pin Conversation'),
                onTap: () {},
              ),
            ],
          ),
        ));
        await snap(tester, '${tag}_bottom_sheet');
        await closeModal(tester);
      }
    }
  });

  testWidgets('Visual QA: Wave 2 Migrated Setup Modals', (tester) async {
    _registerServices(Skins.Material);
    late BuildContext ctx;
    await tester.pumpWidget(_appShell(
      brightness: Brightness.dark,
      bodyBuilder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      },
    ));
    await tester.pumpAndSettle();

    unawaited(FailedToConnectDialog.show(ctx, onDismiss: () => Navigator.of(ctx, rootNavigator: true).pop()));
    await snap(tester, 'wave2_failed_to_connect');
    await closeModal(tester);

    unawaited(showDialog<void>(
      context: ctx,
      builder: (_) => ManualEntryDialog(
        onConnect: () {},
        onClose: () => Navigator.of(ctx, rootNavigator: true).pop(),
      ),
    ));
    await snap(tester, 'wave2_manual_entry');
    await closeModal(tester);
  });

  testWidgets('Visual QA: FaceTime & Ongoing Call UI', (tester) async {
    _registerServices(Skins.Material);

    // 1. Incoming Video
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: IncomingFaceTimeScreen(
          callUuid: 'ft-vid-1',
          callerName: 'Alex Lin',
          avatarBytes: _samplePng,
          isAudio: false,
          onAnswerVideo: () {},
          onAnswerAudio: () {},
          onDecline: () {},
        ),
      ),
    ));
    await snap(tester, 'ft_incoming_video');

    // 2. Incoming Audio
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: IncomingFaceTimeScreen(
          callUuid: 'ft-aud-1',
          callerName: 'Maya Jordan',
          isAudio: true,
          onAnswerAudio: () {},
          onDecline: () {},
        ),
      ),
    ));
    await snap(tester, 'ft_incoming_audio');

    // 3. Connecting state (tap Answer Audio)
    await tester.tap(find.bySemanticsLabel('Answer Audio'));
    await snap(tester, 'ft_connecting', settle: false);

    // 4. Outgoing FaceTime Sheet - mode chooser
    late BuildContext ctx;
    await tester.pumpWidget(_appShell(
      brightness: Brightness.dark,
      bodyBuilder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      },
    ));
    await tester.pumpAndSettle();

    unawaited(showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OutgoingFaceTimeSheet(
        callerName: 'Alex Lin',
        callerAddress: '+1 (415) 555-0192',
        isAndroid: true,
        checkTelecomEnabled: () async => true,
        onOpenCallingAccounts: () async {},
        requestCallPermissions: () async => true,
        onPlaceNativeAudioCall: () async => true,
        onStartServerCall: (bool isAudio) async => const PlacedFaceTimeCall(
          call: FaceTimeCall(callUuid: 'out-1', isVideo: true),
          link: 'https://facetime.apple.com/join#mock',
        ),
        onOpenJoinLink: (_) async {},
        onHangUpRingingCall: (_) async {},
      ),
    ));
    await snap(tester, 'ft_outgoing_sheet_choose');
    await closeModal(tester);

    // 5. Outgoing FaceTime Sheet - Telecom banner
    unawaited(showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OutgoingFaceTimeSheet(
        callerName: 'Alex Lin',
        callerAddress: '+1 (415) 555-0192',
        isAndroid: true,
        initialVideo: false,
        checkTelecomEnabled: () async => false,
        onOpenCallingAccounts: () async {},
        requestCallPermissions: () async => true,
        onPlaceNativeAudioCall: () async => true,
        onStartServerCall: (bool isAudio) async => const PlacedFaceTimeCall(
          call: FaceTimeCall(callUuid: 'out-1', isVideo: true),
          link: 'https://facetime.apple.com/join#mock',
        ),
        onOpenJoinLink: (_) async {},
        onHangUpRingingCall: (_) async {},
      ),
    ));
    await snap(tester, 'ft_outgoing_sheet_telecom');
    await closeModal(tester);

    // 6. Ongoing Call Pill (expanded + collapsed) over app background
    final callCtrl = ActiveCallController(
      onReturnToCall: (_, __) async {},
      onEndCall: (_, __) async {},
    )..startOngoing(
        callUuid: 'ongoing-1',
        callerName: 'Alex Lin',
        isVideo: true,
        joinLink: 'https://facetime.apple.com/join#mock',
      );
    await tester.pumpWidget(_appShell(
      brightness: Brightness.dark,
      bodyBuilder: (_) => const SizedBox.shrink(),
      overlay: OngoingCallPillOverlay(controller: callCtrl),
    ));
    await snap(tester, 'ft_ongoing_pill_expanded');

    // Collapse the pill by tapping the chevron/collapse button if present
    final collapseBtn = find.byIcon(Icons.keyboard_arrow_up_rounded);
    if (collapseBtn.evaluate().isNotEmpty) {
      await tester.tap(collapseBtn.first);
      await snap(tester, 'ft_ongoing_pill_collapsed');
    }

    // 7. Outgoing FaceTime Sheet - Ringing state
    await tester.pumpWidget(_appShell(
      brightness: Brightness.dark,
      bodyBuilder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      },
    ));
    await tester.pumpAndSettle();

    final ringingCtrl = ActiveCallController(
      onReturnToCall: (_, _) async {},
      onEndCall: (_, _) async {},
    );
    unawaited(showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OutgoingFaceTimeSheet(
        callerName: 'Alex Lin',
        callerAddress: '+1 (415) 555-0192',
        isAndroid: false,
        initialVideo: true,
        callController: ringingCtrl,
        checkTelecomEnabled: () async => true,
        onOpenCallingAccounts: () async {},
        requestCallPermissions: () async => true,
        onPlaceNativeAudioCall: () async => true,
        onStartServerCall: (bool isAudio) async => const PlacedFaceTimeCall(
          call: FaceTimeCall(callUuid: 'out-ring-1', isVideo: true),
          link: 'https://facetime.apple.com/join#mock',
        ),
        onTryOpenJoinLink: (_) async => false,
        onOpenJoinLink: (_) async {},
        onHangUpRingingCall: (_) async {},
      ),
    ));
    await snap(tester, 'ft_outgoing_sheet_ringing');
    await closeModal(tester);

    // 8. InAppCallScreen - Audio
    final inAppAudioCtrl = ActiveCallController(
      onReturnToCall: (_, _) async {},
      onEndCall: (_, _) async {},
    )..startOngoing(
        callUuid: 'inapp-aud-1',
        callerName: 'Maya Jordan',
        isVideo: false,
      );
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: InAppCallScreen(
        controller: inAppAudioCtrl,
        onMinimize: () {},
        onToggleSpeaker: (v) async => v,
      ),
    ));
    await snap(tester, 'ft_inapp_audio', settle: false);

    // 9. InAppCallScreen - Video
    final inAppVideoCtrl = ActiveCallController(
      onReturnToCall: (_, _) async {},
      onEndCall: (_, _) async {},
      onSendDtmf: (_, _) async {},
    )..startOngoing(
        callUuid: 'inapp-vid-1',
        callerName: 'Alex Lin',
        avatarBytes: _samplePng,
        isVideo: true,
      );
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: InAppCallScreen(
        controller: inAppVideoCtrl,
        videoView: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0E2A38), Color(0xFF131314)],
            ),
          ),
          child: const Center(
            child: Icon(Icons.videocam_rounded, size: 72, color: Colors.white24),
          ),
        ),
        onMinimize: () {},
        onToggleSpeaker: (v) async => v,
      ),
    ));
    await snap(tester, 'ft_inapp_video', settle: false);

    // 10. InAppCallScreen - DTMF Keypad
    await tester.tap(find.bySemanticsLabel('Keypad'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('5'));
    await snap(tester, 'ft_inapp_dtmf', settle: false);
  });

  testWidgets('Visual QA: Stickers, Add-Media & Voice Recording (Dark & Light)', (tester) async {
    _registerServices(Skins.Material);
    final chat = Chat(guid: 'iMessage;-;+15550004444', chatIdentifier: '+15550004444')
      ..autoSendTypingIndicators = false;

    for (final brightness in [Brightness.dark, Brightness.light]) {
      final tag = brightness == Brightness.dark ? 'dark' : 'light';
      final ctrlTag = 'vqa-chat-$tag';
      final chatCtrl = ConversationViewController(chat, tag_: ctrlTag);
      late BuildContext ctx;

      await tester.pumpWidget(_appShell(
        brightness: brightness,
        bodyBuilder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        },
      ));
      await tester.pumpAndSettle();

      // 1. Stickers Picker
      await GetIt.I<StickerLibraryService>().sync();
      unawaited(showDialog<void>(
        context: ctx,
        builder: (dialogCtx) => Dialog(
          backgroundColor: Theme.of(dialogCtx).colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding: const EdgeInsets.all(16),
          child: SizedBox(
            width: 360,
            height: 440,
            child: StickerLibraryView(
              controller: chatCtrl,
              draggable: false,
            ),
          ),
        ),
      ));
      await snap(tester, 'stickers_picker_$tag');
      await closeModal(tester);

      // 2. Add-media: Web attachment menu
      unawaited(showWebAttachmentMenu(ctx, chatCtrl));
      await snap(tester, 'media_web_attach_$tag');
      await closeModal(tester);

      // 3. Add-media: Timeframe picker
      unawaited(showTimeframePicker('Schedule', ctx, presetsAhead: true));
      await snap(tester, 'media_timeframe_$tag');
      await closeModal(tester);

      // 4. Add-media: Genmoji dialog
      unawaited(showGenmojiDialog(ctx, isIMessage: true));
      await snap(tester, 'media_genmoji_$tag');
      await closeModal(tester);

      // 5. Add-media: Material AttachmentPicker bottom sheet (collapsed + expanded)
      unawaited(showModalBottomSheet<void>(
        context: ctx,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => AttachmentPicker(controller: chatCtrl),
      ));
      await snap(tester, 'media_attachment_picker_$tag');
      final expandDrawerBtn = find.byIcon(Icons.keyboard_arrow_up_rounded);
      if (expandDrawerBtn.evaluate().isNotEmpty) {
        await tester.tap(expandDrawerBtn.first);
        await snap(tester, 'media_attachment_picker_expanded_$tag');
      }
      await closeModal(tester);

      // 6. Voice Recording Overlay
      chatCtrl.showRecording.value = true;
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0A84FF),
              brightness: brightness,
            ),
            extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
          ),
          home: ChatStateScope(
            chatState: ChatState(chat),
            child: Scaffold(
              appBar: AppBar(title: const Text('Alex Lin')),
              body: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _MockBubble('Alex Lin', 'Voice note incoming!', false, brightness == Brightness.dark),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ConversationTextField(parentController: chatCtrl),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await snap(tester, 'voice_recording_$tag', settle: false);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      if (Get.isRegistered<ConversationViewController>(tag: ctrlTag)) {
        Get.delete<ConversationViewController>(tag: ctrlTag, force: true);
      }
    }
  });

  testWidgets('Visual QA: Find My (Dark & Light)', (tester) async {
    _registerServices(Skins.Material);
    final findMyCtrl = Get.put(FindMyController(autoFetch: false));
    final friends = [
      FindMyFriend(
        latitude: 37.3349,
        longitude: -122.009,
        longAddress: null,
        shortAddress: 'Cupertino, CA',
        title: 'Alice Chen',
        subtitle: null,
        handle: null,
        handleAddress: 'alice@example.com',
        status: LocationStatus.live,
        locatingInProgress: false,
        lastUpdated: DateTime.now(),
        horizontalAccuracy: 15,
      ),
      FindMyFriend(
        latitude: 37.7749,
        longitude: -122.4194,
        longAddress: null,
        shortAddress: 'San Francisco, CA',
        title: 'Bob Martinez',
        subtitle: null,
        handle: null,
        handleAddress: 'bob@example.com',
        status: LocationStatus.shallow,
        locatingInProgress: false,
        lastUpdated: DateTime.now().subtract(const Duration(minutes: 4)),
        horizontalAccuracy: 40,
      ),
    ];
    findMyCtrl.friends.addAll(friends);
    findMyCtrl.friendsWithLocation.addAll(friends);
    findMyCtrl.fetching2.value = false;

    for (final brightness in [Brightness.dark, Brightness.light]) {
      final tag = brightness == Brightness.dark ? 'dark' : 'light';
      await tester.pumpWidget(
        GetMaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0A84FF),
              brightness: brightness,
            ),
          ),
          home: const FindMyPage(),
        ),
      );
      await snap(tester, 'findmy_$tag', settle: false);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    Get.delete<FindMyController>(force: true);
  });
}
