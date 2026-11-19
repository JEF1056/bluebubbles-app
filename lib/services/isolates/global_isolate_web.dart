import 'dart:async';

import 'package:bluebubbles/services/isolates/global_isolate.dart';
import 'package:bluebubbles/services/isolates/isolate_actions.dart';
import 'package:bluebubbles/services/isolates/isolate_event.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';

/// Web implementation of [GlobalIsolate]: executes dispatched actions inline on the main thread
/// since Web/Wasm does not support `dart:isolate`.
class GlobalIsolate {
  final StreamController<dynamic> _controller = StreamController.broadcast();
  final Map<IsolateEvent, List<Function(dynamic)>> _eventListeners = {};

  final Duration taskTimeout;
  final Duration startupTimeout;
  final Duration? idleTimeout;

  Stream<dynamic> get outputStream => _controller.stream;

  bool get isRunning => false;

  void addStartedCallback(Future<void> Function() callback) {}

  String get isolatePortName => 'GlobalIsolate';

  String get isolateDebugName => 'GlobalIsolate';

  GlobalIsolate({
    this.taskTimeout = Duration.zero,
    this.startupTimeout = const Duration(seconds: kDebugMode ? 60 : 30),
    this.idleTimeout = const Duration(minutes: 5),
  }) {
    IsolateEventEmitter._instances.add(this);
  }

  void stop({bool clearEventListeners = false, bool closeOutputStream = false}) {
    if (clearEventListeners) {
      _eventListeners.clear();
      IsolateEventEmitter._instances.remove(this);
    }
    if (closeOutputStream && !_controller.isClosed) {
      _controller.close();
    }
  }

  Future<void> drainAndStop() => Future.value();

  void cancelDrain() {}

  void close() {
    stop(clearEventListeners: true, closeOutputStream: true);
  }

  void addEventListener(IsolateEvent event, Function(dynamic) listener) {
    _eventListeners.putIfAbsent(event, () => []).add(listener);
  }

  void removeEventListener(IsolateEvent event, Function(dynamic) listener) {
    final listeners = _eventListeners[event];
    if (listeners == null) return;
    listeners.remove(listener);
    if (listeners.isEmpty) {
      _eventListeners.remove(event);
    }
  }

  void removeAllEventListeners(IsolateEvent event) {
    _eventListeners.remove(event);
  }

  void clearAllEventListeners() {
    _eventListeners.clear();
  }

  Future<T> send<T>(IsolateRequestType type, {dynamic input, Duration? customTimeout}) async {
    final action = getActionMap()[type];
    if (action == null) {
      throw Exception('Unknown request type: $type');
    }
    final result = await action(input);
    return result as T;
  }

  void broadcast(IsolateRequestType type, dynamic input) {
    final action = getActionMap()[type];
    if (action == null) return;
    unawaited(
      action(input).catchError((Object e, StackTrace s) {
        Logger.error('Error in inline isolate broadcast [$type]: $e', trace: s);
        return null;
      }),
    );
  }

  Map<IsolateRequestType, IsolateAction> getActionMap() => IsolateActons.actions;

  void _handleEvent(IsolateEvent event, dynamic data) {
    final listeners = _eventListeners[event];
    if (listeners == null) return;
    for (final listener in List.from(listeners)) {
      try {
        listener(data);
      } catch (e, stack) {
        Logger.error('Error in event listener for ${event.name}: $e', trace: stack);
      }
    }
  }
}

class IsolateEventEmitter {
  static final List<GlobalIsolate> _instances = [];

  static void emit(IsolateEvent event, dynamic data) {
    for (final instance in List.of(_instances)) {
      instance._handleEvent(event, data);
    }
  }
}
