import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/swipe_to_reply_wrapper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_server_actions.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_theme_actions.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
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

class _TestSettings extends Settings {
  final List<String> savedKeys = [];

  @override
  Future<Settings> saveManyAsync(List<String> keys) async {
    savedKeys.addAll(keys);
    return this;
  }
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

  bool tipShown = false;
  bool disabledByUser = false;

  @override
  Future<void> setServerDetails({
    int? macOSVersion,
    int? macOSMinorVersion,
    String? serverVersion,
    int? serverVersionCode,
    List<int>? apiVersions,
    String? serverBuildVersion,
    bool? supportsFaceTimeCalls,
  }) async {}

  @override
  bool hasSeenPrivateApiEnableTip() => tipShown;

  @override
  Future<void> markPrivateApiEnableTipShown() async {
    tipShown = true;
  }

  @override
  bool isPrivateApiDisabledByUser() => disabledByUser;

  @override
  Future<void> setPrivateApiDisabledByUser(bool disabled) async {
    disabledByUser = disabled;
  }
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

class _FakeMessageApi extends MessageApi {
  _FakeMessageApi(super.svc, this._onFetchOne);

  final Future<Response> Function(String guid, String withQuery) _onFetchOne;

  @override
  Future<Response> fetchOne(String guid, {String withQuery = "", CancelToken? cancelToken}) =>
      _onFetchOne(guid, withQuery);
}

class _FakeHttpService extends HttpService {
  _FakeHttpService(Future<Response> Function(String guid, String withQuery) onFetchOne) {
    message = _FakeMessageApi(this, onFetchOne);
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

Message _rcsMsg({
  required String guid,
  required String text,
  required DateTime createdAt,
  String service = 'RCS',
  bool isFromMe = false,
  String? threadOriginatorGuid,
  String? threadOriginatorPart,
  List<dynamic>? attributedBody,
}) {
  return Message.fromMap({
    'guid': guid,
    'text': text,
    'service': service,
    'dateCreated': createdAt.millisecondsSinceEpoch,
    'isFromMe': isFromMe,
    'handleId': isFromMe ? 0 : 1,
    'hasAttachments': false,
    'threadOriginatorGuid': ?threadOriginatorGuid,
    'threadOriginatorPart': ?threadOriginatorPart,
    'attributedBody': ?attributedBody,
  });
}

Widget _wrapApp({
  required Chat chat,
  required Skins skin,
  required Widget child,
}) {
  SettingsSvc.settings.skin.value = skin;
  final theme = ThemesService.materialYouTheme(skin == Skins.iOS ? Brightness.dark : Brightness.light);
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

  group('RCS message reply metadata & normalizedThreadPart', () {
    test('normalizedThreadPart parses single-digit, multi-digit, empty, and null parts safely', () {
      expect(_rcsMsg(guid: 'm1', text: 'a', createdAt: DateTime(2026), threadOriginatorPart: '0:0:45').normalizedThreadPart, 0);
      expect(_rcsMsg(guid: 'm2', text: 'a', createdAt: DateTime(2026), threadOriginatorPart: '12:0:5').normalizedThreadPart, 12);
      expect(_rcsMsg(guid: 'm3', text: 'a', createdAt: DateTime(2026), threadOriginatorPart: '').normalizedThreadPart, 0);
      expect(_rcsMsg(guid: 'm4', text: 'a', createdAt: DateTime(2026), threadOriginatorPart: null).normalizedThreadPart, 0);
      expect(_rcsMsg(guid: 'm5', text: 'a', createdAt: DateTime(2026), threadOriginatorPart: 'bad:0:0').normalizedThreadPart, 0);
    });

    test('Message.fromMap preserves RCS reply fields matching chat.db schema', () {
      final reply = _rcsMsg(
        guid: '58EDFD76-FBA4-4748-B08D-711635A0600C',
        text: 'omg ! how did it go?',
        createdAt: DateTime(2026, 11, 18, 12, 0),
        isFromMe: false,
        threadOriginatorGuid: '5E50001B-F703-4F16-A5BC-F5FE2587CE1E',
        threadOriginatorPart: '0:0:45',
      );
      expect(reply.service, 'RCS');
      expect(reply.threadOriginatorGuid, '5E50001B-F703-4F16-A5BC-F5FE2587CE1E');
      expect(reply.threadOriginatorPart, '0:0:45');
      expect(reply.normalizedThreadPart, 0);
    });
  });

  group('Private API auto-enable in SettingsService', () {
    test('enables enablePrivateAPI and privateAPISend when server reports private_api: true', () async {
      final prefsServer = PrefsSvc.server as _FakePrefsServerActions;
      final testSettings = _TestSettings();
      SettingsSvc.settings = testSettings;
      prefsServer.disabledByUser = false;
      prefsServer.tipShown = false;

      expect(SettingsSvc.settings.enablePrivateAPI.value, isFalse);
      expect(SettingsSvc.settings.privateAPISend.value, isFalse);

      await SettingsSvc.updateServerDetails(
        const ServerDetails(
          macOSVersion: 15,
          macOSMinorVersion: 0,
          serverVersion: '1.9.9',
          serverVersionCode: 199,
          privateApiEnabled: true,
        ),
      );

      expect(SettingsSvc.settings.serverPrivateAPI.value, isTrue);
      expect(SettingsSvc.settings.enablePrivateAPI.value, isTrue);
      expect(SettingsSvc.settings.privateAPISend.value, isTrue);
      expect(prefsServer.tipShown, isTrue);
      expect(testSettings.savedKeys, containsAll(['serverPrivateAPI', 'enablePrivateAPI', 'privateAPISend']));
    });

    test('respects explicit user opt-out of Private API', () async {
      final prefsServer = PrefsSvc.server as _FakePrefsServerActions;
      final testSettings = _TestSettings();
      SettingsSvc.settings = testSettings;
      prefsServer.disabledByUser = true;

      await SettingsSvc.updateServerDetails(
        const ServerDetails(
          macOSVersion: 15,
          macOSMinorVersion: 0,
          serverVersion: '1.9.9',
          serverVersionCode: 199,
          privateApiEnabled: true,
        ),
      );

      expect(SettingsSvc.settings.serverPrivateAPI.value, isTrue);
      expect(SettingsSvc.settings.enablePrivateAPI.value, isFalse);
      expect(SettingsSvc.settings.privateAPISend.value, isFalse);

      // Reset for subsequent tests
      prefsServer.disabledByUser = false;
    });

    test('preserves privateAPISend: false when enablePrivateAPI is already true', () async {
      final prefsServer = PrefsSvc.server as _FakePrefsServerActions;
      final testSettings = _TestSettings()
        ..serverPrivateAPI.value = true
        ..enablePrivateAPI.value = true
        ..privateAPISend.value = false;
      SettingsSvc.settings = testSettings;
      prefsServer.disabledByUser = false;

      await SettingsSvc.updateServerDetails(
        const ServerDetails(
          macOSVersion: 15,
          macOSMinorVersion: 0,
          serverVersion: '1.9.9',
          serverVersionCode: 199,
          privateApiEnabled: true,
        ),
      );

      expect(SettingsSvc.settings.enablePrivateAPI.value, isTrue);
      expect(SettingsSvc.settings.privateAPISend.value, isFalse);
      expect(testSettings.savedKeys, isNot(contains('privateAPISend')));
    });
  });

  group('Off-screen RCS originator hydration', () {
    tearDown(() {
      if (GetIt.I.isRegistered<HttpService>()) {
        GetIt.I.unregister<HttpService>();
      }
    });

    test('addNewMessage fetches missing off-screen originator via HttpSvc without polluting struct.messages', () async {
      final chat = Chat(guid: 'RCS;-;+14084157073', chatIdentifier: '+14084157073', serviceName: 'RCS');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }

      int fetchCalls = 0;
      const originatorGuid = '5E50001B-F703-4F16-A5BC-F5FE2587CE1E';
      GetIt.I.registerSingleton<HttpService>(_FakeHttpService((guid, withQuery) async {
        fetchCalls++;
        expect(guid, originatorGuid);
        return Response(
          requestOptions: RequestOptions(path: '/api/v1/message/$guid'),
          statusCode: 200,
          data: {
            'status': 200,
            'data': {
              'guid': originatorGuid,
              'text': 'Seeing gail in at work on Wednesday actually!',
              'service': 'RCS',
              'isFromMe': true,
              'dateCreated': DateTime(2026, 11, 18, 10, 0).millisecondsSinceEpoch,
              'hasAttachments': false,
            },
          },
        );
      }));

      final service = ensureMessagesSvc(chat.guid);
      service.init(chat, (_) {}, (_, {String? oldGuid}) {}, (_) {}, (_) {}, []);

      final incomingReply = _rcsMsg(
        guid: '58EDFD76-FBA4-4748-B08D-711635A0600C',
        text: 'omg ! how did it go?',
        createdAt: DateTime(2026, 11, 18, 12, 0),
        isFromMe: false,
        threadOriginatorGuid: originatorGuid,
        threadOriginatorPart: '0:0:45',
      );

      await service.addNewMessage(incomingReply);
      // Let unawaited originator fetch complete
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(fetchCalls, 1);
      final resolved = resolveRootReplyTarget(incomingReply, 0, service: service);
      expect(resolved.guid, originatorGuid);
      expect(resolved.message?.text, 'Seeing gail in at work on Wednesday actually!');
      // Originator is cached in _threads, not appended out-of-order into struct.messages
      expect(service.struct.messages.map((m) => m.guid), ['58EDFD76-FBA4-4748-B08D-711635A0600C']);
      expect(service.messageUpdateTrigger[incomingReply.guid!], isNotNull);

      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });
  });

  group('Material UI RCS & iMessage reply/tapback gating', () {
    setUp(() {
      SettingsSvc.settings = _TestSettings();
      SettingsSvc.settings.enablePrivateAPI.value = true;
      SettingsSvc.settings.privateAPISend.value = true;
      SettingsSvc.settings.serverPrivateAPI.value = true;
      SettingsSvc.settings.enableQuickTapback.value = true;
      SettingsSvc.settings.doubleTapForDetails.value = false;
    });

    testWidgets('RCS chat in Material UI renders incoming reply bubble for part 1 and enables SwipeToReplyWrapper',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      final chat = Chat(guid: 'any;-;+14084157073', chatIdentifier: '+14084157073', serviceName: 'RCS');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }

      final service = ensureMessagesSvc(chat.guid);
      final cvController = cvc(chat);
      final t0 = DateTime(2026, 11, 18, 12, 0);
      final orig = _rcsMsg(
        guid: 'rcs-orig-multipart',
        text: 'First part\nSecond part',
        createdAt: t0,
        isFromMe: true,
        attributedBody: [
          {
            'string': 'First part\nSecond part',
            'runs': [
              {'range': [0, 11], 'attributes': {'__kIMMessagePartAttributeName': 0}},
              {'range': [11, 11], 'attributes': {'__kIMMessagePartAttributeName': 1}},
            ],
          }
        ],
      );
      final reply = _rcsMsg(
        guid: 'rcs-reply-part1',
        text: 'Replying to second part',
        createdAt: t0.add(const Duration(minutes: 2)),
        isFromMe: false,
        threadOriginatorGuid: 'rcs-orig-multipart',
        threadOriginatorPart: '1:0:11',
      );
      service.struct.addThreadOriginator(orig);
      service.struct.addMessages([reply]);

      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.Material,
          child: MessageHolder(
            cvController: cvController,
            message: reply,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ReplyBubble), findsOneWidget);
      expect(find.textContaining('Second part'), findsOneWidget);
      expect(find.textContaining('Failed to parse thread parts!'), findsNothing);

      final swipe = tester.widget<SwipeToReplyWrapper>(find.byType(SwipeToReplyWrapper));
      expect(swipe.enabled, isTrue);

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });

