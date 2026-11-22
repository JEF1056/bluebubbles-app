import 'package:bluebubbles/app/layouts/conversation_view/widgets/effects/screen_effects_widget.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/bubble_effects.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/typing/typing_indicator.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart' hide EventDispatcher;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:particles_flutter/engine.dart';

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

class _FakePrefsMessagingActions extends SharedPreferencesMessagingActions {
  _FakePrefsMessagingActions(super.service);

  @override
  List<String> getRecentTapbackEmojis({required String chatGuid}) => const [];
}

void _registerServices() {
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<bb_events.EventDispatcher>()) {
    GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    final settings = SettingsService()..settings = Settings();
    GetIt.I.registerSingleton<SettingsService>(settings);
  }
  if (!GetIt.I.isRegistered<SharedPreferencesService>()) {
    final prefs = SharedPreferencesService();
    prefs.theme = _FakePrefsThemeActions(prefs);
    prefs.messaging = _FakePrefsMessagingActions(prefs);
    GetIt.I.registerSingleton<SharedPreferencesService>(prefs);
  }
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
  }
  if (!GetIt.I.isRegistered<SocketService>()) {
    GetIt.I.registerSingleton<SocketService>(SocketService());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    Get.testMode = true;
    _registerServices();
  });

  group('Wave 1 battery fixes', () {
    testWidgets('FindMyController staleness timer runs at 60s and stops in background', (tester) async {
      final controller = FindMyController(autoFetch: false)..isBackgroundShared = true;
      controller.onInit();
      addTearDown(controller.onClose);

      expect(controller.freshnessTick.value, 0);
      await tester.pump(const Duration(seconds: 59));
      expect(controller.freshnessTick.value, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.freshnessTick.value, 1);

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 120));
      expect(controller.freshnessTick.value, 1);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 60));
      expect(controller.freshnessTick.value, 2);
    });

    testWidgets('ConversationViewController typing indicator auto-clears after 60s and on clearAllTypingIndicators',
        (tester) async {
      final chat = Chat(guid: 'iMessage;-;+15550009999', chatIdentifier: '+15550009999');
      final controller = ConversationViewController(chat);
      controller.onInit();
      addTearDown(controller.onClose);

      controller.setTypingIndicator(true);
      expect(controller.showTypingIndicator.value, isTrue);

      await tester.pump(const Duration(seconds: 59));
      expect(controller.showTypingIndicator.value, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.showTypingIndicator.value, isFalse);

      controller.setTypingIndicator(true);
      expect(controller.showTypingIndicator.value, isTrue);
      ConversationViewController.clearAllTypingIndicators();
      expect(controller.showTypingIndicator.value, isFalse);
    });

    testWidgets('ScreenEffectsWidget disposes controllers and cancels subscription cleanly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 400,
              child: ScreenEffectsWidget(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);

      // Disposing before post-frame callback runs must also succeed without LateInitializationError.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ScreenEffectsWidget(),
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'BubbleEffects invisibleInk skips replay when hasEffectPlayed is true and gates Particles on disableAnimations',
        (tester) async {
      final invisibleInkKey = effectMap['invisible ink']!;
      final playedMsg = Message(
        guid: 'msg-played',
        text: 'Secret',
        dateCreated: DateTime(2026, 11, 20),
        isFromMe: false,
        handleId: 1,
        expressiveSendStyleId: invisibleInkKey,
      );
      final playedState = MessageState(playedMsg)..hasEffectPlayed.value = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BubbleEffects(
              part: 0,
              messageState: playedState,
              globalKey: GlobalKey(),
              showTail: true,
              child: const SizedBox(width: 120, height: 40, child: Text('Secret')),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Particles), findsNothing);

      final unplayedMsg = Message(
        guid: 'msg-unplayed',
        text: 'Secret 2',
        dateCreated: DateTime(2026, 11, 20),
        isFromMe: false,
        handleId: 1,
        expressiveSendStyleId: invisibleInkKey,
      );
      final unplayedState = MessageState(unplayedMsg);

      final unplayedKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: false),
            child: Scaffold(
              body: BubbleEffects(
                key: const ValueKey('unplayed-animated'),
                part: 0,
                messageState: unplayedState,
                globalKey: unplayedKey,
                showTail: true,
                child: SizedBox(key: unplayedKey, width: 120, height: 40, child: const Text('Secret 2')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(Particles), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: BubbleEffects(
                key: const ValueKey('unplayed-animated'),
                part: 0,
                messageState: unplayedState,
                globalKey: unplayedKey,
                showTail: true,
                child: SizedBox(key: unplayedKey, width: 120, height: 40, child: const Text('Secret 2')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Particles), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: false,
            child: MediaQuery(
              data: const MediaQueryData(disableAnimations: false),
              child: Scaffold(
                body: BubbleEffects(
                  key: const ValueKey('unplayed-animated'),
                  part: 0,
                  messageState: unplayedState,
                  globalKey: unplayedKey,
                  showTail: true,
                  child: SizedBox(key: unplayedKey, width: 120, height: 40, child: const Text('Secret 2')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Particles), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('AnimatedDot drops AnimationBehavior.preserve and stops ticking when disableAnimations is true',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: AnimatedDot(index: 0),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);

      // Pump past multiple 700ms cycles to confirm no runaway status-listener restarts.
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });
}
