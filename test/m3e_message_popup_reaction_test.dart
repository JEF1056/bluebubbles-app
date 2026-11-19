import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/wrappers/bb_app_bar.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_server_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
import 'package:get/get.dart';
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

class _TestSettings extends Settings {
  @override
  Future<Settings> saveManyAsync(List<String> keys) async => this;
}

class _FakePrefsThemeActions extends SharedPreferencesThemeActions {
  _FakePrefsThemeActions(super.service);

  @override
  String? getSelectedLightTheme() => null;

  @override
  String? getSelectedDarkTheme() => null;
}

class _FakePrefsServerActions extends SharedPreferencesServerActions {
  _FakePrefsServerActions(super.service);
}

class _FakePrefsMessagingActions extends SharedPreferencesMessagingActions {
  _FakePrefsMessagingActions(super.service);

  @override
  List<String> getRecentTapbackEmojis({String? chatGuid}) => const [];
}

class _FakePrefsService extends SharedPreferencesService {
  _FakePrefsService() {
    theme = _FakePrefsThemeActions(this);
    server = _FakePrefsServerActions(this);
    messaging = _FakePrefsMessagingActions(this);
  }
}

void _registerTestServices() {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    final settingsService = SettingsService()..settings = _TestSettings();
    GetIt.I.registerSingleton<SettingsService>(settingsService);
  }
  if (!GetIt.I.isRegistered<SharedPreferencesService>()) {
    GetIt.I.registerSingleton<SharedPreferencesService>(_FakePrefsService());
  }
  if (!GetIt.I.isRegistered<ThemesService>()) {
    GetIt.I.registerSingleton<ThemesService>(ThemesService());
  }
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (!GetIt.I.isRegistered<HandleService>()) {
    GetIt.I.registerSingleton<HandleService>(HandleService());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
  if (!GetIt.I.isRegistered<CacheService>()) {
    GetIt.I.registerSingleton<CacheService>(CacheService());
  }
  if (!GetIt.I.isRegistered<EventDispatcher>()) {
    GetIt.I.registerSingleton<EventDispatcher>(EventDispatcher());
  }
  if (!GetIt.I.isRegistered<LifecycleService>()) {
    GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  }
  if (!GetIt.I.isRegistered<SocketService>()) {
    GetIt.I.registerSingleton<SocketService>(SocketService());
  }
}

Message _makeMessage({
  required String guid,
  required String text,
  String service = 'RCS',
  bool isFromMe = false,
  List<Message> associatedMessages = const [],
}) {
  final msg = Message.fromMap({
    'guid': guid,
    'text': text,
    'service': service,
    'dateCreated': DateTime(2026, 11, 19, 8, 30).millisecondsSinceEpoch,
    'isFromMe': isFromMe,
    'handleId': isFromMe ? 0 : 1,
    'hasAttachments': false,
  });
  msg.associatedMessages.addAll(associatedMessages);
  return msg;
}

Message _makeReaction({
  required String guid,
  required String type,
  required String targetGuid,
  bool isFromMe = true,
  String? emoji,
}) {
  return Message.fromMap({
    'guid': guid,
    'service': 'RCS',
    'dateCreated': DateTime(2026, 11, 19, 8, 31).millisecondsSinceEpoch,
    'isFromMe': isFromMe,
    'handleId': isFromMe ? 0 : 1,
    'associatedMessageGuid': targetGuid,
    'associatedMessageType': type,
    'associatedMessageEmoji': emoji,
  });
}

Widget _wrapMaterialApp({
  required Chat chat,
  required Widget child,
}) {
  SettingsSvc.settings.skin.value = Skins.Material;
  final theme = ThemesService.materialYouTheme(Brightness.light);
  final chatState = ChatsSvc.getOrCreateChatState(chat);
  ChatsSvc.activeChat = chatState;
  return MaterialApp(
    theme: theme,
    home: ChatStateScope(
      chatState: chatState,
      child: Scaffold(
        body: child,
      ),
    ),
  );
}

