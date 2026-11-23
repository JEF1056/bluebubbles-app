import 'dart:async';

import 'package:flutter/foundation.dart';

enum SyncStatusKind {
  idle,
  syncing,
  failed,
}

@immutable
class SyncStatusSnapshot {
  final SyncStatusKind kind;
  final String? issueKey;
  final String? message;
  final bool retrying;
  final bool dismissed;

  const SyncStatusSnapshot({
    this.kind = SyncStatusKind.idle,
    this.issueKey,
    this.message,
    this.retrying = false,
    this.dismissed = false,
  });

  static const SyncStatusSnapshot idle = SyncStatusSnapshot();

  bool get showSyncing => kind == SyncStatusKind.syncing;
  bool get showFailed => kind == SyncStatusKind.failed && !dismissed;
  bool get isVisible => showSyncing || showFailed;

  SyncStatusSnapshot copyWith({
    SyncStatusKind? kind,
    String? issueKey,
    bool clearIssueKey = false,
    String? message,
    bool clearMessage = false,
    bool? retrying,
    bool? dismissed,
  }) {
    return SyncStatusSnapshot(
      kind: kind ?? this.kind,
      issueKey: clearIssueKey ? null : (issueKey ?? this.issueKey),
      message: clearMessage ? null : (message ?? this.message),
      retrying: retrying ?? this.retrying,
      dismissed: dismissed ?? this.dismissed,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SyncStatusSnapshot &&
        other.kind == kind &&
        other.issueKey == issueKey &&
        other.message == message &&
        other.retrying == retrying &&
        other.dismissed == dismissed;
  }

  @override
  int get hashCode => Object.hash(kind, issueKey, message, retrying, dismissed);
}

/// Pure state machine for unified sync & connection status across Web and Android.
///
/// Keeps a single sticky `failed` episode across reconnect/retry cycles so the UI
/// never flaps between red/yellow or pops repeated error toasts, and debounces
/// `syncing` (~300ms) so fast background syncs don't flash.
class SyncStatusTracker {
  static const String connectionIssueKey = 'sync_connection';
  static const String authIssueKey = 'auth_failed';

  final Duration syncDebounce;
  final Duration startupGrace;
  final Duration reconnectGrace;
  final Duration stableConnectDuration;
  final Duration manualRetryTimeout;
  final void Function(SyncStatusSnapshot) _onChanged;

  SyncStatusSnapshot _snapshot = SyncStatusSnapshot.idle;
  SyncStatusSnapshot get snapshot => _snapshot;

  bool _finishedSetup = false;
  bool _socketConnected = false;
  bool _socketRetrying = false;
  bool _manualRetrying = false;
  bool _socketFailed = false;
  bool _connectionDesired = true;
  bool _networkOnline = true;
  bool _authFailed = false;
  bool _hasConnectedOnce = false;
  bool _syncInProgress = false;
  bool _syncFailedInEpisode = false;
  String? _lastFailureMessage;

  final Set<String> _dismissedKeys = <String>{};
  Timer? _syncDebounceTimer;
  Timer? _startupGraceTimer;
  Timer? _reconnectGraceTimer;
  Timer? _stableConnectTimer;
  Timer? _manualRetryTimer;
  bool _debouncedSyncActive = false;
  bool _graceExpired = false;
  bool _inReconnectGrace = false;

  SyncStatusTracker({
    required this._onChanged,
    this.syncDebounce = const Duration(milliseconds: 300),
    this.startupGrace = const Duration(seconds: 5),
    this.reconnectGrace = const Duration(seconds: 6),
    this.stableConnectDuration = const Duration(seconds: 10),
    this.manualRetryTimeout = const Duration(seconds: 15),
  });

  void setFinishedSetup(bool finished) {
    if (_finishedSetup == finished) return;
    _finishedSetup = finished;
    if (!finished) {
      _resetAll();
      return;
    }
    _armStartupGraceIfNeeded();
    _recompute();
  }

  void beginReconnectGrace() {
    if (!_finishedSetup || _hasActiveFailure) return;
    if (reconnectGrace <= Duration.zero) return;
    _inReconnectGrace = true;
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = Timer(reconnectGrace, () {
      _reconnectGraceTimer = null;
      _inReconnectGrace = false;
      _recompute();
    });
  }

