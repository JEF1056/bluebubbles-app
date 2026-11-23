import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/audio_player.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_recording_overlay.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_suffix.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/voice_message_recorder.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_desktop_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:record/record.dart';

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

class _FakeAudioRecorder implements AudioRecorder {
  bool paused = false;
  bool stopped = false;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {}

  @override
  Future<String?> stop() async {
    stopped = true;
    final tmp = File('${Directory.systemTemp.path}/bb_voice_test_${DateTime.now().millisecondsSinceEpoch}.m4a');
    tmp.writeAsBytesSync(Uint8List.fromList([1, 2, 3, 4]));
    return tmp.path;
  }

  @override
  Future<void> pause() async {
    paused = true;
  }

  @override
  Future<void> resume() async {
    paused = false;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

void main() {
  late _FakeSettingsService settingsService;

  setUp(() {
    settingsService = _FakeSettingsService()..settings = Settings();
    settingsService.settings.skin.value = Skins.Material;
    settingsService.settings.soundVolume.value = 0;
    _registerServices(settingsService);
  });

  testWidgets('Stopping recording shows inline preview row with Delete/Restart/Send and no Dialog', (tester) async {
    final chat = Chat(guid: 'iMessage;-;+15550004444', chatIdentifier: '+15550004444')
      ..autoSendTypingIndicators = false;
    const tag = 'voice-inline-preview';
    final controller = ConversationViewController(chat, tag_: tag);
    addTearDown(() => Get.delete<ConversationViewController>(tag: tag, force: true));

    final fakeRecorder = _FakeAudioRecorder();
    final textCtrl = TextEditingController();
    addTearDown(textCtrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SizedBox(
            width: 480,
            height: 64,
            child: Row(
              children: [
                Expanded(
                  child: TextFieldRecordingOverlay(
                    controller: controller,
                    audioRecorder: fakeRecorder,
                  ),
                ),
                TextFieldSuffix(
                  subjectTextController: null,
                  textController: textCtrl,
                  controller: controller,
                  recorderController: null,
                  audioRecorder: fakeRecorder,
                  sendMessage: ({String? effect}) async {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Start recording
    await tester.tap(find.byKey(const Key('voice-record-button')));
    await tester.pumpAndSettle();
    expect(controller.showRecording.value, isTrue);
    expect(find.byKey(const Key('voice-record-pause-button')), findsOneWidget);

    // Pause & resume recording
    await tester.tap(find.byKey(const Key('voice-record-pause-button')));
    await tester.pump();
    expect(fakeRecorder.paused, isTrue);
    await tester.tap(find.byKey(const Key('voice-record-pause-button')));
    await tester.pump();
    expect(fakeRecorder.paused, isFalse);

    // Stop recording -> should enter inline preview without opening any Dialog
    await tester.tap(find.byKey(const Key('voice-record-button')));
    for (int i = 0; i < 10 && voicePreviewFor(controller).value == null; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(fakeRecorder.stopped, isTrue);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.showRecording.value, isTrue);
    expect(voicePreviewFor(controller).value, isNotNull);

    expect(find.byKey(const Key('voice-record-button')), findsNothing);
    expect(find.byKey(const Key('voice-preview-delete-button')), findsOneWidget);
    expect(find.byKey(const Key('voice-preview-restart-button')), findsOneWidget);
    expect(find.byKey(const Key('voice-preview-send-button')), findsOneWidget);
    expect(find.byType(AudioPlayer), findsOneWidget);

    // Esc discards preview
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(voicePreviewFor(controller).value, isNull);
    expect(controller.showRecording.value, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('AudioSpeedChip cycles 1x -> 1.5x -> 2x -> 1x', (tester) async {
    double rate = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return AudioSpeedChip(
                rate: rate,
                onTap: () => setState(() => rate = nextAudioPlaybackSpeed(rate)),
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('1x'), findsOneWidget);
    await tester.tap(find.byKey(const Key('audio-speed-chip')));
    await tester.pump();
    expect(find.text('1.5x'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio-speed-chip')));
    await tester.pump();
    expect(find.text('2x'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio-speed-chip')));
    await tester.pump();
    expect(find.text('1x'), findsOneWidget);
  });
}
