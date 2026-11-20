import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/html/attachment.dart';
import 'package:bluebubbles/database/html/chat.dart';
import 'package:bluebubbles/database/html/contact_v2.dart';
import 'package:bluebubbles/database/html/custom_group.dart';
import 'package:bluebubbles/database/html/fcm_data.dart';
import 'package:bluebubbles/database/html/handle.dart';
import 'package:bluebubbles/database/html/idb_persistence.dart';
import 'package:bluebubbles/database/html/message.dart';
import 'package:bluebubbles/database/html/objectbox.dart';
import 'package:bluebubbles/database/html/theme.dart';
import 'package:bluebubbles/database/html/theme_entry.dart';
import 'package:bluebubbles/database/html/theme_object.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart' show IdbFactory, newIdbFactoryMemory;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Web ObjectBox + IDB Persistence Engine', () {
    late IdbFactory memoryFactory;
    late String dbName;
    late Store store;
    int testCounter = 0;

    setUp(() async {
      testCounter++;
      memoryFactory = newIdbFactoryMemory();
      dbName = 'test_bluebubbles_store_$testCounter';
      store = await openStore(
        idbFactory: memoryFactory,
        dbName: dbName,
      );
    });

    tearDown(() async {
      await store.close(flushPending: false);
    });

    test('Box CRUD, unique violation, and secondary index eviction on update', () {
      final chats = store.box<Chat>();
      final handles = store.box<Handle>();

      final h1 = Handle(address: '+15551112222', service: 'iMessage', originalROWID: 10);
      final h1Id = handles.put(h1);
      expect(h1Id, greaterThan(0));
      expect(handles.get(h1Id)?.address, '+15551112222');

      // Duplicate uniqueAddressAndService throws UniqueViolationException
      expect(
        () => handles.put(Handle(address: '+15551112222', service: 'iMessage')),
        throwsA(isA<UniqueViolationException>()),
      );

      // PutMode.insert fails if id already exists; PutMode.update requires existing id
      expect(
        () => handles.put(h1, mode: PutMode.insert),
        throwsA(isA<UniqueViolationException>()),
      );
      expect(
        () => handles.put(Handle(id: 9999, address: '+15550000000'), mode: PutMode.update),
        throwsA(isA<ObjectBoxException>()),
      );

      final chat = Chat(guid: 'iMessage;-;+15551112222', displayName: 'Initial Name');
      final chatId = chats.put(chat);
      expect(chats.count(), 1);
      expect(chats.contains(chatId), isTrue);

      // Update unique guid in-place and confirm old guid index key is evicted
      chat.guid = 'iMessage;-;+15553334444';
      chat.displayName = 'Renamed';
      chats.put(chat);

      final oldQuery = chats.query(Chat_.guid.equals('iMessage;-;+15551112222')).build();
      expect(oldQuery.find(), isEmpty);
      oldQuery.close();

      final newQuery = chats.query(Chat_.guid.equals('iMessage;-;+15553334444')).build();
      expect(newQuery.findFirst()?.displayName, 'Renamed');
      newQuery.close();

      // Re-using the freed old guid now succeeds
      final chat2Id = chats.put(Chat(guid: 'iMessage;-;+15551112222'));
      expect(chats.getMany([chatId, chat2Id]).whereType<Chat>().length, 2);

      // Remove and removeMany
      expect(chats.remove(chat2Id), isTrue);
      expect(chats.remove(chat2Id), isFalse);
      expect(chats.count(), 1);
      expect(chats.removeMany([chatId, 99999]), 1);
      expect(chats.count(), 0);
    });

    test('All 12+ query operators, compound logic, order, limit/offset, param, and PropertyQuery', () async {
      final messages = store.box<Message>();
      final now = DateTime.utc(2026, 1, 1, 12, 0, 0);

      messages.putMany([
        Message(
          guid: 'm-1',
          originalROWID: 10,
          text: 'Alpha Beta',
          isFromMe: true,
          dateCreated: now.add(const Duration(minutes: 1)),
          handleId: 1,
        ),
        Message(
          guid: 'm-2',
          originalROWID: 20,
          text: 'alpha gamma',
          isFromMe: false,
          dateCreated: now.add(const Duration(minutes: 2)),
          handleId: 2,
        ),
        Message(
          guid: 'm-3',
          originalROWID: 30,
          text: 'Delta',
          isFromMe: true,
          dateCreated: now.add(const Duration(minutes: 3)),
          handleId: 2,
        ),
        Message(
          guid: 'm-4',
          originalROWID: 40,
          text: null,
          isFromMe: false,
          dateCreated: now.add(const Duration(minutes: 4)),
          handleId: null,
        ),
      ]);

      // equals (caseSensitive false vs true)
      final eqInsensitive = messages.query(Message_.text.equals('alpha beta', caseSensitive: false)).build();
      expect(eqInsensitive.find().map((m) => m.guid), ['m-1']);
      eqInsensitive.close();

      final eqSensitive = messages.query(Message_.text.equals('alpha beta', caseSensitive: true)).build();
      expect(eqSensitive.find(), isEmpty);
      eqSensitive.close();

      // notEquals (including secondary-indexed guid so index fast-path doesn't misfire)
      final neqGuid = messages.query(Message_.guid.notEquals('m-1')).build();
      expect(neqGuid.find().length, 3);
      neqGuid.close();

      final neqRowId = messages.query(Message_.originalROWID.notEquals(20)).build();
      expect(neqRowId.find().map((m) => m.guid), containsAll(['m-1', 'm-3']));
      neqRowId.close();

      // lessThan / lessOrEqual / greaterThan / greaterOrEqual / between
      final lt = messages.query(Message_.originalROWID.lessThan(20)).build();
      expect(lt.find().map((m) => m.guid), ['m-1']);
      lt.close();

      final lte = messages.query(Message_.originalROWID.lessOrEqual(20)).build();
      expect(lte.find().map((m) => m.guid), ['m-1', 'm-2']);
      lte.close();

      final gt = messages.query(Message_.originalROWID.greaterThan(20)).build();
      expect(gt.find().map((m) => m.guid), ['m-3', 'm-4']);
      gt.close();

      final gte = messages.query(Message_.originalROWID.greaterOrEqual(30)).build();
      expect(gte.find().map((m) => m.guid), ['m-3', 'm-4']);
      gte.close();

      final between = messages.query(Message_.originalROWID.between(15, 35)).build();
      expect(between.find().map((m) => m.guid), ['m-2', 'm-3']);
      between.close();

      // oneOf / notOneOf (int & string)
      final oneOf = messages.query(Message_.guid.oneOf(['m-2', 'm-4'])).build();
      expect(oneOf.find().map((m) => m.guid), ['m-2', 'm-4']);
      oneOf.close();

      final notOneOf = messages.query(Message_.originalROWID.notOneOf([10, 40])).build();
      expect(notOneOf.find().map((m) => m.guid), ['m-2', 'm-3']);
      notOneOf.close();

      // isNull / notNull
      final isNullQ = messages.query(Message_.text.isNull()).build();
      expect(isNullQ.find().map((m) => m.guid), ['m-4']);
      isNullQ.close();

      final notNullQ = messages.query(Message_.text.notNull()).build();
      expect(notNullQ.count(), 3);
      notNullQ.close();

      // contains / startsWith / endsWith
      final containsQ = messages.query(Message_.text.contains('ALPHA', caseSensitive: false)).build();
      expect(containsQ.find().map((m) => m.guid), ['m-1', 'm-2']);
      containsQ.close();

      final startsQ = messages.query(Message_.text.startsWith('Alpha', caseSensitive: true)).build();
      expect(startsQ.find().map((m) => m.guid), ['m-1']);
      startsQ.close();

      final endsQ = messages.query(Message_.text.endsWith('gamma', caseSensitive: false)).build();
      expect(endsQ.find().map((m) => m.guid), ['m-2']);
      endsQ.close();

      // Compound AND (&) & OR (|), order, offset, limit, findAsync, findIdsAsync
      final compound = (messages.query(
        (Message_.isFromMe.equals(true) & Message_.originalROWID.greaterThan(10)) |
            Message_.guid.equals('m-4'),
      )..order(Message_.dateCreated, flags: Order.descending))
          .build();
      compound.offset = 0;
      compound.limit = 1;
      expect(compound.findFirst()?.guid, 'm-4');
      compound.offset = 1;
      compound.limit = 5;
      expect((await compound.findAsync()).map((m) => m.guid), ['m-3']);
      expect((await compound.findIdsAsync()).length, 1);
      compound.close();

      // QueryParam re-evaluation
      final paramQuery = messages.query(Message_.guid.equals('')).build();
      final p = paramQuery.param(Message_.guid);
      p.value = 'm-2';
      expect(paramQuery.findFirst()?.originalROWID, 20);
      p.value = 'm-3';
      expect(paramQuery.findFirst()?.originalROWID, 30);
      paramQuery.close();

      // PropertyQuery distinct & count
      final propQ = messages.query(Message_.originalROWID.notNull()).build();
      final pq = propQ.property(Message_.originalROWID);
      expect(pq.find(), [10, 20, 30, 40]);
      expect(pq.count(), 4);

      final handlePropQ = messages.query(Message_.handleId.notNull()).build();
      final hpq = handlePropQ.property(Message_.handleId)..distinct = true;
      expect(hpq.find(), [1, 2]);
      handlePropQ.close();
      propQ.close();
    });

    test('ToOne, bidirectional @Backlink ToMany, link/backlink queries, and stream watch()', () async {
      final chats = store.box<Chat>();
      final handles = store.box<Handle>();
      final messages = store.box<Message>();
      final attachments = store.box<Attachment>();

      final h1 = Handle(address: 'alice@example.com', service: 'iMessage', originalROWID: 101);
      final h2 = Handle(address: 'bob@example.com', service: 'iMessage', originalROWID: 102);
      handles.putMany([h1, h2]);

      final chat = Chat(guid: 'iMessage;+;chat123', displayName: 'Group');
      chats.put(chat);
      chat.handles.addAll([h1, h2]);
      chat.handles.applyToDb();

      // Verify backlinkMany query on Chat_.handles
      final chatsForH1 = (chats.query()..linkMany(Chat_.handles, Handle_.address.equals('alice@example.com'))).build();
      expect(chatsForH1.find().map((c) => c.guid), ['iMessage;+;chat123']);
      chatsForH1.close();

      final m1 = Message(guid: 'msg-1', text: 'with file', dateCreated: DateTime.utc(2026, 1, 2));
      m1.chat.target = chat;
      m1.handleRelation.target = h1;
      messages.put(m1);

      final att = Attachment(guid: 'att-1', mimeType: 'image/png', transferName: 'pic.png', totalBytes: 42);
      att.message.target = m1;
      attachments.put(att);

      expect(chat.messages.length, 1);
      expect(chat.messages.first.guid, 'msg-1');
      expect(m1.dbAttachments.length, 1);
      expect(m1.dbAttachments.first.guid, 'att-1');

      // Link query: attachments whose message belongs to chat
      final attLinkBuilder = attachments.query(Attachment_.mimeType.equals('image/png'));
      attLinkBuilder.link(Attachment_.message, Message_.guid.equals('msg-1'));
      final attLinkQ = attLinkBuilder.build();
      expect(attLinkQ.find().map((a) => a.guid), ['att-1']);
      attLinkQ.close();

      // Backlink query: chats that have a message with text containing 'file'
      final chatBacklinkBuilder = chats.query();
      chatBacklinkBuilder.backlink(Message_.chat, Message_.text.contains('file'));
      final chatBacklinkQ = chatBacklinkBuilder.build();
      expect(chatBacklinkQ.find().map((c) => c.guid), ['iMessage;+;chat123']);
      chatBacklinkQ.close();

      // Watch emits once immediately and once per committed transaction
      final emissions = <int>[];
      final watchBuilder = messages.query()..order(Message_.id);
      final sub = watchBuilder.watch(triggerImmediately: true).listen((q) {
        emissions.add(q.count());
      });
      await Future<void>.delayed(Duration.zero);
      expect(emissions, [1]);

      store.runInTransaction(TxMode.write, () {
        final m2 = Message(guid: 'msg-2', text: 'tx-1')..chat.target = chat;
        final m3 = Message(guid: 'msg-3', text: 'tx-2')..chat.target = chat;
        messages.putMany([m2, m3]);
      });
      await Future<void>.delayed(Duration.zero);
      expect(emissions, [1, 3]);

      await sub.cancel();
    });

    test('Transaction rollback restores RAM, secondary indexes, and suppresses IDB write', () async {
      final chats = store.box<Chat>();
      final base = Chat(guid: 'chat-keep', displayName: 'Original');
      chats.put(base);
      await store.flush();

      expect(
        () => store.runInTransaction(TxMode.write, () {
          base.displayName = 'Mutated';
          chats.put(base);
          chats.put(Chat(guid: 'chat-rolled-back', displayName: 'Gone'));
          throw StateError('abort tx');
        }),
        throwsStateError,
      );

      expect(chats.count(), 1);
      expect(chats.get(base.id!)?.displayName, 'Original');
      final rolledQ = chats.query(Chat_.guid.equals('chat-rolled-back')).build();
      expect(rolledQ.find(), isEmpty);
      rolledQ.close();

      await store.flush();
      await store.close(flushPending: false);

      final reopened = await openStore(idbFactory: memoryFactory, dbName: dbName);
      expect(reopened.box<Chat>().count(), 1);
      expect(reopened.box<Chat>().get(base.id!)?.displayName, 'Original');
      await reopened.close(flushPending: false);
    });

    test('Full IDB persistence round-trip across all 10 stores and clearPersistence()', () async {
      final handle = Handle(
        originalROWID: 77,
        address: '+15559990000',
        service: 'iMessage',
        defaultEmail: 'test@example.com',
        color: '#FF0000',
      );
      store.box<Handle>().put(handle);

      final contact = ContactV2(
        displayName: 'Test Contact',
        nativeContactId: 'native-1',
        namePrefix: 'Dr',
        firstName: 'Test',
        lastName: 'User',
        addresses: ['+15559990000', 'test@example.com'],
      );
      store.box<ContactV2>().put(contact);

      final chat = Chat(
        guid: 'iMessage;-;+15559990000',
        chatIdentifier: '+15559990000',
        displayName: 'Direct',
        isArchived: true,
        hasUnreadMessage: true,
        customAvatar: '/avatars/1.png',
      )..dbOnlyLatestMessageDate = DateTime(2026, 2, 1, 10, 30);
      store.box<Chat>().put(chat);
      chat.handles.add(handle);
      chat.handles.applyToDb();

      final msg = Message(
        guid: 'msg-persist-1',
        originalROWID: 500,
        text: 'Hello IDB',
        isFromMe: true,
        hasEffectPlayed: true,
        isDelievered: true,
        dateCreated: DateTime(2026, 2, 1, 10, 30),
        handleId: 77,
      )..bigEmoji = true;
      msg.chat.target = chat;
      msg.handleRelation.target = handle;
      store.box<Message>().put(msg);

      final att = Attachment(
        guid: 'att-persist-1',
        mimeType: 'image/jpeg',
        transferName: 'photo.jpg',
        totalBytes: 1234,
        hasLivePhoto: true,
      );
      att.message.target = msg;
      store.box<Attachment>().put(att);

      final group = CustomGroup(
        name: 'Favorites',
        sortOrder: 2,
        showUnreadBadge: true,
      )..chats.add(chat);
      store.box<CustomGroup>().put(group);
      group.chats.applyToDb();

      final fcm = FCMData(
        projectID: 'proj-1',
        storageBucket: 'bucket-1',
        apiKey: 'key-1',
        firebaseURL: 'https://example.firebaseio.com',
        clientID: 'client-1',
        applicationID: 'app-1',
      );
      store.box<FCMData>().put(fcm);

      final themeStruct = ThemeStruct(
        name: 'Custom Neon',
        gradientBg: true,
        googleFont: 'Default',
      );
      store.box<ThemeStruct>().put(themeStruct);

      final themeObj = ThemeObject(name: 'Legacy Theme', selectedDarkTheme: true);
      store.box<ThemeObject>().put(themeObj);

      final themeEntry = ThemeEntry(name: 'primary', color: const Color(0xFF112233), isFont: false);
      themeEntry.themeObject.target = themeObj;
      store.box<ThemeEntry>().put(themeEntry);

      await store.flush();
      expect(IdbPersistence.active, isNotNull);
      await IdbPersistence.flushActive();
      await store.close(flushPending: false);

      // Reopen a brand new Store backed by the same idbFactoryMemory
      final hydrated = await openStore(idbFactory: memoryFactory, dbName: dbName);
      expect(hydrated.box<Handle>().count(), 1);
      expect(hydrated.box<ContactV2>().count(), 1);
      expect(hydrated.box<Chat>().count(), 1);
      expect(hydrated.box<Message>().count(), 1);
      expect(hydrated.box<Attachment>().count(), 1);
      expect(hydrated.box<CustomGroup>().count(), 1);
      expect(hydrated.box<FCMData>().count(), 1);
      expect(hydrated.box<ThemeStruct>().count(), 1);
      expect(hydrated.box<ThemeObject>().count(), 1);
      expect(hydrated.box<ThemeEntry>().count(), 1);

      final rChat = hydrated.box<Chat>().getAll().single;
      expect(rChat.isArchived, isTrue);
      expect(rChat.hasUnreadMessage, isTrue);
      expect(rChat.dbOnlyLatestMessageDate, DateTime(2026, 2, 1, 10, 30));
      expect(rChat.dbOnlyLatestMessageDate?.isUtc, isFalse);
      expect(rChat.handles.map((h) => h.address), ['+15559990000']);
      expect(rChat.messages.map((m) => m.guid), ['msg-persist-1']);

      final rMsg = hydrated.box<Message>().getAll().single;
      expect(rMsg.hasEffectPlayed, isTrue);
      expect(rMsg.bigEmoji, isTrue);
      expect(rMsg.isDelivered, isTrue);
      expect(rMsg.handleRelation.target?.address, '+15559990000');
      expect(rMsg.dbAttachments.map((a) => a.guid), ['att-persist-1']);

      final rGroup = hydrated.box<CustomGroup>().getAll().single;
      expect(rGroup.name, 'Favorites');
      expect(rGroup.chats.map((c) => c.guid), ['iMessage;-;+15559990000']);

      final rTheme = hydrated.box<ThemeStruct>().getAll().single;
      expect(rTheme.googleFont, 'Default');
      expect(rTheme.gradientBg, isTrue);

      final rObj = hydrated.box<ThemeObject>().getAll().single;
      expect(rObj.themeEntries.length, 1);
      expect(rObj.themeEntries.first.color?.toARGB32(), 0xFF112233);

      // HtmlDatabase static accessors also work against active store
      expect(HtmlDatabase.chats.count(), 1);
      expect(Chat.findOne(guid: 'iMessage;-;+15559990000')?.displayName, 'Direct');
      expect(Message.findOne(guid: 'msg-persist-1')?.text, 'Hello IDB');

      // clearPersistence wipes RAM + IDB
      await hydrated.clearPersistence();
      expect(hydrated.box<Chat>().count(), 0);
      expect(hydrated.box<Message>().count(), 0);
      await hydrated.close(flushPending: false);

      final afterClear = await openStore(idbFactory: memoryFactory, dbName: dbName);
      expect(afterClear.box<Chat>().count(), 0);
      expect(afterClear.box<Message>().count(), 0);
      await afterClear.close(flushPending: false);

      // Native VM Database hooks are safe no-ops
      await Database.flushWebPersistence();
      await Database.clearWebPersistence();
    });

    test('Round-1 regressions: removeAll indexes, unique keys, pre-attach ToMany, deleted ToOne, watch pause/resume, secondary openStore', () async {
      // #2: Box.removeAll() clears reverse secondary/unique maps
      final handles = store.box<Handle>();
      final h1 = Handle(address: '+15550001111', service: 'iMessage');
      handles.put(h1);
      expect(handles.removeAll(), 1);
      final h1Reinserted = Handle(address: '+15550001111', service: 'iMessage');
      final newId = handles.put(h1Reinserted);
      expect(handles.query(Handle_.uniqueAddressAndService.equals('+15550001111/iMessage')).build().findFirst()?.id, newId);

      // #3: @Unique() enforcement on ContactV2, CustomGroup, ThemeStruct, ThemeObject
      final contacts = store.box<ContactV2>();
      contacts.put(ContactV2(displayName: 'A', nativeContactId: 'dup-contact'));
      expect(
        () => contacts.put(ContactV2(displayName: 'B', nativeContactId: 'dup-contact')),
        throwsA(isA<UniqueViolationException>()),
      );

      final groups = store.box<CustomGroup>();
      groups.put(CustomGroup(name: 'VIP'));
      expect(
        () => groups.put(CustomGroup(name: 'VIP')),
        throwsA(isA<UniqueViolationException>()),
      );

      final themes = store.box<ThemeStruct>();
      themes.put(ThemeStruct(name: 'Solarized', googleFont: 'Default'));
      expect(
        () => themes.put(ThemeStruct(name: 'Solarized', googleFont: 'Default')),
        throwsA(isA<UniqueViolationException>()),
      );

      final themeObjs = store.box<ThemeObject>();
      themeObjs.put(ThemeObject(name: 'LegacyUnique'));
      expect(
        () => themeObjs.put(ThemeObject(name: 'LegacyUnique')),
        throwsA(isA<UniqueViolationException>()),
      );

      // #4: Pre-attach ToMany backlink modifications are preserved across put()
      final chats = store.box<Chat>();
      final messages = store.box<Message>();
      final mPre = Message(guid: 'pre-attach-msg', text: 'before put');
      final cPre = Chat(guid: 'iMessage;-;pre-attach');
      cPre.messages.add(mPre);
      chats.put(cPre);
      expect(mPre.chat.targetId, cPre.id);
      expect(cPre.messages.map((m) => m.guid), ['pre-attach-msg']);
      expect(messages.get(mPre.id!)?.chat.targetId, cPre.id);

      // #5: ToOne.target returns null once the target entity is deleted
      final mRef = Message(guid: 'ref-msg', text: 'refs chat');
      mRef.chat.target = cPre;
      messages.put(mRef);
      expect(mRef.chat.target?.guid, 'iMessage;-;pre-attach');
      chats.remove(cPre.id!);
      expect(mRef.chat.target, isNull);

      // #6: QueryBuilder.watch() pause + resume continues emitting without re-subscribing
      var emissions = 0;
      final sub = chats
          .query()
          .watch(triggerImmediately: true)
          .listen((_) => emissions++);
      await Future<void>.delayed(Duration.zero);
      expect(emissions, 1);
      sub.pause();
      chats.put(Chat(guid: 'iMessage;-;while-paused'));
      await Future<void>.delayed(Duration.zero);
      sub.resume();
      chats.put(Chat(guid: 'iMessage;-;after-resume'));
      await Future<void>.delayed(Duration.zero);
      expect(emissions, greaterThanOrEqualTo(2));
      await sub.cancel();

      // #8: openStore(registerAsActive: false) does not clobber active store's clear hook
      final secondary = await openStore(
        idbFactory: memoryFactory,
        dbName: '${dbName}_secondary',
        registerAsActive: false,
      );
      secondary.box<Chat>().put(Chat(guid: 'iMessage;-;secondary-chat'));
      expect(chats.count(), greaterThan(0));
      expect(secondary.box<Chat>().count(), 1);
      await IdbPersistence.clearActive();
      expect(chats.count(), 0);
      expect(secondary.box<Chat>().count(), 1);
      await secondary.close(flushPending: false);

      // #1: Store static/factory stubs compile & behave sensibly
      expect(Store.isOpen(null), isTrue);
      expect(() => Store.attach(null, null), throwsUnsupportedError);
    });

    test('empty-string secondary index query and message persist before afterPut', () async {
      final chats = store.box<Chat>();
      final messages = store.box<Message>();
      final attachments = store.box<Attachment>();

      // Secondary-index equality query on '' must still find items with empty guid.
      final emptyGuidChat = Chat(guid: '');
      chats.put(emptyGuidChat);
      final q = chats.query(Chat_.guid.equals('')).build();
      expect(q.find().map((c) => c.id), contains(emptyGuidChat.id));
      q.close();

      // Seed an existing attachment so a conflicting explicit id + duplicate guid in afterPut throws UniqueViolationException.
      attachments.put(Attachment(guid: 'dup-att-1'));
      final msg = Message(guid: 'msg-persist-before-afterput', text: 'hello');
      msg.dbAttachments.add(Attachment(id: 99999, guid: 'dup-att-1'));
      expect(() => messages.put(msg), throwsA(isA<UniqueViolationException>()));

      // Message must still have been enqueued for persistence and survive reload.
      await store.flush();
      final reopened = await openStore(idbFactory: memoryFactory, dbName: dbName);
      final reloaded = reopened.box<Message>().query(Message_.guid.equals('msg-persist-before-afterput')).build().findFirst();
      expect(reloaded?.text, 'hello');
      await reopened.close(flushPending: false);
    });

    test('multi-chat sync reuses existing unique entities on un-IDd ToOne/ToMany/Backlink relations', () async {
      final handles = store.box<Handle>();
      final chats = store.box<Chat>();
      final messages = store.box<Message>();
      final attachments = store.box<Attachment>();

      final chat1 = Chat.fromMap({
        'guid': 'any;-;+19499980689',
        'chatIdentifier': '+19499980689',
        'participants': [
          {'originalROWID': 30, 'address': '+19499980689', 'service': 'iMessage'},
        ],
        'lastMessage': {
          'guid': 'msg-sync-1',
          'originalROWID': 101,
          'text': 'Hey there',
          'isFromMe': false,
          'dateCreated': DateTime(2026, 3, 1, 12, 0).millisecondsSinceEpoch,
          'handle': {'originalROWID': 30, 'address': '+19499980689', 'service': 'iMessage'},
          'attachments': [
            {'guid': 'att-sync-1', 'transferName': 'pic.jpg', 'mimeType': 'image/jpeg'},
          ],
        },
      });
      final chat2 = Chat.fromMap({
        'guid': 'any;+;group-with-shared-handle',
        'chatIdentifier': 'chat12345',
        'participants': [
          {'originalROWID': 30, 'address': '+19499980689', 'service': 'iMessage'},
          {'originalROWID': 31, 'address': '+15550001111', 'service': 'iMessage'},
        ],
      });

      // Mirror ChatActions.bulkSyncChats: persist deduplicated participant handles first, then putMany(chats).
      handles.putMany([chat1.participants.first, chat2.participants.last]);
      chats.putMany([chat1, chat2]);

      expect(handles.count(), 2);
      expect(chats.count(), 2);
      expect(messages.count(), 1);
      expect(attachments.count(), 1);
      expect(chat1.handles.map((h) => h.address), ['+19499980689']);
      expect(chat2.handles.map((h) => h.address).toSet(), {'+19499980689', '+15550001111'});

      // Re-syncing the same message & attachment via Message.fromMap updates in place without UniqueViolationException.
      final resynced = Message.fromMap({
        'guid': 'msg-sync-1',
        'originalROWID': 101,
        'text': 'Hey there',
        'isFromMe': false,
        'dateCreated': DateTime(2026, 3, 1, 12, 0).millisecondsSinceEpoch,
        'handle': {'originalROWID': 30, 'address': '+19499980689', 'service': 'iMessage'},
        'attachments': [
          {'guid': 'att-sync-1', 'transferName': 'pic.jpg', 'mimeType': 'image/jpeg'},
        ],
      });
      resynced.id = messages.query(Message_.guid.equals('msg-sync-1')).build().findFirst()!.id;
      resynced.chat.target = chat1;
      resynced.handleRelation.target = Handle(originalROWID: 30, address: '+19499980689', service: 'iMessage');
      messages.put(resynced);

      expect(handles.count(), 2);
      expect(messages.count(), 1);
      expect(attachments.count(), 1);
      expect(attachments.getAll().single.message.targetId, resynced.id);
    });
  });
}