  void setConnectionDesired(bool desired) {
    if (_connectionDesired == desired) return;
    _connectionDesired = desired;
    if (!desired) {
      _startupGraceTimer?.cancel();
      _startupGraceTimer = null;
      _reconnectGraceTimer?.cancel();
      _reconnectGraceTimer = null;
      _inReconnectGrace = false;
      _socketRetrying = false;
      _clearManualRetry();
      // Intentional background disconnect is not a failure.
      if (!_syncFailedInEpisode && _networkOnline && !_authFailed) {
        _socketFailed = false;
      }
    } else {
      _armStartupGraceIfNeeded();
      beginReconnectGrace();
    }
    _recompute();
  }

  void setNetworkOnline(bool online) {
    if (_networkOnline == online) return;
    _networkOnline = online;
    if (!online) {
      if (!_socketConnected) {
        _lastFailureMessage = 'Offline';
      }
    } else if (_lastFailureMessage == 'Offline') {
      _lastFailureMessage = null;
    }
    _recompute();
  }

  void setAuthFailed(bool failed) {
    if (_authFailed == failed) return;
    _authFailed = failed;
    if (failed) {
      _lastFailureMessage = 'Incorrect password';
    }
    _recompute();
  }

  void onSocketState({
    required bool connected,
    required bool retrying,
    required bool failed,
    String? errorMessage,
  }) {
    _socketConnected = connected;
    _socketRetrying = retrying;
    if (connected) {
      _hasConnectedOnce = true;
      _graceExpired = true;
      _startupGraceTimer?.cancel();
      _startupGraceTimer = null;
      _reconnectGraceTimer?.cancel();
      _reconnectGraceTimer = null;
      _inReconnectGrace = false;
      final hadSocketFailure = _socketFailed;
      if (!_syncFailedInEpisode && !_authFailed) {
        _socketFailed = false;
        _clearManualRetry();
        if (_networkOnline) {
          _lastFailureMessage = null;
        }
      }
      if (hadSocketFailure || _dismissedKeys.isNotEmpty) {
        _armStableConnectTimer();
      }
    } else {
      _stableConnectTimer?.cancel();
      _stableConnectTimer = null;
      if (failed && _connectionDesired) {
        _socketFailed = true;
        if (errorMessage != null && errorMessage.isNotEmpty) {
          _lastFailureMessage = errorMessage;
        } else {
          _lastFailureMessage ??= 'Connection lost';
        }
        _armStartupGraceIfNeeded();
      } else if (retrying && _connectionDesired) {
        _armStartupGraceIfNeeded();
      }
    }
    _recompute();
  }

  void _armStableConnectTimer() {
    if (_stableConnectTimer != null) return;
    if (stableConnectDuration <= Duration.zero) {
      _clearSocketFailureOnRecovery();
      return;
    }
    _stableConnectTimer = Timer(stableConnectDuration, () {
      _stableConnectTimer = null;
      if (_socketConnected) {
        _clearSocketFailureOnRecovery();
        _recompute();
      }
    });
  }

  void _clearSocketFailureOnRecovery() {
    _stableConnectTimer?.cancel();
    _stableConnectTimer = null;
    _socketFailed = false;
    if (!_hasActiveFailure) {
      _dismissedKeys.clear();
      _lastFailureMessage = null;
    }
  }

  void onSyncStarted() {
    if (_syncInProgress) return;
    _syncInProgress = true;
    _syncDebounceTimer?.cancel();
    if (syncDebounce <= Duration.zero) {
      _debouncedSyncActive = true;
      _recompute();
      return;
    }
    _debouncedSyncActive = false;
    _syncDebounceTimer = Timer(syncDebounce, () {
      _syncDebounceTimer = null;
      if (_syncInProgress) {
        _debouncedSyncActive = true;
        _recompute();
      }
    });
    _recompute();
  }

  void onSyncFinished({required bool success}) {
    _syncInProgress = false;
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = null;
    _debouncedSyncActive = false;
    _clearManualRetry();

    if (success) {
      _syncFailedInEpisode = false;
      _socketRetrying = false;
      if (_lastFailureMessage == 'Sync failed') {
        _lastFailureMessage = null;
      }
      if (_socketConnected || !_connectionDesired) {
        _stableConnectTimer?.cancel();
        _stableConnectTimer = null;
        _socketFailed = false;
      }
      if (!_hasActiveFailure) {
        _dismissedKeys.clear();
        _lastFailureMessage = null;
      }
    } else {
      _syncFailedInEpisode = true;
      // Only a disconnected socket keeps a socket-reconnect spinner alive after a failed sync.
      if (_socketConnected || !_connectionDesired) {
        _socketRetrying = false;
      }
      _lastFailureMessage = 'Sync failed';
    }
    _recompute();
  }

