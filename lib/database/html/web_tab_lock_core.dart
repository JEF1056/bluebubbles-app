import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

enum WebTabOwnershipState { uninitialized, owner, blocked }

/// Transport abstraction for web multi-tab coordination so protocol logic
/// can be unit-tested on the Dart VM without browser APIs.
abstract class WebTabTransport {
  void Function(String rawMessage)? onMessage;
  void Function(String? newOwnerRaw)? onOwnerStorageChanged;
  void Function()? onVisibilityOrPageshow;

  String? readOwnerRaw();
  void writeOwnerRaw(String raw);
  void clearOwnerRaw();

  void broadcastMessage(String raw);
  void writeSignalRaw(String raw);

  /// Acquires an OS/browser-backed exclusive lock (e.g. `navigator.locks`)
  /// asynchronously after 0ms startup ownership is claimed.
  void acquireExclusiveLock() {}

  /// Releases the OS/browser-backed exclusive lock if held.
  void releaseExclusiveLock() {}

  /// Queries whether another tab still holds the browser lock (`true` = held by
  /// a live or frozen tab, `false` = definitely unheld / crashed, `null` = unsupported).
  Future<bool?> isExclusiveLockHeld() async => null;

  void dispose();
}

/// Pure-Dart multi-tab exclusive IDB ownership coordinator.
///
/// Uses synchronous `localStorage` owner check for 0ms single-tab startup,
/// `BroadcastChannel` + `localStorage` signal fallback for live ping/pong and
/// instant `"Use here"` takeover, plus optional browser `navigator.locks`
/// liveness checks so frozen/throttled owners are not falsely stolen.
class WebTabLockController {
  WebTabLockController({
    required WebTabTransport transport,
    String? tabId,
    int Function()? nowMs,
    this.probeTimeout = const Duration(milliseconds: 350),
    this.takeoverAckTimeout = const Duration(milliseconds: 300),
    this.onRelinquish,
  })  : _transport = transport,
        tabId = tabId ?? _generateTabId(),
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _transport.onMessage = _handleRawMessage;
    _transport.onOwnerStorageChanged = _handleOwnerStorageChanged;
    _transport.onVisibilityOrPageshow = checkOwnershipOnWake;
  }

  final WebTabTransport _transport;
  final String tabId;
  final int Function() _nowMs;
  final Duration probeTimeout;
  final Duration takeoverAckTimeout;
  Future<void> Function()? onRelinquish;

  final ValueNotifier<bool> blockedListenable = ValueNotifier<bool>(false);
  WebTabOwnershipState _state = WebTabOwnershipState.uninitialized;
  int _claimTs = 0;
  int _seq = 0;
  Completer<bool>? _probeCompleter;
  Completer<void>? _releasedCompleter;
  final Map<String, int> _seenSeqByTab = {};
  bool _disposed = false;

  WebTabOwnershipState get state => _state;
  bool get isOwner => _state == WebTabOwnershipState.owner;
  bool get isBlocked => _state == WebTabOwnershipState.blocked;

  static String _generateTabId() {
    final rng = Random();
    final a = rng.nextInt(0x7fffffff).toRadixString(36);
    final b = rng.nextInt(0x7fffffff).toRadixString(36);
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$a-$b';
  }

  /// Acquires exclusive ownership at startup.
  ///
  /// Returns `true` immediately (0ms, no timer/await) when no other tab owns
  /// the storage lease. If another tab is recorded, pings it and returns `false`
  /// as soon as `pong` arrives (or steals stale lease after [probeTimeout]).
  Future<bool> acquireOnStartup() async {
    if (_disposed) return false;
    final owner = _parseOwner(_transport.readOwnerRaw());
    if (owner == null || owner.tabId == tabId) {
      _becomeOwner();
      return true;
    }

    // Another tab wrote an owner lease; probe it via BroadcastChannel + localStorage.
    final completer = Completer<bool>();
    _probeCompleter = completer;
    _send('ping', to: owner.tabId);

    Timer? timer;
    timer = Timer(probeTimeout, () {
      if (!completer.isCompleted) {
        completer.complete(true);
      }
    });

    final shouldAcquire = await completer.future;
    timer.cancel();
    if (identical(_probeCompleter, completer)) {
      _probeCompleter = null;
    }

    if (!shouldAcquire || _disposed) {
      _becomeBlocked();
      return false;
    }

    // Ping timed out: verify via browser lock manager (when available) so a
    // frozen/throttled live background tab is not silently stolen.
    final lockHeld = await _transport.isExclusiveLockHeld();
    if (_disposed || lockHeld == true) {
      _becomeBlocked();
      return false;
    }

    _becomeOwner();
    return true;
  }

  /// Explicit user action ("Use here"): broadcasts takeover so the active tab
  /// cancels pending IDB flushes, closes IDB, disconnects socket, and shows its
  /// blocking prompt.
  Future<void> takeOver() async {
    if (_disposed) return;
    final currentOwner = _parseOwner(_transport.readOwnerRaw());
    final expectAck = currentOwner != null && currentOwner.tabId != tabId;

    Completer<void>? ackCompleter;
    Timer? timer;
    if (expectAck) {
      ackCompleter = Completer<void>();
      _releasedCompleter = ackCompleter;
      timer = Timer(takeoverAckTimeout, () {
        if (!ackCompleter!.isCompleted) {
          ackCompleter.complete();
        }
      });
    }

    _writeOwnerLease();
    _send('takeover');

    if (ackCompleter != null) {
      await ackCompleter.future;
      timer?.cancel();
      if (identical(_releasedCompleter, ackCompleter)) {
        _releasedCompleter = null;
      }
    }

    if (!_disposed) {
      _becomeOwner(broadcastClaim: false);
    }
  }

  void releaseOnPagehide() {
    _transport.releaseExclusiveLock();
    if (_state == WebTabOwnershipState.owner) {
      final current = _parseOwner(_transport.readOwnerRaw());
      if (current == null || current.tabId == tabId) {
        _transport.clearOwnerRaw();
      }
    }
  }

  /// Re-checks `localStorage` owner on `visibilitychange` / `pageshow` so a
  /// tab waking from frozen/BFCache state relinquishes if another tab took over.
  void checkOwnershipOnWake() {
    if (_disposed || _state != WebTabOwnershipState.owner) return;
    final current = _parseOwner(_transport.readOwnerRaw());
    if (current != null && current.tabId != tabId) {
      unawaited(_relinquish(replyTo: current.tabId));
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    releaseOnPagehide();
    if (_probeCompleter != null && !_probeCompleter!.isCompleted) {
      _probeCompleter!.complete(false);
    }
    if (_releasedCompleter != null && !_releasedCompleter!.isCompleted) {
      _releasedCompleter!.complete();
    }
    _transport.dispose();
  }

  void _becomeOwner({bool broadcastClaim = true}) {
    _claimTs = _nowMs();
    _state = WebTabOwnershipState.owner;
    blockedListenable.value = false;
    _writeOwnerLease();
    _transport.acquireExclusiveLock();
    if (broadcastClaim) {
      _send('claim');
    }
  }

  void _becomeBlocked() {
    _transport.releaseExclusiveLock();
    _state = WebTabOwnershipState.blocked;
    blockedListenable.value = true;
  }

  void _writeOwnerLease() {
    _transport.writeOwnerRaw(jsonEncode({
      'tabId': tabId,
      'ts': _nowMs(),
    }));
  }

  void _send(String type, {String? to}) {
    final payload = jsonEncode({
      'type': type,
      'from': tabId,
      'to': ?to,
      'ts': _nowMs(),
      'seq': ++_seq,
    });
    _transport.broadcastMessage(payload);
    _transport.writeSignalRaw(payload);
  }

  void _handleOwnerStorageChanged(String? newOwnerRaw) {
    if (_disposed || _state != WebTabOwnershipState.owner) return;
    final parsed = _parseOwner(newOwnerRaw);
    if (parsed != null && parsed.tabId != tabId) {
      unawaited(_relinquish(replyTo: parsed.tabId));
    }
  }

  void _handleRawMessage(String raw) {
    if (_disposed) return;
    final Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      return;
    }

    final from = msg['from'] as String?;
    final type = msg['type'] as String?;
    final to = msg['to'] as String?;
    final seq = (msg['seq'] as num?)?.toInt();
    final ts = (msg['ts'] as num?)?.toInt() ?? 0;

    if (from == null || from == tabId || type == null) return;
    if (seq != null) {
      final prevSeq = _seenSeqByTab[from];
      if (prevSeq != null && seq <= prevSeq) return;
      if (_seenSeqByTab.length >= 64) {
        _seenSeqByTab.clear();
      }
      _seenSeqByTab[from] = seq;
    }

    switch (type) {
      case 'ping':
        if (_state == WebTabOwnershipState.owner && (to == null || to == tabId)) {
          _send('pong', to: from);
        }
        break;
      case 'pong':
        if (to == null || to == tabId) {
          if (_probeCompleter != null && !_probeCompleter!.isCompleted) {
            _probeCompleter!.complete(false);
          }
        }
        break;
      case 'claim':
        if (_probeCompleter != null && !_probeCompleter!.isCompleted) {
          _probeCompleter!.complete(false);
        } else if (_state == WebTabOwnershipState.owner) {
          // Simultaneous startup tie-breaker: earlier (ts, tabId) wins.
          final incomingWins = ts < _claimTs || (ts == _claimTs && from.compareTo(tabId) < 0);
          if (incomingWins) {
            unawaited(_relinquish(replyTo: from));
          } else {
            _send('pong', to: from);
          }
        }
        break;
      case 'takeover':
        if (_probeCompleter != null && !_probeCompleter!.isCompleted) {
          _probeCompleter!.complete(false);
        }
        if (_state == WebTabOwnershipState.owner) {
          unawaited(_relinquish(replyTo: from));
        }
        break;
      case 'released':
        if (to == null || to == tabId) {
          if (_releasedCompleter != null && !_releasedCompleter!.isCompleted) {
            _releasedCompleter!.complete();
          }
        }
        break;
    }
  }

  Future<void> _relinquish({String? replyTo}) async {
    if (_state != WebTabOwnershipState.owner) return;
    _becomeBlocked();
    final current = _parseOwner(_transport.readOwnerRaw());
    if (current != null && current.tabId == tabId) {
      _transport.clearOwnerRaw();
    }
    try {
      await onRelinquish?.call();
    } catch (_) {}
    _send('released', to: replyTo);
  }

  static _OwnerLease? _parseOwner(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final tabId = decoded['tabId'] as String?;
      final ts = (decoded['ts'] as num?)?.toInt() ?? 0;
      if (tabId == null || tabId.isEmpty) return null;
      return _OwnerLease(tabId, ts);
    } catch (_) {
      return null;
    }
  }
}

class _OwnerLease {
  final String tabId;
  final int ts;
  const _OwnerLease(this.tabId, this.ts);
}
