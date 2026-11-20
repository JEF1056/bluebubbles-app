import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/database/html/idb_persistence.dart';
import 'package:bluebubbles/database/html/web_tab_lock.dart';
import 'package:bluebubbles/database/html/web_tab_lock_core.dart';
import 'package:bluebubbles/services/ui/navigator/navigator_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

class _InMemoryTabBus {
  String? _ownerJson;
  bool? exclusiveLockHeld;
  final Map<String, _FakeTabTransport> _transports = {};

  String? readOwner() => _ownerJson;

  void writeOwner(String value) {
    _ownerJson = value;
    for (final transport in List.of(_transports.values)) {
      scheduleMicrotask(() => transport.onOwnerStorageChanged?.call(value));
    }
  }

  void clearOwner() {
    _ownerJson = null;
    for (final transport in List.of(_transports.values)) {
      scheduleMicrotask(() => transport.onOwnerStorageChanged?.call(null));
    }
  }

  void register(String tabId, _FakeTabTransport transport) {
    _transports[tabId] = transport;
  }

  void unregister(String tabId) {
    _transports.remove(tabId);
  }

  void broadcast(String senderTabId, String raw) {
    for (final entry in List.of(_transports.entries)) {
      if (entry.key == senderTabId) continue;
      scheduleMicrotask(() => entry.value.onMessage?.call(raw));
    }
  }
}

class _FakeTabTransport implements WebTabTransport {
  _FakeTabTransport(this.bus, this.tabId) {
    bus.register(tabId, this);
  }

  final _InMemoryTabBus bus;
  final String tabId;
  bool _disposed = false;

  @override
  void Function(String rawMessage)? onMessage;

  @override
  void Function(String? newOwnerRaw)? onOwnerStorageChanged;

  @override
  void Function()? onVisibilityOrPageshow;

  @override
  String? readOwnerRaw() => bus.readOwner();

  @override
  void writeOwnerRaw(String raw) => bus.writeOwner(raw);

  @override
  void clearOwnerRaw() => bus.clearOwner();

  @override
  void broadcastMessage(String raw) {
    if (_disposed) return;
    bus.broadcast(tabId, raw);
  }

  @override
  void writeSignalRaw(String raw) {
    if (_disposed) return;
    bus.broadcast(tabId, raw);
  }

  @override
  void acquireExclusiveLock() {
    bus.exclusiveLockHeld = true;
  }

  @override
  void releaseExclusiveLock() {
    bus.exclusiveLockHeld = false;
  }

  @override
  Future<bool?> isExclusiveLockHeld() async => bus.exclusiveLockHeld;

  @override
  void dispose() {
    _disposed = true;
    bus.unregister(tabId);
  }
}

String? _ownerTabId(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return decoded['tabId'] as String?;
}

