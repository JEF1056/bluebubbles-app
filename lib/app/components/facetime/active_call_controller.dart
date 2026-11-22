import 'dart:async';

import 'package:bluebubbles/app/components/facetime/web_ringtone.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
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
    // Missed calls are reported as missed-call notifications, never error banners.
    if (reason == 'missed') return null;
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
    Future<bool> Function({
      required String callUuid,
      required String callerName,
      String? callerAddress,
      bool isTelephony,
      bool isVideo,
    })? onStartTelecomCall,
    Future<void> Function(String callUuid, {bool onlyIfRinging})? onEndNativeCall,
    void Function(String callUuid, {bool keepCallState})? onDismissOverlay,
    void Function(String title, String message)? onShowError,
    void Function(String? callUuid)? onStartIncomingRingtone,
    void Function(String? callUuid)? onStopIncomingRingtone,
    WebWebRtcClient? webRtcClient,
    Future<bool> Function(bool enabled)? onToggleSpeaker,
    bool? isWebOverride,
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
        _onStartTelecomCall = onStartTelecomCall,
        _onEndNativeCall = onEndNativeCall,
        _onDismissOverlay = onDismissOverlay,
        _onShowError = onShowError,
        _onStartIncomingRingtone = onStartIncomingRingtone,
        _onStopIncomingRingtone = onStopIncomingRingtone,
        _webRtcClient = webRtcClient ?? WebWebRtcClient(),
        _onToggleSpeaker = onToggleSpeaker,
        _isWebOverride = isWebOverride;

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
  final Future<bool> Function({
    required String callUuid,
    required String callerName,
    String? callerAddress,
    bool isTelephony,
    bool isVideo,
  })? _onStartTelecomCall;
  final Future<void> Function(String callUuid, {bool onlyIfRinging})? _onEndNativeCall;
  final void Function(String callUuid, {bool keepCallState})? _onDismissOverlay;
  final void Function(String title, String message)? _onShowError;
  final void Function(String? callUuid)? _onStartIncomingRingtone;
  final void Function(String? callUuid)? _onStopIncomingRingtone;
  final WebWebRtcClient _webRtcClient;
  final Future<bool> Function(bool enabled)? _onToggleSpeaker;
  final bool? _isWebOverride;
  String? _ringingCallUuid;

  bool get _isWeb => _isWebOverride ?? kIsWeb;

  final Rxn<Widget> remoteVideoWidget = Rxn<Widget>();
  final Rxn<Widget> localVideoWidget = Rxn<Widget>();
  final RxBool cameraEnabled = false.obs;
  final RxBool canFlipCamera = false.obs;
  final RxBool isFrontCamera = true.obs;
  final RxBool isSpeakerOn = false.obs;

  WebRtcBridgeConfig? get cachedWebRtcConfig => _webRtcClient.cachedConfig;
  bool get isWebRtcActive => _webRtcClient.isActive;

  Future<WebRtcBridgeConfig> getWebRtcConfig({bool forceRefresh = false}) =>
      _webRtcClient.fetchBridgeConfig(forceRefresh: forceRefresh);

  Future<bool> toggleSpeaker() async {
    final next = !isSpeakerOn.value;
    if (_onToggleSpeaker != null) {
      try {
        final applied = await _onToggleSpeaker(next);
        if (applied) {
          isSpeakerOn.value = next;
          notifyListeners();
        }
        return applied;
      } catch (_) {
        return false;
      }
    }
    if (_isWeb) {
      return false;
    }
    if (Platform.isAndroid && GetIt.I.isRegistered<MethodChannelService>()) {
      try {
        final result = await MethodChannelSvc.channel.invokeMethod<bool>(
          'set-facetime-speaker',
          <String, dynamic>{'call_uuid': _state.callUuid, 'enabled': next},
        );
        final applied = result ?? next;
        if (applied) {
          isSpeakerOn.value = next;
          notifyListeners();
        }
        return applied;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  Future<bool> toggleCamera() async {
    if (_state.phase == ActiveCallPhase.idle || _state.isTelephony) {
      return false;
    }
    final next = !cameraEnabled.value;
    if (_webRtcClient.isActive) {
      try {
        await _webRtcClient.setCameraEnabled(next);
        cameraEnabled.value = _webRtcClient.cameraEnabled.value;
        localVideoWidget.value = _webRtcClient.localVideo.value;
        canFlipCamera.value = _webRtcClient.canFlipCamera.value;
        isFrontCamera.value = _webRtcClient.frontCamera.value;
        notifyListeners();
        return cameraEnabled.value == next;
      } catch (_) {
        return false;
      }
    }
    if (!_isWeb &&
        Platform.isAndroid &&
        GetIt.I.isRegistered<MethodChannelService>() &&
        (_state.callUuid?.isNotEmpty ?? false)) {
      try {
        final applied = await MethodChannelSvc.channel.invokeMethod<bool>(
          'set-facetime-camera-enabled',
          <String, dynamic>{'call_uuid': _state.callUuid, 'enabled': next},
        );
        if (applied == true) {
          cameraEnabled.value = next;
          notifyListeners();
          return true;
        }
        return false;
      } catch (_) {
        return false;
      }
    }
    cameraEnabled.value = next;
    notifyListeners();
    return true;
  }

  Future<bool> flipCamera() async {
    if (_state.phase == ActiveCallPhase.idle || !canFlipCamera.value || !cameraEnabled.value) {
      return false;
    }
    if (_webRtcClient.isActive) {
      try {
        await _webRtcClient.flipCamera();
        isFrontCamera.value = _webRtcClient.frontCamera.value;
        notifyListeners();
        return true;
      } catch (_) {
        return false;
      }
    }
    if (!_isWeb &&
        Platform.isAndroid &&
        GetIt.I.isRegistered<MethodChannelService>() &&
        (_state.callUuid?.isNotEmpty ?? false)) {
      try {
        final flipped = await MethodChannelSvc.channel.invokeMethod<bool>(
          'flip-facetime-camera',
          <String, dynamic>{'call_uuid': _state.callUuid},
        );
        if (flipped == true) {
          isFrontCamera.value = !isFrontCamera.value;
          notifyListeners();
          return true;
        }
        return false;
      } catch (_) {
        return false;
      }
    }
    isFrontCamera.value = !isFrontCamera.value;
    notifyListeners();
    return true;
  }

  Future<void> openFaceTimeLink({BuildContext? context}) async {
    final link = _state.joinLink;
    if (link == null || link.isEmpty) return;
    await _launchJoinLink(link, context: context);
  }

  Future<bool> _startWebRtcBridge({
    required String callUuid,
    required bool wantVideo,
    required bool answerCall,
    bool initialMuted = false,
  }) async {
    _webRtcClient.onRemoteVideoChanged = (widget) {
      remoteVideoWidget.value = widget;
      notifyListeners();
    };
    _webRtcClient.onLocalVideoChanged = (widget) {
      localVideoWidget.value = widget;
      notifyListeners();
    };
    _webRtcClient.onCameraEnabledChanged = (enabled) {
      cameraEnabled.value = enabled;
      notifyListeners();
    };
    _webRtcClient.onCanFlipCameraChanged = (canFlip) {
      canFlipCamera.value = canFlip;
      notifyListeners();
    };
    _webRtcClient.onFrontCameraChanged = (isFront) {
      isFrontCamera.value = isFront;
      notifyListeners();
    };
    try {
      await _webRtcClient.start(
        callUuid: callUuid,
        wantVideo: wantVideo,
        answerCall: answerCall,
        initialMuted: initialMuted,
      );
      if (_state.phase == ActiveCallPhase.idle || _state.callUuid != callUuid) {
        await _stopWebRtcBridge(emitHangup: false);
        return false;
      }
      remoteVideoWidget.value = _webRtcClient.remoteVideo.value;
      localVideoWidget.value = _webRtcClient.localVideo.value;
      cameraEnabled.value = _webRtcClient.cameraEnabled.value;
      canFlipCamera.value = _webRtcClient.canFlipCamera.value;
      isFrontCamera.value = _webRtcClient.frontCamera.value;
      notifyListeners();
      return true;
    } catch (e, s) {
      _safeLogWarn('WebRTC bridge startup failed', e, s);
      _resetVideoNotifiers();
      return false;
    }
  }

  Future<void> _stopWebRtcBridge({bool emitHangup = true}) async {
    _webRtcClient.onRemoteVideoChanged = null;
    _webRtcClient.onLocalVideoChanged = null;
    _webRtcClient.onCameraEnabledChanged = null;
    _webRtcClient.onCanFlipCameraChanged = null;
    _webRtcClient.onFrontCameraChanged = null;
    _resetVideoNotifiers();
    await _webRtcClient.hangup(emitSignal: emitHangup);
  }

  void _resetVideoNotifiers() {
    remoteVideoWidget.value = null;
    localVideoWidget.value = null;
    cameraEnabled.value = false;
    canFlipCamera.value = false;
    isFrontCamera.value = true;
  }

  int? _parseTextureId(dynamic rawTextureId) {
    if (rawTextureId is int) return rawTextureId;
    if (rawTextureId is num) return rawTextureId.toInt();
    return int.tryParse(rawTextureId?.toString() ?? '');
  }

  Future<bool> startWebOutgoingCall({
    required String address,
    required String callerName,
    Uint8List? avatarBytes,
    required bool video,
    required bool isTelephony,
    String? chatGuid,
    Future<PlacedFaceTimeCall> Function(bool isVideo)? onPlaceServerCall,
    void Function(String link)? onFallbackJoinLink,
  }) async {
    final effectiveVideo = video && !isTelephony;
    startOutgoing(
      callerName: callerName,
      callerAddress: address,
      avatarBytes: avatarBytes,
      isVideo: effectiveVideo,
      isTelephony: isTelephony,
      chatGuid: chatGuid,
      activeDeviceId: localDeviceId,
      activeDeviceName: localDeviceName,
    );

    PlacedFaceTimeCall placed;
    try {
      placed = await (onPlaceServerCall != null
          ? onPlaceServerCall(effectiveVideo)
          : HttpSvc.faceTime.call(
              address,
              video: effectiveVideo,
              isTelephony: isTelephony,
              displayName: callerName,
              chatGuid: chatGuid,
            ));
    } on FaceTimeException catch (e, s) {
      _safeLogWarn('Failed to place FaceTime call', e, s);
      clear();
      reportError(e.message);
      return false;
    } catch (e, s) {
      _safeLogWarn('Failed to place FaceTime call', e, s);
      clear();
      reportError("Couldn't start the call.");
      return false;
    }

    final uuid = placed.call.callUuid;
    if (_state.phase == ActiveCallPhase.idle) {
      await _leaveServer(uuid);
      return false;
    }

    startOutgoing(
      callUuid: uuid,
      callerName: callerName,
      callerAddress: address,
      avatarBytes: avatarBytes,
      isVideo: effectiveVideo,
      joinLink: placed.link,
      isTelephony: isTelephony,
      chatGuid: chatGuid,
      activeDeviceId: localDeviceId,
      activeDeviceName: localDeviceName,
    );

    final started = await _startWebRtcBridge(
      callUuid: uuid,
      wantVideo: effectiveVideo,
      answerCall: false,
    );
    if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) {
      await _stopWebRtcBridge(emitHangup: false);
      return false;
    }
    if (started) {
      return true;
    }

    final link = placed.link;
    if (effectiveVideo && link != null && link.isNotEmpty && onFallbackJoinLink != null) {
      onFallbackJoinLink(link);
      return true;
    }

    await endCall();
    reportError("Couldn't connect WebRTC media for this call.");
    return false;
  }

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
  bool _isForeground = true;

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
    _startIncomingRingtone(callUuid);
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
    _stopIncomingRingtone();
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
    _stopIncomingRingtone(callUuid);
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
    _stopIncomingRingtone(callUuid);
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
  void notifyTelecomActive(String callUuid, {bool isTelephony = false, bool? isVideo}) {
    if (callUuid.isEmpty) return;
    final wasIdle = _state.phase == ActiveCallPhase.idle;
    final wasOnOtherDevice = _state.isOnOtherDevice || _state.phase == ActiveCallPhase.incoming;
    final prevActiveDeviceId = _state.activeDeviceId;
    final matchesOrIdle = wasIdle ||
        _state.callUuid == null ||
        _state.callUuid!.isEmpty ||
        _state.callUuid == callUuid;
    if (!matchesOrIdle) return;

    final effectiveTelephony = isTelephony || (!wasIdle && _state.isTelephony);
    final effectiveVideo = effectiveTelephony ? false : (isVideo ?? (wasIdle ? false : _state.isVideo));

    if (wasIdle) {
      startOngoing(
        callUuid: callUuid,
        callerName: effectiveTelephony ? 'iPhone Call' : 'FaceTime Call',
        isVideo: effectiveVideo,
        isTelecomCall: true,
        isTelephony: effectiveTelephony,
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
        isVideo: effectiveVideo,
        isTelecomCall: true,
        isTelephony: effectiveTelephony,
        activeDeviceId: localDeviceId,
        activeDeviceName: localDeviceName,
        connectedAt: connectedAt,
        localDeviceId: localDeviceId,
      );
      _startTickerFrom(connectedAt);
      notifyListeners();
    }

    if (wasIdle || wasOnOtherDevice || prevActiveDeviceId != localDeviceId) {
      unawaited(_handoffServer(callUuid, mode: effectiveVideo ? 'video_bridge' : 'audio'));
    }
    unawaited(syncNativeVideoTextures(callUuid: callUuid));
  }

  /// Queries native Android Telecom for already-registered remote/local video
  /// texture IDs on controller attach or call screen init so calls whose native
  /// texture events arrived earlier still render video.
  Future<void> syncNativeVideoTextures({String? callUuid}) async {
    if (_isWeb || !Platform.isAndroid || !GetIt.I.isRegistered<MethodChannelService>()) return;
    if (_state.phase == ActiveCallPhase.idle || _webRtcClient.isActive) return;
    final targetUuid = (callUuid != null && callUuid.isNotEmpty) ? callUuid : _state.callUuid;
    if (targetUuid == null || targetUuid.isEmpty) return;

    int? remoteId;
    int? localId;
    try {
      remoteId = _parseTextureId(
        await MethodChannelSvc.channel.invokeMethod<dynamic>(
          'get-facetime-video-texture',
          {'call_uuid': targetUuid},
        ),
      );
    } catch (_) {}
    try {
      localId = _parseTextureId(
        await MethodChannelSvc.channel.invokeMethod<dynamic>(
          'get-facetime-local-video-texture',
          {'call_uuid': targetUuid},
        ),
      );
    } catch (_) {}

    if (_state.phase == ActiveCallPhase.idle || _state.callUuid != targetUuid) return;
    bool changed = false;
    if (remoteId != null && remoteId > 0) {
      remoteVideoWidget.value = Texture(textureId: remoteId);
      changed = true;
    }
    if (localId != null && localId > 0) {
      localVideoWidget.value = Texture(textureId: localId);
      cameraEnabled.value = true;
      changed = true;
    }
    if (changed) notifyListeners();
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

  void handleFacetimeCallState(Map<String, dynamic> arguments) {
    final phase = arguments['phase']?.toString();
    final uuid = arguments['call_uuid']?.toString();
    if (phase == null || uuid == null || uuid.isEmpty) return;
    final isTelephony = arguments['is_telephony'] == true;
    switch (phase) {
      case 'dialing':
        bindCallUuid(uuid, isTelephony: isTelephony);
        break;
      case 'active':
        notifyTelecomActive(
          uuid,
          isTelephony: isTelephony,
          isVideo: arguments['is_video'] is bool ? arguments['is_video'] as bool : null,
        );
        break;
      case 'mute':
        syncMutedFromNative(uuid, arguments['muted'] == true);
        break;
      case 'video-texture':
        if (_state.phase == ActiveCallPhase.idle) return;
        if (_state.callUuid != null && _state.callUuid!.isNotEmpty && _state.callUuid != uuid) return;
        final textureId = _parseTextureId(arguments['texture_id']);
        remoteVideoWidget.value = (textureId != null && textureId > 0) ? Texture(textureId: textureId) : null;
        notifyListeners();
        break;
      case 'local-video-texture':
        if (_state.phase == ActiveCallPhase.idle) return;
        if (_state.callUuid != null && _state.callUuid!.isNotEmpty && _state.callUuid != uuid) return;
        final textureId = _parseTextureId(arguments['texture_id']);
        final hasTex = textureId != null && textureId > 0;
        localVideoWidget.value = hasTex ? Texture(textureId: textureId) : null;
        cameraEnabled.value = arguments['camera_enabled'] is bool
            ? arguments['camera_enabled'] as bool
            : hasTex;
        if (arguments['can_flip_camera'] is bool) {
          canFlipCamera.value = arguments['can_flip_camera'] as bool;
        } else if (!hasTex) {
          canFlipCamera.value = false;
        }
        if (arguments['front_camera'] is bool) {
          isFrontCamera.value = arguments['front_camera'] as bool;
        }
        notifyListeners();
        break;
      case 'ended':
        if (_state.callUuid == uuid && !_state.isOnOtherDevice) {
          clear();
        }
        break;
    }
  }

  void toggleMute() {
    if (_state.phase != ActiveCallPhase.ongoing && _state.phase != ActiveCallPhase.outgoing) return;
    final nextMuted = !_state.isMuted;
    _state = _state.copyWith(isMuted: nextMuted);
    if (_onMuteChanged != null) {
      _onMuteChanged(nextMuted);
    } else if (_isWeb || _webRtcClient.isActive) {
      unawaited(_webRtcClient.setMuted(nextMuted));
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
    if (_webRtcClient.isActive) {
      await _webRtcClient.sendDtmf(digit);
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

    if (_isWeb && !effectiveAudioOnly && _webRtcClient.cachedConfig?.videoSupported != true) {
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

    if (_isWeb) {
      if (effectiveAudioOnly) {
        final started = await _startWebRtcBridge(
          callUuid: uuid,
          wantVideo: false,
          answerCall: true,
        );
        if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) {
          await _stopWebRtcBridge(emitHangup: false);
          return false;
        }
        if (started) {
          _closePendingCallTab();
          _dismissOverlay(uuid, keepCallState: true);
          startOngoing(
            callUuid: uuid,
            callerName: prev.callerName,
            callerAddress: prev.callerAddress,
            avatarBytes: prev.avatarBytes,
            isVideo: false,
            isTelecomCall: false,
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
        _closePendingCallTab();
        _stopIncomingRingtone(uuid);
        _dismissOverlay(uuid, keepCallState: false);
        clearPendingIfMatches(uuid);
        reportError("Couldn't connect WebRTC audio for this call.");
        return false;
      }

      final config = await getWebRtcConfig();
      if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) return false;
      if (config.videoSupported) {
        _closePendingCallTab();
        final started = await _startWebRtcBridge(
          callUuid: uuid,
          wantVideo: true,
          answerCall: true,
        );
        if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) {
          await _stopWebRtcBridge(emitHangup: false);
          return false;
        }
        if (started) {
          _dismissOverlay(uuid, keepCallState: true);
          startOngoing(
            callUuid: uuid,
            callerName: prev.callerName,
            callerAddress: prev.callerAddress,
            avatarBytes: prev.avatarBytes,
            isVideo: true,
            isTelecomCall: false,
            isTelephony: false,
            chatGuid: prev.chatGuid,
            isOutgoing: prev.isOutgoing,
            activeDeviceId: localDeviceId,
            activeDeviceName: localDeviceName,
            startedAt: prev.startedAt,
          );
          try {
            if (_onAnswerServerCall != null) {
              await _onAnswerServerCall(
                uuid,
                audioOnly: false,
                displayName: prev.callerName,
                chatGuid: prev.chatGuid,
              );
            } else {
              await _handoffServer(uuid, mode: 'video_bridge');
            }
          } catch (e, s) {
            _safeLogWarn('Failed to sync answered FaceTime video call', e, s);
          }
          _openInAppCallScreenIfPossible(context);
          return true;
        }
      }
    }

    final isVideo = !effectiveAudioOnly && !effectiveTelephony;
    if (!_isWeb && (Platform.isAndroid || _onStartTelecomCall != null || (!isVideo && _onStartTelecomAudio != null))) {
      final routed = await _startTelecomCall(
        callUuid: uuid,
        callerName: prev.callerName.isNotEmpty ? prev.callerName : (effectiveTelephony ? 'iPhone Call' : 'FaceTime Call'),
        callerAddress: prev.callerAddress,
        isTelephony: effectiveTelephony,
        isVideo: isVideo,
      );
      if (routed) {
        _closePendingCallTab();
        _dismissOverlay(uuid, keepCallState: true);
        startOngoing(
          callUuid: uuid,
          callerName: prev.callerName,
          callerAddress: prev.callerAddress,
          avatarBytes: prev.avatarBytes,
          isVideo: isVideo,
          isTelecomCall: true,
          isTelephony: effectiveTelephony,
          chatGuid: prev.chatGuid,
          isOutgoing: prev.isOutgoing,
          activeDeviceId: localDeviceId,
          activeDeviceName: localDeviceName,
          startedAt: prev.startedAt,
        );
        try {
          if (_onAnswerServerCall != null) {
            await _onAnswerServerCall(
              uuid,
              audioOnly: !isVideo,
              displayName: prev.callerName,
              chatGuid: prev.chatGuid,
            );
          } else {
            await _handoffServer(uuid, mode: isVideo ? 'video_bridge' : 'audio');
          }
        } catch (e, s) {
          _safeLogWarn('Failed to sync answered FaceTime call', e, s);
        }
        if (isVideo) {
          _openInAppCallScreenIfPossible(context);
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
        audioOnly: effectiveAudioOnly && !_isWeb,
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
      _stopIncomingRingtone(uuid);
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
    } else {
      mode = prev.isVideo ? 'video' : 'audio';
    }

    if ((_isWeb || _onOpenPendingTab != null) &&
        mode == 'video' &&
        (!_isWeb || _webRtcClient.cachedConfig?.videoSupported != true)) {
      _closePendingCallTab();
      _pendingCallTab = (_onOpenPendingTab ?? openPendingCallTab)();
    }

    if (_isWeb) {
      if (mode == 'audio') {
        try {
          await _handoffServer(uuid, mode: 'audio');
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

        final started = await _startWebRtcBridge(
          callUuid: uuid,
          wantVideo: false,
          answerCall: false,
          initialMuted: prev.isMuted,
        );
        if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) {
          await _stopWebRtcBridge(emitHangup: false);
          return false;
        }
        if (!started) {
          _closePendingCallTab();
          reportError("Couldn't connect WebRTC audio for this call.");
          return false;
        }
        final nextPhase = prev.phase == ActiveCallPhase.outgoing ? ActiveCallPhase.outgoing : ActiveCallPhase.ongoing;
        final nextConnectedAt = nextPhase == ActiveCallPhase.ongoing ? (prev.connectedAt ?? _now()) : prev.connectedAt;
        _state = prev.copyWith(
          phase: nextPhase,
          isVideo: false,
          isTelecomCall: false,
          activeDeviceId: localDeviceId,
          activeDeviceName: localDeviceName,
          connectedAt: nextConnectedAt,
          localDeviceId: localDeviceId,
        );
        if (nextPhase == ActiveCallPhase.ongoing && nextConnectedAt != null) {
          _startTickerFrom(nextConnectedAt);
        }
        notifyListeners();
        _closePendingCallTab();
        return true;
      }

      final config = await getWebRtcConfig();
      if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) return false;
      if (config.videoSupported) {
        _closePendingCallTab();
        final started = await _startWebRtcBridge(
          callUuid: uuid,
          wantVideo: true,
          answerCall: false,
          initialMuted: prev.isMuted,
        );
        if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) {
          await _stopWebRtcBridge(emitHangup: false);
          return false;
        }
        if (started) {
          try {
            await _handoffServer(uuid, mode: 'video_bridge');
          } on FaceTimeException catch (e, s) {
            _safeLogWarn('Failed to transfer FaceTime call here', e, s);
            await _stopWebRtcBridge();
            reportError(e.message);
            return false;
          } catch (e, s) {
            _safeLogWarn('Failed to transfer FaceTime call here', e, s);
            await _stopWebRtcBridge();
            reportError("Couldn't transfer the FaceTime call.");
            return false;
          }
          final nextPhase = prev.phase == ActiveCallPhase.outgoing ? ActiveCallPhase.outgoing : ActiveCallPhase.ongoing;
          final nextConnectedAt = nextPhase == ActiveCallPhase.ongoing ? (prev.connectedAt ?? _now()) : prev.connectedAt;
          _state = prev.copyWith(
            phase: nextPhase,
            isVideo: true,
            isTelecomCall: false,
            activeDeviceId: localDeviceId,
            activeDeviceName: localDeviceName,
            connectedAt: nextConnectedAt,
            localDeviceId: localDeviceId,
          );
          if (nextPhase == ActiveCallPhase.ongoing && nextConnectedAt != null) {
            _startTickerFrom(nextConnectedAt);
          }
          notifyListeners();
          _openInAppCallScreenIfPossible(context);
          return true;
        }
      }
    }

    final effectiveVideo = mode == 'video' && !prev.isTelephony;
    final bool useTelecom = !_isWeb &&
        (Platform.isAndroid || _onStartTelecomCall != null || (!effectiveVideo && _onStartTelecomAudio != null));
    bool telecomStarted = false;
    if (useTelecom) {
      telecomStarted = await _startTelecomCall(
        callUuid: uuid,
        callerName: prev.callerName.isNotEmpty ? prev.callerName : (prev.isTelephony ? 'iPhone Call' : 'FaceTime Call'),
        callerAddress: prev.callerAddress,
        isTelephony: prev.isTelephony,
        isVideo: effectiveVideo,
      );
    }

    PlacedFaceTimeCall? placed;
    try {
      placed = await _handoffServer(
        uuid,
        mode: telecomStarted && effectiveVideo ? 'video_bridge' : mode,
      );
    } on FaceTimeException catch (e, s) {
      _safeLogWarn('Failed to transfer FaceTime call here', e, s);
      if (telecomStarted) {
        unawaited(_endNativeCall(uuid, onlyIfRinging: false));
      }
      _closePendingCallTab();
      reportError(e.message);
      return false;
    } catch (e, s) {
      _safeLogWarn('Failed to transfer FaceTime call here', e, s);
      if (telecomStarted) {
        unawaited(_endNativeCall(uuid, onlyIfRinging: false));
      }
      _closePendingCallTab();
      reportError("Couldn't transfer the FaceTime call.");
      return false;
    }

    final link = placed?.link ?? prev.joinLink;
    final nextPhase = prev.phase == ActiveCallPhase.outgoing ? ActiveCallPhase.outgoing : ActiveCallPhase.ongoing;
    final nextConnectedAt = nextPhase == ActiveCallPhase.ongoing ? (prev.connectedAt ?? _now()) : prev.connectedAt;

    _state = prev.copyWith(
      phase: nextPhase,
      isVideo: effectiveVideo,
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
      if (effectiveVideo) {
        _openInAppCallScreenIfPossible(context);
      }
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
    final bridgeActive = _webRtcClient.isActive;
    _stopTicker();
    _stopIncomingRingtone();
    _closePendingCallTab();
    _resetVideoNotifiers();
    isSpeakerOn.value = false;
    _elapsed = Duration.zero;
    if (_state.phase != ActiveCallPhase.idle) {
      _state = ActiveCallState.idle;
      notifyListeners();
    }
    if (bridgeActive) {
      await _stopWebRtcBridge(emitHangup: true);
    }

    final uuid = prev.callUuid;
    if (uuid != null && uuid.isNotEmpty) {
      _stopIncomingRingtone(uuid);
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

      _stopIncomingRingtone(uuid);
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

      if (matchesActive && failureReason != null && _lastFailureUuid != uuid) {
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

    final rawActiveDeviceId = data.containsKey('active_device_id')
        ? _nonEmptyString(data['active_device_id'])
        : (matchesPrev ? prev.activeDeviceId : null);
    final rawActiveDeviceName = data.containsKey('active_device_name')
        ? _nonEmptyString(data['active_device_name'])
        : (matchesPrev ? prev.activeDeviceName : null);
    final holdsWebRtcHere = _webRtcClient.activeCallUuid == uuid;
    final activeDeviceId = rawActiveDeviceId ?? (holdsWebRtcHere ? localDeviceId : null);
    final activeDeviceName = rawActiveDeviceName ?? (holdsWebRtcHere ? localDeviceName : null);
    final nowOnOtherDevice = activeDeviceId != null && activeDeviceId != localDeviceId;

    final wasHeldHere = matchesPrev && prev.isHeldHere;
    final wasTelecom = matchesPrev && prev.isTelecomCall;

    // Remote device took over an active call from us -> close local Web tab / Telecom / WebRTC without hanging up server.
    if (nowOnOtherDevice && (wasHeldHere || wasTelecom || holdsWebRtcHere || _pendingCallTab != null)) {
      _closePendingCallTab();
      if (holdsWebRtcHere) {
        unawaited(_stopWebRtcBridge(emitHangup: false));
      }
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

    if (nextPhase == ActiveCallPhase.incoming) {
      _startIncomingRingtone(uuid);
    } else {
      _stopIncomingRingtone(uuid);
    }

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
          _stopIncomingRingtone(uuid);
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
    _stopIncomingRingtone();
    _closePendingCallTab();
    _resetVideoNotifiers();
    isSpeakerOn.value = false;
    _elapsed = Duration.zero;
    if (_state.phase != ActiveCallPhase.idle) {
      _state = ActiveCallState.idle;
      notifyListeners();
    }
    if (_webRtcClient.isActive) {
      unawaited(_stopWebRtcBridge(emitHangup: false));
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

  void _openInAppCallScreenIfPossible(BuildContext? context) {
    BuildContext? target = (context != null && context.mounted) ? context : null;
    if (target == null) {
      try {
        final ctx = Get.context;
        if (ctx != null && ctx.mounted) {
          target = ctx;
        }
      } catch (_) {
        return;
      }
    }
    if (target == null || !target.mounted) return;
    if (Navigator.maybeOf(target, rootNavigator: true) == null) return;
    openInAppCallScreen(context: target, controller: this);
  }

  Future<bool> _startTelecomCall({
    required String callUuid,
    required String callerName,
    String? callerAddress,
    required bool isTelephony,
    required bool isVideo,
  }) async {
    final effectiveVideo = isVideo && !isTelephony;
    if (_onStartTelecomCall != null) {
      return _onStartTelecomCall(
        callUuid: callUuid,
        callerName: callerName,
        callerAddress: callerAddress,
        isTelephony: isTelephony,
        isVideo: effectiveVideo,
      );
    }
    if (!effectiveVideo && _onStartTelecomAudio != null) {
      return _onStartTelecomAudio(
        callUuid: callUuid,
        callerName: callerName,
        callerAddress: callerAddress,
        isTelephony: isTelephony,
      );
    }
    if (!kIsWeb && Platform.isAndroid && GetIt.I.isRegistered<MethodChannelService>()) {
      if (effectiveVideo) {
        final result = await MethodChannelSvc.channel.invokeMethod<bool>('answer-facetime-audio', {
          'call_uuid': callUuid,
          'caller_name': callerName,
          'caller_address': callerAddress,
          'is_telephony': false,
          'is_video': true,
        });
        return result == true;
      }
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

  void setForeground(bool foreground) {
    if (_isForeground == foreground) return;
    _isForeground = foreground;
    if (!foreground) {
      _stopTicker();
      return;
    }
    if (_state.phase == ActiveCallPhase.ongoing && _state.connectedAt != null) {
      _startTickerFrom(_state.connectedAt!);
      notifyListeners();
    }
  }

  void _startTickerFrom(DateTime connectedAt) {
    _stopTicker();
    final diff = _now().difference(connectedAt);
    _elapsed = diff.isNegative ? Duration.zero : diff;
    if (!_isForeground) return;
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

  void _startIncomingRingtone(String? uuid) {
    if (uuid == null || uuid.isEmpty) return;
    if (_ringingCallUuid == uuid) return;
    if (_ringingCallUuid != null) {
      _stopIncomingRingtone(_ringingCallUuid);
    }
    _ringingCallUuid = uuid;
    if (_onStartIncomingRingtone != null) {
      _onStartIncomingRingtone(uuid);
      return;
    }
    if (kIsWeb && identical(this, instance)) {
      final double volume = GetIt.I.isRegistered<SettingsService>()
          ? (SettingsSvc.settings.soundVolume.value / 100.0).clamp(0.0, 1.0)
          : 1.0;
      startWebFaceTimeRingtone(callUuid: uuid, volume: volume);
    }
  }

  void _stopIncomingRingtone([String? uuid]) {
    final active = _ringingCallUuid;
    if (active != null && uuid != null && uuid.isNotEmpty && active != uuid) {
      return;
    }
    final target = (uuid != null && uuid.isNotEmpty) ? uuid : active;
    final hadActive = active != null;
    _ringingCallUuid = null;
    if (_onStopIncomingRingtone != null) {
      if (hadActive || (uuid != null && uuid.isNotEmpty)) {
        _onStopIncomingRingtone(target);
      }
      return;
    }
    if (kIsWeb && identical(this, instance)) {
      stopWebFaceTimeRingtone(callUuid: target);
    }
  }

  @override
  void dispose() {
    _stopTicker();
    _stopIncomingRingtone();
    _closePendingCallTab();
    _webRtcClient.dispose();
    remoteVideoWidget.close();
    localVideoWidget.close();
    cameraEnabled.close();
    canFlipCamera.close();
    isFrontCamera.close();
    isSpeakerOn.close();
    super.dispose();
  }
}