    for (final testCase in [
      (label: 'RCS', chat: Chat(guid: 'any;-;+14084157073', chatIdentifier: '+14084157073', serviceName: 'RCS'), expectReplyAndTapbacks: true),
      (label: 'iMessage', chat: Chat(guid: 'any;-;+16266165776', chatIdentifier: '+16266165776', serviceName: 'iMessage'), expectReplyAndTapbacks: true),
      (label: 'SMS', chat: Chat(guid: 'any;-;+15555550100', chatIdentifier: '+15555550100', serviceName: 'SMS'), expectReplyAndTapbacks: false),
    ]) {
      testWidgets('${testCase.label} Material MessagePopup reply/tapback gating',
          variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
        final chat = testCase.chat;
        if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
          Get.delete<MessagesService>(tag: chat.guid, force: true);
        }
        if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
          Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        }

        final service = ensureMessagesSvc(chat.guid);
        final cvController = cvc(chat);
        final msg = _rcsMsg(
          guid: 'popup-msg-${testCase.label}',
          text: 'Hello from ${testCase.label}',
          createdAt: DateTime(2026, 11, 18, 12, 0),
          service: testCase.label,
          isFromMe: false,
        );
        service.struct.addMessages([msg]);
        final msgState = service.getOrCreateState(msg);