void main() {
  group('WebTabLockController exclusive IDB tab coordination', () {
    late _InMemoryTabBus bus;

    setUp(() {
      bus = _InMemoryTabBus();
      IdbPersistence.ownershipCheck = null;
      IdbPersistence.active = null;
    });

    tearDown(() async {
      IdbPersistence.ownershipCheck = null;
      await IdbPersistence.relinquishActive();
    });

    test('single tab acquires ownership immediately without waiting for probe', () async {
      final tabA = WebTabLockController(
        tabId: 'tab-a',
        transport: _FakeTabTransport(bus, 'tab-a'),
        probeTimeout: const Duration(milliseconds: 500),
      );
      addTearDown(tabA.dispose);

      final sw = Stopwatch()..start();
      final acquired = await tabA.acquireOnStartup();
      sw.stop();

      expect(acquired, isTrue);
      expect(tabA.isBlocked, isFalse);
      expect(tabA.blockedListenable.value, isFalse);
      expect(sw.elapsedMilliseconds, lessThan(200));
    });

    test('second tab blocks when live owner replies pong, then takes over cleanly on Use here', () async {
      bool tabARelinquished = false;
      IdbPersistence? tabAPersistence;

      late WebTabLockController tabA;
      tabA = WebTabLockController(
        tabId: 'tab-a',
        transport: _FakeTabTransport(bus, 'tab-a'),
        probeTimeout: const Duration(milliseconds: 60),
        takeoverAckTimeout: const Duration(milliseconds: 120),
        onRelinquish: () async {
          tabARelinquished = true;
          await tabAPersistence?.close(flushPending: false);
        },
      );
      addTearDown(tabA.dispose);

      expect(await tabA.acquireOnStartup(), isTrue);
      IdbPersistence.ownershipCheck = () => !tabA.isBlocked;
      tabAPersistence = await IdbPersistence.open(
        factory: idbFactoryMemory,
        dbName: 'tab_lock_test_1',
      );
      tabAPersistence.enqueuePut(IdbPersistence.storeMessages, 1, {'id': 1, 'text': 'hello'});
      await tabAPersistence.flush();

      final tabB = WebTabLockController(
        tabId: 'tab-b',
        transport: _FakeTabTransport(bus, 'tab-b'),
        probeTimeout: const Duration(milliseconds: 80),
        takeoverAckTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(tabB.dispose);

      expect(await tabB.acquireOnStartup(), isFalse);
      expect(tabB.isBlocked, isTrue);
      expect(tabB.blockedListenable.value, isTrue);

      // Start takeover, then enqueue a write on tab A before takeover finishes;
      // tab A must cancel pending flushes and drop the write without hitting IDB.
      final takeoverFuture = tabB.takeOver();
      tabAPersistence.enqueuePut(IdbPersistence.storeMessages, 2, {'id': 2, 'text': 'stale'});
      await takeoverFuture;

      expect(tabARelinquished, isTrue);
      expect(tabA.isBlocked, isTrue);
      expect(tabA.blockedListenable.value, isTrue);
      expect(tabB.isBlocked, isFalse);
      expect(tabB.blockedListenable.value, isFalse);

      // Tab B now owns IDB and can open & write.
      IdbPersistence.ownershipCheck = () => !tabB.isBlocked;
      final tabBPersistence = await IdbPersistence.open(
        factory: idbFactoryMemory,
        dbName: 'tab_lock_test_1',
      );
      addTearDown(() => tabBPersistence.close(flushPending: false));

      final storesBefore = await tabBPersistence.loadAllStores();
      expect(storesBefore[IdbPersistence.storeMessages]!.map((e) => e['id']).toList(), equals([1]));

      tabBPersistence.enqueuePut(IdbPersistence.storeMessages, 3, {'id': 3, 'text': 'from-b'});
      await tabBPersistence.flush();
      final storesAfter = await tabBPersistence.loadAllStores();
      expect(storesAfter[IdbPersistence.storeMessages]!.map((e) => e['id']).toList(), equals([1, 3]));
    });

    test('frozen owner holding browser lock blocks new tab even when ping times out', () async {
      bus.writeOwner(jsonEncode({'tabId': 'frozen-tab', 'ts': 1000}));
      bus.exclusiveLockHeld = true;

      final tabB = WebTabLockController(
        tabId: 'tab-b',
        transport: _FakeTabTransport(bus, 'tab-b'),
        probeTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(tabB.dispose);

      expect(await tabB.acquireOnStartup(), isFalse);
      expect(tabB.isBlocked, isTrue);
      expect(tabB.blockedListenable.value, isTrue);
      expect(_ownerTabId(bus.readOwner()), equals('frozen-tab'));
    });

    test('crashed owner with unheld browser lock is replaced after probe timeout', () async {
      bus.writeOwner(jsonEncode({'tabId': 'dead-tab', 'ts': 1000}));
      bus.exclusiveLockHeld = false;

      final tabB = WebTabLockController(
        tabId: 'tab-b',
        transport: _FakeTabTransport(bus, 'tab-b'),
        probeTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(tabB.dispose);

      expect(await tabB.acquireOnStartup(), isTrue);
      expect(tabB.isBlocked, isFalse);
      expect(_ownerTabId(bus.readOwner()), equals('tab-b'));
    });

    test('visibility/pageshow wake relinquishes ownership if another tab took over while frozen', () async {
      bool relinquished = false;
      final transport = _FakeTabTransport(bus, 'tab-a');
      final tabA = WebTabLockController(
        tabId: 'tab-a',
        transport: transport,
        onRelinquish: () async {
          relinquished = true;
        },
      );
      addTearDown(tabA.dispose);

      expect(await tabA.acquireOnStartup(), isTrue);
      bus._ownerJson = jsonEncode({'tabId': 'tab-b', 'ts': 2000});
      transport.onVisibilityOrPageshow?.call();
      await pumpEventQueue();

      expect(relinquished, isTrue);
      expect(tabA.isBlocked, isTrue);
    });

    test('releaseOnPagehide clears owner only when matching current tabId', () async {
      final tabA = WebTabLockController(
        tabId: 'tab-a',
        transport: _FakeTabTransport(bus, 'tab-a'),
      );
      addTearDown(tabA.dispose);
      expect(await tabA.acquireOnStartup(), isTrue);

      bus.writeOwner(jsonEncode({'tabId': 'tab-other', 'ts': 9999}));
      tabA.releaseOnPagehide();
      expect(_ownerTabId(bus.readOwner()), equals('tab-other'));

      bus.writeOwner(jsonEncode({'tabId': 'tab-a', 'ts': 9999}));
      tabA.releaseOnPagehide();
      expect(bus.readOwner(), isNull);
    });
  });

  group('IdbPersistence ownershipCheck enforcement', () {
    tearDown(() async {
      IdbPersistence.ownershipCheck = null;
      await IdbPersistence.relinquishActive();
    });

    test('blocks open and drops queued writes when ownershipCheck returns false', () async {
      bool allowed = true;
      IdbPersistence.ownershipCheck = () => allowed;

      final db = await IdbPersistence.open(
        factory: idbFactoryMemory,
        dbName: 'idb_ownership_guard_test',
      );
      db.enqueuePut(IdbPersistence.storeChats, 10, {'id': 10, 'guid': 'c1'});
      await db.flush();

      allowed = false;
      expect(
        () => IdbPersistence.open(
          factory: idbFactoryMemory,
          dbName: 'idb_ownership_guard_test',
        ),
        throwsStateError,
      );

      db.enqueuePut(IdbPersistence.storeChats, 11, {'id': 11, 'guid': 'c2'});
      await db.flush();
      await IdbPersistence.relinquishActive();

      allowed = true;
      final reopened = await IdbPersistence.open(
        factory: idbFactoryMemory,
        dbName: 'idb_ownership_guard_test',
      );
      addTearDown(() => reopened.close(flushPending: false));
      final stores = await reopened.loadAllStores();
      expect(stores[IdbPersistence.storeChats]!.map((e) => e['id']).toList(), equals([10]));
    });

    test('mid-open ownership flip throws StateError and clearActive no-ops when blocked', () async {
      bool allowed = true;
      bool clearInMemoryCalled = false;
      IdbPersistence.ownershipCheck = () => allowed;
      IdbPersistence.onClearAllInMemory = () => clearInMemoryCalled = true;
      addTearDown(() => IdbPersistence.onClearAllInMemory = null);

      final db = await IdbPersistence.open(
        factory: idbFactoryMemory,
        dbName: 'idb_mid_open_guard_test',
      );
      db.enqueuePut(IdbPersistence.storeChats, 20, {'id': 20, 'guid': 'c20'});
      await db.flush();
      await db.close(flushPending: false);
      IdbPersistence.active = null;

      // Flip ownership to blocked right after open() starts awaiting factory.open.
      final openFuture = IdbPersistence.open(
        factory: idbFactoryMemory,
        dbName: 'idb_mid_open_guard_test',
      );
      allowed = false;
      await expectLater(openFuture, throwsStateError);
      expect(IdbPersistence.active, isNull);

      await IdbPersistence.clearActive();
      expect(clearInMemoryCalled, isFalse);

      allowed = true;
      final reopened = await IdbPersistence.open(
        factory: idbFactoryMemory,
        dbName: 'idb_mid_open_guard_test',
      );
      addTearDown(() => reopened.close(flushPending: false));
      final stores = await reopened.loadAllStores();
      expect(stores[IdbPersistence.storeChats]!.map((e) => e['id']).toList(), equals([20]));
    });
  });

  group('Stub WebTabLock and deep-link route parser', () {
    test('non-web WebTabLock stub always grants ownership', () async {
      expect(await WebTabLock.instance.acquireOnStartup(), isTrue);
      expect(WebTabLock.instance.isBlocked, isFalse);
      expect(WebTabLock.instance.blockedListenable.value, isFalse);
    });

    test('parseWebHashRoute distinguishes deep links from home', () {
      expect(parseWebHashRoute('/chat/iMessage;-;+15551234567').kind, equals(WebHashRouteKind.chat));
      expect(parseWebHashRoute('/settings').kind, equals(WebHashRouteKind.settings));
      expect(parseWebHashRoute('').kind, equals(WebHashRouteKind.home));
    });
  });
}
