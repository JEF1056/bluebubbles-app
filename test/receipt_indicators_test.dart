import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_holder_timestamps.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/delivered_indicator.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/relative_timestamp_ticker.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class _FakeLogger extends BaseLogger {
  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

class _FakeSettingsService extends SettingsService {
  final Rx<ServerDetails> fakeDetails = const ServerDetails(
    macOSVersion: 14,
    macOSMinorVersion: 0,
    serverVersion: '1.9.0',
    serverVersionCode: 10900,
  ).obs;

  @override
  ServerDetails get serverDetails => fakeDetails.value;
}

void _registerServices(_FakeSettingsService settingsService) {
  Get.testMode = true;
  if (GetIt.I.isRegistered<SettingsService>()) {
    GetIt.I.unregister<SettingsService>();
  }
  GetIt.I.registerSingleton<SettingsService>(settingsService);
  if (!GetIt.I.isRegistered<BaseLogger>()) {
    GetIt.I.registerSingleton<BaseLogger>(_FakeLogger());
  }
  if (!GetIt.I.isRegistered<LifecycleService>()) {
    GetIt.I.registerSingleton<LifecycleService>(LifecycleService());
  }
  if (!GetIt.I.isRegistered<NavigatorService>()) {
    GetIt.I.registerSingleton<NavigatorService>(NavigatorService());
  }
  if (!GetIt.I.isRegistered<HttpService>()) {
    GetIt.I.registerSingleton<HttpService>(HttpService());
  }
  if (!GetIt.I.isRegistered<AttachmentDownloadService>()) {
    GetIt.I.registerSingleton<AttachmentDownloadService>(AttachmentDownloadService());
  }
  if (!GetIt.I.isRegistered<SocketService>()) {
    GetIt.I.registerSingleton<SocketService>(SocketService());
  }
  if (!GetIt.I.isRegistered<ChatsService>()) {
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
  }
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
}

MessagesService _createService(Chat chat) {
  final service = MessagesService(chat.guid);
  service.init(
    chat,
    (_) {},
    (_, {String? oldGuid}) {},
    (_) {},
    (_) {},
    const <Message>[],
  );
  return service;
}

void main() {
  late _FakeSettingsService settingsService;

  setUp(() {
    settingsService = _FakeSettingsService()..settings = Settings();
    settingsService.settings.skin.value = Skins.Material;
    settingsService.settings.showDeliveryTimestamps.value = false;
    _registerServices(settingsService);
  });

  group('MessagesService 4-tier receipt indicator ownership', () {
    test('latest sent delivered + earlier last-read are both shown', () async {
      final chat = Chat(guid: 'iMessage;-;+15550001');
      final service = _createService(chat);
      addTearDown(service.close);

      final t1 = DateTime(2026, 11, 19, 10, 0);
      final t2 = DateTime(2026, 11, 19, 10, 5);
      final m1 = Message(
        guid: 'm1',
        text: 'Read earlier',
        isFromMe: true,
        dateCreated: t1,
        dateDelivered: t1,
        dateRead: t1.add(const Duration(minutes: 1)),
      );
      final m2 = Message(
        guid: 'm2',
        text: 'Delivered later',
        isFromMe: true,
        dateCreated: t2,
        dateDelivered: t2,
      );

      await service.addNewMessage(m1);
      await service.addNewMessage(m2);

      final s1 = service.getMessageStateIfExists('m1')!;
      final s2 = service.getMessageStateIfExists('m2')!;
      expect(s1.showReadIndicator.value, isTrue);
      expect(s1.showDeliveredIndicator.value, isFalse);
      expect(s2.showReadIndicator.value, isFalse);
      expect(s2.showDeliveredIndicator.value, isTrue);
      expect(s2.showSentIndicator.value, isFalse);
    });

    test('latest sent already read is shown once and hides older delivered', () async {
      final chat = Chat(guid: 'iMessage;-;+15550002');
      final service = _createService(chat);
      addTearDown(service.close);

      final t1 = DateTime(2026, 11, 19, 10, 0);
      final t2 = DateTime(2026, 11, 19, 10, 5);
      final m1 = Message(
        guid: 'm1',
        text: 'Delivered earlier',
        isFromMe: true,
        dateCreated: t1,
        dateDelivered: t1,
      );
      final m2 = Message(
        guid: 'm2',
        text: 'Read latest',
        isFromMe: true,
        dateCreated: t2,
        dateDelivered: t2,
        dateRead: t2.add(const Duration(minutes: 1)),
      );

      await service.addNewMessage(m1);
      await service.addNewMessage(m2);

      final s1 = service.getMessageStateIfExists('m1')!;
      final s2 = service.getMessageStateIfExists('m2')!;
      expect(s1.showReadIndicator.value, isFalse);
      expect(s1.showDeliveredIndicator.value, isFalse);
      expect(s2.showReadIndicator.value, isTrue);
      expect(s2.showDeliveredIndicator.value, isFalse);
      expect(s2.showSentIndicator.value, isFalse);
    });

    test('latest sent-only keeps Sent indicator even if older outgoing message is delivered afterward', () async {
      final chat = Chat(guid: 'iMessage;-;+15550003');
      final service = _createService(chat);
      addTearDown(service.close);

      final t1 = DateTime(2026, 11, 19, 10, 0);
      final t2 = DateTime(2026, 11, 19, 10, 5);
      final m1 = Message(guid: 'm1', text: 'First sent', isFromMe: true, dateCreated: t1);
      final m2 = Message(guid: 'm2', text: 'Second sent', isFromMe: true, dateCreated: t2);

      await service.addNewMessage(m1);
      await service.addNewMessage(m2);

      expect(service.getMessageStateIfExists('m1')!.showSentIndicator.value, isFalse);
      expect(service.getMessageStateIfExists('m2')!.showSentIndicator.value, isTrue);

      // Older m1 receives delivery receipt after newer sent-only m2 already exists.
      service.updateMessage(Message(
        guid: 'm1',
        text: 'First sent',
        isFromMe: true,
        dateCreated: t1,
        dateDelivered: t2.add(const Duration(seconds: 10)),
      ));

      final s1 = service.getMessageStateIfExists('m1')!;
      final s2 = service.getMessageStateIfExists('m2')!;
      expect(s1.showDeliveredIndicator.value, isTrue);
      expect(s1.showSentIndicator.value, isFalse);
      expect(s2.showSentIndicator.value, isTrue);
    });

    test('errored, temp, and unsent outgoing messages do not steal Sent indicator', () async {
      final chat = Chat(guid: 'iMessage;-;+15550004');
      final service = _createService(chat);
      addTearDown(service.close);

      final t1 = DateTime(2026, 11, 19, 10, 0);
      final t2 = DateTime(2026, 11, 19, 10, 1);
      final t3 = DateTime(2026, 11, 19, 10, 2);
      final t4 = DateTime(2026, 11, 19, 10, 3);

      await service.addNewMessage(Message(guid: 'm1', text: 'Valid sent', isFromMe: true, dateCreated: t1));
      await service.addNewMessage(Message(guid: 'temp-2', text: 'Sending', isFromMe: true, dateCreated: t2));
      await service.addNewMessage(Message(guid: 'm3', text: 'Errored', isFromMe: true, dateCreated: t3, error: 4));
      await service.addNewMessage(Message(
        guid: 'm4',
        text: 'Unsent',
        isFromMe: true,
        dateCreated: t4,
        dateEdited: t4,
        messageSummaryInfo: [
          MessageSummaryInfo.fromJson({'retractedParts': [0]})
        ],
      ));

      expect(service.getMessageStateIfExists('m1')!.showSentIndicator.value, isTrue);
      expect(service.getMessageStateIfExists('temp-2')!.showSentIndicator.value, isFalse);
      expect(service.getMessageStateIfExists('m3')!.showSentIndicator.value, isFalse);
      expect(service.getMessageStateIfExists('m4')!.showSentIndicator.value, isFalse);
    });

    test('latest visible incoming message gets Received, ignoring tapbacks, group events, and unsent', () async {
      final chat = Chat(guid: 'iMessage;-;+15550005');
      final service = _createService(chat);
      addTearDown(service.close);

      final t1 = DateTime(2026, 11, 19, 10, 0);
      final t2 = DateTime(2026, 11, 19, 10, 1);
      final t3 = DateTime(2026, 11, 19, 10, 2);
      final t4 = DateTime(2026, 11, 19, 10, 3);
      final t5 = DateTime(2026, 11, 19, 10, 4);

      await service.addNewMessage(Message(guid: 'in-1', text: 'Earlier', isFromMe: false, dateCreated: t1));
      await service.addNewMessage(Message(guid: 'in-2', text: 'Latest visible', isFromMe: false, dateCreated: t2));
      await service.addNewMessage(Message(
        guid: 'tapback-1',
        isFromMe: false,
        dateCreated: t3,
        associatedMessageGuid: 'in-2',
        associatedMessageType: 'love',
      ));
      await service.addNewMessage(Message(
        guid: 'event-1',
        isFromMe: false,
        dateCreated: t4,
        itemType: 1,
        groupActionType: 0,
      ));
      await service.addNewMessage(Message(
        guid: 'unsent-in',
        text: 'Retracted',
        isFromMe: false,
        dateCreated: t5,
        dateEdited: t5,
        messageSummaryInfo: [
          MessageSummaryInfo.fromJson({'retractedParts': [0]})
        ],
      ));

      expect(service.getMessageStateIfExists('in-1')!.showReceivedIndicator.value, isFalse);
      expect(service.getMessageStateIfExists('in-2')!.showReceivedIndicator.value, isTrue);
      expect(service.getMessageStateIfExists('event-1')!.showReceivedIndicator.value, isFalse);
      expect(service.getMessageStateIfExists('unsent-in')!.showReceivedIndicator.value, isFalse);

      // Unsending the current Received owner falls back to the earlier visible incoming message.
      service.updateMessage(Message(
        guid: 'in-2',
        text: 'Latest visible',
        isFromMe: false,
        dateCreated: t2,
        dateEdited: t5,
        messageSummaryInfo: [
          MessageSummaryInfo.fromJson({'retractedParts': [0]})
        ],
      ));
      expect(service.getMessageStateIfExists('in-2')!.showReceivedIndicator.value, isFalse);
      expect(service.getMessageStateIfExists('in-1')!.showReceivedIndicator.value, isTrue);
    });

    test('temp->real GUID rename promotes Sent and preserves Delivered tracking', () async {
      final chat = Chat(guid: 'iMessage;-;+15550006');
      final service = _createService(chat);
      addTearDown(service.close);

      final t1 = DateTime(2026, 11, 19, 10, 0);
      final t2 = DateTime(2026, 11, 19, 10, 1);

      // Case 1: temp -> real sent-only promotion
      final tempMsg = Message(guid: 'temp-1', text: 'Hello', isFromMe: true, dateCreated: t1);
      await service.addNewMessage(tempMsg);
      expect(service.getMessageStateIfExists('temp-1')!.showSentIndicator.value, isFalse);

      service.updateMessage(
        Message(guid: 'real-1', text: 'Hello', isFromMe: true, dateCreated: t1),
        oldGuid: 'temp-1',
      );
      final real1State = service.getMessageStateIfExists('real-1')!;
      expect(real1State.showSentIndicator.value, isTrue);

      // Case 2: temp with early delivery receipt -> real rename keeps Delivered
      final tempDelivered = Message(
        guid: 'temp-2',
        text: 'Second',
        isFromMe: true,
        dateCreated: t2,
        dateDelivered: t2,
      );
      await service.addNewMessage(tempDelivered);
      expect(service.getMessageStateIfExists('temp-2')!.showDeliveredIndicator.value, isTrue);
      expect(real1State.showSentIndicator.value, isFalse);

      service.updateMessage(
        Message(
          guid: 'real-2',
          text: 'Second',
          isFromMe: true,
          dateCreated: t2,
          dateDelivered: t2,
        ),
        oldGuid: 'temp-2',
      );
      final real2State = service.getMessageStateIfExists('real-2')!;
      expect(real2State.showDeliveredIndicator.value, isTrue);
    });

    test('removeMessage recomputes indicators onto previous eligible messages', () async {
      final chat = Chat(guid: 'iMessage;-;+15550007');
      final service = _createService(chat);
      addTearDown(service.close);

      final t1 = DateTime(2026, 11, 19, 10, 0);
      final t2 = DateTime(2026, 11, 19, 10, 1);
      final in1 = Message(guid: 'in-1', text: 'In 1', isFromMe: false, dateCreated: t1);
      final in2 = Message(guid: 'in-2', text: 'In 2', isFromMe: false, dateCreated: t2);
      final out1 = Message(guid: 'out-1', text: 'Out 1', isFromMe: true, dateCreated: t1);
      final out2 = Message(guid: 'out-2', text: 'Out 2', isFromMe: true, dateCreated: t2);

      await service.addNewMessage(in1);
      await service.addNewMessage(in2);
      await service.addNewMessage(out1);
      await service.addNewMessage(out2);

      expect(service.getMessageStateIfExists('in-2')!.showReceivedIndicator.value, isTrue);
      expect(service.getMessageStateIfExists('out-2')!.showSentIndicator.value, isTrue);

      service.removeMessage(in2);
      service.removeMessage(out2);

      expect(service.getMessageStateIfExists('in-1')!.showReceivedIndicator.value, isTrue);
      expect(service.getMessageStateIfExists('out-1')!.showSentIndicator.value, isTrue);
    });
  });

  group('DeliveredIndicator detail text across Material, iOS, and Samsung skins', () {
    Widget wrapIndicator(MessageState state, {bool forceShow = false}) {
      return GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MessageStateScope(
          messageState: state,
          child: Scaffold(
            body: DeliveredIndicator(
              key: ValueKey('${state.message.guid}_$forceShow'),
              forceShow: forceShow,
            ),
          ),
        ),
      );
    }

    final t = DateTime(2026, 11, 19, 14, 20);

    for (final skin in [Skins.Material, Skins.iOS, Skins.Samsung]) {
      testWidgets('renders full detail text for all 4 tiers on $skin', (tester) async {
        settingsService.settings.skin.value = skin;
        settingsService.settings.showDeliveryTimestamps.value = false;
        final expectedTime = buildDate(t);

        final readState = MessageState(Message(
          guid: 'read-$skin',
          text: 'Read',
          isFromMe: true,
          dateCreated: t,
          dateDelivered: t,
          dateRead: t,
        ))
          ..showReadIndicator.value = true;
        await tester.pumpWidget(wrapIndicator(readState));
        await tester.pumpAndSettle();
        expect(find.textContaining('Read · $expectedTime', findRichText: true), findsOneWidget);
        if (skin == Skins.Material) {
          expect(find.bySemanticsLabel('Read'), findsOneWidget);
        }

        final deliveredState = MessageState(Message(
          guid: 'deliv-$skin',
          text: 'Delivered',
          isFromMe: true,
          dateCreated: t,
          dateDelivered: t,
          wasDeliveredQuietly: true,
        ))
          ..showDeliveredIndicator.value = true;
        await tester.pumpWidget(wrapIndicator(deliveredState));
        await tester.pumpAndSettle();
        expect(find.textContaining('Delivered Quietly · $expectedTime', findRichText: true), findsOneWidget);

        final sentState = MessageState(Message(
          guid: 'sent-$skin',
          text: 'Sent',
          isFromMe: true,
          dateCreated: t,
        ))
          ..showSentIndicator.value = true;
        await tester.pumpWidget(wrapIndicator(sentState));
        await tester.pumpAndSettle();
        expect(find.textContaining('Sent · $expectedTime', findRichText: true), findsOneWidget);

        final receivedState = MessageState(Message(
          guid: 'recv-$skin',
          text: 'Received',
          isFromMe: false,
          dateCreated: t,
        ))
          ..showReceivedIndicator.value = true;
        await tester.pumpWidget(wrapIndicator(receivedState));
        await tester.pumpAndSettle();
        expect(find.textContaining('Received · $expectedTime', findRichText: true), findsOneWidget);

        // Older inactive message remains hidden when forceShow is false, expands on tap (forceShow: true).
        receivedState.showReceivedIndicator.value = false;
        await tester.pumpWidget(wrapIndicator(receivedState, forceShow: false));
        await tester.pumpAndSettle();
        expect(find.textContaining('Received · $expectedTime', findRichText: true), findsNothing);

        await tester.pumpWidget(wrapIndicator(receivedState, forceShow: true));
        await tester.pumpAndSettle();
        expect(find.textContaining('Received · $expectedTime', findRichText: true), findsOneWidget);
      });

      testWidgets('renders Edited in place of status/received and toggles showEdits on tap ($skin)', (tester) async {
        settingsService.settings.skin.value = skin;
        settingsService.settings.showDeliveryTimestamps.value = false;

        final editedOutgoing = MessageState(Message(
          guid: 'edited-out-$skin',
          text: 'Updated text',
          isFromMe: true,
          dateCreated: t,
          dateDelivered: t,
          dateRead: t,
          dateEdited: t,
        ))
          ..parts.assignAll([
            MessagePart(
              part: 0,
              text: 'Updated text',
              edits: [MessagePart(part: 0, text: 'Original text')],
            ),
          ]);
        // Even with all receipt flags false, edited messages still show "Edited".
        await tester.pumpWidget(wrapIndicator(editedOutgoing));
        await tester.pumpAndSettle();
        expect(find.text('Edited', findRichText: true), findsOneWidget);
        expect(find.textContaining('Read', findRichText: true), findsNothing);
        expect(editedOutgoing.showEdits.value, isFalse);

        await tester.tap(find.text('Edited', findRichText: true));
        await tester.pump();
        expect(editedOutgoing.showEdits.value, isTrue);

        await tester.tap(find.text('Edited', findRichText: true));
        await tester.pump();
        expect(editedOutgoing.showEdits.value, isFalse);

        final editedIncoming = MessageState(Message(
          guid: 'edited-in-$skin',
          text: 'Incoming updated',
          isFromMe: false,
          dateCreated: t,
          dateEdited: t,
        ))
          ..showReceivedIndicator.value = true
          ..parts.assignAll([
            MessagePart(
              part: 0,
              text: 'Incoming updated',
              edits: [MessagePart(part: 0, text: 'Incoming original')],
            ),
          ]);
        await tester.pumpWidget(wrapIndicator(editedIncoming));
        await tester.pumpAndSettle();
        expect(find.text('Edited', findRichText: true), findsOneWidget);
        expect(find.textContaining('Received', findRichText: true), findsNothing);
      });
    }

    testWidgets('tapping Edited reveals ghost original without duplicate Edited label, and forceShow toggles Edited · time',
        (tester) async {
      settingsService.settings.skin.value = Skins.Material;
      settingsService.settings.showDeliveryTimestamps.value = false;

      final editedPart = MessagePart(
        part: 0,
        text: 'Updated text',
        edits: [MessagePart(part: 0, text: 'Original text')],
      );
      final state = MessageState(Message(
        guid: 'edited-history-toggle',
        text: 'Updated text',
        isFromMe: true,
        dateCreated: t,
        dateEdited: t,
      )..chat.target = Chat(guid: 'iMessage;-;+15550099'))
        ..parts.assignAll([editedPart]);

      Widget buildTree({required bool forceShow}) => GetMaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 15))],
            ),
            home: MessageStateScope(
              messageState: state,
              child: Scaffold(
                body: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    EditHistoryObserver(
                      part: editedPart,
                      newerMessage: null,
                      showAvatar: false,
                      alwaysShowAvatars: false,
                      avatarScale: 1.0,
                    ),
                    DeliveredIndicator(forceShow: forceShow),
                  ],
                ),
              ),
            ),
          );

      await tester.pumpWidget(buildTree(forceShow: false));
      await tester.pumpAndSettle();

      // Initially collapsed: only the DeliveredIndicator "Edited" label is shown (no timestamp).
      expect(find.textContaining('Original text', findRichText: true), findsNothing);
      expect(find.text('Edited', findRichText: true), findsOneWidget);
      expect(find.textContaining('·', findRichText: true), findsNothing);

      // Tap "Edited" -> reveals ghost original message with NO duplicate ghost "Edited" label.
      await tester.tap(find.text('Edited', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('Original text', findRichText: true), findsOneWidget);
      expect(find.text('Edited', findRichText: true), findsOneWidget);

      // Tap "Edited" again -> hides original message.
      await tester.tap(find.text('Edited', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('Original text', findRichText: true), findsNothing);
      expect(find.text('Edited', findRichText: true), findsOneWidget);

      // Tapping the message bubble toggles forceShow -> shows "Edited · <time>" in-place
      // without cross-fading a second "Edited" on top of the first.
      await tester.pumpWidget(buildTree(forceShow: true));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.descendant(of: find.byType(DeliveredIndicator), matching: find.byType(Text)), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.textContaining('Edited · ', findRichText: true), findsOneWidget);

      await tester.pumpWidget(buildTree(forceShow: false));
      await tester.pumpAndSettle();
      expect(find.text('Edited', findRichText: true), findsOneWidget);
      expect(find.textContaining('·', findRichText: true), findsNothing);
    });
  });

  group('Realtime relative-timestamp ticker (Google Messages parity)', () {
    Widget wrapIndicator(
      MessageState state, {
      bool forceShow = false,
      bool tickerEnabled = true,
    }) {
      return GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: TickerMode(
          enabled: tickerEnabled,
          child: MessageStateScope(
            messageState: state,
            child: Scaffold(
              body: DeliveredIndicator(
                key: ValueKey('${state.message.guid}_$forceShow'),
                forceShow: forceShow,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('Delivered Quietly · 47 min ticks to 48 min on exact minute boundary', (tester) async {
      settingsService.settings.skin.value = Skins.Material;
      settingsService.settings.showDeliveryTimestamps.value = false;

      final tDelivered = clock.now().subtract(const Duration(minutes: 47, seconds: 15));
      final state = MessageState(Message(
        guid: 'quiet-47',
        text: 'Quiet',
        isFromMe: true,
        dateCreated: tDelivered,
        dateDelivered: tDelivered,
        wasDeliveredQuietly: true,
      ))
        ..showDeliveredIndicator.value = true;

      await tester.pumpWidget(wrapIndicator(state));
      await tester.pumpAndSettle();
      expect(find.textContaining('Delivered Quietly · 47 min', findRichText: true), findsOneWidget);

      // 44s later -> 47m59s elapsed, still 47 min.
      await tester.pump(const Duration(seconds: 44));
      expect(find.textContaining('Delivered Quietly · 47 min', findRichText: true), findsOneWidget);

      // +1s -> 48m00s elapsed, ticks on exact minute boundary.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('Delivered Quietly · 48 min', findRichText: true), findsOneWidget);
    });

    testWidgets('transitions Now -> 1 min -> ... -> 59 min -> absolute time and cancels timer', (tester) async {
      settingsService.settings.skin.value = Skins.Material;
      settingsService.settings.showDeliveryTimestamps.value = false;

      final tRead = clock.now();
      final state = MessageState(Message(
        guid: 'read-full-cycle',
        text: 'Read now',
        isFromMe: true,
        dateCreated: tRead,
        dateDelivered: tRead,
        dateRead: tRead,
      ))
        ..showReadIndicator.value = true;

      await tester.pumpWidget(wrapIndicator(state));
      await tester.pumpAndSettle();
      expect(find.textContaining('Read · Now', findRichText: true), findsOneWidget);

      await tester.pump(const Duration(seconds: 59));
      expect(find.textContaining('Read · Now', findRichText: true), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('Read · 1 min', findRichText: true), findsOneWidget);

      for (int m = 2; m < 60; m++) {
        await tester.pump(const Duration(minutes: 1));
        await tester.pump();
        expect(find.textContaining('Read · $m min', findRichText: true), findsOneWidget);
      }

      // Crossing 60 min switches to absolute time and stops scheduling timers.
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      final absoluteLabel = buildDate(tRead, now: tRead.add(const Duration(minutes: 60)));
      expect(absoluteLabel, isNot('60 min'));
      expect(find.textContaining('Read · $absoluteLabel', findRichText: true), findsOneWidget);
      expect(
        nextRelativeTimestampTickDelay(tRead, now: clock.now(), skin: Skins.Material),
        isNull,
      );

      // Verify RelativeTimestampTicker stops scheduling once absolute (>= 60 min).
      int ticks = 0;
      final ticker = RelativeTimestampTicker(onTick: () => ticks++);
      addTearDown(ticker.dispose);
      ticker.sync(tRead.add(const Duration(minutes: 1)), isRelative: true);
      expect(ticker.isTimerActive, isTrue); // 59 min -> 1 min left
      await tester.pump(const Duration(minutes: 1));
      expect(ticks, 1);
      expect(ticker.isTimerActive, isFalse); // now 60 min -> timer cancelled
      await tester.pump(const Duration(minutes: 10));
      expect(ticks, 1);
    });

    testWidgets('pauses in background and hidden TickerMode, then refreshes immediately on resume', (tester) async {
      settingsService.settings.skin.value = Skins.Material;
      settingsService.settings.showDeliveryTimestamps.value = false;

      final tDelivered = clock.now().subtract(const Duration(minutes: 47));
      final state = MessageState(Message(
        guid: 'bg-pause',
        text: 'Delivered',
        isFromMe: true,
        dateCreated: tDelivered,
        dateDelivered: tDelivered,
      ))
        ..showDeliveredIndicator.value = true;

      int tickerTicks = 0;
      final ticker = RelativeTimestampTicker(onTick: () => tickerTicks++);
      addTearDown(ticker.dispose);
      ticker.sync(tDelivered, isRelative: true);
      expect(ticker.isTimerActive, isTrue);

      await tester.pumpWidget(wrapIndicator(state));
      await tester.pumpAndSettle();
      expect(find.textContaining('Delivered · 47 min', findRichText: true), findsOneWidget);

      // Background app -> timer is cancelled and stays at 47 min across 5 minutes.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(ticker.isTimerActive, isFalse);

      await tester.pump(const Duration(minutes: 5));
      expect(tickerTicks, 0);
      expect(find.textContaining('Delivered · 47 min', findRichText: true), findsOneWidget);

      // Foreground resume -> immediate refresh to 52 min and resumes minute ticking.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tickerTicks, 1);
      expect(ticker.isTimerActive, isTrue);
      expect(find.textContaining('Delivered · 52 min', findRichText: true), findsOneWidget);

      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(tickerTicks, 2);
      expect(find.textContaining('Delivered · 53 min', findRichText: true), findsOneWidget);

      // Hidden tab (TickerMode disabled) pauses timer; re-enabling refreshes immediately.
      await tester.pumpWidget(wrapIndicator(state, tickerEnabled: false));
      await tester.pump();
      await tester.pump(const Duration(minutes: 3));
      expect(find.textContaining('Delivered · 53 min', findRichText: true), findsOneWidget);

      await tester.pumpWidget(wrapIndicator(state, tickerEnabled: true));
      await tester.pump();
      expect(find.textContaining('Delivered · 56 min', findRichText: true), findsOneWidget);

      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(find.textContaining('Delivered · 57 min', findRichText: true), findsOneWidget);
    });

    testWidgets('future/clock-skew timestamp (+5 min) shows Now and schedules tick at target + 1 min', (tester) async {
      settingsService.settings.skin.value = Skins.Material;
      settingsService.settings.showDeliveryTimestamps.value = false;

      final now = clock.now();
      final futureTarget = now.add(const Duration(minutes: 5));
      expect(buildDate(futureTarget, now: now), 'Now');
      expect(buildChatListDateMaterial(futureTarget, now: now), 'Now');
      expect(
        nextRelativeTimestampTickDelay(futureTarget, now: now, skin: Skins.Material),
        const Duration(minutes: 6),
      );

      final state = MessageState(Message(
        guid: 'future-skew',
        text: 'Ahead clock',
        isFromMe: true,
        dateCreated: futureTarget,
        dateDelivered: futureTarget,
      ))
        ..showDeliveredIndicator.value = true;

      await tester.pumpWidget(wrapIndicator(state));
      await tester.pumpAndSettle();
      expect(find.textContaining('Delivered · Now', findRichText: true), findsOneWidget);

      await tester.pump(const Duration(minutes: 5, seconds: 59));
      expect(find.textContaining('Delivered · Now', findRichText: true), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('Delivered · 1 min', findRichText: true), findsOneWidget);
    });
  });
}
