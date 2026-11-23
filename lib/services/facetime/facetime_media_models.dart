import 'package:flutter/foundation.dart';

enum FaceTimeAudioDeviceKind {
  earpiece,
  speaker,
  wired,
  bluetooth,
  usb,
  builtinMic,
  unknown,
}

enum FaceTimeVideoEffectType {
  none,
  blurLight,
  blurStrong,
  virtualBackground,
}

@immutable
class FaceTimeAudioDevice {
  const FaceTimeAudioDevice({
    required this.id,
    required this.label,
    required this.kind,
    required this.isInput,
    this.isActive = false,
  });

  final String id;
  final String label;
  final FaceTimeAudioDeviceKind kind;
  final bool isInput;
  final bool isActive;

  FaceTimeAudioDevice copyWith({
    String? id,
    String? label,
    FaceTimeAudioDeviceKind? kind,
    bool? isInput,
    bool? isActive,
  }) {
    return FaceTimeAudioDevice(
      id: id ?? this.id,
      label: label ?? this.label,
      kind: kind ?? this.kind,
      isInput: isInput ?? this.isInput,
      isActive: isActive ?? this.isActive,
    );
  }

  static FaceTimeAudioDeviceKind parseKind(dynamic raw, {bool isInput = false}) {
    final normalized = raw?.toString().trim().toLowerCase() ?? '';
    switch (normalized) {
      case 'earpiece':
        return FaceTimeAudioDeviceKind.earpiece;
      case 'speaker':
      case 'speakerphone':
        return FaceTimeAudioDeviceKind.speaker;
      case 'wired':
      case 'wired_headset':
      case 'wired_headphones':
      case 'headset':
        return FaceTimeAudioDeviceKind.wired;
      case 'bluetooth':
      case 'bt':
      case 'bt_sco':
      case 'ble_headset':
      case 'hearing_aid':
        return FaceTimeAudioDeviceKind.bluetooth;
      case 'usb':
      case 'usb_headset':
      case 'usb_device':
        return FaceTimeAudioDeviceKind.usb;
      case 'builtinmic':
      case 'builtin_mic':
      case 'builtin':
      case 'mic':
        return FaceTimeAudioDeviceKind.builtinMic;
      default:
        return isInput ? FaceTimeAudioDeviceKind.builtinMic : FaceTimeAudioDeviceKind.unknown;
    }
  }

  factory FaceTimeAudioDevice.fromJson(Map<dynamic, dynamic> json, {bool? isInputOverride}) {
    final isInput = isInputOverride ?? (json['is_input'] == true || json['isInput'] == true);
    final id = (json['id'] ?? json['device_id'] ?? json['deviceId'] ?? '').toString();
    final rawLabel = (json['label'] ?? json['name'] ?? '').toString().trim();
    return FaceTimeAudioDevice(
      id: id,
      label: rawLabel.isNotEmpty ? rawLabel : (isInput ? 'Microphone' : 'Audio output'),
      kind: parseKind(json['kind'] ?? json['type'], isInput: isInput),
      isInput: isInput,
      isActive: json['is_active'] == true || json['isActive'] == true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FaceTimeAudioDevice &&
        other.id == id &&
        other.label == label &&
        other.kind == kind &&
        other.isInput == isInput &&
        other.isActive == isActive;
  }

  @override
  int get hashCode => Object.hash(id, label, kind, isInput, isActive);
}

@immutable
class FaceTimeBackgroundPreset {
  const FaceTimeBackgroundPreset({
    required this.id,
    required this.label,
    this.assetOrPath,
  });

  final String id;
  final String label;
  final String? assetOrPath;

  static const List<FaceTimeBackgroundPreset> presets = <FaceTimeBackgroundPreset>[
    FaceTimeBackgroundPreset(id: 'studio_warm', label: 'Warm Studio'),
    FaceTimeBackgroundPreset(id: 'gradient_dusk', label: 'Dusk Gradient'),
    FaceTimeBackgroundPreset(id: 'slate_minimal', label: 'Slate Minimal'),
    FaceTimeBackgroundPreset(id: 'ocean_calm', label: 'Ocean Calm'),
  ];
}

@immutable
class FaceTimeCallQualityStats {
  const FaceTimeCallQualityStats({
    this.sendWidth = 0,
    this.sendHeight = 0,
    this.sendFps = 0,
    this.sendBitrateKbps = 0,
    this.recvWidth = 0,
    this.recvHeight = 0,
    this.recvFps = 0,
    this.recvBitrateKbps = 0,
    this.packetLossPct = 0.0,
    this.rttMs = 0,
    this.audioSendBitrateKbps = 0,
    this.audioRecvBitrateKbps = 0,
    this.audioPacketsLost = 0,
    this.audioInLevel = 0.0,
    this.audioOutLevel = 0.0,
  });

