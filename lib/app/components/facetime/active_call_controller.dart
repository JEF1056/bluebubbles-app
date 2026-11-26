import 'dart:async';

import 'package:bluebubbles/app/components/facetime/web_ringtone.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/facetime/facetime_media_models.dart';
import 'package:bluebubbles/services/facetime/web_webrtc_client.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
class CallParticipant {
  final String address;
  final String? displayName;
  final Uint8List? avatarBytes;

  const CallParticipant({
    required this.address,
    this.displayName,
    this.avatarBytes,
  });

  String get label {
    final name = displayName?.trim();
    return (name != null && name.isNotEmpty) ? name : address;
  }

  CallParticipant copyWith({
    String? address,
    String? displayName,
    Uint8List? avatarBytes,
  }) {
    return CallParticipant(
      address: address ?? this.address,
      displayName: displayName ?? this.displayName,
      avatarBytes: avatarBytes ?? this.avatarBytes,
    );
  }
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
  final bool isGroup;
  final List<String> participants;
  final List<CallParticipant> participantDetails;
  final String? joinLink;
  final DateTime? connectedAt;
  final String? chatGuid;
  final bool isOutgoing;
  final bool isLinkOnly;
  final String? activeDeviceId;
  final String? activeDeviceName;
  final DateTime? startedAt;
  final String? localDeviceId;
  final bool endpointOnMac;
  final bool fromIphone;

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
    this.isGroup = false,
    this.participants = const [],
    this.participantDetails = const [],
    this.joinLink,
    this.connectedAt,
    this.chatGuid,
    this.isOutgoing = false,
    this.isLinkOnly = false,
    this.activeDeviceId,
    this.activeDeviceName,
    this.startedAt,
    this.localDeviceId,
    this.endpointOnMac = true,
    this.fromIphone = false,
  });

  static const idle = ActiveCallState();

  bool get isActive => phase != ActiveCallPhase.idle;
  bool get isIncoming => phase == ActiveCallPhase.incoming;
  bool get isOutgoingPhase => phase == ActiveCallPhase.outgoing;
  bool get isConnecting => phase == ActiveCallPhase.connecting;
  bool get isOngoing => phase == ActiveCallPhase.ongoing;
  bool get hasCallUuid => callUuid != null && callUuid!.isNotEmpty;
  bool get hasJoinLink => joinLink != null && joinLink!.isNotEmpty;
  bool get canShowKeypad => hasCallUuid;

  String get callKindLabel => ActiveCallController.callKindLabelFor(
        isVideo: isVideo,
        isTelephony: isTelephony,
        isGroup: isGroup,
      );

  String get displayCallerName {
    if (callerName.isNotEmpty && !ActiveCallController.isGenericCallLabel(callerName)) {
      return callerName;
    }
    if (isGroup && participantDetails.isNotEmpty) {
      return participantDetails.map((p) => p.label).join(', ');
    }
    if (isGroup && participants.isNotEmpty) {
      return participants.join(', ');
    }
    final addr = callerAddress?.trim();
    if (addr != null && addr.isNotEmpty) return addr;
    return callKindLabel;
  }

  String? get distinctCallerHandle {
    if (isGroup && participants.length > 1) return null;
    final addr = callerAddress?.trim();
    if (addr == null || addr.isEmpty) return null;
    if (addr.toLowerCase() == displayCallerName.trim().toLowerCase()) return null;
    return addr;
  }

  String get _effectiveLocalDeviceId =>
      (localDeviceId != null && localDeviceId!.isNotEmpty) ? localDeviceId! : ActiveCallController.instance.localDeviceId;

  bool get isOnOtherDevice =>
      !endpointOnMac ||
      (activeDeviceId != null && activeDeviceId!.isNotEmpty && activeDeviceId != _effectiveLocalDeviceId);

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
        return 'Incoming $callKindLabel';
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
        return callKindLabel;
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
    bool? isGroup,
    List<String>? participants,
    List<CallParticipant>? participantDetails,
    String? joinLink,
    DateTime? connectedAt,
    String? chatGuid,
    bool? isOutgoing,
    bool? isLinkOnly,
    String? activeDeviceId,
    String? activeDeviceName,
    DateTime? startedAt,
    String? localDeviceId,
    bool? endpointOnMac,
    bool? fromIphone,
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
      isGroup: isGroup ?? this.isGroup,
      participants: participants ?? this.participants,
      participantDetails: participantDetails ?? this.participantDetails,
      joinLink: clearJoinLink ? null : (joinLink ?? this.joinLink),
      connectedAt: connectedAt ?? this.connectedAt,
      chatGuid: chatGuid ?? this.chatGuid,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      isLinkOnly: isLinkOnly ?? this.isLinkOnly,
      activeDeviceId: clearActiveDevice ? null : (activeDeviceId ?? this.activeDeviceId),
      activeDeviceName: clearActiveDevice ? null : (activeDeviceName ?? this.activeDeviceName),
      startedAt: startedAt ?? this.startedAt,
      localDeviceId: localDeviceId ?? this.localDeviceId,
      endpointOnMac: endpointOnMac ?? this.endpointOnMac,
      fromIphone: fromIphone ?? this.fromIphone,
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
class ActiveCallController extends ChangeNotifier with WidgetsBindingObserver {
  static final ActiveCallController instance = ActiveCallController();

  static const int maxTelecomAvatarBytes = 256 * 1024;

  static const Set<String> _genericCallLabels = {
    'facetime call',
    'facetime video',
    'facetime audio',
    'group facetime video',
    'group facetime audio',
    'iphone call',
    'phone call',
    'active call',
    'unknown number',
  };

  static String callKindLabelFor({
    required bool isVideo,
    bool isTelephony = false,
    bool isGroup = false,
  }) {
    if (isTelephony) return 'Phone Call';
    if (isGroup) return isVideo ? 'Group FaceTime Video' : 'Group FaceTime Audio';
    return isVideo ? 'FaceTime Video' : 'FaceTime Audio';
  }

  static bool isGenericCallLabel(String? value) {
    final trimmed = value?.trim().toLowerCase() ?? '';
    return trimmed.isEmpty || _genericCallLabels.contains(trimmed);
  }

