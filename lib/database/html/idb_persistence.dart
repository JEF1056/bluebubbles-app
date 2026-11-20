import 'dart:async';

import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:idb_shim/idb_shim.dart';

/// Pure IndexedDB persistence engine for web ObjectBox replacement.
/// Kept free of `package:web` / `dart:js_interop` so it runs on Dart VM tests
/// with `idbFactoryMemory` as well as Flutter Web/WASM with `idbFactoryWeb`.
class IdbPersistence {
  static const String dbName = 'BlueBubblesStore.db';
  static const int schemaVersion = 1;

  static const String storeChats = 'chats';
  static const String storeMessages = 'messages';
  static const String storeHandles = 'handles';
  static const String storeAttachments = 'attachments';
  static const String storeContactsV2 = 'contactsV2';
  static const String storeCustomGroups = 'customGroups';
  static const String storeFcmData = 'fcmData';
  static const String storeThemes = 'themes';
  static const String storeThemeEntries = 'themeEntries';
  static const String storeThemeObjects = 'themeObjects';

  static const List<String> storeNames = [
    storeChats,
    storeMessages,
    storeHandles,
    storeAttachments,
    storeContactsV2,
    storeCustomGroups,
    storeFcmData,
    storeThemes,
    storeThemeEntries,
    storeThemeObjects,
  ];

  static IdbPersistence? active;
  static void Function()? onClearAllInMemory;
  static bool Function()? ownershipCheck;

  static bool get _isOwnershipBlocked => ownershipCheck != null && !ownershipCheck!();

  final IdbFactory factory;
  final Database _db;
  final Map<String, Map<int, Map<String, dynamic>?>> _pending = {};
  final Set<String> _pendingClearedStores = {};
  bool _microtaskScheduled = false;
  bool _closed = false;
  Future<void>? _activeFlush;

  IdbPersistence._(this.factory, this._db);

  static Future<IdbPersistence> open({
    IdbFactory? factory,
    String dbName = IdbPersistence.dbName,
    bool registerAsActive = true,
  }) async {
    if (registerAsActive && _isOwnershipBlocked) {
      throw StateError('IDB ownership held by another tab');
    }
    final resolvedFactory = factory ?? idbFactoryWeb;
    final db = await resolvedFactory.open(
      dbName,
      version: schemaVersion,
      onUpgradeNeeded: (VersionChangeEvent event) {
        final database = event.database;
        for (final name in storeNames) {
          if (!database.objectStoreNames.contains(name)) {
            database.createObjectStore(name, keyPath: 'id');
          }
        }
      },
    );
    final persistence = IdbPersistence._(resolvedFactory, db);
    if (registerAsActive && _isOwnershipBlocked) {
      db.close();
      throw StateError('IDB ownership held by another tab');
    }
    if (registerAsActive) {
      active = persistence;
    }
    return persistence;
  }

  static Future<void> flushActive() async {
    await active?.flush();
  }

  static Future<void> relinquishActive() async {
    final current = active;
    if (current != null) {
      await current.close(flushPending: false);
    }
  }

  static Future<void> clearActive() async {
    if (_isOwnershipBlocked) return;
    onClearAllInMemory?.call();
    if (active != null && !active!._closed) {
      await active!.clearAll();
    } else {
      await idbFactoryWeb.deleteDatabase(dbName);
    }
  }

  Future<Map<String, List<Map<String, dynamic>>>> loadAllStores() async {
    if (_closed) return {for (final name in storeNames) name: <Map<String, dynamic>>[]};
    final txn = _db.transaction(storeNames, idbModeReadOnly);
    final futures = <Future<MapEntry<String, List<Map<String, dynamic>>>>>[];
    for (final name in storeNames) {
      final store = txn.objectStore(name);
      futures.add(store.getAll().then((rows) {
        final list = <Map<String, dynamic>>[];
        for (final row in rows) {
          final normalized = _normalizeValue(row);
          if (normalized is Map<String, dynamic>) {
            list.add(normalized);
          }
        }
        return MapEntry(name, list);
      }));
    }
    final entries = await Future.wait(futures);
    await txn.completed;
    return Map<String, List<Map<String, dynamic>>>.fromEntries(entries);
  }

  void enqueuePut(String storeName, int id, Map<String, dynamic> record) {
    if (_closed || _isOwnershipBlocked) return;
    (_pending[storeName] ??= <int, Map<String, dynamic>?>{})[id] = record;
    _scheduleMicrotask();
  }

