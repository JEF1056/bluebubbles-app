import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/send_button.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
import 'package:geolocator/geolocator.dart';
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
  @override
  Future<Settings> saveManyAsync(List<String> keys) async => this;
}

class _TestChatsService extends ChatsService {}

void _registerServices() {
  Get.testMode = true;
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_SilentLogger());
  }
  if (!GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = _TestSettings());
  }
  if (!GetIt.I.isRegistered<FilesystemService>()) {
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  }
  if (!GetIt.I.isRegistered<HandleService>()) {
    GetIt.I.registerSingleton<HandleService>(HandleService());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(_TestChatsService());
  }
  if (!GetIt.I.isRegistered<EventDispatcher>()) {
    GetIt.I.registerSingleton<EventDispatcher>(EventDispatcher());
  }
  if (!GetIt.I.isRegistered<ContactServiceV2>()) {
    GetIt.I.registerSingleton<ContactServiceV2>(ContactServiceV2());
  }
}

Position _pos(double lat, double lng) => Position(
      longitude: lng,
      latitude: lat,
      timestamp: DateTime(2026, 11, 22),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _registerServices();

  group('Storage GUID sanitization', () {
    test('sanitizeGuid strips non-alphanumeric chars matching disk directory names', () {
      expect(FilesystemService.sanitizeGuid('at_0_ABC-123/xyz'), 'at0ABC123xyz');
      expect(FilesystemService.sanitizeGuid('p:0/guid:99'), 'p0guid99');
    });
  });

  group('FindMy lifecycle gating (P0)', () {
    test('deactivatePage stops live stream, cancels polling and tokens, and blocks background restarts', () async {
      final now = DateTime(2026, 11, 22, 12, 0, 0);
      var refreshCalls = 0;
      var startCalls = 0;
      var stopCalls = 0;
      var streamSubscribeCalls = 0;
      CancelToken? lastToken;
      final controller = FindMyController(
        now: () => now,
        autoFetch: false,
        livePollInterval: const Duration(milliseconds: 20),
        liveFallbackInterval: const Duration(milliseconds: 20),
        fetchCurrentPosition: () async => _pos(37.77, -122.41),
        positionStream: () {
          streamSubscribeCalls++;
          return const Stream<Position>.empty();
        },
        startLiveFriendRequest: ({required String handle, CancelToken? cancelToken}) async {
          startCalls++;
          lastToken = cancelToken;
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/live/start'),
            statusCode: 200,
          );
        },
        stopLiveFriendRequest: ({String? handle, CancelToken? cancelToken}) async {
          stopCalls++;
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/live/stop'),
            statusCode: 200,
          );
        },
        refreshFriendsRequest: ({handle, force = false, live = false, cancelToken}) async {
          refreshCalls++;
          lastToken = cancelToken;
          return Response(
            requestOptions: RequestOptions(path: '/icloud/findmy/friends/refresh'),
            statusCode: 200,
            data: {'data': []},
          );
        },
      );

      final alice = FindMyFriend(
        latitude: 37.3349,
        longitude: -122.009,
        longAddress: null,
        shortAddress: null,
        title: 'Alice',
        subtitle: null,
        handle: Handle(address: 'alice@example.com'),
        handleAddress: 'alice@example.com',
        lastUpdated: now.subtract(const Duration(minutes: 2)),
        status: LocationStatus.shallow,
        locatingInProgress: false,
      );
      controller.friends.add(alice);
      controller.activatePage();
      controller.selectFriend(alice);
      await Future<void>.delayed(const Duration(milliseconds: 55));

      expect(startCalls, greaterThan(0));
      expect(lastToken, isNotNull);

      final callsBeforeDeactivate = refreshCalls;
      final startsBeforeDeactivate = startCalls;
      final streamsBeforeDeactivate = streamSubscribeCalls;
      controller.deactivatePage();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(controller.locationSub, isNull);
      expect(stopCalls, greaterThanOrEqualTo(1));
      expect(refreshCalls, callsBeforeDeactivate);
      expect(startCalls, startsBeforeDeactivate);

      // Resuming app while FindMyPage is deactivated must NOT restart GPS or friend polling.
      controller.onAppResumed();
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(controller.locationSub, isNull);
      expect(refreshCalls, callsBeforeDeactivate);
      expect(startCalls, startsBeforeDeactivate);
      expect(streamSubscribeCalls, streamsBeforeDeactivate);

      controller.onClose();
    });
  });

  group('ChatState unread count caching (P1)', () {
    test('skips DB fetch when read or muted, caches per state, and invalidates on updates', () {
      var fetchCalls = 0;
      List<Message> fakeFetch(Chat chat, {int limit = 25}) {
        fetchCalls++;
        return [
          Message(guid: 'm-2', isFromMe: false),
          Message(guid: 'm-1', isFromMe: false),
        ];
      }

      final chat = Chat(
        id: 101,
        guid: 'iMessage;-;+15550009999',
        hasUnreadMessage: false,
      );
      final state = ChatState(chat);

      // Read chat skips fetch completely.
      expect(state.getUnreadCount(fetchMessages: fakeFetch), 0);
      expect(fetchCalls, 0);

      // Muted unread chat skips fetch completely.
      state.updateHasUnreadInternal(true);
      state.updateMutedInternal('mute', null);
      expect(state.getUnreadCount(fetchMessages: fakeFetch), 0);
      expect(fetchCalls, 0);

      // Unmuted unread chat computes once and caches across repeated rebuilds.
      state.updateMutedInternal(null, null);
      expect(state.getUnreadCount(fetchMessages: fakeFetch), 2);
      expect(state.getUnreadCount(fetchMessages: fakeFetch), 2);
      expect(state.getUnreadCount(fetchMessages: fakeFetch), 2);
      expect(fetchCalls, 1);

      // Updating latestMessage invalidates cache so next read refreshes.
      state.updateLatestMessageInternal(Message(guid: 'm-3', isFromMe: false));
      expect(state.getUnreadCount(fetchMessages: fakeFetch), 2);
      expect(fetchCalls, 2);

      // Updating lastReadMessageGuid invalidates cache.
      state.lastReadMessageGuid.value = 'm-1';
      expect(state.getUnreadCount(fetchMessages: fakeFetch), 1);
      expect(fetchCalls, 3);
    });
  });

  group('MessageState per-message updates & reaction transition cleanup (P1)', () {
    test('triggerMessageUpdate bumps only target MessageState.updateVersion', () {
      final svc = MessagesService('iMessage;-;+15550008888');
      svc.struct.addMessages([
        Message(guid: 'm-a', text: 'A'),
        Message(guid: 'm-b', text: 'B'),
      ]);
      final stateA = svc.getOrCreateMessageState('m-a');
      final stateB = svc.getOrCreateMessageState('m-b');

      expect(stateA.updateVersion.value, 0);
      expect(stateB.updateVersion.value, 0);

      svc.triggerMessageUpdate('m-a');

      expect(stateA.updateVersion.value, 1);
      expect(stateB.updateVersion.value, 0);
    });

    test('updateMessage removes stale toUpdate.guid on non-reaction to reaction transition', () {
      final svc = MessagesService('iMessage;-;+15550008889');
      final removed = <Message>[];
      svc.removeFunc = removed.add;
      final parent = Message(guid: 'parent-1', text: 'Hello');
      final fallback = Message(guid: 'temp-guid-1', text: 'Liked "Hello"');
      svc.struct.addMessages([parent, fallback]);

      final updated = Message(
        guid: 'real-reaction-1',
        text: 'Liked "Hello"',
        associatedMessageGuid: 'parent-1',
        associatedMessageType: 'like',
      );
      svc.updateMessage(updated, oldGuid: 'temp-guid-1');

      expect(svc.struct.getMessage('temp-guid-1'), isNull);
      expect(svc.struct.messages.map((m) => m.guid), isNot(contains('temp-guid-1')));
      expect(svc.struct.messages.map((m) => m.guid), isNot(contains('real-reaction-1')));
      expect(removed.map((m) => m.guid), contains('temp-guid-1'));
    });
  });

  group('ChatsService unread badge recalculation (P1)', () {
    test('addChat, removeChat, and reset recalculate unreadCount', () async {
      final chatsSvc = _TestChatsService();
      final unreadChat = Chat(guid: 'iMessage;-;+15551110001', hasUnreadMessage: true);
      final readChat = Chat(guid: 'iMessage;-;+15551110002', hasUnreadMessage: false);

      await chatsSvc.addChat(unreadChat);
      expect(chatsSvc.unreadCount.value, 1);

      await chatsSvc.addChat(readChat);
      expect(chatsSvc.unreadCount.value, 1);

      chatsSvc.removeChat(unreadChat);
      expect(chatsSvc.unreadCount.value, 0);

      await chatsSvc.addChat(unreadChat);
      expect(chatsSvc.unreadCount.value, 1);

      chatsSvc.reset();
      expect(chatsSvc.unreadCount.value, 0);
    });
  });

  group('SendButton dispose (P1)', () {
    testWidgets('disposes AnimationController cleanly on widget removal', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SendButton(
              onLongPress: () {},
              sendMessage: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pump();
    });
  });
}