void main() {
  setUpAll(_registerTestServices);

  group('P0-2 Material in-context MessagePopup overlay', () {
    testWidgets(
      'renders dimmed scrim, anchored bubble, floating tapback pill above bubble, selected pill highlight, and bottom M3E DockedToolbar without BBAppBar',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        SettingsSvc.settings.enablePrivateAPI.value = true;
        SettingsSvc.settings.privateAPISend.value = true;

        final chat = Chat(guid: 'any;-;+14085550199', chatIdentifier: '+14085550199', serviceName: 'RCS');
        if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
          Get.delete<MessagesService>(tag: chat.guid, force: true);
        }
        if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
          Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        }

        final service = ensureMessagesSvc(chat.guid);
        final cvController = cvc(chat);
        final selfLove = _makeReaction(
          guid: 'rxn-self-love',
          type: 'love',
          targetGuid: 'popup-p02-msg',
          isFromMe: true,
        );
        final msg = _makeMessage(
          guid: 'popup-p02-msg',
          text: 'Anchored message text',
          isFromMe: false,
          associatedMessages: [selfLove],
        );
        service.struct.addMessages([msg]);
        final msgState = service.getOrCreateState(msg);

        String? sentTapbackType;
        int? sentTapbackPart;

        await tester.pumpWidget(
          _wrapMaterialApp(
            chat: chat,
            child: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).push(
                      PageRouteBuilder(
                        opaque: false,
                        barrierDismissible: true,
                        pageBuilder: (_, _, _) => MessagePopup(
                          childPosition: const Offset(20, 260),
                          size: const Size(180, 48),
                          controller: msgState,
                          part: msgState.parts.first,
                          cvController: cvController,
                          serverDetails: const MessagePopupServerDetails(
                            minSierra: true,
                            minBigSur: true,
                            supportsOriginalDownload: true,
                          ),
                          sendTapback: ([type, part, _]) {
                            sentTapbackType = type;
                            sentTapbackPart = part;
                          },
                          widthContext: () => ctx,
                          child: const SizedBox(
                            width: 180,
                            height: 48,
                            child: Center(child: Text('Anchored bubble')),
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('Open overlay'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open overlay'));
        await tester.pumpAndSettle();

        // No top BBAppBar or Material AppBar in Material in-context mode.
        expect(find.byType(BBAppBar), findsNothing);
        expect(find.byType(AppBar), findsNothing);

        // Anchored bubble clone is rendered on the overlay.
        final bubbleFinder = find.text('Anchored bubble');
        expect(bubbleFinder, findsOneWidget);

        // Floating tapback pill sits above the anchored bubble.
        final heartFinder = find.text('❤️');
        expect(heartFinder, findsOneWidget);
        expect(tester.getRect(heartFinder).bottom, lessThan(tester.getRect(bubbleFinder).top));

        // Selected tapback pill highlight uses primaryContainer + AnimatedScale(1.12).
        final selectedScale = tester.widget<AnimatedScale>(
          find.ancestor(of: heartFinder, matching: find.byType(AnimatedScale)).first,
        );
        expect(selectedScale.scale, closeTo(1.12, 0.001));
        final unselectedScale = tester.widget<AnimatedScale>(
          find.ancestor(of: find.text('👍'), matching: find.byType(AnimatedScale)).first,
        );
        expect(unselectedScale.scale, closeTo(1.0, 0.001));

        // Bottom M3E DockedToolbar sits below the anchored bubble with labeled actions & overflow.
        final replyLabel = find.text('Reply');
        expect(replyLabel, findsOneWidget);
        expect(find.byTooltip('Reply'), findsOneWidget);
        expect(find.text('More'), findsOneWidget);
        expect(tester.getRect(replyLabel).top, greaterThan(tester.getRect(bubbleFinder).bottom));

        // Overflow menu opens and lists remaining actions (e.g., Delete, Message Info).
        await tester.tap(find.text('More'));
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsOneWidget);
        expect(find.text('Message Info'), findsOneWidget);

        // Dismiss the PopupMenu first, then tap Reply in the DockedToolbar.
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Reply'));
        await tester.pumpAndSettle();
        expect(cvController.replyToMessage?.message.guid, 'popup-p02-msg');
        expect(find.text('Anchored bubble'), findsNothing);

        // Re-open overlay and tap a tapback to verify sendTapback + dismissal.
        await tester.tap(find.text('Open overlay'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('👍'));
        await tester.pumpAndSettle();
        expect(sentTapbackType, 'like');
        expect(sentTapbackPart, 0);
        expect(find.text('Anchored bubble'), findsNothing);

        // Re-open overlay and tap the dimmed scrim to verify dismissal.
        await tester.tap(find.text('Open overlay'));
        await tester.pumpAndSettle();
        expect(find.text('Anchored bubble'), findsOneWidget);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(find.text('Anchored bubble'), findsNothing);

        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      },
    );
  });

  group('P1-6 ReactionWidget spring scale-bounce burst', () {
    testWidgets(
      'runs spring overshoot burst on mount and when reaction type changes, without re-bouncing on GUID swap',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        final chat = Chat(guid: 'any;-;+14085550188', chatIdentifier: '+14085550188', serviceName: 'RCS');
        if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
          Get.delete<MessagesService>(tag: chat.guid, force: true);
        }
        final service = ensureMessagesSvc(chat.guid);
        final parent = _makeMessage(guid: 'parent-msg', text: 'Parent');
        final initialReaction = _makeReaction(
          guid: 'temp-rxn-1',
          type: 'love',
          targetGuid: 'parent-msg',
          isFromMe: true,
        );
        parent.associatedMessages.add(initialReaction);
        service.struct.addMessages([parent]);
        final msgState = service.getOrCreateState(parent);

        Widget buildReactionTree(Message rxn) {
          return _wrapMaterialApp(
            chat: chat,
            child: MessageStateScope(
              messageState: msgState,
              child: Center(
                child: ReactionWidget(
                  reaction: rxn,
                  reactions: [rxn],
                  chatGuid: chat.guid,
                ),
              ),
            ),
          );
        }

        await tester.pumpWidget(buildReactionTree(initialReaction));

        ScaleTransition getReactionScale() =>
            tester.widget<ScaleTransition>(find.byType(ScaleTransition).first);

        // Starts below 1.0, overshoots above 1.0 during spring burst, and settles at 1.0.
        expect(getReactionScale().scale.value, lessThan(1.0));
        await tester.pump(const Duration(milliseconds: 90));
        expect(getReactionScale().scale.value, greaterThan(1.0));
        await tester.pumpAndSettle();
        expect(getReactionScale().scale.value, closeTo(1.0, 0.01));

        // Replacing temp GUID with real GUID (same reaction type) must NOT re-bounce.
        final realGuidReaction = _makeReaction(
          guid: 'p:0/real-rxn-1',
          type: 'love',
          targetGuid: 'parent-msg',
          isFromMe: true,
        );
        msgState.associatedMessages.assignAll([realGuidReaction]);
        await tester.pumpWidget(buildReactionTree(realGuidReaction));
        expect(getReactionScale().scale.value, closeTo(1.0, 0.01));
        await tester.pumpAndSettle();

        // Toggling to a different reaction type ('like') triggers a fresh spring burst.
        final toggledReaction = _makeReaction(
          guid: 'p:0/real-rxn-2',
          type: 'like',
          targetGuid: 'parent-msg',
          isFromMe: true,
        );
        msgState.associatedMessages.assignAll([toggledReaction]);
        await tester.pumpWidget(buildReactionTree(toggledReaction));
        expect(getReactionScale().scale.value, lessThan(1.0));
        await tester.pump(const Duration(milliseconds: 90));
        expect(getReactionScale().scale.value, greaterThan(1.0));
        await tester.pumpAndSettle();
        expect(getReactionScale().scale.value, closeTo(1.0, 0.01));

        Get.delete<MessagesService>(tag: chat.guid, force: true);
      },
    );
  });
}
