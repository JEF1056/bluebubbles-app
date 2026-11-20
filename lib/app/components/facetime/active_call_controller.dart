import 'dart:async';

import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/models/facetime.dart';
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
  outgoing,
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
  final bool isTelephony;
  final String? joinLink;
  final DateTime? connectedAt;
  final String? chatGuid;
  final bool isOutgoing;
  final bool isLinkOnly;
  final String? activeDeviceId;
  final String? activeDeviceName;
  final DateTime? startedAt;
  final String? localDeviceId;

  const ActiveCallState({
    this.phase = ActiveCallPhase.idle,
    this.callUuid,
    this.callerName = '',
    this.callerAddress,
    this.avatarBytes,
    this.isVideo = true,
    this.isMuted = false,
    this.isTelecomCall = false,
    this.isTelephony = false,
    this.joinLink,
    this.connectedAt,
    this.chatGuid,
    this.isOutgoing = false,
    this.isLinkOnly = false,
    this.activeDeviceId,
    this.activeDeviceName,
    this.startedAt,
    this.localDeviceId,
  });

  static const idle = ActiveCallState();

  bool get isActive => phase != ActiveCallPhase.idle;
  bool get isIncoming => phase == ActiveCallPhase.incoming;
  bool get isOutgoingPhase => phase == ActiveCallPhase.outgoing;
  bool get isConnecting => phase == ActiveCallPhase.connecting;
  bool get isOngoing => phase == ActiveCallPhase.ongoing;
  bool get hasCallUuid => callUuid != null && callUuid!.isNotEmpty;
  bool get hasJoinLink => joinLink != null && joinLink!.isNotEmpty;

  String get _effectiveLocalDeviceId =>
      (localDeviceId != null && localDeviceId!.isNotEmpty) ? localDeviceId! : ActiveCallController.instance.localDeviceId;

  bool get isOnOtherDevice =>
      activeDeviceId != null && activeDeviceId!.isNotEmpty && activeDeviceId != _effectiveLocalDeviceId;

  bool get isHeldHere =>
      isActive &&
      !isOnOtherDevice &&
      (isTelecomCall || hasJoinLink || (activeDeviceId != null && activeDeviceId == _effectiveLocalDeviceId));

  bool get canTransferHere =>
      isActive && hasCallUuid && (isOnOtherDevice || !isHeldHere) && (phase == ActiveCallPhase.ongoing || phase == ActiveCallPhase.outgoing);

  String get statusSubtitle {
    switch (phase) {
      case ActiveCallPhase.idle:
        return '';
      case ActiveCallPhase.incoming:
        if (isTelephony) return 'Incoming iPhone Call';
        return isVideo ? 'Incoming FaceTime Video' : 'Incoming FaceTime Audio';
      case ActiveCallPhase.outgoing:
        if (isOnOtherDevice) {
          final device = (activeDeviceName != null && activeDeviceName!.isNotEmpty) ? activeDeviceName! : 'another device';
          return 'Calling · On $device';
        }
        return 'Calling…';
      case ActiveCallPhase.connecting:
        return 'Connecting…';
      case ActiveCallPhase.ongoing:
        if (isOnOtherDevice) {
          final device = (activeDeviceName != null && activeDeviceName!.isNotEmpty) ? activeDeviceName! : 'another device';
          return 'On $device';
        }
        if (isLinkOnly) return 'FaceTime Link';
        if (isTelephony) return 'iPhone Call';
        return isVideo ? 'FaceTime Video' : 'FaceTime Audio';
    }
  }

  ActiveCallState copyWith({
    ActiveCallPhase? phase,
    String? callUuid,
    String? callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    bool? isVideo,
    bool? isMuted,
    bool? isTelecomCall,
    bool? isTelephony,
    String? joinLink,
    DateTime? connectedAt,
    String? chatGuid,
    bool? isOutgoing,
    bool? isLinkOnly,
    String? activeDeviceId,
    String? activeDeviceName,
    DateTime? startedAt,
    String? localDeviceId,
    bool clearJoinLink = false,
    bool clearActiveDevice = false,
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
      isTelephony: isTelephony ?? this.isTelephony,
      joinLink: clearJoinLink ? null : (joinLink ?? this.joinLink),
      connectedAt: connectedAt ?? this.connectedAt,
      chatGuid: chatGuid ?? this.chatGuid,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      isLinkOnly: isLinkOnly ?? this.isLinkOnly,
      activeDeviceId: clearActiveDevice ? null : (activeDeviceId ?? this.activeDeviceId),
      activeDeviceName: clearActiveDevice ? null : (activeDeviceName ?? this.activeDeviceName),
      startedAt: startedAt ?? this.startedAt,
      localDeviceId: localDeviceId ?? this.localDeviceId,
    );
  }
}

@immutable
class ActiveCallFailure {
  final String callUuid;
  final String message;
  final String? endedReason;
  final String? endedError;

  const ActiveCallFailure({
    required this.callUuid,
    required this.message,
    this.endedReason,
    this.endedError,
  });
}

/// Controller for in-app FaceTime incoming/outgoing/connecting/ongoing call state and cross-device sync.
class ActiveCallController extends ChangeNotifier {
  static final ActiveCallController instance = ActiveCallController();

  static const Set<String> _failureEndedReasons = {
    'call_failed',
    'declined',
    'no_answer',
    'busy',
    'unreachable',
    'link_failed',
    'admit_failed',
  };

  static String? failureMessageFor({String? endedReason, String? endedError}) {
    final reason = endedReason?.trim().toLowerCase();
    final err = endedError?.trim();
    final hasFailureReason = reason != null && _failureEndedReasons.contains(reason);
    final hasEndedError = err != null && err.isNotEmpty;
    if (!hasFailureReason && !hasEndedError) return null;
    if (hasEndedError) return err;
    return switch (reason) {
      'declined' => 'Call declined.',
      'no_answer' => 'No answer.',
      'busy' => 'Line is busy.',
      'unreachable' => 'Recipient is unreachable.',
      'link_failed' => "Couldn't create FaceTime link.",
      'admit_failed' => "Couldn't admit participant to FaceTime call.",
      _ => 'FaceTime call failed.',
    };
  }

