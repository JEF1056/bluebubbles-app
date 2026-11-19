import 'dart:async';

import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

enum ActiveCallPhase {
  idle,
  incoming,
  connecting,
  ongoing,
}

@immutable
class ActiveCallState {
  final ActiveCallPhase phase;
  final String? callUuid;
  final String callerName;
  final String? callerAddress;
  final Uint8List? avatarBytes;
  final bool isVideo;
  final bool isMuted;
  final bool isTelecomCall;
  final String? joinLink;
  final DateTime? connectedAt;

  const ActiveCallState({
    this.phase = ActiveCallPhase.idle,
    this.callUuid,
    this.callerName = '',
    this.callerAddress,
    this.avatarBytes,
    this.isVideo = true,
    this.isMuted = false,
    this.isTelecomCall = false,
    this.joinLink,
    this.connectedAt,
  });

  static const idle = ActiveCallState();

  ActiveCallState copyWith({
    ActiveCallPhase? phase,
    String? callUuid,
    String? callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    bool? isVideo,
    bool? isMuted,
    bool? isTelecomCall,
    String? joinLink,
    DateTime? connectedAt,
  }) {
    return ActiveCallState(
      phase: phase ?? this.phase,
      callUuid: callUuid ?? this.callUuid,
      callerName: callerName ?? this.callerName,
      callerAddress: callerAddress ?? this.callerAddress,
      avatarBytes: avatarBytes ?? this.avatarBytes,
      isVideo: isVideo ?? this.isVideo,
      isMuted: isMuted ?? this.isMuted,
      isTelecomCall: isTelecomCall ?? this.isTelecomCall,
      joinLink: joinLink ?? this.joinLink,
      connectedAt: connectedAt ?? this.connectedAt,
    );
  }
}

/// Lightweight controller for in-app FaceTime incoming/connecting/ongoing call state.
class ActiveCallController extends ChangeNotifier {
  static final ActiveCallController instance = ActiveCallController();

  ActiveCallController({
    Future<void> Function(String? callUuid, bool isTelecom)? onEndCall,
    Future<void> Function(String? joinLink, BuildContext? context)? onReturnToCall,
    void Function(bool muted)? onMuteChanged,
    DateTime Function()? now,
  })  : _onEndCall = onEndCall,
        _onReturnToCall = onReturnToCall,
        _onMuteChanged = onMuteChanged,
        _now = now ?? DateTime.now;

  final Future<void> Function(String? callUuid, bool isTelecom)? _onEndCall;
  final Future<void> Function(String? joinLink, BuildContext? context)? _onReturnToCall;
  final void Function(bool muted)? _onMuteChanged;
  final DateTime Function() _now;

  ActiveCallState _state = ActiveCallState.idle;
  ActiveCallState get state => _state;

  bool get canReturn => _onReturnToCall != null || (_state.joinLink?.isNotEmpty ?? false);

  Duration _elapsed = Duration.zero;
  Duration get elapsed => _elapsed;

  Timer? _ticker;

  String get formattedDuration {
    final totalSeconds = _elapsed.inSeconds < 0 ? 0 : _elapsed.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$mm:$ss';
    }
    return '$mm:$ss';
  }

  void startIncoming({
    required String callUuid,
    required String callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    required bool isVideo,
  }) {
    _stopTicker();
    _elapsed = Duration.zero;
    _state = ActiveCallState(
      phase: ActiveCallPhase.incoming,
      callUuid: callUuid,
      callerName: callerName,
      callerAddress: callerAddress,
      avatarBytes: avatarBytes,
      isVideo: isVideo,
    );
    notifyListeners();
  }

  void setConnecting({
    required String callUuid,
    String? callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    bool? isVideo,
  }) {
    _stopTicker();
    _elapsed = Duration.zero;
    final matches = _state.callUuid == callUuid;
    _state = ActiveCallState(
      phase: ActiveCallPhase.connecting,
      callUuid: callUuid,
      callerName: callerName ?? (matches ? _state.callerName : 'FaceTime Call'),
      callerAddress: callerAddress ?? (matches ? _state.callerAddress : null),
      avatarBytes: avatarBytes ?? (matches ? _state.avatarBytes : null),
      isVideo: isVideo ?? (matches ? _state.isVideo : true),
    );
    notifyListeners();
  }

  void startOngoing({
    String? callUuid,
    required String callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    required bool isVideo,
    String? joinLink,
    bool isTelecomCall = false,
  }) {
    _stopTicker();
    final connectedAt = _now();
    _elapsed = Duration.zero;
    _state = ActiveCallState(
      phase: ActiveCallPhase.ongoing,
      callUuid: callUuid,
      callerName: callerName,
      callerAddress: callerAddress,
      avatarBytes: avatarBytes,
      isVideo: isVideo,
      isMuted: false,
      isTelecomCall: isTelecomCall,
      joinLink: joinLink,
      connectedAt: connectedAt,
    );
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_state.phase != ActiveCallPhase.ongoing || _state.connectedAt == null) return;
      _elapsed = _now().difference(_state.connectedAt!);
      notifyListeners();
    });
    notifyListeners();
  }

  void toggleMute() {
    if (_state.phase != ActiveCallPhase.ongoing) return;
    final nextMuted = !_state.isMuted;
    _state = _state.copyWith(isMuted: nextMuted);
    _onMuteChanged?.call(nextMuted);
    notifyListeners();
  }

  Future<void> returnToCall([BuildContext? context]) async {
    if (_state.phase != ActiveCallPhase.ongoing) return;
    if (_onReturnToCall != null) {
      await _onReturnToCall(_state.joinLink, context);
      return;
    }
    final link = _state.joinLink;
    if (link == null || link.isEmpty) return;
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: kIsWeb ? '_blank' : null,
    );
  }

  Future<void> endCall() async {
    final prev = _state;
    clear();

    if (_onEndCall != null) {
      await _onEndCall(prev.callUuid, prev.isTelecomCall);
      return;
    }

    final uuid = prev.callUuid;
    if (uuid == null || uuid.isEmpty) return;

    if (!kIsWeb && Platform.isAndroid && GetIt.I.isRegistered<MethodChannelService>()) {
      try {
        await MethodChannelSvc.actions.endFaceTimeCall(callUuid: uuid);
      } catch (e, s) {
        Logger.warn('Failed to end native FaceTime call', error: e, trace: s, tag: 'FaceTime');
      }
    }

    if (GetIt.I.isRegistered<HttpService>()) {
      try {
        await HttpSvc.faceTime.leave(uuid);
      } catch (e, s) {
        Logger.warn('Failed to leave FaceTime call', error: e, trace: s, tag: 'FaceTime');
      }
    }
  }

  /// Clears only pre-connection states (`incoming` / `connecting`) for [callUuid].
  void clearPendingIfMatches(String callUuid) {
    if (_state.callUuid == callUuid &&
        (_state.phase == ActiveCallPhase.incoming || _state.phase == ActiveCallPhase.connecting)) {
      clear();
    }
  }

  void clear() {
    _stopTicker();
    _elapsed = Duration.zero;
    if (_state.phase != ActiveCallPhase.idle) {
      _state = ActiveCallState.idle;
      notifyListeners();
    }
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }
}