  final int sendWidth;
  final int sendHeight;
  final int sendFps;
  final int sendBitrateKbps;
  final int recvWidth;
  final int recvHeight;
  final int recvFps;
  final int recvBitrateKbps;
  final double packetLossPct;
  final int rttMs;
  final int audioSendBitrateKbps;
  final int audioRecvBitrateKbps;
  final int audioPacketsLost;
  final double audioInLevel;
  final double audioOutLevel;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FaceTimeCallQualityStats &&
        other.sendWidth == sendWidth &&
        other.sendHeight == sendHeight &&
        other.sendFps == sendFps &&
        other.sendBitrateKbps == sendBitrateKbps &&
        other.recvWidth == recvWidth &&
        other.recvHeight == recvHeight &&
        other.recvFps == recvFps &&
        other.recvBitrateKbps == recvBitrateKbps &&
        other.packetLossPct == packetLossPct &&
        other.rttMs == rttMs &&
        other.audioSendBitrateKbps == audioSendBitrateKbps &&
        other.audioRecvBitrateKbps == audioRecvBitrateKbps &&
        other.audioPacketsLost == audioPacketsLost &&
        other.audioInLevel == audioInLevel &&
        other.audioOutLevel == audioOutLevel;
  }

  @override
  int get hashCode => Object.hash(
        sendWidth,
        sendHeight,
        sendFps,
        sendBitrateKbps,
        recvWidth,
        recvHeight,
        recvFps,
        recvBitrateKbps,
        packetLossPct,
        rttMs,
        audioSendBitrateKbps,
        audioRecvBitrateKbps,
        audioPacketsLost,
        audioInLevel,
        audioOutLevel,
      );
}

@immutable
class AdaptiveQualityRung {
  const AdaptiveQualityRung({
    required this.index,
    required this.maxWidth,
    required this.maxHeight,
    required this.maxFramerate,
    required this.scaleResolutionDownBy,
    required this.stepDownFloorKbps,
    required this.maxBitrateKbps,
    required this.stepUpCeilingKbps,
  });

  final int index;
  final int maxWidth;
  final int maxHeight;
  final int maxFramerate;
  final double scaleResolutionDownBy;
  final int stepDownFloorKbps;
  final int maxBitrateKbps;
  final int stepUpCeilingKbps;
}

@immutable
class AdaptiveQualityDecision {
  const AdaptiveQualityDecision({
    required this.rungIndex,
    required this.maxBitrateBps,
    required this.maxFramerate,
    required this.scaleResolutionDownBy,
    required this.changed,
  });

  final int rungIndex;
  final int maxBitrateBps;
  final int maxFramerate;
  final double scaleResolutionDownBy;
  final bool changed;
}

/// 5-rung adaptive uplink ladder with asymmetric hysteresis (2s drop, 6s step-up,
/// and 8s->14s->20s oscillation cooldown) matching the server downlink ladder.
class AdaptiveQualityLadder {
  AdaptiveQualityLadder({
    int initialRung = 4,
    DateTime Function()? now,
  })  : _rungIndex = initialRung.clamp(0, rungs.length - 1),
        _now = now ?? DateTime.now;

  static const List<AdaptiveQualityRung> rungs = <AdaptiveQualityRung>[
    AdaptiveQualityRung(
      index: 0,
      maxWidth: 426,
      maxHeight: 240,
      maxFramerate: 15,
      scaleResolutionDownBy: 4.0,
      stepDownFloorKbps: 150,
      maxBitrateKbps: 300,
      stepUpCeilingKbps: 400,
    ),
    AdaptiveQualityRung(
      index: 1,
      maxWidth: 640,
      maxHeight: 360,
      maxFramerate: 24,
      scaleResolutionDownBy: 3.0,
      stepDownFloorKbps: 240,
      maxBitrateKbps: 650,
      stepUpCeilingKbps: 820,
    ),
    AdaptiveQualityRung(
      index: 2,
      maxWidth: 960,
      maxHeight: 540,
      maxFramerate: 30,
      scaleResolutionDownBy: 2.0,
      stepDownFloorKbps: 500,
      maxBitrateKbps: 1200,
      stepUpCeilingKbps: 1500,
    ),
    AdaptiveQualityRung(
      index: 3,
      maxWidth: 1280,
      maxHeight: 720,
      maxFramerate: 30,
      scaleResolutionDownBy: 1.5,
      stepDownFloorKbps: 950,
      maxBitrateKbps: 2500,
      stepUpCeilingKbps: 3000,
    ),
    AdaptiveQualityRung(
      index: 4,
      maxWidth: 1920,
      maxHeight: 1080,
      maxFramerate: 30,
      scaleResolutionDownBy: 1.0,
      stepDownFloorKbps: 1800,
      maxBitrateKbps: 4000,
      stepUpCeilingKbps: 4500,
    ),
  ];