  void dismissIssue([String? key]) {
    final target = key ?? _snapshot.issueKey;
    if (target == null) return;
    _dismissedKeys.add(target);
    _recompute();
  }

  void prepareManualRetry() {
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = null;
    _inReconnectGrace = false;
    final activeKey = _snapshot.issueKey;
    if (activeKey != null) {
      _dismissedKeys.remove(activeKey);
    }
    _manualRetrying = true;
    _manualRetryTimer?.cancel();
    _manualRetryTimer = null;
    if (manualRetryTimeout > Duration.zero) {
      _manualRetryTimer = Timer(manualRetryTimeout, () {
        _manualRetryTimer = null;
        _manualRetrying = false;
        // Unblock Retry even if socket stayed stalled in connecting/reconnecting.
        _socketRetrying = false;
        _recompute();
      });
    }
    _recompute();
  }

  void _clearManualRetry() {
    _manualRetryTimer?.cancel();
    _manualRetryTimer = null;
    _manualRetrying = false;
  }

  void _armStartupGraceIfNeeded() {
    if (_hasConnectedOnce || _graceExpired || _startupGraceTimer != null || !_finishedSetup) return;
    if (startupGrace <= Duration.zero) {
      _graceExpired = true;
      return;
    }
    _startupGraceTimer = Timer(startupGrace, () {
      _startupGraceTimer = null;
      _graceExpired = true;
      _recompute();
    });
  }

  bool get _pastStartupGrace => _hasConnectedOnce || _graceExpired;

  bool get _hasActiveFailure {
    if (!_finishedSetup) return false;
    if (_authFailed) return true;
    if (_syncFailedInEpisode) return true;
    if (!_networkOnline && !_socketConnected && !_inReconnectGrace) return true;
    if (_socketFailed && _pastStartupGrace && !_inReconnectGrace) return true;
    return false;
  }

  void _resetAll() {
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = null;
    _startupGraceTimer?.cancel();
    _startupGraceTimer = null;
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = null;
    _stableConnectTimer?.cancel();
    _stableConnectTimer = null;
    _clearManualRetry();
    _debouncedSyncActive = false;
    _inReconnectGrace = false;
    _syncInProgress = false;
    _syncFailedInEpisode = false;
    _socketFailed = false;
    _socketRetrying = false;
    _lastFailureMessage = null;
    _dismissedKeys.clear();
    _emit(SyncStatusSnapshot.idle);
  }

  void _recompute() {
    if (!_finishedSetup) {
      _emit(SyncStatusSnapshot.idle);
      return;
    }

    if (_hasActiveFailure) {
      final issueKey = _authFailed ? authIssueKey : connectionIssueKey;
      final message = _authFailed
          ? 'Incorrect password'
          : ((!_networkOnline && !_socketConnected)
              ? 'Offline'
              : (_syncFailedInEpisode ? 'Sync failed' : (_lastFailureMessage ?? 'Connection lost')));
      final retrying = _manualRetrying || _socketRetrying || _syncInProgress;
      final dismissed = _dismissedKeys.contains(issueKey);
      _emit(SyncStatusSnapshot(
        kind: SyncStatusKind.failed,
        issueKey: issueKey,
        message: message,
        retrying: retrying,
        dismissed: dismissed,
      ));
      return;
    }

    if (_debouncedSyncActive && _syncInProgress) {
      _emit(const SyncStatusSnapshot(
        kind: SyncStatusKind.syncing,
        message: 'Syncing…',
      ));
      return;
    }

    _emit(SyncStatusSnapshot.idle);
  }

  void _emit(SyncStatusSnapshot next) {
    if (_snapshot == next) return;
    _snapshot = next;
    _onChanged(next);
  }

  void dispose() {
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = null;
    _startupGraceTimer?.cancel();
    _startupGraceTimer = null;
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = null;
    _stableConnectTimer?.cancel();
    _stableConnectTimer = null;
    _clearManualRetry();
  }
}