  static String _normalizePhoneDigits(String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > 10) return digits.substring(digits.length - 10);
    return digits;
  }

  static String _normalizeAddressKey(String address) {
    final trimmed = address.trim().toLowerCase();
    if (trimmed.contains('@')) return trimmed;
    final digits = _normalizePhoneDigits(trimmed);
    return digits.length >= 7 ? digits : trimmed;
  }

  static Set<String> selfAddresses() {
    final out = <String>{};
    if (!GetIt.I.isRegistered<SettingsService>()) return out;
    try {
      final svc = SettingsSvc;
      void addCandidate(dynamic raw) {
        if (raw is String) {
          final trimmed = raw.trim();
          if (trimmed.isNotEmpty) out.add(trimmed);
        } else if (raw is Iterable) {
          for (final item in raw) {
            addCandidate(item);
          }
        }
      }

      addCandidate(svc.iCloudAliases);
      addCandidate(svc.iCloudActiveAlias.value);
      addCandidate(svc.settings.iCloudAccount.value);
      final info = svc.iCloudAccountInfo;
      addCandidate(info['vetted_aliases']);
      addCandidate(info['vettedAliases']);
      addCandidate(info['aliases']);
      addCandidate(info['active_alias']);
      addCandidate(info['apple_id']);
      addCandidate(info['email']);
    } catch (_) {
      // SettingsService may be partially initialized in unit tests.
    }
    return out;
  }

  static bool isSelfAddress(String address, Iterable<String> self) {
    final key = _normalizeAddressKey(address);
    if (key.isEmpty) return false;
    for (final s in self) {
      final sKey = _normalizeAddressKey(s);
      if (sKey.isNotEmpty && sKey == key) return true;
    }
    return false;
  }

  static List<String> filterRemoteAddresses(
    Iterable<String> rawAddresses, {
    Iterable<String>? selfAddresses,
  }) {
    final own = selfAddresses ?? ActiveCallController.selfAddresses();
    final seen = <String>{};
    final result = <String>[];
    for (final raw in rawAddresses) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      if (isSelfAddress(trimmed, own)) continue;
      final key = _normalizeAddressKey(trimmed);
      if (seen.add(key)) {
        result.add(trimmed);
      }
    }
    return result;
  }

  static String formatParticipantNames(
    Iterable<String> names, {
    required bool isVideo,
    bool isTelephony = false,
    bool isGroup = false,
  }) {
    final cleaned = names.map((n) => n.trim()).where((n) => n.isNotEmpty).toList(growable: false);
    if (cleaned.isNotEmpty) return cleaned.join(', ');
    return callKindLabelFor(isVideo: isVideo, isTelephony: isTelephony, isGroup: isGroup);
  }

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
    // Missed and remotely-handled calls are never error banners.
    if (reason == 'missed' || reason == 'answered_elsewhere' || reason == 'declined_elsewhere') return null;
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
    Future<PlacedFaceTimeCall?> Function(
      String callUuid, {
      bool audioOnly,
      String? mode,
      String? displayName,
      String? chatGuid,
    })? onAnswerServerCall,
    Future<void> Function(String callUuid)? onDeclineServerCall,
    Future<void> Function(String callUuid)? onLeaveServerCall,
    Future<PlacedFaceTimeCall?> Function(String callUuid, {String? mode})? onHandoffServerCall,
    Future<dynamic> Function(String callUuid)? onTransferBackServerCall,
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
    void Function(String? callUuid)? onStartOutgoingRingback,
    void Function(String? callUuid)? onStopOutgoingRingback,
    void Function()? onPlayCallEndedTone,
    WebWebRtcClient? webRtcClient,
    Future<bool> Function(bool enabled)? onToggleSpeaker,
    Future<bool> Function(bool enabled)? onSetVoiceIsolation,
    Future<bool> Function(FaceTimeVideoEffectType effect, bool denoise, String? backgroundId, String? backgroundPath)?
        onSetVideoProcessing,
    Future<bool> Function(String deviceId)? onSelectAudioOutput,
    Future<bool> Function(String deviceId)? onSelectAudioInput,
    Future<
            ({
              List<FaceTimeAudioDevice> outputs,
              List<FaceTimeAudioDevice> inputs,
              String? activeOutputId,
              String? activeInputId,
            })>
        Function()? onFetchAudioDevices,
    Future<bool> Function()? onCheckWearWatchConnected,
    Future<bool> Function(String callUuid)? onTransferCallToWatch,
    Future<({int? remoteId, int? localId})> Function(String callUuid)? onFetchNativeVideoTextureIds,
    bool wearWatchConnected = false,
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
        _onTransferBackServerCall = onTransferBackServerCall,
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
        _onStartOutgoingRingback = onStartOutgoingRingback,
        _onStopOutgoingRingback = onStopOutgoingRingback,
        _onPlayCallEndedTone = onPlayCallEndedTone,
        _webRtcClient = webRtcClient ?? WebWebRtcClient(),
        _onToggleSpeaker = onToggleSpeaker,
        _onSetVoiceIsolation = onSetVoiceIsolation,
        _onSetVideoProcessing = onSetVideoProcessing,
        _onSelectAudioOutput = onSelectAudioOutput,
        _onSelectAudioInput = onSelectAudioInput,
        _onFetchAudioDevices = onFetchAudioDevices,
        _onCheckWearWatchConnected = onCheckWearWatchConnected,
        _onTransferCallToWatch = onTransferCallToWatch,
        _onFetchNativeVideoTextureIds = onFetchNativeVideoTextureIds,
        _wearWatchConnected = wearWatchConnected,
        _isWebOverride = isWebOverride {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
  }

  final Future<void> Function(String? callUuid, bool isTelecom)? _onEndCall;
  final Future<void> Function(String? joinLink, BuildContext? context)? _onReturnToCall;
  final void Function(bool muted)? _onMuteChanged;
  final Future<void> Function(String callUuid, String digit)? _onSendDtmf;
  final DateTime Function() _now;
  final String? _deviceId;
  final String? _deviceName;
  final Future<PlacedFaceTimeCall?> Function(
    String callUuid, {
    bool audioOnly,
    String? mode,
    String? displayName,
    String? chatGuid,
  })? _onAnswerServerCall;
  final Future<void> Function(String callUuid)? _onDeclineServerCall;
  final Future<void> Function(String callUuid)? _onLeaveServerCall;
  final Future<PlacedFaceTimeCall?> Function(String callUuid, {String? mode})? _onHandoffServerCall;
  final Future<dynamic> Function(String callUuid)? _onTransferBackServerCall;
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
  final void Function(String? callUuid)? _onStartOutgoingRingback;
  final void Function(String? callUuid)? _onStopOutgoingRingback;
  final void Function()? _onPlayCallEndedTone;
  final WebWebRtcClient _webRtcClient;
  final Future<bool> Function(bool enabled)? _onToggleSpeaker;
  final Future<bool> Function(bool enabled)? _onSetVoiceIsolation;
  final Future<bool> Function(
    FaceTimeVideoEffectType effect,
    bool denoise,
    String? backgroundId,
    String? backgroundPath,
  )? _onSetVideoProcessing;
  final Future<bool> Function(String deviceId)? _onSelectAudioOutput;
  final Future<bool> Function(String deviceId)? _onSelectAudioInput;
  final Future<
          ({
            List<FaceTimeAudioDevice> outputs,
            List<FaceTimeAudioDevice> inputs,
            String? activeOutputId,
            String? activeInputId,
          })>
      Function()? _onFetchAudioDevices;
  final Future<bool> Function()? _onCheckWearWatchConnected;
  final Future<bool> Function(String callUuid)? _onTransferCallToWatch;
  final Future<({int? remoteId, int? localId})> Function(String callUuid)? _onFetchNativeVideoTextureIds;
  bool _wearWatchConnected;
  bool _disposed = false;
  final bool? _isWebOverride;
  String? _ringingCallUuid;
  bool _ringbackActive = false;
  String? _ringbackCallUuid;
  int? _remoteTextureId;
  double? _remoteTextureWidth;
  double? _remoteTextureHeight;
  int? _localTextureId;
  double? _localTextureWidth;
  double? _localTextureHeight;

  bool get _isWeb => _isWebOverride ?? kIsWeb;
  bool get wearWatchConnected => _wearWatchConnected;

  double? get remoteVideoWidth => _remoteTextureWidth;
  double? get remoteVideoHeight => _remoteTextureHeight;
  double? get localVideoWidth => _localTextureWidth;
  double? get localVideoHeight => _localTextureHeight;
  double get remoteAspectRatio {
    if (_remoteTextureWidth != null && _remoteTextureHeight != null && _remoteTextureHeight! > 0) {
      return _remoteTextureWidth! / _remoteTextureHeight!;
    }
    return 16 / 9;
  }

  final Rxn<Widget> remoteVideoWidget = Rxn<Widget>();
  final Rxn<Widget> localVideoWidget = Rxn<Widget>();
  final RxBool cameraEnabled = false.obs;
  final RxBool canFlipCamera = false.obs;
  final RxBool isFrontCamera = true.obs;
  final RxBool isSpeakerOn = false.obs;
  final RxBool isReconnecting = false.obs;
  final RxBool voiceIsolationEnabled = true.obs;
  final RxBool videoDenoiseEnabled = true.obs;
  final RxBool audioOnWatch = false.obs;
  final Rx<FaceTimeVideoEffectType> videoEffect = FaceTimeVideoEffectType.none.obs;
  final RxnString virtualBackgroundId = RxnString();
  final RxnString virtualBackgroundPath = RxnString();
  final RxList<FaceTimeAudioDevice> audioOutputs = <FaceTimeAudioDevice>[].obs;
  final RxnString activeAudioOutputId = RxnString();
  final RxBool canSelectAudioOutput = false.obs;
  final RxList<FaceTimeAudioDevice> audioInputs = <FaceTimeAudioDevice>[].obs;
  final RxnString activeAudioInputId = RxnString();
  final Rxn<FaceTimeCallQualityStats> callQualityStats = Rxn<FaceTimeCallQualityStats>();

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

  Future<bool> setVoiceIsolation(bool enabled) async {
    if (_onSetVoiceIsolation != null) {
      try {
        final applied = await _onSetVoiceIsolation(enabled);
        if (applied) {
          voiceIsolationEnabled.value = enabled;
          notifyListeners();
        }
        return applied;
      } catch (_) {
        return false;
      }
    }
    if (_webRtcClient.isActive || _isWeb) {
      try {
        final applied = await _webRtcClient.setVoiceIsolation(enabled);
        if (applied) {
          voiceIsolationEnabled.value = enabled;
          notifyListeners();
        }
        return applied;
      } catch (_) {
        return false;
      }
    }
    if (!kIsWeb &&
        Platform.isAndroid &&
        GetIt.I.isRegistered<MethodChannelService>() &&
        (_state.callUuid?.isNotEmpty ?? false)) {
      try {
        final result = await MethodChannelSvc.channel.invokeMethod<bool>(
          'set-facetime-voice-isolation',
          <String, dynamic>{'call_uuid': _state.callUuid, 'enabled': enabled},
        );
        final applied = result ?? true;
        if (applied) {
          voiceIsolationEnabled.value = enabled;
          notifyListeners();
        }
        return applied;
      } catch (_) {
        return false;
      }
    }
    voiceIsolationEnabled.value = enabled;
    notifyListeners();
    return true;
  }

  Future<bool> setVideoDenoise(bool enabled) => _applyVideoProcessing(
        effect: videoEffect.value,
        denoise: enabled,
        backgroundId: virtualBackgroundId.value,
        backgroundPath: virtualBackgroundPath.value,
      );

  Future<bool> setVideoEffect(
    FaceTimeVideoEffectType effect, {
    String? backgroundId,
    String? backgroundPath,
  }) =>
      _applyVideoProcessing(
        effect: effect,
        denoise: videoDenoiseEnabled.value,
        backgroundId: effect == FaceTimeVideoEffectType.virtualBackground ? (backgroundId ?? virtualBackgroundId.value) : null,
        backgroundPath:
            effect == FaceTimeVideoEffectType.virtualBackground ? (backgroundPath ?? virtualBackgroundPath.value) : null,
      );

  Future<bool> _applyVideoProcessing({
    required FaceTimeVideoEffectType effect,
    required bool denoise,
    String? backgroundId,
    String? backgroundPath,
  }) async {
    bool applied = false;
    if (_onSetVideoProcessing != null) {
      try {
        applied = await _onSetVideoProcessing(effect, denoise, backgroundId, backgroundPath);
      } catch (_) {
        return false;
      }
    } else if (_webRtcClient.isActive || _isWeb) {
      try {
        applied = await _webRtcClient.setVideoProcessing(
          effect: effect,
          denoise: denoise,
          backgroundId: backgroundId,
          backgroundPath: backgroundPath,
        );
      } catch (_) {
        return false;
      }
    } else if (!kIsWeb &&
        Platform.isAndroid &&
        GetIt.I.isRegistered<MethodChannelService>() &&
        (_state.callUuid?.isNotEmpty ?? false)) {
      try {
        final result = await MethodChannelSvc.channel.invokeMethod<bool>(
          'set-facetime-video-processing',
          <String, dynamic>{
            'call_uuid': _state.callUuid,
            'effect': effect.name,
            'denoise': denoise,
            if (backgroundId != null) 'background_id': backgroundId,
            if (backgroundPath != null) 'background_path': backgroundPath,
          },
        );
        applied = result ?? true;
      } catch (_) {
        return false;
      }
    } else {
      applied = true;
    }

    if (applied) {
      videoEffect.value = effect;
      videoDenoiseEnabled.value = denoise;
      if (effect == FaceTimeVideoEffectType.virtualBackground) {
        virtualBackgroundId.value = backgroundId;
        virtualBackgroundPath.value = backgroundPath;
      } else {
        virtualBackgroundId.value = null;
        virtualBackgroundPath.value = null;
      }
      notifyListeners();
    }
    return applied;
  }

  Future<void> refreshWearWatchConnected() async {
    bool connected = false;
    if (_onCheckWearWatchConnected != null) {
      try {
        connected = await _onCheckWearWatchConnected();
      } catch (_) {
        connected = false;
      }
    } else if (!_isWeb && Platform.isAndroid && GetIt.I.isRegistered<MethodChannelService>()) {
      try {
        final res = await MethodChannelSvc.channel.invokeMethod<bool>('is-wear-watch-connected');
        connected = res ?? false;
      } catch (_) {
        connected = false;
      }
    }
    if (!_disposed && _wearWatchConnected != connected) {
      _wearWatchConnected = connected;
      notifyListeners();
    }
  }

  Future<bool> transferCallToWatch() async {
    final callUuid = _state.callUuid;
    bool ok = false;
    if (_onTransferCallToWatch != null) {
      try {
        ok = await _onTransferCallToWatch(callUuid ?? '');
      } catch (_) {
        ok = false;
      }
    } else if (!_isWeb &&
        Platform.isAndroid &&
        GetIt.I.isRegistered<MethodChannelService>() &&
        callUuid != null &&
        callUuid.isNotEmpty) {
      try {
        final res = await MethodChannelSvc.channel.invokeMethod<bool>(
          'transfer-call-to-watch',
          <String, dynamic>{'call_uuid': callUuid},
        );
        ok = res ?? false;
      } catch (_) {
        ok = false;
      }
    }
    if (ok && !_disposed) {
      audioOnWatch.value = true;
      notifyListeners();
    }
    return ok;
  }

  Future<bool> transferCallToPhone() async {
    final callUuid = _state.callUuid;
    bool ok = false;
    if (!_isWeb &&
        Platform.isAndroid &&
        GetIt.I.isRegistered<MethodChannelService>() &&
        callUuid != null &&
        callUuid.isNotEmpty) {
      try {
        final res = await MethodChannelSvc.channel.invokeMethod<bool>(
          'transfer-call-to-phone',
          <String, dynamic>{'call_uuid': callUuid},
        );
        ok = res ?? false;
      } catch (_) {
        ok = false;
      }
    }
    if (ok && !_disposed) {
      audioOnWatch.value = false;
      notifyListeners();
    }
    return ok;
  }

  Future<void> refreshAudioDevices() async {
    if (_onFetchAudioDevices != null) {
      try {
        final res = await _onFetchAudioDevices();
        _applyAudioDeviceLists(res.outputs, res.inputs, res.activeOutputId, res.activeInputId);
        canSelectAudioOutput.value = res.outputs.isNotEmpty;
        notifyListeners();
      } catch (_) {}
      return;
    }
    if (_webRtcClient.isActive) {
      await _webRtcClient.refreshAudioDevices();
      _applyAudioDeviceLists(
        _webRtcClient.audioOutputs.value,
        _webRtcClient.audioInputs.value,
        _webRtcClient.activeAudioOutputId.value,
        _webRtcClient.activeAudioInputId.value,
      );
      canSelectAudioOutput.value = _webRtcClient.canSelectAudioOutput.value;
      notifyListeners();
      return;
    }
    if (!kIsWeb && Platform.isAndroid && GetIt.I.isRegistered<MethodChannelService>()) {
      try {
        final raw = await MethodChannelSvc.channel.invokeMethod<dynamic>(
          'get-facetime-audio-devices',
          <String, dynamic>{if (_state.callUuid != null) 'call_uuid': _state.callUuid},
        );
        if (raw is Map) {
          _applyAudioDeviceMap(raw);
          notifyListeners();
        }
      } catch (_) {}
    }
  }

  Future<bool> selectAudioOutput(String deviceId) async {
    bool applied = false;
    if (_onSelectAudioOutput != null) {
      try {
        applied = await _onSelectAudioOutput(deviceId);
      } catch (_) {
        return false;
      }
    } else if (_webRtcClient.isActive) {
      applied = await _webRtcClient.selectAudioOutput(deviceId);
    } else if (!kIsWeb &&
        Platform.isAndroid &&
        GetIt.I.isRegistered<MethodChannelService>() &&
        (_state.callUuid?.isNotEmpty ?? false)) {
      try {
        final res = await MethodChannelSvc.channel.invokeMethod<bool>(
          'set-facetime-audio-output',
          <String, dynamic>{'call_uuid': _state.callUuid, 'device_id': deviceId},
        );
        applied = res ?? true;
      } catch (_) {
        return false;
      }
    }
    if (applied) {
      activeAudioOutputId.value = deviceId;
      audioOutputs.assignAll(
        audioOutputs.map((d) => d.copyWith(isActive: d.id == deviceId)).toList(growable: false),
      );
      final selected = audioOutputs.firstWhereOrNull((d) => d.id == deviceId);
      if (selected != null) {
        isSpeakerOn.value = selected.kind == FaceTimeAudioDeviceKind.speaker;
        if (selected.kind != FaceTimeAudioDeviceKind.bluetooth) {
          audioOnWatch.value = false;
        }
      }
      notifyListeners();
    }
    return applied;
  }

  Future<bool> selectAudioInput(String deviceId) async {
    bool applied = false;
    if (_onSelectAudioInput != null) {
      try {
        applied = await _onSelectAudioInput(deviceId);
      } catch (_) {
        return false;
      }
    } else if (_webRtcClient.isActive) {
      applied = await _webRtcClient.selectAudioInput(deviceId);
    } else if (!kIsWeb &&
        Platform.isAndroid &&
        GetIt.I.isRegistered<MethodChannelService>() &&
        (_state.callUuid?.isNotEmpty ?? false)) {
      try {
        final res = await MethodChannelSvc.channel.invokeMethod<bool>(
          'set-facetime-audio-input',
          <String, dynamic>{'call_uuid': _state.callUuid, 'device_id': deviceId},
        );
        applied = res ?? true;
      } catch (_) {
        return false;
      }
    }
    if (applied) {
      activeAudioInputId.value = deviceId;
      audioInputs.assignAll(
        audioInputs.map((d) => d.copyWith(isActive: d.id == deviceId)).toList(growable: false),
      );
      notifyListeners();
    }
    return applied;
  }

  void _applyAudioDeviceMap(Map<dynamic, dynamic> raw) {
    final rawOutputs = raw['outputs'] is List ? raw['outputs'] as List : const <dynamic>[];
    final rawInputs = raw['inputs'] is List ? raw['inputs'] as List : const <dynamic>[];
    final outputs = rawOutputs
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => FaceTimeAudioDevice.fromJson(m, isInputOverride: false))
        .where((d) => d.id.isNotEmpty)
        .toList(growable: false);
    final inputs = rawInputs
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => FaceTimeAudioDevice.fromJson(m, isInputOverride: true))
        .where((d) => d.id.isNotEmpty)
        .toList(growable: false);
    final activeOut = _nonEmptyString(raw['active_output_id'] ?? raw['activeOutputId']) ??
        outputs.firstWhereOrNull((d) => d.isActive)?.id;
    final activeIn = _nonEmptyString(raw['active_input_id'] ?? raw['activeInputId']) ??
        inputs.firstWhereOrNull((d) => d.isActive)?.id;
    _applyAudioDeviceLists(outputs, inputs, activeOut, activeIn);
    if (raw['can_select_output'] is bool) {
      canSelectAudioOutput.value = raw['can_select_output'] as bool;
    } else if (outputs.isNotEmpty) {
      canSelectAudioOutput.value = true;
    }
  }

  void _applyAudioDeviceLists(
    List<FaceTimeAudioDevice> outputs,
    List<FaceTimeAudioDevice> inputs,
    String? activeOut,
    String? activeIn,
  ) {
    audioOutputs.assignAll(outputs);
    audioInputs.assignAll(inputs);
    activeAudioOutputId.value = activeOut;
    activeAudioInputId.value = activeIn;
    final activeOutDevice = outputs.firstWhereOrNull((d) => d.id == activeOut || d.isActive);
    if (activeOutDevice != null) {
      isSpeakerOn.value = activeOutDevice.kind == FaceTimeAudioDeviceKind.speaker;
    }
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
    _webRtcClient.onAudioDevicesChanged = (outputs, inputs, activeOut, activeIn) {
      _applyAudioDeviceLists(outputs, inputs, activeOut, activeIn);
      canSelectAudioOutput.value = _webRtcClient.canSelectAudioOutput.value;
      notifyListeners();
    };
    _webRtcClient.onQualityStatsChanged = (stats) {
      callQualityStats.value = stats;
    };
    _webRtcClient.onConnectionStateChanged = (state) => _handleWebRtcConnectivityState(callUuid, state);
    _webRtcClient.onIceStateChanged = (state) => _handleWebRtcConnectivityState(callUuid, state);
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
      canSelectAudioOutput.value = _webRtcClient.canSelectAudioOutput.value;
      _applyAudioDeviceLists(
        _webRtcClient.audioOutputs.value,
        _webRtcClient.audioInputs.value,
        _webRtcClient.activeAudioOutputId.value,
        _webRtcClient.activeAudioInputId.value,
      );
      isReconnecting.value = false;
      notifyListeners();
      return true;
    } catch (e, s) {
      _safeLogWarn('WebRTC bridge startup failed', e, s);
      _resetVideoNotifiers();
      return false;
    }
  }

  void _handleWebRtcConnectivityState(String callUuid, String rawState) {
    if (_state.phase == ActiveCallPhase.idle || _state.callUuid != callUuid) return;
    final state = rawState.trim().toLowerCase();
    if (state == 'disconnected' || state == 'reconnecting') {
      if (!isReconnecting.value) {
        isReconnecting.value = true;
        notifyListeners();
      }
    } else if (state == 'connected' || state == 'completed') {
      if (isReconnecting.value) {
        isReconnecting.value = false;
        notifyListeners();
      }
    } else if (state == 'failed') {
      isReconnecting.value = false;
      notifyListeners();
      unawaited(endCall());
    }
  }

  Future<void> _stopWebRtcBridge({bool emitHangup = true}) async {
    _webRtcClient.onRemoteVideoChanged = null;
    _webRtcClient.onLocalVideoChanged = null;
    _webRtcClient.onCameraEnabledChanged = null;
    _webRtcClient.onCanFlipCameraChanged = null;
    _webRtcClient.onFrontCameraChanged = null;
    _webRtcClient.onAudioDevicesChanged = null;
    _webRtcClient.onQualityStatsChanged = null;
    _webRtcClient.onConnectionStateChanged = null;
    _webRtcClient.onIceStateChanged = null;
    _resetVideoNotifiers();
    await _webRtcClient.hangup(emitSignal: emitHangup);
  }

  void _clearRemoteTextureCache() {
    _remoteTextureId = null;
    _remoteTextureWidth = null;
    _remoteTextureHeight = null;
  }

  void _clearLocalTextureCache() {
    _localTextureId = null;
    _localTextureWidth = null;
    _localTextureHeight = null;
  }

  void _resetVideoNotifiers() {
    _clearRemoteTextureCache();
    _clearLocalTextureCache();
    remoteVideoWidget.value = null;
    localVideoWidget.value = null;
    cameraEnabled.value = false;
    canFlipCamera.value = false;
    isFrontCamera.value = true;
    isReconnecting.value = false;
    callQualityStats.value = null;
    audioOutputs.clear();
    audioInputs.clear();
    activeAudioOutputId.value = null;
    activeAudioInputId.value = null;
    canSelectAudioOutput.value = false;
    videoEffect.value = FaceTimeVideoEffectType.none;
    videoDenoiseEnabled.value = true;
    audioOnWatch.value = false;
    virtualBackgroundId.value = null;
    virtualBackgroundPath.value = null;
  }

  int? _parseTextureId(dynamic rawTextureId) {
    if (rawTextureId is int) return rawTextureId;
    if (rawTextureId is num) return rawTextureId.toInt();
    return int.tryParse(rawTextureId?.toString() ?? '');
  }

  double? _parsePositiveDimension(dynamic raw) {
    final value = raw is num ? raw.toDouble() : double.tryParse(raw?.toString() ?? '');
    if (value == null || !value.isFinite || value <= 0) return null;
    return value;
  }

  Future<void> _hydrateAvatarIfMissing(String? address) async {
    if (address == null || address.trim().isEmpty) return;
    if (_state.avatarBytes != null && _state.avatarBytes!.isNotEmpty) return;
    if (!GetIt.I.isRegistered<ContactServiceV2>()) return;
    try {
      final contact = ContactsSvcV2.findContactForAddressSync(address) ?? await ContactsSvcV2.getContact(address);
      if (contact == null) return;
      final avatar = await ContactsSvcV2.getContactAvatar(contact.nativeContactId);
      if (avatar != null && avatar.isNotEmpty && (_state.avatarBytes == null || _state.avatarBytes!.isEmpty)) {
        _state = _state.copyWith(avatarBytes: avatar);
        notifyListeners();
      }
    } catch (_) {}
  }

  bool _shouldCoverRemoteVideo(double? width, double? height) =>
      width != null && height != null && height > width;

  Widget _buildTextureWidget(int textureId, {dynamic width, dynamic height, bool cover = true}) {
    final tex = Texture(textureId: textureId);
    final w = _parsePositiveDimension(width);
    final h = _parsePositiveDimension(height);
    if (w == null || h == null) return tex;
    // shortcut: syncNativeVideoTextures path stays unsized until the first frame re-emits
    return FittedBox(
      fit: cover ? BoxFit.cover : BoxFit.contain,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: w,
        height: h,
        child: tex,
      ),
    );
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
  String? _answeringCallUuid;

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

  bool _hasActiveLocalCallForOtherUuid(String uuid) {
    final p = _state.phase;
    if (p != ActiveCallPhase.outgoing &&
        p != ActiveCallPhase.connecting &&
        p != ActiveCallPhase.ongoing) {
      return false;
    }
    if (_state.isOnOtherDevice) return false;
    return _state.callUuid != uuid;
  }

  void startIncoming({
    required String callUuid,
    required String callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    required bool isVideo,
    bool isTelephony = false,
    bool? isGroup,
    List<String>? participants,
    List<CallParticipant>? participantDetails,
    String? chatGuid,
    DateTime? startedAt,
  }) {
    if (_hasActiveLocalCallForOtherUuid(callUuid)) return;
    _stopTicker();
    _elapsed = Duration.zero;
    final matches = _state.callUuid == callUuid;
    final nextParticipants = participants ?? (matches ? _state.participants : const []);
    final nextDetails = participantDetails ?? (matches ? _state.participantDetails : const []);
    final nextIsGroup = isTelephony
        ? false
        : (isGroup ?? (nextParticipants.length > 1 || (matches && _state.isGroup)));
    _state = ActiveCallState(
      phase: ActiveCallPhase.incoming,
      callUuid: callUuid,
      callerName: callerName,
      callerAddress: callerAddress ?? (matches ? _state.callerAddress : null),
      avatarBytes: avatarBytes ?? (matches ? _state.avatarBytes : null),
      isVideo: isTelephony ? false : isVideo,
      isTelephony: isTelephony,
      isGroup: nextIsGroup,
      participants: nextParticipants,
      participantDetails: nextDetails,
      chatGuid: chatGuid ?? (matches ? _state.chatGuid : null),
      isOutgoing: false,
      startedAt: startedAt ?? (matches ? _state.startedAt : null) ?? _now(),
      localDeviceId: localDeviceId,
    );
    _startIncomingRingtone(callUuid);
    unawaited(refreshWearWatchConnected());
    if (avatarBytes == null && (callerAddress != null || nextParticipants.isNotEmpty)) {
      unawaited(_hydrateAvatarIfMissing(callerAddress ?? nextParticipants.firstOrNull));
    }
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
    bool? isGroup,
    List<String>? participants,
    List<CallParticipant>? participantDetails,
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
    final nextParticipants = participants ?? const [];
    final nextIsGroup = isTelephony ? false : (isGroup ?? nextParticipants.length > 1);
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
      isGroup: nextIsGroup,
      participants: nextParticipants,
      participantDetails: participantDetails ?? const [],
      joinLink: joinLink,
      chatGuid: chatGuid,
      isOutgoing: true,
      isLinkOnly: isLinkOnly,
      activeDeviceId: activeDeviceId ?? localDeviceId,
      activeDeviceName: activeDeviceName ?? localDeviceName,
      startedAt: startedAt ?? _now(),
      localDeviceId: localDeviceId,
    );
    if (!isLinkOnly) {
      _startOutgoingRingback(callUuid);
    } else {
      _stopOutgoingRingback(callUuid, isTelecomCall: isTelecomCall);
    }
    unawaited(refreshWearWatchConnected());
    if (avatarBytes == null && (callerAddress != null || nextParticipants.isNotEmpty)) {
      unawaited(_hydrateAvatarIfMissing(callerAddress ?? nextParticipants.firstOrNull));
    }
    notifyListeners();
  }

  void setConnecting({
    required String callUuid,
    String? callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    bool? isVideo,
    bool? isTelephony,
    bool? isGroup,
    List<String>? participants,
    List<CallParticipant>? participantDetails,
    String? chatGuid,
    bool? isOutgoing,
    String? activeDeviceId,
    String? activeDeviceName,
  }) {
    _stopTicker();
    _stopIncomingRingtone(callUuid);
    _stopOutgoingRingback(callUuid);
    _elapsed = Duration.zero;
    final matches = _state.callUuid == callUuid;
    final nextTelephony = isTelephony ?? (matches ? _state.isTelephony : false);
    final nextVideo = nextTelephony ? false : (isVideo ?? (matches ? _state.isVideo : true));
    final nextParticipants = participants ?? (matches ? _state.participants : const []);
    final nextIsGroup = nextTelephony
        ? false
        : (isGroup ?? (nextParticipants.length > 1 || (matches && _state.isGroup)));
    final nextAddress = callerAddress ?? (matches ? _state.callerAddress : null);
    final fallbackName = (nextAddress != null && nextAddress.trim().isNotEmpty)
        ? nextAddress.trim()
        : callKindLabelFor(isVideo: nextVideo, isTelephony: nextTelephony, isGroup: nextIsGroup);
    _state = ActiveCallState(
      phase: ActiveCallPhase.connecting,
      callUuid: callUuid,
      callerName: (callerName != null && callerName.isNotEmpty)
          ? callerName
          : (matches && _state.callerName.isNotEmpty ? _state.callerName : fallbackName),
      callerAddress: nextAddress,
      avatarBytes: avatarBytes ?? (matches ? _state.avatarBytes : null),
      isVideo: nextVideo,
      isTelephony: nextTelephony,
      isGroup: nextIsGroup,
      participants: nextParticipants,
      participantDetails: participantDetails ?? (matches ? _state.participantDetails : const []),
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
    bool? isGroup,
    List<String>? participants,
    List<CallParticipant>? participantDetails,
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
    _stopOutgoingRingback(callUuid, isTelecomCall: isTelecomCall);
    final matches = callUuid != null && callUuid.isNotEmpty && _state.callUuid == callUuid;
    final nextParticipants = participants ?? (matches ? _state.participants : const []);
    final nextIsGroup = isTelephony
        ? false
        : (isGroup ?? (nextParticipants.length > 1 || (matches && _state.isGroup)));
    _state = ActiveCallState(
      phase: ActiveCallPhase.ongoing,
      callUuid: callUuid,
      callerName: callerName,
      callerAddress: callerAddress ?? (matches ? _state.callerAddress : null),
      avatarBytes: avatarBytes ?? (matches ? _state.avatarBytes : null),
      isVideo: isTelephony ? false : isVideo,
      isMuted: matches ? _state.isMuted : false,
      isTelecomCall: isTelecomCall,
      isTelephony: isTelephony,
      isGroup: nextIsGroup,
      participants: nextParticipants,
      participantDetails: participantDetails ?? (matches ? _state.participantDetails : const []),
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
    unawaited(refreshWearWatchConnected());
    if (avatarBytes == null && (callerAddress != null || nextParticipants.isNotEmpty)) {
      unawaited(_hydrateAvatarIfMissing(callerAddress ?? nextParticipants.firstOrNull));
    }
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
  void notifyTelecomActive(
    String callUuid, {
    bool isTelephony = false,
    bool? isVideo,
    String? callerName,
  }) {
    if (callUuid.isEmpty) return;
    final prevPhase = _state.phase;
    final wasIdle = prevPhase == ActiveCallPhase.idle;
    final wasOnOtherDevice = _state.isOnOtherDevice || prevPhase == ActiveCallPhase.incoming;
    final prevActiveDeviceId = _state.activeDeviceId;
    final matchesOrIdle = wasIdle ||
        _state.callUuid == null ||
        _state.callUuid!.isEmpty ||
        _state.callUuid == callUuid;
    if (!matchesOrIdle) return;

    final effectiveTelephony = isTelephony || (!wasIdle && _state.isTelephony);
    final effectiveVideo = effectiveTelephony ? false : (isVideo ?? (wasIdle ? false : _state.isVideo));
    final trimmedCaller = callerName?.trim();
    final hasCallerName = trimmedCaller != null && trimmedCaller.isNotEmpty;

    if (prevPhase == ActiveCallPhase.idle ||
        prevPhase == ActiveCallPhase.incoming ||
        prevPhase == ActiveCallPhase.connecting) {
      _dismissOverlay(callUuid, keepCallState: true);
    }

    if (wasIdle) {
      startOngoing(
        callUuid: callUuid,
        callerName: hasCallerName
            ? trimmedCaller
            : callKindLabelFor(isVideo: effectiveVideo, isTelephony: effectiveTelephony),
        isVideo: effectiveVideo,
        isTelecomCall: true,
        isTelephony: effectiveTelephony,
        activeDeviceId: localDeviceId,
        activeDeviceName: localDeviceName,
      );
    } else {
      final connectedAt = prevPhase == ActiveCallPhase.ongoing && _state.connectedAt != null
          ? _state.connectedAt!
          : _now();
      final nextCallerName =
          (hasCallerName && !isGenericCallLabel(trimmedCaller) && isGenericCallLabel(_state.callerName))
              ? trimmedCaller
              : null;
      _state = _state.copyWith(
        phase: ActiveCallPhase.ongoing,
        callUuid: callUuid,
        callerName: nextCallerName,
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

    if (prevPhase == ActiveCallPhase.idle ||
        prevPhase == ActiveCallPhase.incoming ||
        prevPhase == ActiveCallPhase.connecting) {
      _openInAppCallScreenIfPossible(null);
    }

    if (wasIdle || wasOnOtherDevice || prevActiveDeviceId != localDeviceId) {
      unawaited(_handoffServer(callUuid, mode: effectiveVideo ? 'video_bridge' : 'audio'));
    }
    unawaited(syncNativeVideoTextures(callUuid: callUuid));
  }

  void updateCallerInfo(
    String uuid, {
    String? callerName,
    String? callerAddress,
    Uint8List? avatarBytes,
    bool? isGroup,
    List<String>? participants,
    List<CallParticipant>? participantDetails,
  }) {
    if (uuid.isEmpty || _state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) {
      return;
    }
    final nextParticipants = participants ?? _state.participants;
    final nextIsGroup = _state.isTelephony
        ? false
        : (isGroup ?? (_state.isGroup || nextParticipants.length > 1));
    _state = _state.copyWith(
      callerName: (callerName != null && callerName.trim().isNotEmpty) ? callerName.trim() : null,
      callerAddress: (callerAddress != null && callerAddress.trim().isNotEmpty) ? callerAddress.trim() : null,
      avatarBytes: (avatarBytes != null && avatarBytes.isNotEmpty) ? avatarBytes : null,
      isGroup: nextIsGroup,
      participants: participants,
      participantDetails: participantDetails,
    );
    notifyListeners();

    if (!_isWeb && Platform.isAndroid && _state.isTelecomCall && _state.isOngoing && GetIt.I.isRegistered<MethodChannelService>()) {
      final avatar = _state.avatarBytes;
      unawaited(
        MethodChannelSvc.actions.markFaceTimeCallActive(
          callUuid: uuid,
          isOutgoing: _state.isOutgoing,
          callerName: _state.displayCallerName,
          callerAddress: _state.callerAddress,
          callerAvatar: (avatar != null && avatar.length <= maxTelecomAvatarBytes) ? avatar : null,
          isVideo: _state.isVideo,
          isGroup: _state.isGroup,
          isTelephony: _state.isTelephony,
        ),
      );
    }
  }

  /// Queries native Android Telecom for already-registered remote/local video
  /// texture IDs on controller attach or call screen init so calls whose native
  /// texture events arrived earlier still render video.
  Future<void> syncNativeVideoTextures({String? callUuid}) async {
    if (_isWeb) return;
    if (_onFetchNativeVideoTextureIds == null &&
        (!Platform.isAndroid || !GetIt.I.isRegistered<MethodChannelService>())) {
      return;
    }
    if (_state.phase == ActiveCallPhase.idle || _webRtcClient.isActive) return;
    final targetUuid = (callUuid != null && callUuid.isNotEmpty) ? callUuid : _state.callUuid;
    if (targetUuid == null || targetUuid.isEmpty) return;

    int? remoteId;
    int? localId;
    double? remoteWidth;
    double? remoteHeight;
    double? localWidth;
    double? localHeight;
    if (_onFetchNativeVideoTextureIds != null) {
      try {
        final ids = await _onFetchNativeVideoTextureIds(targetUuid);
        remoteId = ids.remoteId;
        localId = ids.localId;
      } catch (_) {}
    } else {
      try {
        final res = await MethodChannelSvc.channel.invokeMethod<dynamic>(
          'get-facetime-video-textures',
          {'call_uuid': targetUuid},
        );
        if (res is Map) {
          remoteId = _parseTextureId(res['remote_texture_id']);
          localId = _parseTextureId(res['local_texture_id']);
          remoteWidth = _parsePositiveDimension(res['remote_video_width']);
          remoteHeight = _parsePositiveDimension(res['remote_video_height']);
          localWidth = _parsePositiveDimension(res['local_video_width']);
          localHeight = _parsePositiveDimension(res['local_video_height']);
        }
      } catch (_) {}
      if (remoteId == null && localId == null) {
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
      }
    }

    if (_state.phase == ActiveCallPhase.idle || _state.callUuid != targetUuid) return;
    bool changed = false;
    if (remoteId != null && remoteId > 0) {
      if (remoteWidth != null && remoteHeight != null) {
        _remoteTextureId = remoteId;
        _remoteTextureWidth = remoteWidth;
        _remoteTextureHeight = remoteHeight;
      }
      final hasCachedDims = _remoteTextureId == remoteId && _remoteTextureWidth != null && _remoteTextureHeight != null;
      remoteVideoWidget.value = hasCachedDims
          ? _buildTextureWidget(
              remoteId,
              width: _remoteTextureWidth,
              height: _remoteTextureHeight,
              cover: _shouldCoverRemoteVideo(_remoteTextureWidth, _remoteTextureHeight),
            )
          : Texture(textureId: remoteId);
      if (!hasCachedDims) {
        _remoteTextureId = remoteId;
        _remoteTextureWidth = null;
        _remoteTextureHeight = null;
      }
      changed = true;
    }
    if (localId != null && localId > 0) {
      if (localWidth != null && localHeight != null) {
        _localTextureId = localId;
        _localTextureWidth = localWidth;
        _localTextureHeight = localHeight;
      }
      final hasCachedDims = _localTextureId == localId && _localTextureWidth != null && _localTextureHeight != null;
      localVideoWidget.value = hasCachedDims
          ? _buildTextureWidget(localId, width: _localTextureWidth, height: _localTextureHeight)
          : Texture(textureId: localId);
      if (!hasCachedDims) {
        _localTextureId = localId;
        _localTextureWidth = null;
        _localTextureHeight = null;
      }
      cameraEnabled.value = true;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> _refreshNativeVideoTextures({String? callUuid}) => syncNativeVideoTextures(callUuid: callUuid);

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
          callerName: arguments['caller_name']?.toString(),
        );
        break;
      case 'mute':
        syncMutedFromNative(uuid, arguments['muted'] == true);
        break;
      case 'video-texture':
        if (_state.phase == ActiveCallPhase.idle) return;
        if (_state.callUuid != null && _state.callUuid!.isNotEmpty && _state.callUuid != uuid) return;
        final textureId = _parseTextureId(arguments['texture_id']);
        if (textureId == null || textureId <= 0) {
          _clearRemoteTextureCache();
          remoteVideoWidget.value = null;
        } else {
          final hasExplicitDims = arguments.containsKey('width') || arguments.containsKey('height');
          final w = _parsePositiveDimension(arguments['width']);
          final h = _parsePositiveDimension(arguments['height']);
          if (w != null && h != null) {
            _remoteTextureId = textureId;
            _remoteTextureWidth = w;
            _remoteTextureHeight = h;
            remoteVideoWidget.value = _buildTextureWidget(
              textureId,
              width: w,
              height: h,
              cover: _shouldCoverRemoteVideo(w, h),
            );
          } else if (!hasExplicitDims &&
              _remoteTextureId == textureId &&
              _remoteTextureWidth != null &&
              _remoteTextureHeight != null) {
            remoteVideoWidget.value = _buildTextureWidget(
              textureId,
              width: _remoteTextureWidth,
              height: _remoteTextureHeight,
              cover: _shouldCoverRemoteVideo(_remoteTextureWidth, _remoteTextureHeight),
            );
          } else {
            _remoteTextureId = textureId;
            _remoteTextureWidth = null;
            _remoteTextureHeight = null;
            remoteVideoWidget.value = Texture(textureId: textureId);
          }
        }
        notifyListeners();
        break;
      case 'local-video-texture':
        if (_state.phase == ActiveCallPhase.idle) return;
        if (_state.callUuid != null && _state.callUuid!.isNotEmpty && _state.callUuid != uuid) return;
        final textureId = _parseTextureId(arguments['texture_id']);
        final hasTex = textureId != null && textureId > 0;
        if (!hasTex) {
          _clearLocalTextureCache();
          localVideoWidget.value = null;
        } else {
          final hasExplicitDims = arguments.containsKey('width') || arguments.containsKey('height');
          final w = _parsePositiveDimension(arguments['width']);
          final h = _parsePositiveDimension(arguments['height']);
          if (w != null && h != null) {
            _localTextureId = textureId;
            _localTextureWidth = w;
            _localTextureHeight = h;
            localVideoWidget.value = _buildTextureWidget(textureId, width: w, height: h);
          } else if (!hasExplicitDims &&
              _localTextureId == textureId &&
              _localTextureWidth != null &&
              _localTextureHeight != null) {
            localVideoWidget.value = _buildTextureWidget(
              textureId,
              width: _localTextureWidth,
              height: _localTextureHeight,
            );
          } else {
            _localTextureId = textureId;
            _localTextureWidth = null;
            _localTextureHeight = null;
            localVideoWidget.value = Texture(textureId: textureId);
          }
        }
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
      case 'ice-state':
        if (_state.phase == ActiveCallPhase.idle) return;
        if (_state.callUuid != null && _state.callUuid!.isNotEmpty && _state.callUuid != uuid) return;
        final iceState = arguments['state']?.toString().trim().toLowerCase() ?? '';
        if (iceState == 'disconnected' || iceState == 'reconnecting') {
          isReconnecting.value = true;
          notifyListeners();
        } else if (iceState == 'connected' || iceState == 'completed' || iceState == 'failed') {
          isReconnecting.value = false;
          notifyListeners();
        }
        break;
      case 'audio-devices':
        if (_state.phase == ActiveCallPhase.idle) return;
        if (_state.callUuid != null && _state.callUuid!.isNotEmpty && _state.callUuid != uuid) return;
        _applyAudioDeviceMap(arguments);
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
    if (_answeringCallUuid == uuid) return false;
    _answeringCallUuid = uuid;
    try {

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
      if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) {
        _closePendingCallTab();
        return false;
      }
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
            isGroup: prev.isGroup,
            participants: prev.participants,
            participantDetails: prev.participantDetails,
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
        callerName: prev.displayCallerName,
        callerAddress: prev.callerAddress,
        isTelephony: effectiveTelephony,
        isVideo: isVideo,
      );
      if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) {
        _closePendingCallTab();
        if (routed) {
          unawaited(_endNativeCall(uuid, onlyIfRinging: false));
        }
        return false;
      }
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
          isGroup: prev.isGroup,
          participants: prev.participants,
          participantDetails: prev.participantDetails,
          chatGuid: prev.chatGuid,
          isOutgoing: prev.isOutgoing,
          activeDeviceId: localDeviceId,
          activeDeviceName: localDeviceName,
          startedAt: prev.startedAt,
        );
        _openInAppCallScreenIfPossible(context);
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
    final wantsLinkFallback = !effectiveAudioOnly || _isWeb;
    try {
      placed = await _answerServer(
        uuid,
        audioOnly: effectiveAudioOnly && !_isWeb,
        mode: wantsLinkFallback ? 'video' : null,
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
      isGroup: prev.isGroup,
      participants: prev.participants,
      participantDetails: prev.participantDetails,
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
    } finally {
      if (_answeringCallUuid == uuid) {
        _answeringCallUuid = null;
      }
    }
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

    String resolveUuid(PlacedFaceTimeCall? placedCall, String currentUuid) {
      final nextUuid = placedCall?.call.callUuid;
      if (nextUuid != null && nextUuid.isNotEmpty && nextUuid != currentUuid) {
        if (_state.callUuid == uuid || _state.callUuid == currentUuid) {
          _state = _state.copyWith(callUuid: nextUuid);
        }
        return nextUuid;
      }
      return currentUuid;
    }

    if ((_isWeb || _onOpenPendingTab != null) &&
        mode == 'video' &&
        (!_isWeb || _webRtcClient.cachedConfig?.videoSupported != true)) {
      _closePendingCallTab();
      _pendingCallTab = (_onOpenPendingTab ?? openPendingCallTab)();
    }

    var activeUuid = uuid;
    PlacedFaceTimeCall? preHandoffPlaced;
    var handoffDone = false;

    if (_isWeb) {
      if (mode == 'audio') {
        PlacedFaceTimeCall? placed;
        try {
          placed = await _handoffServer(uuid, mode: 'audio');
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

        final effectiveUuid = resolveUuid(placed, uuid);
        final started = await _startWebRtcBridge(
          callUuid: effectiveUuid,
          wantVideo: false,
          answerCall: false,
          initialMuted: prev.isMuted,
        );
        if (_state.phase == ActiveCallPhase.idle || (_state.callUuid != uuid && _state.callUuid != effectiveUuid)) {
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
        final nextFromIphone =
            placed?.session?['from_iphone'] is bool ? placed!.session!['from_iphone'] as bool : prev.fromIphone;
        _state = prev.copyWith(
          callUuid: effectiveUuid,
          phase: nextPhase,
          isVideo: false,
          isTelecomCall: false,
          activeDeviceId: localDeviceId,
          activeDeviceName: localDeviceName,
          connectedAt: nextConnectedAt,
          localDeviceId: localDeviceId,
          endpointOnMac: true,
          fromIphone: nextFromIphone,
        );
        if (nextPhase == ActiveCallPhase.ongoing && nextConnectedAt != null) {
          _startTickerFrom(nextConnectedAt);
        }
        notifyListeners();
        _closePendingCallTab();
        return true;
      }

      final config = await getWebRtcConfig();
      if (_state.phase == ActiveCallPhase.idle || _state.callUuid != uuid) {
        _closePendingCallTab();
        return false;
      }
      if (config.videoSupported) {
        _closePendingCallTab();
        PlacedFaceTimeCall? placed;
        if (!prev.endpointOnMac) {
          try {
            placed = await _handoffServer(activeUuid, mode: 'video_bridge');
          } on FaceTimeException catch (e, s) {
            _safeLogWarn('Failed to transfer FaceTime call here', e, s);
            reportError(e.message);
            return false;
          } catch (e, s) {
            _safeLogWarn('Failed to transfer FaceTime call here', e, s);
            reportError("Couldn't transfer the FaceTime call.");
            return false;
          }
          activeUuid = resolveUuid(placed, activeUuid);
          preHandoffPlaced = placed;
          handoffDone = true;
        }

        final started = await _startWebRtcBridge(
          callUuid: activeUuid,
          wantVideo: true,
          answerCall: false,
          initialMuted: prev.isMuted,
        );
        if (_state.phase == ActiveCallPhase.idle || (_state.callUuid != uuid && _state.callUuid != activeUuid)) {
          await _stopWebRtcBridge(emitHangup: false);
          return false;
        }
        if (started) {
          if (!handoffDone) {
            try {
              placed = await _handoffServer(activeUuid, mode: 'video_bridge');
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
            activeUuid = resolveUuid(placed, activeUuid);
          }
          final nextPhase = prev.phase == ActiveCallPhase.outgoing ? ActiveCallPhase.outgoing : ActiveCallPhase.ongoing;
          final nextConnectedAt = nextPhase == ActiveCallPhase.ongoing ? (prev.connectedAt ?? _now()) : prev.connectedAt;
          final nextFromIphone =
              placed?.session?['from_iphone'] is bool ? placed!.session!['from_iphone'] as bool : prev.fromIphone;
          _state = prev.copyWith(
            callUuid: activeUuid,
            phase: nextPhase,
            isVideo: true,
            isTelecomCall: false,
            activeDeviceId: localDeviceId,
            activeDeviceName: localDeviceName,
            connectedAt: nextConnectedAt,
            localDeviceId: localDeviceId,
            endpointOnMac: true,
            fromIphone: nextFromIphone,
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
    PlacedFaceTimeCall? placed = preHandoffPlaced;

    bool isAborted() =>
        _state.phase == ActiveCallPhase.idle || (_state.callUuid != uuid && _state.callUuid != activeUuid);

    if (!prev.endpointOnMac) {
      if (!handoffDone) {
        try {
          placed = await _handoffServer(
            activeUuid,
            mode: useTelecom && effectiveVideo ? 'video_bridge' : mode,
          );
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
        activeUuid = resolveUuid(placed, activeUuid);
        if (isAborted()) {
          _closePendingCallTab();
          return false;
        }
      }

      if (useTelecom) {
        telecomStarted = await _startTelecomCall(
          callUuid: activeUuid,
          callerName: prev.displayCallerName,
          callerAddress: prev.callerAddress,
          isTelephony: prev.isTelephony,
          isVideo: effectiveVideo,
        );
        if (isAborted()) {
          if (telecomStarted) {
            unawaited(_endNativeCall(activeUuid, onlyIfRinging: false));
          }
          _closePendingCallTab();
          return false;
        }
      }

      if (!telecomStarted && effectiveVideo && (placed?.link == null || placed!.link!.isEmpty)) {
        try {
          placed = await _handoffServer(activeUuid);
          activeUuid = resolveUuid(placed, activeUuid);
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
        if (isAborted()) {
          _closePendingCallTab();
          return false;
        }
      }
    } else {
      if (useTelecom) {
        telecomStarted = await _startTelecomCall(
          callUuid: activeUuid,
          callerName: prev.displayCallerName,
          callerAddress: prev.callerAddress,
          isTelephony: prev.isTelephony,
          isVideo: effectiveVideo,
        );
        if (isAborted()) {
          if (telecomStarted) {
            unawaited(_endNativeCall(activeUuid, onlyIfRinging: false));
          }
          _closePendingCallTab();
          return false;
        }
      }

      try {
        placed = await _handoffServer(
          activeUuid,
          mode: telecomStarted && effectiveVideo ? 'video_bridge' : mode,
        );
      } on FaceTimeException catch (e, s) {
        _safeLogWarn('Failed to transfer FaceTime call here', e, s);
        if (telecomStarted) {
          unawaited(_endNativeCall(activeUuid, onlyIfRinging: false));
        }
        _closePendingCallTab();
        reportError(e.message);
        return false;
      } catch (e, s) {
        _safeLogWarn('Failed to transfer FaceTime call here', e, s);
        if (telecomStarted) {
          unawaited(_endNativeCall(activeUuid, onlyIfRinging: false));
        }
        _closePendingCallTab();
        reportError("Couldn't transfer the FaceTime call.");
        return false;
      }
      activeUuid = resolveUuid(placed, activeUuid);
      if (isAborted()) {
        if (telecomStarted) {
          unawaited(_endNativeCall(activeUuid, onlyIfRinging: false));
        }
        _closePendingCallTab();
        return false;
      }
    }

    final link = placed?.link ?? prev.joinLink;
    final nextPhase = prev.phase == ActiveCallPhase.outgoing ? ActiveCallPhase.outgoing : ActiveCallPhase.ongoing;
    final nextConnectedAt = nextPhase == ActiveCallPhase.ongoing ? (prev.connectedAt ?? _now()) : prev.connectedAt;
    final nextFromIphone =
        placed?.session?['from_iphone'] is bool ? placed!.session!['from_iphone'] as bool : prev.fromIphone;

    _state = prev.copyWith(
      callUuid: activeUuid,
      phase: nextPhase,
      isVideo: effectiveVideo,
      isTelecomCall: telecomStarted,
      joinLink: link,
      activeDeviceId: localDeviceId,
      activeDeviceName: localDeviceName,
      connectedAt: nextConnectedAt,
      localDeviceId: localDeviceId,
      endpointOnMac: true,
      fromIphone: nextFromIphone,
    );
    if (nextPhase == ActiveCallPhase.ongoing && nextConnectedAt != null) {
      _startTickerFrom(nextConnectedAt);
    }
    notifyListeners();

    if (telecomStarted) {
      _closePendingCallTab();
      _openInAppCallScreenIfPossible(context);
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

  Future<bool> transferBack() async {
    final prev = _state;
    final uuid = prev.callUuid;
    if (uuid == null || uuid.isEmpty) return false;

    dynamic serverRes;
    try {
      if (_onTransferBackServerCall != null) {
        serverRes = await _onTransferBackServerCall(uuid);
      } else if (GetIt.I.isRegistered<HttpService>()) {
        serverRes = await HttpSvc.faceTime.transferBackFaceTime(
          uuid,
          displayName: prev.callerName,
          chatGuid: prev.chatGuid,
        );
      }
    } on FaceTimeException catch (e, s) {
      _safeLogWarn('Failed to transfer FaceTime call back to iPhone', e, s);
      reportError(e.message);
      return false;
    } catch (e, s) {
      _safeLogWarn('Failed to transfer FaceTime call back to iPhone', e, s);
      reportError("Couldn't transfer the call back to iPhone.");
      return false;
    }

    _closePendingCallTab();
    if (_webRtcClient.isActive) {
      await _stopWebRtcBridge(emitHangup: false);
    }
    if (prev.isTelecomCall) {
      await _endNativeCall(uuid, onlyIfRinging: false);
    }

    if (serverRes is Map) {
      applyServerSession(serverRes.cast<String, dynamic>());
      return true;
    }

    if (_state.callUuid == uuid && _state.phase != ActiveCallPhase.idle) {
      _state = _state
          .copyWith(
            isTelecomCall: false,
            endpointOnMac: false,
            fromIphone: true,
            clearJoinLink: true,
            clearActiveDevice: true,
          )
          .copyWith(
            activeDeviceName: 'iPhone',
          );
      notifyListeners();
    }
    return true;
  }

  Future<void> endCall() async {
    final prev = _state;
    final bridgeActive = _webRtcClient.isActive;
    _stopTicker();
    _stopIncomingRingtone();
    _stopOutgoingRingback(prev.callUuid, isTelecomCall: prev.isTelecomCall);
    _closePendingCallTab();
    _resetVideoNotifiers();
    isSpeakerOn.value = false;
    _elapsed = Duration.zero;
    if (_state.phase != ActiveCallPhase.idle) {
      _state = ActiveCallState.idle;
      notifyListeners();
    }
    if ((prev.phase == ActiveCallPhase.outgoing || prev.phase == ActiveCallPhase.ongoing) && !prev.isOnOtherDevice) {
      _playCallEndedTone(callUuid: prev.callUuid, isTelecomCall: prev.isTelecomCall);
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
      final prev = _state;
      final endedReason = _nonEmptyString(data['ended_reason']);
      final endedError = _nonEmptyString(data['ended_error']);
      final failureReason = failureMessageFor(endedReason: endedReason, endedError: endedError);

      _stopIncomingRingtone(uuid);
      _stopOutgoingRingback(uuid, isTelecomCall: prev.isTelecomCall);
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
        if ((prev.phase == ActiveCallPhase.outgoing || prev.phase == ActiveCallPhase.ongoing) && !prev.isOnOtherDevice) {
          _playCallEndedTone(callUuid: uuid, isTelecomCall: prev.isTelecomCall);
        }
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
        (data['session_uuid'] != null && data['session_uuid'].toString() == prev.callUuid) ||
        (prev.callUuid == null && (prev.phase == ActiveCallPhase.outgoing || prev.phase == ActiveCallPhase.ongoing));

    final nextPhase = switch (status) {
      'incoming' => ActiveCallPhase.incoming,
      'outgoing' => ActiveCallPhase.outgoing,
      'connecting' => ActiveCallPhase.connecting,
      'answered' => ActiveCallPhase.ongoing,
      _ => null,
    };
    if (nextPhase == null) return;
    if (nextPhase == ActiveCallPhase.incoming && !matchesPrev && _hasActiveLocalCallForOtherUuid(uuid)) {
      return;
    }

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

    final rawHandle = data['handle'] is Map ? _nonEmptyString((data['handle'] as Map)['address']) : null;
    final rawSingleAddress = _nonEmptyString(data['address']);
    final rawAddressesList = data['addresses'] is List
        ? (data['addresses'] as List)
            .map((e) => _nonEmptyString(e))
            .whereType<String>()
            .toList(growable: false)
        : const <String>[];
    final candidateAddresses = <String>[
      ...rawAddressesList,
      if (rawHandle != null) rawHandle,
      if (rawSingleAddress != null) rawSingleAddress,
    ];
    final filteredAddresses = filterRemoteAddresses(candidateAddresses);
    final participants = filteredAddresses.isNotEmpty
        ? filteredAddresses
        : (matchesPrev ? prev.participants : const <String>[]);
    final callerAddress = (participants.isNotEmpty ? participants.first : null) ??
        rawHandle ??
        rawSingleAddress ??
        (matchesPrev ? prev.callerAddress : null);
    final explicitIsGroup = data['is_group'] is bool ? data['is_group'] as bool : null;
    final isGroup = isTelephony
        ? false
        : (explicitIsGroup ?? (participants.length > 1 || (matchesPrev && prev.isGroup)));

    final existingByAddr = <String, CallParticipant>{
      for (final p in (matchesPrev ? prev.participantDetails : const <CallParticipant>[]))
        _normalizeAddressKey(p.address): p,
    };
    final participantDetails = <CallParticipant>[
      for (final addr in participants)
        () {
          final existing = existingByAddr[_normalizeAddressKey(addr)];
          if (existing != null) return existing;
          String? cachedName;
          if (GetIt.I.isRegistered<ContactServiceV2>()) {
            final c = ContactsSvcV2.findContactForAddressSync(addr);
            if (c != null && c.displayName.trim().isNotEmpty) {
              cachedName = c.displayName.trim();
            }
          }
          return CallParticipant(address: addr, displayName: cachedName);
        }(),
    ];

    final serverDisplayName = _nonEmptyString(data['display_name']);
    final prevDisplayName = (matchesPrev && prev.callerName.isNotEmpty && !isGenericCallLabel(prev.callerName))
        ? prev.callerName
        : null;
    final formattedParticipants = participantDetails.isNotEmpty
        ? formatParticipantNames(
            participantDetails.map((p) => p.label),
            isVideo: isVideo,
            isTelephony: isTelephony,
            isGroup: isGroup,
          )
        : null;
    final callerName = (serverDisplayName != null && !isGenericCallLabel(serverDisplayName))
        ? serverDisplayName
        : (prevDisplayName ??
            formattedParticipants ??
            callerAddress ??
            callKindLabelFor(isVideo: isVideo, isTelephony: isTelephony, isGroup: isGroup));

    final chatGuid = _nonEmptyString(data['chat_guid']) ?? (matchesPrev ? prev.chatGuid : null);
    final joinLink = _extractLink(data['link']) ?? (matchesPrev ? prev.joinLink : null);
    final isMuted = data['is_muted'] is bool ? data['is_muted'] as bool : (matchesPrev ? prev.isMuted : false);

    final endpointOnMac = data['endpoint_on_mac'] is bool
        ? data['endpoint_on_mac'] as bool
        : (matchesPrev ? prev.endpointOnMac : true);
    final fromIphone = data['from_iphone'] is bool
        ? data['from_iphone'] as bool
        : (matchesPrev ? prev.fromIphone : false);

    final sameEndpointSide = matchesPrev && prev.endpointOnMac == endpointOnMac;
    final rawActiveDeviceId = data.containsKey('active_device_id')
        ? _nonEmptyString(data['active_device_id'])
        : (sameEndpointSide ? prev.activeDeviceId : null);
    final rawActiveDeviceName = data.containsKey('active_device_name')
        ? _nonEmptyString(data['active_device_name'])
        : (sameEndpointSide ? prev.activeDeviceName : null);
    final hasLocalWebRtc = _webRtcClient.activeCallUuid == uuid;
    final holdsWebRtcHere = endpointOnMac && hasLocalWebRtc;
    final activeDeviceId = rawActiveDeviceId ?? (holdsWebRtcHere ? localDeviceId : null);
    final activeDeviceName = rawActiveDeviceName ??
        (!endpointOnMac ? 'iPhone' : (holdsWebRtcHere ? localDeviceName : null));
    final nowOnOtherDevice = !endpointOnMac || (activeDeviceId != null && activeDeviceId != localDeviceId);

    final wasHeldHere = matchesPrev && prev.isHeldHere;
    final wasTelecom = matchesPrev && prev.isTelecomCall;

    // Remote device took over an active call from us -> close local Web tab / Telecom / WebRTC without hanging up server.
    if (nowOnOtherDevice && (wasHeldHere || wasTelecom || hasLocalWebRtc || _pendingCallTab != null)) {
      _closePendingCallTab();
      if (hasLocalWebRtc) {
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

    final prevAvatar = matchesPrev ? prev.avatarBytes : null;
    final nextTelecomCall = nowOnOtherDevice ? false : wasTelecom;
    if (nextTelecomCall && !nowOnOtherDevice && nextPhase == ActiveCallPhase.ongoing) {
      if (GetIt.I.isRegistered<MethodChannelService>() && !kIsWeb && Platform.isAndroid) {
        unawaited(
          MethodChannelSvc.actions.markFaceTimeCallActive(
            callUuid: uuid,
            isOutgoing: isOutgoing,
            callerName: callerName,
            callerAddress: callerAddress,
            callerAvatar: (prevAvatar != null && prevAvatar.length <= maxTelecomAvatarBytes) ? prevAvatar : null,
            isVideo: isVideo,
            isGroup: isGroup,
            isTelephony: isTelephony,
          ),
        );
        if (matchesPrev && prev.isMuted != isMuted) {
          unawaited(MethodChannelSvc.actions.setFaceTimeMuted(callUuid: uuid, muted: isMuted));
        }
      }
      if (matchesPrev && prev.isMuted != isMuted && _webRtcClient.activeCallUuid == uuid && _webRtcClient.isMuted != isMuted) {
        unawaited(_webRtcClient.setMuted(isMuted));
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
      avatarBytes: prevAvatar,
      isVideo: isVideo,
      isMuted: isMuted,
      isTelecomCall: nextTelecomCall,
      isTelephony: isTelephony,
      isGroup: isGroup,
      participants: participants,
      participantDetails: participantDetails,
      joinLink: joinLink,
      connectedAt: connectedAt,
      chatGuid: chatGuid,
      isOutgoing: isOutgoing,
      isLinkOnly: isLinkOnly,
      activeDeviceId: activeDeviceId,
      activeDeviceName: activeDeviceName,
      startedAt: startedAt,
      localDeviceId: localDeviceId,
      endpointOnMac: endpointOnMac,
      fromIphone: fromIphone,
    );

    if (nextPhase == ActiveCallPhase.incoming) {
      _startIncomingRingtone(uuid);
    } else {
      _stopIncomingRingtone(uuid);
    }

    if (nextPhase == ActiveCallPhase.outgoing && !nowOnOtherDevice && !isLinkOnly) {
      _startOutgoingRingback(uuid);
    } else {
      _stopOutgoingRingback(uuid, isTelecomCall: nextTelecomCall);
    }

    if (nextPhase == ActiveCallPhase.ongoing && connectedAt != null) {
      _startTickerFrom(connectedAt);
    } else {
      _stopTicker();
      _elapsed = Duration.zero;
    }

    if (prevAvatar == null && (callerAddress != null || participants.isNotEmpty)) {
      unawaited(_hydrateAvatarIfMissing(callerAddress ?? participants.firstOrNull));
    }

    notifyListeners();
  }

  void reconcileServerSessions(List<Map<String, dynamic>> sessions) {
    final active = sessions.where((s) => _normalizeStatus(s) != 'disconnected').toList(growable: false);
    if (active.isEmpty) {
      if (_state.isActive && !(_state.isTelecomCall && !_state.hasCallUuid)) {
        final uuid = _state.callUuid;
        final prevTelecom = _state.isTelecomCall;
        _closePendingCallTab();
        clear();
        if (uuid != null && uuid.isNotEmpty) {
          _stopIncomingRingtone(uuid);
          _stopOutgoingRingback(uuid, isTelecomCall: prevTelecom);
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
    final prev = _state;
    _stopTicker();
    _stopIncomingRingtone();
    _stopOutgoingRingback(prev.callUuid, isTelecomCall: prev.isTelecomCall);
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
    String? mode,
    String? displayName,
    String? chatGuid,
  }) async {
    if (_onAnswerServerCall != null) {
      return _onAnswerServerCall(
        callUuid,
        audioOnly: audioOnly,
        mode: mode,
        displayName: displayName,
        chatGuid: chatGuid,
      );
    }
    if (GetIt.I.isRegistered<HttpService>()) {
      return HttpSvc.faceTime.answerFaceTime(
        callUuid,
        audioOnly: audioOnly,
        mode: mode,
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
    final target = resolveFaceTimeNavigatorContext(context);
    if (target != null) {
      openInAppCallScreen(context: target, controller: this);
      return;
    }
    try {
      final expectedUuid = _state.callUuid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || _state.phase == ActiveCallPhase.idle) return;
        if (expectedUuid != null && expectedUuid.isNotEmpty && _state.callUuid != expectedUuid) return;
        final retryTarget = resolveFaceTimeNavigatorContext(context);
        if (retryTarget != null) {
          openInAppCallScreen(context: retryTarget, controller: this);
        }
      });
    } catch (_) {
      // WidgetsBinding may not be initialized in pure Dart unit tests.
    }
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
    final targetContext = resolveFaceTimeNavigatorContext(context);
    if (targetContext != null) {
      await openFaceTimeJoinLink(link, context: targetContext);
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

  double _callToneVolume() => GetIt.I.isRegistered<SettingsService>()
      ? (SettingsSvc.settings.soundVolume.value / 100.0).clamp(0.0, 1.0)
      : 1.0;

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
      startWebFaceTimeRingtone(callUuid: uuid, volume: _callToneVolume());
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

  void _startOutgoingRingback(String? uuid) {
    final nextUuid = (uuid != null && uuid.isNotEmpty) ? uuid : null;
    if (_ringbackActive) {
      if (_ringbackCallUuid == null && nextUuid != null) {
        _ringbackCallUuid = nextUuid;
        return;
      }
      if (_ringbackCallUuid == nextUuid) return;
      _stopOutgoingRingback(_ringbackCallUuid);
    }
    _ringbackActive = true;
    _ringbackCallUuid = nextUuid;
    if (_onStartOutgoingRingback != null) {
      _onStartOutgoingRingback(nextUuid);
      return;
    }
    if (kIsWeb && identical(this, instance)) {
      startWebFaceTimeRingback(callUuid: nextUuid, volume: _callToneVolume());
    } else if (!kIsWeb &&
        Platform.isAndroid &&
        identical(this, instance) &&
        !_state.isTelecomCall &&
        GetIt.I.isRegistered<MethodChannelService>()) {
      unawaited(MethodChannelSvc.actions.setCallTone(action: 'start_ringback', callUuid: nextUuid));
    }
  }

  void _stopOutgoingRingback(String? uuid, {bool? isTelecomCall}) {
    if (!_ringbackActive) return;
    final normalized = (uuid != null && uuid.isNotEmpty) ? uuid : null;
    if (_ringbackCallUuid != null && normalized != null && _ringbackCallUuid != normalized) {
      return;
    }
    final target = normalized ?? _ringbackCallUuid;
    _ringbackActive = false;
    _ringbackCallUuid = null;
    if (_onStopOutgoingRingback != null) {
      _onStopOutgoingRingback(target);
      return;
    }
    if (kIsWeb && identical(this, instance)) {
      stopWebFaceTimeRingback(callUuid: target);
    } else if (!kIsWeb &&
        Platform.isAndroid &&
        identical(this, instance) &&
        !(isTelecomCall ?? _state.isTelecomCall) &&
        GetIt.I.isRegistered<MethodChannelService>()) {
      unawaited(MethodChannelSvc.actions.setCallTone(action: 'stop_ringback', callUuid: target));
    }
  }

  void _playCallEndedTone({String? callUuid, bool? isTelecomCall}) {
    if (_onPlayCallEndedTone != null) {
      _onPlayCallEndedTone();
      return;
    }
    if (kIsWeb && identical(this, instance)) {
      playWebFaceTimeCallEndedTone(volume: _callToneVolume());
    } else if (!kIsWeb &&
        Platform.isAndroid &&
        identical(this, instance) &&
        !(isTelecomCall ?? _state.isTelecomCall) &&
        GetIt.I.isRegistered<MethodChannelService>()) {
      unawaited(MethodChannelSvc.actions.setCallTone(action: 'play_ended', callUuid: callUuid));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _state.phase == ActiveCallPhase.ongoing &&
        _state.isHeldHere &&
        !_state.isTelephony) {
      if (!_isWeb && Platform.isAndroid && GetIt.I.isRegistered<MethodChannelService>()) {
        try {
          unawaited(MethodChannelSvc.channel.invokeMethod<bool>(
            'resume-facetime-video',
            <String, dynamic>{'call_uuid': _state.callUuid},
          ).catchError((Object err) {
            Logger.debug('resume-facetime-video failed: $err', tag: 'ActiveCall');
            return null;
          }));
        } on MissingPluginException catch (e) {
          Logger.debug('resume-facetime-video MissingPluginException: $e', tag: 'ActiveCall');
        } catch (e) {
          Logger.debug('resume-facetime-video error: $e', tag: 'ActiveCall');
        }
        unawaited(syncNativeVideoTextures(callUuid: _state.callUuid));
      }
      if (_isWeb && !_webRtcClient.isActive && _state.callUuid != null) {
        unawaited(_startWebRtcBridge(
          callUuid: _state.callUuid!,
          wantVideo: _state.isVideo,
          answerCall: false,
          initialMuted: _state.isMuted,
        ));
      }
    }
  }

  @override
  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    final prev = _state;
    _disposed = true;
    _stopTicker();
    _stopIncomingRingtone();
    _stopOutgoingRingback(prev.callUuid, isTelecomCall: prev.isTelecomCall);
    _closePendingCallTab();
    _webRtcClient.dispose();
    remoteVideoWidget.close();
    localVideoWidget.close();
    cameraEnabled.close();
    canFlipCamera.close();
    isFrontCamera.close();
    isSpeakerOn.close();
    isReconnecting.close();
    voiceIsolationEnabled.close();
    videoDenoiseEnabled.close();
    audioOnWatch.close();
    videoEffect.close();
    virtualBackgroundId.close();
    virtualBackgroundPath.close();
    audioOutputs.close();
    activeAudioOutputId.close();
    canSelectAudioOutput.close();
    audioInputs.close();
    activeAudioInputId.close();
    callQualityStats.close();
    super.dispose();
  }
}