  final DateTime Function() _now;
  int _rungIndex;
  int _consecutiveModerateLoss = 0;
  DateTime? _lowConditionStart;
  DateTime? _highConditionStart;
  DateTime? _lastDropAt;
  DateTime? _lastStepUpAt;
  DateTime? _lastBitrateUpdateAt;
  int _oscillationCount = 0;
  int _appliedMaxBitrateBps = 4000000;

  int get rungIndex => _rungIndex;
  AdaptiveQualityRung get currentRung => rungs[_rungIndex];

  Duration get _currentCooldown {
    if (_oscillationCount >= 2) return const Duration(seconds: 20);
    if (_oscillationCount == 1) return const Duration(seconds: 14);
    return const Duration(seconds: 8);
  }

  AdaptiveQualityDecision evaluate({
    required double availableBitrateKbps,
    required double packetLossPct,
    required int rttMs,
    bool qualityLimited = false,
    DateTime? timestamp,
  }) {
    final ts = timestamp ?? _now();
    final rung = currentRung;
    final prevRung = _rungIndex;

    if (packetLossPct > 5.0) {
      _consecutiveModerateLoss++;
    } else {
      _consecutiveModerateLoss = 0;
    }

    final severeImmediateDrop = packetLossPct > 10.0 || _consecutiveModerateLoss >= 2 || rttMs > 400;
    final lowBwe = availableBitrateKbps > 0 && availableBitrateKbps < rung.stepDownFloorKbps * 0.8;
    final shouldDropCondition = lowBwe || qualityLimited;

    if (shouldDropCondition) {
      _lowConditionStart ??= ts;
    } else {
      _lowConditionStart = null;
    }

    final sustainedDrop = _lowConditionStart != null && ts.difference(_lowConditionStart!) >= const Duration(seconds: 2);

    if (_rungIndex > 0 && (severeImmediateDrop || sustainedDrop)) {
      if (_lastStepUpAt != null && ts.difference(_lastStepUpAt!) <= const Duration(seconds: 30)) {
        _oscillationCount++;
      }
      _rungIndex--;
      _lastDropAt = ts;
      _lowConditionStart = null;
      _highConditionStart = null;
      _consecutiveModerateLoss = 0;
    } else if (_rungIndex < rungs.length - 1) {
      final cooldownActive = _lastDropAt != null && ts.difference(_lastDropAt!) < _currentCooldown;
      final hasEnoughBwe = availableBitrateKbps >= rung.stepUpCeilingKbps;
      final healthyNetwork = packetLossPct < 1.0 && rttMs < 200 && !qualityLimited;

      if (!cooldownActive && hasEnoughBwe && healthyNetwork) {
        _highConditionStart ??= ts;
        if (ts.difference(_highConditionStart!) >= const Duration(seconds: 6)) {
          _rungIndex++;
          _lastStepUpAt = ts;
          _highConditionStart = null;
        }
      } else {
        _highConditionStart = null;
      }
    }

    final next = currentRung;
    final rungChanged = _rungIndex != prevRung;

    int targetBitrateKbps = next.maxBitrateKbps;
    if (availableBitrateKbps > 0) {
      targetBitrateKbps = availableBitrateKbps.round().clamp(next.stepDownFloorKbps, next.maxBitrateKbps);
    }
    final desiredBitrateBps = targetBitrateKbps * 1000;

    bool bitrateChanged = rungChanged;
    if (!rungChanged && desiredBitrateBps != _appliedMaxBitrateBps) {
      final deltaRatio = (_appliedMaxBitrateBps - desiredBitrateBps).abs() /
          (_appliedMaxBitrateBps > 0 ? _appliedMaxBitrateBps : desiredBitrateBps);
      final cadenceOk = _lastBitrateUpdateAt == null ||
          ts.difference(_lastBitrateUpdateAt!) >= const Duration(milliseconds: 500);
      if (deltaRatio >= 0.10 && cadenceOk) {
        bitrateChanged = true;
      }
    }

    if (bitrateChanged) {
      _appliedMaxBitrateBps = desiredBitrateBps;
      _lastBitrateUpdateAt = ts;
    }

    return AdaptiveQualityDecision(
      rungIndex: _rungIndex,
      maxBitrateBps: _appliedMaxBitrateBps,
      maxFramerate: next.maxFramerate,
      scaleResolutionDownBy: next.scaleResolutionDownBy,
      changed: bitrateChanged,
    );
  }
}