  void enqueueDelete(String storeName, int id) {
    if (_closed || _isOwnershipBlocked) return;
    (_pending[storeName] ??= <int, Map<String, dynamic>?>{})[id] = null;
    _scheduleMicrotask();
  }

  void enqueueClear(String storeName) {
    if (_closed || _isOwnershipBlocked) return;
    _pending.remove(storeName);
    _pendingClearedStores.add(storeName);
    _scheduleMicrotask();
  }

  void _scheduleMicrotask() {
    if (_microtaskScheduled || _closed || _isOwnershipBlocked) return;
    _microtaskScheduled = true;
    scheduleMicrotask(() {
      _microtaskScheduled = false;
      if (!_closed && !_isOwnershipBlocked) {
        unawaited(flush().catchError((Object e, StackTrace s) {
          Logger.warn('Web IDB microtask flush failed: $e', tag: 'WebIDB');
        }));
      }
    });
  }

  Future<void> flush() async {
    if (_isOwnershipBlocked) {
      _pending.clear();
      _pendingClearedStores.clear();
      return;
    }
    while (!_closed && !_isOwnershipBlocked && (_activeFlush != null || _pending.isNotEmpty || _pendingClearedStores.isNotEmpty)) {
      if (_activeFlush != null) {
        await _activeFlush;
        continue;
      }
      if (_closed || _isOwnershipBlocked || (_pending.isEmpty && _pendingClearedStores.isEmpty)) break;

      final touchedStores = <String>{..._pendingClearedStores, ..._pending.keys}.toList(growable: false);
      final clearedSnapshot = Set<String>.from(_pendingClearedStores);
      final pendingSnapshot = <String, Map<int, Map<String, dynamic>?>>{};
      for (final entry in _pending.entries) {
        pendingSnapshot[entry.key] = Map<int, Map<String, dynamic>?>.from(entry.value);
      }
      _pendingClearedStores.clear();
      _pending.clear();

      final completer = Completer<void>();
      completer.future.ignore();
      _activeFlush = completer.future;
      try {
        final txn = _db.transaction(touchedStores, idbModeReadWrite);
        final opFutures = <Future<Object?>>[];
        for (final storeName in touchedStores) {
          final store = txn.objectStore(storeName);
          if (clearedSnapshot.contains(storeName)) {
            opFutures.add(store.clear());
          }
          final ops = pendingSnapshot[storeName];
          if (ops != null) {
            for (final op in ops.entries) {
              if (op.value == null) {
                opFutures.add(store.delete(op.key));
              } else {
                opFutures.add(store.put(op.value!));
              }
            }
          }
        }
        await Future.wait(opFutures);
        await txn.completed;
        completer.complete();
      } catch (e, s) {
        if (!_closed && !_isOwnershipBlocked) {
          for (final entry in pendingSnapshot.entries) {
            if (_pendingClearedStores.contains(entry.key)) continue;
            final target = _pending.putIfAbsent(entry.key, () => <int, Map<String, dynamic>?>{});
            for (final op in entry.value.entries) {
              target.putIfAbsent(op.key, () => op.value);
            }
          }
          _pendingClearedStores.addAll(clearedSnapshot);
        }
        completer.completeError(e, s);
        rethrow;
      } finally {
        _activeFlush = null;
      }
    }
  }

  Future<void> clearAll() async {
    _pending.clear();
    _pendingClearedStores.clear();
    if (_activeFlush != null) {
      try {
        await _activeFlush;
      } catch (_) {}
    }
    _pending.clear();
    _pendingClearedStores.clear();
    if (_closed || _isOwnershipBlocked) return;
    final txn = _db.transaction(storeNames, idbModeReadWrite);
    for (final name in storeNames) {
      await txn.objectStore(name).clear();
    }
    await txn.completed;
  }

  Future<void> close({bool flushPending = true}) async {
    if (_closed) return;
    if (flushPending) {
      await flush();
    } else {
      _pending.clear();
      _pendingClearedStores.clear();
    }
    _closed = true;
    final inFlight = _activeFlush;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
    }
    _db.close();
    if (identical(active, this)) {
      active = null;
    }
  }

  static dynamic _normalizeValue(dynamic value) {
    if (value is Map) {
      final out = <String, dynamic>{};
      value.forEach((k, v) {
        if (k != null) {
          out[k.toString()] = _normalizeValue(v);
        }
      });
      return out;
    }
    if (value is List) {
      return value.map(_normalizeValue).toList();
    }
    return value;
  }
}
