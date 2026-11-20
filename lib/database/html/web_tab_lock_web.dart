import 'dart:async';
import 'dart:js_interop';

import 'package:bluebubbles/database/html/idb_persistence.dart';
import 'package:bluebubbles/database/html/web_tab_lock_core.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

class _BrowserWebTabTransport implements WebTabTransport {
  static const String _ownerKey = 'bb_idb_owner_v1';
  static const String _signalKey = 'bb_idb_msg_v1';
  static const String _channelName = 'bluebubbles_idb_lock_v1';

  _BrowserWebTabTransport() {
    try {
      final ch = web.BroadcastChannel(_channelName);
      _channelListener = ((web.MessageEvent event) {
        final data = event.data;
        if (data != null && data.isA<JSString>()) {
          onMessage?.call((data as JSString).toDart);
        }
      }).toJS;
      ch.addEventListener('message', _channelListener!);
      _channel = ch;
    } catch (_) {}

    try {
      _storageListener = ((web.Event rawEvent) {
        final event = rawEvent as web.StorageEvent;
        if (event.key == _signalKey) {
          final val = event.newValue;
          if (val != null && val.isNotEmpty) {
            onMessage?.call(val);
          }
        } else if (event.key == _ownerKey) {
          onOwnerStorageChanged?.call(event.newValue);
        }
      }).toJS;
      web.window.addEventListener('storage', _storageListener!);
    } catch (_) {}

    try {
      _wakeListener = ((web.Event _) {
        onVisibilityOrPageshow?.call();
      }).toJS;
      web.document.addEventListener('visibilitychange', _wakeListener!);
      web.window.addEventListener('pageshow', _wakeListener!);
    } catch (_) {}
  }

  web.BroadcastChannel? _channel;
  JSFunction? _channelListener;
  JSFunction? _storageListener;
  JSFunction? _wakeListener;
  Completer<void>? _lockCompleter;
  bool _lockWanted = false;

  @override
  void Function(String rawMessage)? onMessage;

  @override
  void Function(String? newOwnerRaw)? onOwnerStorageChanged;

  @override
  void Function()? onVisibilityOrPageshow;

  @override
  String? readOwnerRaw() {
    try {
      return web.window.localStorage.getItem(_ownerKey);
    } catch (_) {
      return null;
    }
  }

  @override
  void writeOwnerRaw(String raw) {
    try {
      web.window.localStorage.setItem(_ownerKey, raw);
    } catch (_) {}
  }

  @override
  void clearOwnerRaw() {
    try {
      web.window.localStorage.removeItem(_ownerKey);
    } catch (_) {}
  }

  @override
  void broadcastMessage(String raw) {
    try {
      _channel?.postMessage(raw.toJS);
    } catch (_) {}
  }

  @override
  void writeSignalRaw(String raw) {
    try {
      web.window.localStorage.setItem(_signalKey, raw);
    } catch (_) {}
  }

  @override
  void acquireExclusiveLock() {
    releaseExclusiveLock();
    _lockWanted = true;
    try {
      final promise = web.window.navigator.locks.request(
        _channelName,
        web.LockOptions(mode: 'exclusive', steal: true),
        ((web.Lock? _) {
          if (!_lockWanted) {
            return Future<void>.value().toJS;
          }
          final completer = Completer<void>();
          _lockCompleter = completer;
          return completer.future.toJS;
        }).toJS,
      );
      unawaited(promise.toDart.catchError((Object _) => null));
    } catch (_) {}
  }

  @override
  void releaseExclusiveLock() {
    _lockWanted = false;
    final completer = _lockCompleter;
    _lockCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  @override
  Future<bool?> isExclusiveLockHeld() async {
    try {
      final snapshot = await web.window.navigator.locks.query().toDart;
      for (final info in snapshot.held.toDart) {
        if (info.name == _channelName) return true;
      }
      return false;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    releaseExclusiveLock();
    if (_wakeListener != null) {
      try {
        web.document.removeEventListener('visibilitychange', _wakeListener!);
        web.window.removeEventListener('pageshow', _wakeListener!);
      } catch (_) {}
      _wakeListener = null;
    }
    if (_storageListener != null) {
      try {
        web.window.removeEventListener('storage', _storageListener!);
      } catch (_) {}
      _storageListener = null;
    }
    if (_channel != null) {
      if (_channelListener != null) {
        try {
          _channel!.removeEventListener('message', _channelListener!);
        } catch (_) {}
        _channelListener = null;
      }
      try {
        _channel!.close();
      } catch (_) {}
      _channel = null;
    }
  }
}

class WebTabLock {
  WebTabLock._() {
    _controller = WebTabLockController(
      transport: _BrowserWebTabTransport(),
      onRelinquish: () async {
        // Cancel pending IDB flushes and close IDB immediately before disconnecting socket.
        await IdbPersistence.relinquishActive();
        await onRelinquish?.call();
      },
    );
    IdbPersistence.ownershipCheck = () => !_controller.isBlocked;
    _pagehideListener = ((web.Event _) {
      _controller.releaseOnPagehide();
    }).toJS;
    web.window.addEventListener('pagehide', _pagehideListener!);
    web.window.addEventListener('beforeunload', _pagehideListener!);
  }

  static final WebTabLock instance = WebTabLock._();

  late final WebTabLockController _controller;
  JSFunction? _pagehideListener;
  Future<void> Function()? onRelinquish;

  ValueListenable<bool> get blockedListenable => _controller.blockedListenable;
  bool get isBlocked => _controller.isBlocked;
  bool get isOwner => _controller.isOwner;

  Future<bool> acquireOnStartup() => _controller.acquireOnStartup();

  Future<void> takeOver() => _controller.takeOver();

  void reloadPage() {
    web.window.location.reload();
  }
}
