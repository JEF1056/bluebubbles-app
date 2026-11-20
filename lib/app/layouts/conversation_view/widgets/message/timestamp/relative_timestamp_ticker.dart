import 'dart:async';

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

/// Minute-boundary relative-timestamp ticker matching Google Messages:
/// schedules a single [Timer] for the exact next minute boundary, cancels once
/// the timestamp reaches the 60-minute absolute cutoff, pauses while
/// backgrounded or hidden by [TickerMode], and refreshes immediately on resume.
class RelativeTimestampTicker with WidgetsBindingObserver {
  RelativeTimestampTicker({
    required this._onTick,
    DateTime Function()? now,
  }) : _now = now ?? (() => clock.now()) {
    final state = WidgetsBinding.instance.lifecycleState;
    _isForeground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  final VoidCallback _onTick;
  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _target;
  bool _isRelative = false;
  bool _isForeground = true;
  bool _isVisible = true;
  bool _disposed = false;

  @visibleForTesting
  bool get isTimerActive => _timer?.isActive ?? false;

  void sync(DateTime? target, {required bool isRelative}) {
    if (_disposed) return;
    if (_target == target && _isRelative == isRelative && _timer != null && _timer!.isActive) {
      return;
    }
    _target = target;
    _isRelative = isRelative;
    _reschedule();
  }

  void setVisible(bool visible) {
    if (_disposed || _isVisible == visible) return;
    _isVisible = visible;
    if (!visible) {
      _cancelTimer();
    } else {
      _reschedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_disposed || foreground == _isForeground) return;
    _isForeground = foreground;
    if (!foreground) {
      _cancelTimer();
    } else {
      _reschedule();
      if (_isVisible && _isRelative && _target != null) {
        _onTick();
      }
    }
  }

  void _reschedule() {
    _cancelTimer();
    if (_disposed || !_isForeground || !_isVisible || !_isRelative || _target == null) {
      return;
    }
    final delay = nextRelativeTimestampTickDelay(
      _target,
      now: _now(),
      skin: Skins.Material,
    );
    if (delay == null) return;
    _timer = Timer(delay, () {
      _timer = null;
      if (_disposed || !_isForeground || !_isVisible) return;
      _onTick();
      _reschedule();
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelTimer();
    WidgetsBinding.instance.removeObserver(this);
  }
}