  ActiveCallController({
    Future<void> Function(String? callUuid, bool isTelecom)? onEndCall,
    Future<void> Function(String? joinLink, BuildContext? context)? onReturnToCall,
    void Function(bool muted)? onMuteChanged,
    Future<void> Function(String callUuid, String digit)? onSendDtmf,
    DateTime Function()? now,
    String? deviceId,
    String? deviceName,
    Future<PlacedFaceTimeCall?> Function(String callUuid, {bool audioOnly, String? displayName, String? chatGuid})?
        onAnswerServerCall,
    Future<void> Function(String callUuid)? onDeclineServerCall,
    Future<void> Function(String callUuid)? onLeaveServerCall,
    Future<PlacedFaceTimeCall?> Function(String callUuid, {String? mode})? onHandoffServerCall,
    Future<void> Function(String callUuid, bool muted)? onSetServerMuted,
    Future<List<Map<String, dynamic>>> Function()? onFetchServerSessions,
    Future<bool> Function(String link)? onLaunchJoinLink,
    PendingCallTab? Function()? onOpenPendingTab,
    Future<bool> Function({required String callUuid, required String callerName, String? callerAddress, bool isTelephony})?
        onStartTelecomAudio,
    Future<void> Function(String callUuid, {bool onlyIfRinging})? onEndNativeCall,
    void Function(String callUuid, {bool keepCallState})? onDismissOverlay,
    void Function(String title, String message)? onShowError,
  })  : _onEndCall = onEndCall,
        _onReturnToCall = onReturnToCall,
        _onMuteChanged = onMuteChanged,
        _onSendDtmf = onSendDtmf,
        _now = now ?? DateTime.now,
        _deviceId = deviceId,
        _deviceName = deviceName,
        _onAnswerServerCall = onAnswerServerCall,
        _onDeclineServerCall = onDeclineServerCall,
        _onLeaveServerCall = onLeaveServerCall,
        _onHandoffServerCall = onHandoffServerCall,
        _onSetServerMuted = onSetServerMuted,
        _onFetchServerSessions = onFetchServerSessions,
        _onLaunchJoinLink = onLaunchJoinLink,
        _onOpenPendingTab = onOpenPendingTab,
        _onStartTelecomAudio = onStartTelecomAudio,
        _onEndNativeCall = onEndNativeCall,
        _onDismissOverlay = onDismissOverlay,
        _onShowError = onShowError;

  final Future<void> Function(String? callUuid, bool isTelecom)? _onEndCall;
  final Future<void> Function(String? joinLink, BuildContext? context)? _onReturnToCall;
  final void Function(bool muted)? _onMuteChanged;
  final Future<void> Function(String callUuid, String digit)? _onSendDtmf;
  final DateTime Function() _now;
  final String? _deviceId;
  final String? _deviceName;
  final Future<PlacedFaceTimeCall?> Function(String callUuid, {bool audioOnly, String? displayName, String? chatGuid})?
      _onAnswerServerCall;
  final Future<void> Function(String callUuid)? _onDeclineServerCall;
  final Future<void> Function(String callUuid)? _onLeaveServerCall;
  final Future<PlacedFaceTimeCall?> Function(String callUuid, {String? mode})? _onHandoffServerCall;
  final Future<void> Function(String callUuid, bool muted)? _onSetServerMuted;
  final Future<List<Map<String, dynamic>>> Function()? _onFetchServerSessions;
  final Future<bool> Function(String link)? _onLaunchJoinLink;
  final PendingCallTab? Function()? _onOpenPendingTab;
  final Future<bool> Function({
    required String callUuid,
    required String callerName,
    String? callerAddress,
    bool isTelephony,
  })? _onStartTelecomAudio;
  final Future<void> Function(String callUuid, {bool onlyIfRinging})? _onEndNativeCall;
  final void Function(String callUuid, {bool keepCallState})? _onDismissOverlay;
  final void Function(String title, String message)? _onShowError;

  String get localDeviceId =>
      (_deviceId != null && _deviceId.isNotEmpty) ? _deviceId : ClientDeviceIdentity.resolveDeviceId();

  String get localDeviceName =>
      (_deviceName != null && _deviceName.isNotEmpty) ? _deviceName : ClientDeviceIdentity.resolveDeviceName();

  ActiveCallState _state = ActiveCallState.idle;
  ActiveCallState get state => _state;

  ActiveCallFailure? _lastFailure;
  ActiveCallFailure? get lastFailure => _lastFailure;
  String? _lastFailureUuid;

  PendingCallTab? _pendingCallTab;

  void attachPendingCallTab(PendingCallTab? tab) {
    if (tab == null || identical(tab, _pendingCallTab)) return;
    _closePendingCallTab();
    _pendingCallTab = tab;
  }

  void _safeLogWarn(String message, Object error, StackTrace trace) {
    try {
      Logger.warn(message, error: error, trace: trace, tag: 'FaceTime');
    } catch (_) {
      // Headless unit tests without GetIt BaseLogger registration.
    }
  }

  void reportError(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    if (_onShowError != null) {
      _onShowError('Call failed', trimmed);
      return;
    }
    try {
      showSnackbar('Call failed', trimmed, type: SnackbarType.error);
    } catch (_) {
      // Headless unit tests without GetMaterialApp / AppNoticeController.
    }
  }

