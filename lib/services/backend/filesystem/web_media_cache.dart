import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:idb_shim/idb.dart' as idb;
import 'package:idb_shim/idb_browser.dart';

import 'web_media_cache_quota_stub.dart'
    if (dart.library.js_interop) 'web_media_cache_quota_web.dart';

typedef StorageQuotaEstimator = Future<int?> Function();

class WebMediaCache {
  static const String dbName = 'BlueBubblesMedia.db';
  static const int dbVersion = 1;

  static const String attachmentsStore = 'attachments';
  static const String chatBackgroundsStore = 'chat_backgrounds';
  static const String fontsStore = 'fonts';
  static const String _metadataStore = '_metadata';

  static const int defaultMaxBytes = 250 * 1024 * 1024;

  static final WebMediaCache instance = WebMediaCache._();

  final idb.IdbFactory _idbFactory;
  final String _dbName;
  final int _maxBytes;
  final StorageQuotaEstimator _quotaEstimator;

  Future<idb.Database>? _dbFuture;
  int _lastAccessTick = 0;

  WebMediaCache._({
    idb.IdbFactory? idbFactory,
    String dbName = WebMediaCache.dbName,
    int maxBytes = defaultMaxBytes,
    StorageQuotaEstimator? quotaEstimator,
  })  : _idbFactory = idbFactory ?? idbFactoryBrowser,
        _dbName = dbName,
        _maxBytes = maxBytes,
        _quotaEstimator = quotaEstimator ?? estimateRemainingStorageBytes;

  factory WebMediaCache.forTesting({
    required idb.IdbFactory idbFactory,
    String dbName = WebMediaCache.dbName,
    int maxBytes = defaultMaxBytes,
    StorageQuotaEstimator? quotaEstimator,
  }) {
    return WebMediaCache._(
      idbFactory: idbFactory,
      dbName: dbName,
      maxBytes: maxBytes,
      quotaEstimator: quotaEstimator,
    );
  }

