import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_recording_overlay.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/voice_message_recorder.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _FakeSettingsService extends SettingsService {
  @override
  ServerDetails get serverDetails => const ServerDetails(
        macOSVersion: 14,
        macOSMinorVersion: 0,
        serverVersion: '1.9.0',
        serverVersionCode: 10900,
      );
}

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

void _registerServices(_FakeSettingsService settingsService) {
  Get.testMode = true;
  if (GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.unregister<SettingsService>();
  }
  GetIt.I.registerSingleton<SettingsService>(settingsService);
  if (!GetIt.I.isRegistered<SharedPreferencesService>()) {
    GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  }
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.unregister<ChatsService>();
  }
  GetIt.I.registerSingleton<ChatsService>(_FakeChatsService());
  if (!GetIt.I.isRegistered<HandleService>()) {
    GetIt.I.registerSingleton<HandleService>(HandleService());
  }
  if (!GetIt.I.isRegistered<ThemesService>()) {
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
  if (!GetIt.I.isRegistered<bb_events.EventDispatcher>()) {
    GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
  }
  if (!GetIt.I.isRegistered<SyncService>()) {
    GetIt.I.registerSingleton<SyncService>(SyncService());
  }
  if (!GetIt.I.isRegistered<LifecycleService>()) {
    GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  }
  if (!GetIt.I.isRegistered<SocketService>()) {
    GetIt.I.registerSingleton<SocketService>(SocketService());
  }
  if (!GetIt.I.isRegistered<OutgoingMessageHandler>()) {
    GetIt.I.registerSingleton<OutgoingMessageHandler>(_FakeOutgoingMessageHandler());
  }
}

ThemeData _testTheme() => ThemeData(
      useMaterial3: true,
      extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
    );

Widget _buildComposerApp({
  required Size viewportSize,
  required Chat chat,
  required ConversationViewController controller,
}) {
  return MediaQuery(
    data: MediaQueryData(size: viewportSize),
    child: MaterialApp(
      theme: _testTheme(),
      home: ChatStateScope(
        chatState: ChatState(chat),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ConversationTextField(parentController: controller),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late _FakeSettingsService settingsService;

  setUp(() {
    settingsService = _FakeSettingsService()..settings = Settings();
    settingsService.settings.enablePrivateAPI.value = true;
    settingsService.settings.privateSendTypingIndicators.value = false;
    _registerServices(settingsService);
  });

  group('Single mic trigger across skins and viewports', () {
    for (final skin in [Skins.iOS, Skins.Material, Skins.Samsung]) {
      for (final viewport in const [Size(360, 800), Size(1024, 600)]) {
        testWidgets(
          '${skin.name} at ${viewport.width.toInt()}x${viewport.height.toInt()} renders exactly one mic button',
          (tester) async {
            settingsService.settings.skin.value = skin;
            tester.view.physicalSize = viewport;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);

            final chat = Chat(guid: 'iMessage;-;+15550001111', chatIdentifier: '+15550001111')
              ..autoSendTypingIndicators = false;
            final tag = 'mic-${skin.name}-${viewport.width.toInt()}';
            final controller = ConversationViewController(chat, tag_: tag);
            addTearDown(() => Get.delete<ConversationViewController>(tag: tag, force: true));

            await tester.pumpWidget(_buildComposerApp(
              viewportSize: viewport,
              chat: chat,
              controller: controller,
            ));
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull);
            expect(find.byKey(const Key('voice-record-button')), findsOneWidget);
            expect(find.byKey(const Key('native-stt-mic-button')), findsNothing);

            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 4));
          },
        );
      }
    }
  });

  group('Active recording overlay layout', () {
    for (final width in const [320.0, 360.0, 1024.0]) {
      testWidgets(
        'iOS active recording at ${width.toInt()}px has no overflow, non-overlapping cancel/stop, and opaque surface',
        (tester) async {
          settingsService.settings.skin.value = Skins.iOS;
          final viewport = Size(width, 800);
          tester.view.physicalSize = viewport;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final chat = Chat(guid: 'iMessage;-;+15550002222', chatIdentifier: '+15550002222')
            ..autoSendTypingIndicators = false;
          final tag = 'rec-ios-${width.toInt()}';
          final controller = ConversationViewController(chat, tag_: tag);
          addTearDown(() => Get.delete<ConversationViewController>(tag: tag, force: true));

          await tester.pumpWidget(_buildComposerApp(
            viewportSize: viewport,
            chat: chat,
            controller: controller,
          ));
          await tester.pumpAndSettle();

          controller.showRecording.value = true;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          expect(tester.takeException(), isNull);

          final cancelFinder = find.byKey(const Key('voice-record-cancel-button'));
          final stopFinder = find.byKey(const Key('voice-record-button'));
          expect(cancelFinder, findsOneWidget);
          expect(stopFinder, findsOneWidget);

          final cancelRect = tester.getRect(cancelFinder);
          final stopRect = tester.getRect(stopFinder);
          expect(cancelRect.right, lessThanOrEqualTo(stopRect.left));

          final theme = _testTheme();
          final opaqueOverlay = find.descendant(
            of: find.byType(TextFieldRecordingOverlay),
            matching: find.byWidgetPredicate((w) {
              if (w is! Container) return false;
              final dec = w.decoration;
              if (dec is! BoxDecoration) return false;
              return dec.color == theme.colorScheme.surface &&
                  dec.borderRadius == const BorderRadius.horizontal(left: Radius.circular(19)) &&
                  w.clipBehavior == Clip.antiAlias;
            }),
          );
          expect(opaqueOverlay, findsOneWidget);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 4));
        },
      );
    }
  });

  group('Narrow recording bar widths', () {
    for (final width in const [60.0, 80.0, 110.0, 220.0]) {
      testWidgets(
        'TextFieldRecordingOverlay (_DesktopRecordingBar) at ${width.toInt()}px has zero overflow',
        (tester) async {
          settingsService.settings.skin.value = Skins.Material;

          final chat = Chat(guid: 'iMessage;-;+15550003333', chatIdentifier: '+15550003333')
            ..autoSendTypingIndicators = false;
          final tag = 'narrow-overlay-${width.toInt()}';
          final controller = ConversationViewController(chat, tag_: tag);
          controller.showRecording.value = true;
          addTearDown(() => Get.delete<ConversationViewController>(tag: tag, force: true));

          await tester.pumpWidget(
            MaterialApp(
              theme: _testTheme(),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: width,
                    height: 48,
                    child: TextFieldRecordingOverlay(controller: controller),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 200));

          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('voice-record-cancel-button')), findsOneWidget);
          expect(find.text('Recording'), width >= 188 ? findsOneWidget : findsNothing);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 4));
        },
      );
    }

    for (final width in const [60.0, 220.0]) {
      testWidgets(
        'VoiceMessageRecorder at ${width.toInt()}px has zero overflow',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: _testTheme(),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: width,
                    height: 48,
                    child: VoiceMessageRecorder(
                      recorderController: null,
                      textFieldSize: Size(width, 48),
                      iOS: false,
                      samsung: false,
                      onCancel: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));

          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('voice-record-cancel-button')), findsOneWidget);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
        },
      );
    }
  });
}