  bool get canReturn =>
      _onReturnToCall != null || ((_state.joinLink?.isNotEmpty ?? false) && !_state.isOnOtherDevice);

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
    bool isTelephony = false,
    String? chatGuid,
    DateTime? startedAt,
  }) {
    _stopTicker();
    _elapsed = Duration.zero;
    final matches = _state.callUuid == callUuid;
    _state = ActiveCallState(
      phase: ActiveCallPhase.incoming,
      callUuid: callUuid,
      callerName: callerName,
      callerAddress: callerAddress,
      avatarBytes: avatarBytes,
      isVideo: isTelephony ? false : isVideo,
      isTelephony: isTelephony,
      chatGuid: chatGuid ?? (matches ? _state.chatGuid : null),
      isOutgoing: false,
      startedAt: startedAt ?? (matches ? _state.startedAt : null) ?? _now(),
      localDeviceId: localDeviceId,
    );
    notifyListeners();
  }

  void startOutgoing({
    String? callUuid,
    required String callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    bool isVideo = true,
    bool isTelecomCall = false,
    bool isTelephony = false,
    String? joinLink,
    String? chatGuid,
    bool isLinkOnly = false,
    String? activeDeviceId,
    String? activeDeviceName,
    DateTime? startedAt,
  }) {
    _stopTicker();
    _elapsed = Duration.zero;
    _state = ActiveCallState(
      phase: ActiveCallPhase.outgoing,
      callUuid: callUuid,
      callerName: callerName,
      callerAddress: callerAddress,
      avatarBytes: avatarBytes,
      isVideo: isTelephony ? false : isVideo,
      isMuted: false,
      isTelecomCall: isTelecomCall,
      isTelephony: isTelephony,
      joinLink: joinLink,
      chatGuid: chatGuid,
      isOutgoing: true,
      isLinkOnly: isLinkOnly,
      activeDeviceId: activeDeviceId ?? localDeviceId,
      activeDeviceName: activeDeviceName ?? localDeviceName,
      startedAt: startedAt ?? _now(),
      localDeviceId: localDeviceId,
    );
    notifyListeners();
  }

  void setConnecting({
    required String callUuid,
    String? callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    bool? isVideo,
    bool? isTelephony,
    String? chatGuid,
    bool? isOutgoing,
    String? activeDeviceId,
    String? activeDeviceName,
  }) {
    _stopTicker();
    _elapsed = Duration.zero;
    final matches = _state.callUuid == callUuid;
    final nextTelephony = isTelephony ?? (matches ? _state.isTelephony : false);
    _state = ActiveCallState(
      phase: ActiveCallPhase.connecting,
      callUuid: callUuid,
      callerName: callerName ?? (matches ? _state.callerName : (nextTelephony ? 'iPhone Call' : 'FaceTime Call')),
      callerAddress: callerAddress ?? (matches ? _state.callerAddress : null),
      avatarBytes: avatarBytes ?? (matches ? _state.avatarBytes : null),
      isVideo: nextTelephony ? false : (isVideo ?? (matches ? _state.isVideo : true)),
      isTelephony: nextTelephony,
      chatGuid: chatGuid ?? (matches ? _state.chatGuid : null),
      isOutgoing: isOutgoing ?? (matches ? _state.isOutgoing : false),
      activeDeviceId: activeDeviceId ?? (matches ? _state.activeDeviceId : localDeviceId),
      activeDeviceName: activeDeviceName ?? (matches ? _state.activeDeviceName : localDeviceName),
      startedAt: matches ? _state.startedAt : _now(),
      localDeviceId: localDeviceId,
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
    bool isTelephony = false,
    String? chatGuid,
    bool isOutgoing = false,
    bool isLinkOnly = false,
    String? activeDeviceId,
    String? activeDeviceName,
    DateTime? startedAt,
    DateTime? connectedAt,
  }) {
    final effectiveConnectedAt = connectedAt ?? _now();
    final matches = callUuid != null && callUuid.isNotEmpty && _state.callUuid == callUuid;
    _state = ActiveCallState(
      phase: ActiveCallPhase.ongoing,
      callUuid: callUuid,
      callerName: callerName,
      callerAddress: callerAddress,
      avatarBytes: avatarBytes,
      isVideo: isTelephony ? false : isVideo,
      isMuted: matches ? _state.isMuted : false,
      isTelecomCall: isTelecomCall,
      isTelephony: isTelephony,
      joinLink: joinLink,
      connectedAt: effectiveConnectedAt,
      chatGuid: chatGuid ?? (matches ? _state.chatGuid : null),
      isOutgoing: isOutgoing,
      isLinkOnly: isLinkOnly,
      activeDeviceId: activeDeviceId ?? localDeviceId,
      activeDeviceName: activeDeviceName ?? localDeviceName,
      startedAt: startedAt ?? (matches ? _state.startedAt : effectiveConnectedAt),
      localDeviceId: localDeviceId,
    );
    _startTickerFrom(effectiveConnectedAt);
    notifyListeners();
  }

  void bindCallUuid(String callUuid, {bool? isTelephony}) {
    if (callUuid.isEmpty) return;
    if ((_state.phase == ActiveCallPhase.ongoing || _state.phase == ActiveCallPhase.outgoing) &&
        _state.isTelecomCall &&
        (_state.callUuid == null || _state.callUuid!.isEmpty || _state.callUuid == callUuid)) {
      _state = _state.copyWith(
        callUuid: callUuid,
        isTelephony: isTelephony ?? _state.isTelephony,
        localDeviceId: localDeviceId,
      );
      notifyListeners();
    }
  }

  void markConnected(String callUuid, {bool? isTelephony}) {
    if (callUuid.isEmpty) return;
    if (_state.phase != ActiveCallPhase.ongoing &&
        _state.phase != ActiveCallPhase.outgoing &&
        _state.phase != ActiveCallPhase.connecting) {
      return;
    }
    final matchesUuid = _state.callUuid == callUuid;
    final unboundTelecom = _state.isTelecomCall && (_state.callUuid == null || _state.callUuid!.isEmpty);
    if (!matchesUuid && !unboundTelecom) return;
    final connectedAt = _state.phase == ActiveCallPhase.ongoing && _state.connectedAt != null
        ? _state.connectedAt!
        : _now();
    _state = _state.copyWith(
      phase: ActiveCallPhase.ongoing,
      callUuid: callUuid,
      isTelephony: isTelephony ?? _state.isTelephony,
      connectedAt: connectedAt,
      localDeviceId: localDeviceId,
    );
    _startTickerFrom(connectedAt);
    notifyListeners();
  }

  /// Called when Android Telecom reports the local call transitioned to `active`.
  void notifyTelecomActive(String callUuid, {bool isTelephony = false}) {
    if (callUuid.isEmpty) return;
    final wasOnOtherDevice = _state.isOnOtherDevice || _state.phase == ActiveCallPhase.incoming;
    final matchesOrIdle = _state.phase == ActiveCallPhase.idle ||
        _state.callUuid == null ||
        _state.callUuid!.isEmpty ||
        _state.callUuid == callUuid;
    if (!matchesOrIdle) return;

    if (_state.phase == ActiveCallPhase.idle) {
      startOngoing(
        callUuid: callUuid,
        callerName: isTelephony ? 'iPhone Call' : 'FaceTime Call',
        isVideo: false,
        isTelecomCall: true,
        isTelephony: isTelephony,
        activeDeviceId: localDeviceId,
        activeDeviceName: localDeviceName,
      );
    } else {
      final connectedAt = _state.phase == ActiveCallPhase.ongoing && _state.connectedAt != null
          ? _state.connectedAt!
          : _now();
      _state = _state.copyWith(
        phase: ActiveCallPhase.ongoing,
        callUuid: callUuid,
        isVideo: false,
        isTelecomCall: true,
        isTelephony: isTelephony || _state.isTelephony,
        activeDeviceId: localDeviceId,
        activeDeviceName: localDeviceName,
        connectedAt: connectedAt,
        localDeviceId: localDeviceId,
      );
      _startTickerFrom(connectedAt);
      notifyListeners();
    }

    if (wasOnOtherDevice || _state.activeDeviceId != localDeviceId) {
      unawaited(_handoffServer(callUuid, mode: 'audio'));
    }
  }

  void syncMutedFromNative(String callUuid, bool muted) {
    if (_state.phase != ActiveCallPhase.ongoing && _state.phase != ActiveCallPhase.outgoing) return;
    if (_state.callUuid != null && _state.callUuid!.isNotEmpty && _state.callUuid != callUuid) return;
    if (_state.isMuted != muted) {
      _state = _state.copyWith(isMuted: muted);
      notifyListeners();
    }
    if (callUuid.isNotEmpty) {
      unawaited(_syncMuteToServer(callUuid, muted));
    }
  }

  void toggleMute() {
    if (_state.phase != ActiveCallPhase.ongoing && _state.phase != ActiveCallPhase.outgoing) return;
    final nextMuted = !_state.isMuted;
    _state = _state.copyWith(isMuted: nextMuted);
    if (_onMuteChanged != null) {
      _onMuteChanged(nextMuted);
    } else if (!kIsWeb &&
        Platform.isAndroid &&
        _state.isTelecomCall &&
        (_state.callUuid?.isNotEmpty ?? false) &&
        GetIt.I.isRegistered<MethodChannelService>()) {
      unawaited(MethodChannelSvc.actions.setFaceTimeMuted(callUuid: _state.callUuid!, muted: nextMuted));
    }
    final uuid = _state.callUuid;
    if (uuid != null && uuid.isNotEmpty) {
      unawaited(_syncMuteToServer(uuid, nextMuted));
    }
    notifyListeners();
  }

  Future<void> sendDtmf(String digit) async {
    final uuid = _state.callUuid;
    if (uuid == null || uuid.isEmpty) return;
    if (_onSendDtmf != null) {
      await _onSendDtmf(uuid, digit);
      return;
    }
    if (GetIt.I.isRegistered<HttpService>()) {
      await HttpSvc.faceTime.dtmf(uuid, digit);
    }
  }

  Future<void> returnToCall([BuildContext? context]) async {
    if (_state.phase != ActiveCallPhase.ongoing && _state.phase != ActiveCallPhase.outgoing) return;
    if (_onReturnToCall != null) {
      await _onReturnToCall(_state.joinLink, context);
      return;
    }
    final link = _state.joinLink;
    if (link == null || link.isEmpty) return;
    await _launchJoinLink(link, context: context);
  }

  Future<bool> answerCall({bool audioOnly = false, BuildContext? context}) async {
    final prev = _state;
    final uuid = prev.callUuid;
    if (uuid == null || uuid.isEmpty) return false;

    final effectiveTelephony = prev.isTelephony;
    final effectiveAudioOnly = audioOnly || effectiveTelephony || !prev.isVideo;

    if (kIsWeb && !effectiveAudioOnly) {
      _closePendingCallTab();
      _pendingCallTab = (_onOpenPendingTab ?? openPendingCallTab)();
    }

    setConnecting(
      callUuid: uuid,
      callerName: prev.callerName,
      callerAddress: prev.callerAddress,
      avatarBytes: prev.avatarBytes,
      isVideo: !effectiveAudioOnly,
      isTelephony: effectiveTelephony,
      chatGuid: prev.chatGuid,
      isOutgoing: prev.isOutgoing,
      activeDeviceId: localDeviceId,
      activeDeviceName: localDeviceName,
    );

    if (effectiveAudioOnly && (!kIsWeb && Platform.isAndroid || _onStartTelecomAudio != null)) {
      final routed = await _startTelecomAudio(
        callUuid: uuid,
        callerName: prev.callerName.isNotEmpty ? prev.callerName : (effectiveTelephony ? 'iPhone Call' : 'FaceTime Call'),
        callerAddress: prev.callerAddress,
        isTelephony: effectiveTelephony,
      );
      if (routed) {
        _closePendingCallTab();
        _dismissOverlay(uuid, keepCallState: true);
        startOngoing(
          callUuid: uuid,
          callerName: prev.callerName,
          callerAddress: prev.callerAddress,
          avatarBytes: prev.avatarBytes,
          isVideo: false,
          isTelecomCall: true,
          isTelephony: effectiveTelephony,
          chatGuid: prev.chatGuid,
          isOutgoing: prev.isOutgoing,
          activeDeviceId: localDeviceId,
          activeDeviceName: localDeviceName,
          startedAt: prev.startedAt,
        );
        if (_onAnswerServerCall != null) {
          await _onAnswerServerCall(uuid, audioOnly: true, displayName: prev.callerName, chatGuid: prev.chatGuid);
        } else {
          await _handoffServer(uuid, mode: 'audio');
        }
        return true;
      }
      if (effectiveTelephony) {
        _closePendingCallTab();
        clearPendingIfMatches(uuid);
        return false;
      }
    }

    PlacedFaceTimeCall? placed;
    String? answerFailure;
    try {
      placed = await _answerServer(
        uuid,
        audioOnly: effectiveAudioOnly && !kIsWeb,
        displayName: prev.callerName,
        chatGuid: prev.chatGuid,
      );
    } on FaceTimeException catch (e, s) {
      _safeLogWarn('Failed to answer FaceTime call', e, s);
      answerFailure = e.message;
    } catch (e, s) {
      _safeLogWarn('Failed to answer FaceTime call', e, s);
      answerFailure = "Couldn't answer the FaceTime call.";
    }

    final link = placed?.link;
    if (_state.callUuid != uuid) {
      _closePendingCallTab();
      return false;
    }

    if (link == null || link.isEmpty) {
      _closePendingCallTab();
      _dismissOverlay(uuid, keepCallState: false);
      clearPendingIfMatches(uuid);
      reportError(answerFailure ?? "Couldn't join the FaceTime call.");
      return false;
    }

    _dismissOverlay(uuid, keepCallState: true);
    startOngoing(
      callUuid: uuid,
      callerName: prev.callerName,
      callerAddress: prev.callerAddress,
      avatarBytes: prev.avatarBytes,
      isVideo: !effectiveAudioOnly && !effectiveTelephony,
      joinLink: link,
      isTelecomCall: false,
      isTelephony: effectiveTelephony,
      chatGuid: prev.chatGuid,
      isOutgoing: prev.isOutgoing,
      activeDeviceId: localDeviceId,
      activeDeviceName: localDeviceName,
      startedAt: prev.startedAt,
    );

    if (_pendingCallTab != null && _pendingCallTab!.isOpen) {
      _pendingCallTab!.navigate(link);
    } else {
      await _launchJoinLink(link, context: (context != null && context.mounted) ? context : null);
    }
    return true;
  }

  Future<bool> answerIncoming({bool audioOnly = false, BuildContext? context}) =>
      answerCall(audioOnly: audioOnly, context: context);

  Future<void> declineCall() async {
    final prev = _state;
    final uuid = prev.callUuid;
    _closePendingCallTab();
    clear();
    if (uuid == null || uuid.isEmpty) return;

    _dismissOverlay(uuid, keepCallState: false);
    await _endNativeCall(uuid, onlyIfRinging: false);
    await _declineServer(uuid);
  }

  Future<void> declineIncoming() => declineCall();

  Future<bool> transferHere({BuildContext? context, bool? audioOnly}) async {
    final prev = _state;
    final uuid = prev.callUuid;
    if (uuid == null || uuid.isEmpty) return false;

    final String mode;
    if (audioOnly == true || prev.isTelephony) {
      mode = 'audio';
    } else if (audioOnly == false) {
      mode = 'video';
    } else if (kIsWeb) {
      mode = 'video';
    } else if (Platform.isAndroid && !prev.isVideo) {
      mode = 'audio';
    } else {
      mode = 'video';
    }

    if ((kIsWeb || _onOpenPendingTab != null) && mode == 'video') {
      _closePendingCallTab();
      _pendingCallTab = (_onOpenPendingTab ?? openPendingCallTab)();
    }

    PlacedFaceTimeCall? placed;
    try {
      placed = await _handoffServer(uuid, mode: mode);
    } on FaceTimeException catch (e, s) {
      _safeLogWarn('Failed to transfer FaceTime call here', e, s);
      _closePendingCallTab();
      reportError(e.message);
      return false;
    } catch (e, s) {
      _safeLogWarn('Failed to transfer FaceTime call here', e, s);
      _closePendingCallTab();
      reportError("Couldn't transfer the FaceTime call.");
      return false;
    }

    final link = placed?.link ?? prev.joinLink;
    final bool useAudioTelecom = mode == 'audio' && (!kIsWeb && Platform.isAndroid || _onStartTelecomAudio != null);
    bool telecomStarted = false;
    if (useAudioTelecom) {
      telecomStarted = await _startTelecomAudio(
        callUuid: uuid,
        callerName: prev.callerName.isNotEmpty ? prev.callerName : (prev.isTelephony ? 'iPhone Call' : 'FaceTime Call'),
        callerAddress: prev.callerAddress,
        isTelephony: prev.isTelephony,
      );
    }

    final nextPhase = prev.phase == ActiveCallPhase.outgoing ? ActiveCallPhase.outgoing : ActiveCallPhase.ongoing;
    final nextConnectedAt = nextPhase == ActiveCallPhase.ongoing ? (prev.connectedAt ?? _now()) : prev.connectedAt;

    _state = prev.copyWith(
      phase: nextPhase,
      isVideo: mode == 'video' && !prev.isTelephony,
      isTelecomCall: telecomStarted,
      joinLink: link,
      activeDeviceId: localDeviceId,
      activeDeviceName: localDeviceName,
      connectedAt: nextConnectedAt,
      localDeviceId: localDeviceId,
    );
    if (nextPhase == ActiveCallPhase.ongoing && nextConnectedAt != null) {
      _startTickerFrom(nextConnectedAt);
    }
    notifyListeners();

    if (telecomStarted) {
      _closePendingCallTab();
      return true;
    }

    if (link != null && link.isNotEmpty) {
      if (_pendingCallTab != null && _pendingCallTab!.isOpen) {
        _pendingCallTab!.navigate(link);
      } else {
        await _launchJoinLink(link, context: (context != null && context.mounted) ? context : null);
      }
      return true;
    }

    _closePendingCallTab();
    return mode == 'audio' && !prev.isTelephony ? telecomStarted : false;
  }

  Future<void> endCall() async {
    final prev = _state;
    _closePendingCallTab();
    clear();

    final uuid = prev.callUuid;
    if (uuid != null && uuid.isNotEmpty) {
      _dismissOverlay(uuid, keepCallState: false);
    }

    if (_onEndCall != null) {
      await _onEndCall(prev.callUuid, prev.isTelecomCall);
    }

    if (uuid == null || uuid.isEmpty) return;

    if (!prev.isOnOtherDevice || prev.isTelecomCall || prev.phase == ActiveCallPhase.incoming) {
      await _endNativeCall(uuid, onlyIfRinging: false);
    }

    if (prev.phase == ActiveCallPhase.incoming) {
      await _declineServer(uuid);
    } else {
      await _leaveServer(uuid);
    }
  }

  void applyServerSession(Map<String, dynamic> data) {
    final status = _normalizeStatus(data);
    final uuid = _extractUuid(data);
    if (uuid == null || uuid.isEmpty) return;

    if (status == 'disconnected') {
      final endedReason = _nonEmptyString(data['ended_reason']);
      final endedError = _nonEmptyString(data['ended_error']);
      final failureReason = failureMessageFor(endedReason: endedReason, endedError: endedError);

      _dismissOverlay(uuid, keepCallState: false);
      unawaited(_endNativeCall(uuid, onlyIfRinging: false));
      final matchesActive = _state.phase != ActiveCallPhase.idle &&
          (_state.callUuid == null ||
              _state.callUuid!.isEmpty ||
              _state.callUuid == uuid ||
              data['session_uuid']?.toString() == _state.callUuid);
      if (matchesActive) {
        _closePendingCallTab();
        clear();
      } else if (_pendingCallTab != null) {
        _closePendingCallTab();
      }

      if (failureReason != null && _lastFailureUuid != uuid) {
        _lastFailureUuid = uuid;
        _lastFailure = ActiveCallFailure(
          callUuid: uuid,
          message: failureReason,
          endedReason: endedReason,
          endedError: endedError,
        );
        reportError(failureReason);
        notifyListeners();
      }
      return;
    }

    _lastFailure = null;
    final prev = _state;
    final matchesPrev = prev.callUuid == uuid ||
        (data['session_uuid'] != null && data['session_uuid'].toString() == prev.callUuid);

    final nextPhase = switch (status) {
      'incoming' => ActiveCallPhase.incoming,
      'outgoing' => ActiveCallPhase.outgoing,
      'connecting' => ActiveCallPhase.connecting,
      'answered' => ActiveCallPhase.ongoing,
      _ => null,
    };
    if (nextPhase == null) return;

    final isTelephony = data['is_telephony'] == true || (matchesPrev && prev.isTelephony);
    final bool isVideo;
    if (isTelephony) {
      isVideo = false;
    } else if (data['is_video'] is bool) {
      isVideo = data['is_video'] as bool;
    } else if (data['is_audio'] is bool) {
      isVideo = !(data['is_audio'] as bool);
    } else {
      isVideo = matchesPrev ? prev.isVideo : true;
    }

    final isOutgoing = data['is_outgoing'] == true || nextPhase == ActiveCallPhase.outgoing || (matchesPrev && prev.isOutgoing);
    final isLinkOnly = data['is_link_only'] == true || (matchesPrev && prev.isLinkOnly);

    final rawHandle = data['handle'] is Map ? (data['handle'] as Map)['address'] : null;
    final rawAddresses = data['addresses'] is List && (data['addresses'] as List).isNotEmpty
        ? (data['addresses'] as List).first
        : null;
    final callerAddress = _nonEmptyString(rawHandle) ??
        _nonEmptyString(data['address']) ??
        _nonEmptyString(rawAddresses) ??
        (matchesPrev ? prev.callerAddress : null);

    final serverDisplayName = _nonEmptyString(data['display_name']);
    final callerName = serverDisplayName ??
        (matchesPrev && prev.callerName.isNotEmpty ? prev.callerName : null) ??
        callerAddress ??
        (isTelephony ? 'iPhone Call' : 'FaceTime Call');

    final chatGuid = _nonEmptyString(data['chat_guid']) ?? (matchesPrev ? prev.chatGuid : null);
    final joinLink = _extractLink(data['link']) ?? (matchesPrev ? prev.joinLink : null);
    final isMuted = data['is_muted'] is bool ? data['is_muted'] as bool : (matchesPrev ? prev.isMuted : false);

    final activeDeviceId = data.containsKey('active_device_id')
        ? _nonEmptyString(data['active_device_id'])
        : (matchesPrev ? prev.activeDeviceId : null);
    final activeDeviceName = data.containsKey('active_device_name')
        ? _nonEmptyString(data['active_device_name'])
        : (matchesPrev ? prev.activeDeviceName : null);
    final nowOnOtherDevice = activeDeviceId != null && activeDeviceId != localDeviceId;

    final wasHeldHere = matchesPrev && prev.isHeldHere;
    final wasTelecom = matchesPrev && prev.isTelecomCall;

    // Remote device took over an active call from us -> close local Web tab / Telecom audio without hanging up server.
    if (nowOnOtherDevice && (wasHeldHere || wasTelecom || _pendingCallTab != null)) {
      _closePendingCallTab();
      if (wasTelecom) {
        unawaited(_endNativeCall(uuid, onlyIfRinging: false));
      }
      _dismissOverlay(uuid, keepCallState: true);
    }

    // Any answered/connecting call should ensure its incoming overlay is dismissed,
    // and remote-answered calls cancel any ringing native call/notification.
    if (nextPhase == ActiveCallPhase.ongoing || nextPhase == ActiveCallPhase.connecting) {
      _dismissOverlay(uuid, keepCallState: true);
    }
    if (nextPhase == ActiveCallPhase.ongoing &&
        ((matchesPrev && prev.phase == ActiveCallPhase.incoming) || !matchesPrev) &&
        activeDeviceId != localDeviceId &&
        (nowOnOtherDevice || activeDeviceId == null)) {
      unawaited(_endNativeCall(uuid, onlyIfRinging: true));
    }

    final nextTelecomCall = nowOnOtherDevice ? false : wasTelecom;
    if (nextTelecomCall && !nowOnOtherDevice && nextPhase == ActiveCallPhase.ongoing) {
      if (GetIt.I.isRegistered<MethodChannelService>() && !kIsWeb && Platform.isAndroid) {
        unawaited(MethodChannelSvc.actions.markFaceTimeCallActive(callUuid: uuid, isOutgoing: isOutgoing));
        if (matchesPrev && prev.isMuted != isMuted) {
          unawaited(MethodChannelSvc.actions.setFaceTimeMuted(callUuid: uuid, muted: isMuted));
        }
      }
    }

    final startedAt = _parseTimestamp(data['started_at']) ?? (matchesPrev ? prev.startedAt : _now());
    final answeredAt = _parseTimestamp(data['answered_at']);
    final connectedAt = nextPhase == ActiveCallPhase.ongoing
        ? (answeredAt ?? (matchesPrev ? prev.connectedAt : null) ?? _now())
        : (matchesPrev ? prev.connectedAt : null);

    _state = ActiveCallState(
      phase: nextPhase,
      callUuid: uuid,
      callerName: callerName,
      callerAddress: callerAddress,
      avatarBytes: matchesPrev ? prev.avatarBytes : null,
      isVideo: isVideo,
      isMuted: isMuted,
      isTelecomCall: nextTelecomCall,
      isTelephony: isTelephony,
      joinLink: joinLink,
      connectedAt: connectedAt,
      chatGuid: chatGuid,
      isOutgoing: isOutgoing,
      isLinkOnly: isLinkOnly,
      activeDeviceId: activeDeviceId,
      activeDeviceName: activeDeviceName,
      startedAt: startedAt,
      localDeviceId: localDeviceId,
    );

    if (nextPhase == ActiveCallPhase.ongoing && connectedAt != null) {
      _startTickerFrom(connectedAt);
    } else {
      _stopTicker();
      _elapsed = Duration.zero;
    }

    notifyListeners();
  }

  void reconcileServerSessions(List<Map<String, dynamic>> sessions) {
    final active = sessions.where((s) => _normalizeStatus(s) != 'disconnected').toList(growable: false);
    if (active.isEmpty) {
      if (_state.isActive && !(_state.isTelecomCall && !_state.hasCallUuid)) {
        final uuid = _state.callUuid;
        _closePendingCallTab();
        clear();
        if (uuid != null && uuid.isNotEmpty) {
          _dismissOverlay(uuid, keepCallState: false);
          unawaited(_endNativeCall(uuid, onlyIfRinging: false));
        }
      }
      return;
    }

    Map<String, dynamic> chosen = active.first;
    final currentUuid = _state.callUuid;
    if (currentUuid != null && currentUuid.isNotEmpty) {
      for (final s in active) {
        if (_extractUuid(s) == currentUuid) {
          chosen = s;
          break;
        }
      }
    } else {
      for (final s in active) {
        if (_nonEmptyString(s['active_device_id']) == localDeviceId) {
          chosen = s;
          break;
        }
      }
    }
    applyServerSession(chosen);
  }

  Future<void> syncFromServer() async {
    try {
      final List<Map<String, dynamic>> sessions;
      if (_onFetchServerSessions != null) {
        sessions = await _onFetchServerSessions();
      } else if (GetIt.I.isRegistered<HttpService>()) {
        sessions = await HttpSvc.faceTime.getFaceTimeSessions();
      } else {
        return;
      }
      reconcileServerSessions(sessions);
    } catch (e, s) {
      Logger.debug('FaceTime session sync skipped: $e', tag: 'FaceTime');
      Logger.trace('FaceTime session sync stack: $s', tag: 'FaceTime');
    }
  }

  /// Clears only pre-connection states (`incoming` / `connecting`) for [callUuid].
  void clearPendingIfMatches(String callUuid) {
    if (_state.callUuid == callUuid &&
        (_state.phase == ActiveCallPhase.incoming || _state.phase == ActiveCallPhase.connecting)) {
      _closePendingCallTab();
      clear();
    }
  }

  void clear() {
    _stopTicker();
    _closePendingCallTab();
    _elapsed = Duration.zero;
    if (_state.phase != ActiveCallPhase.idle) {
      _state = ActiveCallState.idle;
      notifyListeners();
    }
  }

  Future<PlacedFaceTimeCall?> _answerServer(
    String callUuid, {
    required bool audioOnly,
    String? displayName,
    String? chatGuid,
  }) async {
    if (_onAnswerServerCall != null) {
      return _onAnswerServerCall(callUuid, audioOnly: audioOnly, displayName: displayName, chatGuid: chatGuid);
    }
    if (GetIt.I.isRegistered<HttpService>()) {
      return HttpSvc.faceTime.answerFaceTime(
        callUuid,
        audioOnly: audioOnly,
        displayName: displayName,
        chatGuid: chatGuid,
      );
    }
    return null;
  }

  Future<PlacedFaceTimeCall?> _handoffServer(String callUuid, {String? mode}) async {
    if (_onHandoffServerCall != null) {
      return _onHandoffServerCall(callUuid, mode: mode);
    }
    if (GetIt.I.isRegistered<HttpService>()) {
      return HttpSvc.faceTime.handoffFaceTime(
        callUuid,
        mode: mode,
        displayName: _state.callerName,
        chatGuid: _state.chatGuid,
      );
    }
    return null;
  }

  Future<void> _syncMuteToServer(String callUuid, bool muted) async {
    try {
      if (_onSetServerMuted != null) {
        await _onSetServerMuted(callUuid, muted);
        return;
      }
      if (GetIt.I.isRegistered<HttpService>()) {
        await HttpSvc.faceTime.setFaceTimeMuted(
          callUuid,
          muted,
          displayName: _state.callerName,
          chatGuid: _state.chatGuid,
        );
      }
    } catch (e, s) {
      Logger.warn('Failed to sync FaceTime mute state', error: e, trace: s, tag: 'FaceTime');
    }
  }

  Future<void> _leaveServer(String callUuid) async {
    try {
      if (_onLeaveServerCall != null) {
        await _onLeaveServerCall(callUuid);
        return;
      }
      if (GetIt.I.isRegistered<HttpService>()) {
        await HttpSvc.faceTime.leaveFaceTime(
          callUuid,
          displayName: _state.callerName,
          chatGuid: _state.chatGuid,
        );
      }
    } catch (e, s) {
      Logger.warn('Failed to leave FaceTime call', error: e, trace: s, tag: 'FaceTime');
    }
  }

  Future<void> _declineServer(String callUuid) async {
    try {
      if (_onDeclineServerCall != null) {
        await _onDeclineServerCall(callUuid);
        return;
      }
      if (GetIt.I.isRegistered<HttpService>()) {
        await HttpSvc.faceTime.declineFaceTime(
          callUuid,
          displayName: _state.callerName,
          chatGuid: _state.chatGuid,
        );
      }
    } catch (e, s) {
      Logger.warn('Failed to decline FaceTime call', error: e, trace: s, tag: 'FaceTime');
    }
  }

  Future<bool> _startTelecomAudio({
    required String callUuid,
    required String callerName,
    String? callerAddress,
    required bool isTelephony,
  }) async {
    if (_onStartTelecomAudio != null) {
      return _onStartTelecomAudio(
        callUuid: callUuid,
        callerName: callerName,
        callerAddress: callerAddress,
        isTelephony: isTelephony,
      );
    }
    if (!kIsWeb && Platform.isAndroid && GetIt.I.isRegistered<MethodChannelService>()) {
      return MethodChannelSvc.actions.answerFaceTimeAudio(
        callUuid: callUuid,
        callerName: callerName,
        callerAddress: callerAddress,
        isTelephony: isTelephony,
      );
    }
    return false;
  }

  Future<void> _endNativeCall(String callUuid, {bool onlyIfRinging = false}) async {
    if (_onEndNativeCall != null) {
      await _onEndNativeCall(callUuid, onlyIfRinging: onlyIfRinging);
      return;
    }
    if (!kIsWeb && Platform.isAndroid) {
      if (GetIt.I.isRegistered<MethodChannelService>()) {
        try {
          await MethodChannelSvc.actions.endFaceTimeCall(callUuid: callUuid, onlyIfRinging: onlyIfRinging);
        } catch (e, s) {
          Logger.warn('Failed to end native FaceTime call', error: e, trace: s, tag: 'FaceTime');
        }
      }
      if (GetIt.I.isRegistered<NotificationsService>()) {
        try {
          await NotificationsSvc.clearFaceTimeNotification(callUuid, onlyIfRinging: onlyIfRinging);
        } catch (_) {}
      }
    }
  }

  void _dismissOverlay(String callUuid, {bool keepCallState = false}) {
    if (_onDismissOverlay != null) {
      _onDismissOverlay(callUuid, keepCallState: keepCallState);
      return;
    }
    hideFaceTimeOverlay(callUuid, keepCallState: keepCallState);
  }

  Future<void> _launchJoinLink(String link, {BuildContext? context}) async {
    if (_onLaunchJoinLink != null) {
      await _onLaunchJoinLink(link);
      return;
    }
    if (context != null && context.mounted) {
      await openFaceTimeJoinLink(link, context: context);
      return;
    }
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: kIsWeb ? '_blank' : null,
    );
  }

  void _closePendingCallTab() {
    _pendingCallTab?.close();
    _pendingCallTab = null;
  }

  void _startTickerFrom(DateTime connectedAt) {
    _stopTicker();
    final diff = _now().difference(connectedAt);
    _elapsed = diff.isNegative ? Duration.zero : diff;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_state.phase != ActiveCallPhase.ongoing || _state.connectedAt == null) return;
      final d = _now().difference(_state.connectedAt!);
      _elapsed = d.isNegative ? Duration.zero : d;
      notifyListeners();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  static String? _nonEmptyString(dynamic raw) {
    if (raw == null) return null;
    final str = raw.toString().trim();
    return str.isEmpty ? null : str;
  }

  static String? _extractUuid(Map<String, dynamic> data) =>
      _nonEmptyString(data['uuid']) ?? _nonEmptyString(data['call_uuid']) ?? _nonEmptyString(data['session_uuid']);

  static String? _extractLink(dynamic rawLink) {
    if (rawLink is String && rawLink.trim().isNotEmpty) return rawLink.trim();
    if (rawLink is Map && rawLink['url'] is String && (rawLink['url'] as String).trim().isNotEmpty) {
      return (rawLink['url'] as String).trim();
    }
    return null;
  }

  static String? _normalizeStatus(Map<String, dynamic> data) {
    final status = _nonEmptyString(data['status'])?.toLowerCase();
    if (status != null) {
      switch (status) {
        case 'incoming':
        case 'outgoing':
        case 'connecting':
        case 'answered':
        case 'disconnected':
          return status;
      }
    }
    final rawId = data['status_id'];
    final statusId = rawId is num ? rawId.toInt() : int.tryParse(rawId?.toString() ?? '');
    return switch (statusId) {
      4 => 'incoming',
      3 => 'outgoing',
      2 => 'connecting',
      1 => 'answered',
      6 => 'disconnected',
      _ => null,
    };
  }

  static DateTime? _parseTimestamp(dynamic raw) {
    final ms = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
    if (ms == null || ms <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  void dispose() {
    _stopTicker();
    _closePendingCallTab();
    super.dispose();
  }
}