  Future<idb.Database> _openDb() {
    final existing = _dbFuture;
    if (existing != null) return existing;
    final future = _idbFactory.open(
      _dbName,
      version: dbVersion,
      onUpgradeNeeded: (idb.VersionChangeEvent e) {
        final db = e.database;
        for (final store in const [
          attachmentsStore,
          chatBackgroundsStore,
          fontsStore,
          _metadataStore,
        ]) {
          if (!db.objectStoreNames.contains(store)) {
            db.createObjectStore(store);
          }
        }
      },
    ).catchError((Object error, StackTrace stack) {
      _dbFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
    _dbFuture = future;
    return future;
  }

  int _nextTick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastAccessTick = now > _lastAccessTick ? now : _lastAccessTick + 1;
    return _lastAccessTick;
  }

  static String _metaKey(String store, String key) => '$store::$key';

  static Uint8List? _asBytes(Object? raw) {
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    return null;
  }

  Future<Uint8List?> get(String store, String key) async {
    final db = await _openDb();
    final txn = db.transaction([store, _metadataStore], idb.idbModeReadWrite);
    final dataStore = txn.objectStore(store);
    final raw = await dataStore.getObject(key);
    final bytes = _asBytes(raw);
    if (bytes != null) {
      final metaStore = txn.objectStore(_metadataStore);
      await metaStore.put({
        'store': store,
        'key': key,
        'byteLength': bytes.length,
        'lastAccessedAt': _nextTick(),
      }, _metaKey(store, key));
    }
    await txn.completed;
    return bytes;
  }

  Future<void> put(String store, String key, Uint8List bytes) async {
    final db = await _openDb();
    final txn = db.transaction([store, _metadataStore], idb.idbModeReadWrite);
    await txn.objectStore(store).put(bytes, key);
    await txn.objectStore(_metadataStore).put({
      'store': store,
      'key': key,
      'byteLength': bytes.length,
      'lastAccessedAt': _nextTick(),
    }, _metaKey(store, key));
    await txn.completed;
    await _evictIfNeeded();
  }

  Future<void> delete(String store, String key) async {
    final db = await _openDb();
    final txn = db.transaction([store, _metadataStore], idb.idbModeReadWrite);
    await txn.objectStore(store).delete(key);
    await txn.objectStore(_metadataStore).delete(_metaKey(store, key));
    await txn.completed;
  }

  Future<void> clearStore(String store) async {
    final db = await _openDb();
    final readTxn = db.transaction(_metadataStore, idb.idbModeReadOnly);
    final rawEntries = await readTxn.objectStore(_metadataStore).getAll();
    await readTxn.completed;

    final writeTxn = db.transaction([store, _metadataStore], idb.idbModeReadWrite);
    await writeTxn.objectStore(store).clear();
    final metaStore = writeTxn.objectStore(_metadataStore);
    for (final entry in rawEntries) {
      if (entry is Map && entry['store'] == store) {
        final key = entry['key'] as String?;
        if (key != null) {
          await metaStore.delete(_metaKey(store, key));
        }
      }
    }
    await writeTxn.completed;
  }

  Future<void> clearAll() async {
    final db = await _openDb();
    final stores = [
      attachmentsStore,
      chatBackgroundsStore,
      fontsStore,
      _metadataStore,
    ];
    final txn = db.transaction(stores, idb.idbModeReadWrite);
    for (final store in stores) {
      await txn.objectStore(store).clear();
    }
    await txn.completed;
  }

  Future<int> usageBytes() async {
    final db = await _openDb();
    final txn = db.transaction(_metadataStore, idb.idbModeReadOnly);
    final entries = await txn.objectStore(_metadataStore).getAll();
    await txn.completed;
    var total = 0;
    for (final entry in entries) {
      if (entry is Map) {
        total += (entry['byteLength'] as num?)?.toInt() ?? 0;
      }
    }
    return total;
  }

  Future<Map<String, Uint8List>> getAllEntries(String store) async {
    final db = await _openDb();
    final txn = db.transaction([store, _metadataStore], idb.idbModeReadOnly);
    final entries = await txn.objectStore(_metadataStore).getAll();
    final dataStore = txn.objectStore(store);
    final result = <String, Uint8List>{};
    for (final entry in entries) {
      if (entry is Map && entry['store'] == store) {
        final key = entry['key'] as String?;
        if (key != null) {
          final bytes = _asBytes(await dataStore.getObject(key));
          if (bytes != null) result[key] = bytes;
        }
      }
    }
    await txn.completed;
    return result;
  }

  Future<int> _effectiveMaxBytes() async {
    final remaining = await _quotaEstimator();
    if (remaining == null) return _maxBytes;
    return min(_maxBytes, (remaining * 0.5).floor());
  }

  Future<void> _evictIfNeeded() async {
    final limit = await _effectiveMaxBytes();
    final db = await _openDb();
    final readTxn = db.transaction(_metadataStore, idb.idbModeReadOnly);
    final rawEntries = await readTxn.objectStore(_metadataStore).getAll();
    await readTxn.completed;

    final entries = rawEntries.whereType<Map>().toList();
    var total = 0;
    for (final entry in entries) {
      total += (entry['byteLength'] as num?)?.toInt() ?? 0;
    }
    if (total <= limit) return;

    // Only evict attachments; fonts and chat backgrounds stay pinned unless explicitly cleared.
    final evictable = entries.where((e) => e['store'] == attachmentsStore).toList()
      ..sort((a, b) {
        final at = (a['lastAccessedAt'] as num?)?.toInt() ?? 0;
        final bt = (b['lastAccessedAt'] as num?)?.toInt() ?? 0;
        return at.compareTo(bt);
      });

    final toDelete = <Map>[];
    for (final entry in evictable) {
      if (total <= limit) break;
      toDelete.add(entry);
      total -= (entry['byteLength'] as num?)?.toInt() ?? 0;
    }
    if (toDelete.isEmpty) return;

    final stores = {
      _metadataStore,
      for (final e in toDelete)
        if (e['store'] is String) e['store'] as String,
    }.toList();
    final writeTxn = db.transaction(stores, idb.idbModeReadWrite);
    final metaStore = writeTxn.objectStore(_metadataStore);
    for (final entry in toDelete) {
      final store = entry['store'] as String?;
      final key = entry['key'] as String?;
      if (store == null || key == null) continue;
      await writeTxn.objectStore(store).delete(key);
      await metaStore.delete(_metaKey(store, key));
    }
    await writeTxn.completed;
  }

  Future<void> close() async {
    final future = _dbFuture;
    _dbFuture = null;
    if (future != null) {
      final db = await future;
      db.close();
    }
  }
}