        await tester.pumpWidget(
          _wrapApp(
            chat: chat,
            skin: Skins.Material,
            child: Builder(
              builder: (ctx) => MessagePopup(
                childPosition: const Offset(20, 250),
                size: const Size(160, 44),
                controller: msgState,
                part: msgState.parts.first,
                cvController: cvController,
                serverDetails: const MessagePopupServerDetails(
                  minSierra: true,
                  minBigSur: true,
                  supportsOriginalDownload: true,
                ),
                sendTapback: ([_, _, _]) {},
                widthContext: () => ctx,
                child: const SizedBox(width: 160, height: 44, child: Text('Hello')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        if (testCase.expectReplyAndTapbacks) {
          // Bottom M3E DockedToolbar Reply action + tapback picker
          expect(find.byIcon(Icons.reply), findsOneWidget);
          expect(find.byTooltip('Reply'), findsOneWidget);
          expect(find.text('❤️'), findsOneWidget);
        } else {
          expect(find.byIcon(Icons.reply), findsNothing);
          expect(find.byTooltip('Reply'), findsNothing);
          expect(find.text('❤️'), findsNothing);
        }

        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      });
    }

    testWidgets('MessagePopupHolder enables double-tap quick tapback for RCS and iMessage, but not SMS',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      for (final testCase in [
        (serviceName: 'RCS', expectedEnabled: true),
        (serviceName: 'iMessage', expectedEnabled: true),
        (serviceName: 'SMS', expectedEnabled: false),
      ]) {
        final chat = Chat(
          guid: 'any;-;quick-${testCase.serviceName}',
          chatIdentifier: 'quick-${testCase.serviceName}',
          serviceName: testCase.serviceName,
        );
        if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
          Get.delete<MessagesService>(tag: chat.guid, force: true);
        }
        if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
          Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        }

        final service = ensureMessagesSvc(chat.guid);
        final cvController = cvc(chat);
        final msg = _rcsMsg(
          guid: 'quick-tapback-${testCase.serviceName}',
          text: 'Double tap ${testCase.serviceName}',
          createdAt: DateTime(2026, 11, 18, 12, 0),
          service: testCase.serviceName,
          isFromMe: false,
        );
        service.struct.addMessages([msg]);
        final msgState = service.getOrCreateState(msg);

        await tester.pumpWidget(
          _wrapApp(
            chat: chat,
            skin: Skins.Material,
            child: MessagePopupHolder(
              controller: msgState,
              cvController: cvController,
              part: msgState.parts.first,
              isEditing: false,
              child: SizedBox(width: 120, height: 40, child: Text('Double tap ${testCase.serviceName}')),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final detector = tester.widget<GestureDetector>(
          find.ancestor(
            of: find.text('Double tap ${testCase.serviceName}'),
            matching: find.byType(GestureDetector),
          ).first,
        );
        expect(detector.onDoubleTap != null, testCase.expectedEnabled);

        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
    });

    test('Message.merge, takeOmittableFieldsFrom, fillsGapsIn, and updateFromMessage preserve threadOriginatorGuid', () {
      final pushCopy = Message(
        guid: '58EDFD76-FBA4-4748-B08D-711635A0600C',
        text: 'omg ! how did it go?',
        isFromMe: false,
        service: 'RCS',
        threadOriginatorGuid: '5E50001B-F703-4F16-A5BC-F5FE2587CE1E',
        threadOriginatorPart: null,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(1792098155620),
      );
      final socketCopy = Message(
        guid: '58EDFD76-FBA4-4748-B08D-711635A0600C',
        text: 'omg ! how did it go?',
        isFromMe: false,
        service: 'RCS',
        threadOriginatorGuid: '5E50001B-F703-4F16-A5BC-F5FE2587CE1E',
        threadOriginatorPart: '0:0:45',
        dateCreated: DateTime.fromMillisecondsSinceEpoch(1792098155620),
      );
      final partialNoThread = Message(
        guid: '58EDFD76-FBA4-4748-B08D-711635A0600C',
        text: 'omg ! how did it go?',
        isFromMe: false,
        service: 'RCS',
        threadOriginatorGuid: null,
        threadOriginatorPart: null,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(1792098155620),
      );

      expect(socketCopy.fillsGapsIn(partialNoThread), isTrue);

      final merged = Message.merge(partialNoThread, socketCopy);
      expect(merged.threadOriginatorGuid, '5E50001B-F703-4F16-A5BC-F5FE2587CE1E');
      expect(merged.threadOriginatorPart, '0:0:45');

      final service = ensureMessagesSvc('any;-;+14084157073-merge-test');
      final state = service.getOrCreateState(pushCopy);
      state.updateFromMessage(partialNoThread);
      expect(state.message.threadOriginatorGuid, '5E50001B-F703-4F16-A5BC-F5FE2587CE1E');
      expect(state.threadOriginatorGuid.value, '5E50001B-F703-4F16-A5BC-F5FE2587CE1E');
      Get.delete<MessagesService>(tag: 'any;-;+14084157073-merge-test', force: true);
    });

    test('MessagesService.updateMessage hydrates missing off-screen originator when update attaches threadOriginatorGuid', () async {
      final chat = Chat(guid: 'any;-;+14084157073-update-hydrate', chatIdentifier: '+14084157073', serviceName: 'RCS');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }

      const originatorGuid = '5E50001B-F703-4F16-A5BC-F5FE2587CE1E';
      const replyGuid = '58EDFD76-FBA4-4748-B08D-711635A0600C';
      final requestedGuids = <String>[];
      if (GetIt.I.isRegistered<HttpService>()) {
        GetIt.I.unregister<HttpService>();
      }
      GetIt.I.registerSingleton<HttpService>(_FakeHttpService((guid, withQuery) async {
        requestedGuids.add(guid);
        return Response(
          requestOptions: RequestOptions(path: '/api/v1/message/$guid'),
          statusCode: 200,
          data: {
            'status': 200,
            'data': {
              'originalROWID': 65555,
              'guid': originatorGuid,
              'text': 'Seeing gail in at work on Wednesday actually!',
              'isFromMe': true,
              'service': 'RCS',
              'dateCreated': 1791866310069,
              'partCount': 1,
            },
          },
        );
      }));

      final service = ensureMessagesSvc(chat.guid);
      service.init(chat, (_) {}, (_, {String? oldGuid}) {}, (_) {}, (_) {}, []);
      final initialReply = _rcsMsg(
        guid: replyGuid,
        text: 'omg ! how did it go?',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1792098155620),
        isFromMe: false,
      );
      await service.addNewMessage(initialReply);
      expect(service.struct.getThreadOriginator(originatorGuid), isNull);

      final updatedReply = Message.fromMap({
        'originalROWID': 66008,
        'guid': replyGuid,
        'text': 'omg ! how did it go?',
        'isFromMe': false,
        'service': 'RCS',
        'dateCreated': 1792098155620,
        'threadOriginatorGuid': originatorGuid,
        'threadOriginatorPart': '0:0:45',
        'partCount': 1,
      });
      service.updateMessage(updatedReply);

      for (var i = 0; i < 20 && service.struct.getThreadOriginator(originatorGuid) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(requestedGuids, [originatorGuid]);
      expect(service.struct.getThreadOriginator(originatorGuid)?.text,
          'Seeing gail in at work on Wednesday actually!');
      expect(service.messageStates[replyGuid]?.threadOriginatorGuid.value, originatorGuid);

      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });

    testWidgets('Real chat.db incoming RCS reply (66008 -> 65555) renders ReplyBubble in Material and updates when threadOriginatorGuid arrives later',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      final chat = Chat(guid: 'any;-;+14084157073-real-shape', chatIdentifier: '+14084157073', serviceName: 'RCS');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }

      final originator = Message.fromMap({
        'originalROWID': 65555,
        'guid': '5E50001B-F703-4F16-A5BC-F5FE2587CE1E',
        'text': 'Seeing gail in at work on Wednesday actually!',
        'isFromMe': true,
        'service': 'RCS',
        'dateCreated': 1791866310069,
        'partCount': 1,
        'attributedBody': [
          {
            'string': 'Seeing gail in at work on Wednesday actually!',
            'runs': [
              {'range': [0, 22], 'attributes': {'__kIMMessagePartAttributeName': 0}},
              {'range': [22, 9], 'attributes': {'__kIMMessagePartAttributeName': 0, '__kIMCalendarEventAttributeName': true}},
              {'range': [31, 14], 'attributes': {'__kIMMessagePartAttributeName': 0}},
            ],
          }
        ],
      });
      final priorIncoming = _rcsMsg(
        guid: 'prior-66007',
        text: 'That sounds so good!',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1792098140000),
        isFromMe: false,
      );
      final initialReply = Message.fromMap({
        'originalROWID': 66008,
        'guid': '58EDFD76-FBA4-4748-B08D-711635A0600C',
        'text': 'omg ! how did it go?',
        'isFromMe': false,
        'service': 'RCS',
        'dateCreated': 1792098155620,
        'partCount': 1,
      });
      final updatedReply = Message.fromMap({
        'originalROWID': 66008,
        'guid': '58EDFD76-FBA4-4748-B08D-711635A0600C',
        'text': 'omg ! how did it go?',
        'isFromMe': false,
        'service': 'RCS',
        'dateCreated': 1792098155620,
        'threadOriginatorGuid': '5E50001B-F703-4F16-A5BC-F5FE2587CE1E',
        'threadOriginatorPart': '0:0:45',
        'partCount': 1,
      });

      final service = ensureMessagesSvc(chat.guid);
      service.init(chat, (_) {}, (_, {String? oldGuid}) {}, (_) {}, (_) {}, []);
      final cvController = cvc(chat);
      service.struct.addMessages([originator, priorIncoming, initialReply]);

      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.Material,
          child: SingleChildScrollView(
            child: MessageHolder(
              cvController: cvController,
              message: initialReply,
              oldMessage: priorIncoming,
              newMessage: null,
              isReplyThread: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ReplyBubble), findsNothing);

      service.updateMessage(updatedReply);
      await tester.pumpAndSettle();

      expect(find.byType(ReplyBubble), findsOneWidget);
      expect(find.textContaining('Seeing gail in at work on Wednesday actually!', findRichText: true), findsOneWidget);
      expect(find.textContaining('omg ! how did it go?', findRichText: true), findsOneWidget);
      expect(find.text('Failed to parse thread parts!'), findsNothing);

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });

    testWidgets('Real chat.db incoming RCS reply (66008 -> 65555) renders ReplyBubble in iOS skin and refreshes when originator parts update',
        variant: TargetPlatformVariant.only(TargetPlatform.android), (tester) async {
      final chat = Chat(guid: 'any;-;+14084157073-ios-shape', chatIdentifier: '+14084157073', serviceName: 'RCS');
      if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
        Get.delete<MessagesService>(tag: chat.guid, force: true);
      }
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }

      final originator = Message.fromMap({
        'originalROWID': 65555,
        'guid': '5E50001B-F703-4F16-A5BC-F5FE2587CE1E',
        'text': 'Seeing gail in at work on Wednesday actually!',
        'isFromMe': true,
        'service': 'RCS',
        'dateCreated': 1791866310069,
        'partCount': 1,
      });
      final priorIncoming = _rcsMsg(
        guid: 'prior-66007-ios',
        text: 'That sounds so good!',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1792098140000),
        isFromMe: false,
      );
      final incomingReply = Message.fromMap({
        'originalROWID': 66008,
        'guid': '58EDFD76-FBA4-4748-B08D-711635A0600C',
        'text': 'omg ! how did it go?',
        'isFromMe': false,
        'service': 'RCS',
        'dateCreated': 1792098155620,
        'threadOriginatorGuid': '5E50001B-F703-4F16-A5BC-F5FE2587CE1E',
        'threadOriginatorPart': '0:0:45',
        'partCount': 1,
      });

      final service = ensureMessagesSvc(chat.guid);
      service.init(chat, (_) {}, (_, {String? oldGuid}) {}, (_) {}, (_) {}, []);
      final cvController = cvc(chat);
      service.struct.addMessages([originator, priorIncoming, incomingReply]);

      await tester.pumpWidget(
        _wrapApp(
          chat: chat,
          skin: Skins.iOS,
          child: SingleChildScrollView(
            child: MessageHolder(
              cvController: cvController,
              message: incomingReply,
              oldMessage: priorIncoming,
              newMessage: null,
              isReplyThread: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ReplyBubble), findsOneWidget);
      expect(find.textContaining('Seeing gail in at work on Wednesday actually!', findRichText: true), findsOneWidget);
      expect(find.textContaining('omg ! how did it go?', findRichText: true), findsOneWidget);
      expect(find.text('Failed to parse thread parts!'), findsNothing);

      Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      Get.delete<MessagesService>(tag: chat.guid, force: true);
    });
  });
}
