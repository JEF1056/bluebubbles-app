import 'dart:ui';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/call_controls.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-bleed M3 Expressive incoming / ringing / connecting FaceTime call screen.
class IncomingFaceTimeScreen extends StatefulWidget {
  const IncomingFaceTimeScreen({
    super.key,
    required this.callUuid,
    required this.callerName,
    this.callerAddress,
    this.avatarBytes,
    this.isAudio = false,
    this.isTelephony = false,
    this.isGroup = false,
    this.participants = const [],
    this.participantDetails = const [],
    this.isConnecting = false,
    this.controller,
    this.onAnswerVideo,
    this.onAnswerAudio,
    this.onDecline,
    this.onCancelConnecting,
  });

  final String callUuid;
  final String callerName;
  final String? callerAddress;
  final Uint8List? avatarBytes;
  final bool isAudio;
  final bool isTelephony;
  final bool isGroup;
  final List<String> participants;
  final List<CallParticipant> participantDetails;
  final bool isConnecting;
  final ActiveCallController? controller;
  final VoidCallback? onAnswerVideo;
  final VoidCallback? onAnswerAudio;
  final VoidCallback? onDecline;
  final VoidCallback? onCancelConnecting;

  @override
  State<IncomingFaceTimeScreen> createState() => _IncomingFaceTimeScreenState();
}

class _IncomingFaceTimeScreenState extends State<IncomingFaceTimeScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _localConnecting = false;
  bool _localAudioOverride = false;
  int _swipeAttempt = 0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: FaceTimeMotion.ring,
    );
    _localConnecting = widget.isConnecting;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(IncomingFaceTimeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isConnecting != oldWidget.isConnecting) {
      _localConnecting = widget.isConnecting;
    }
    _syncPulse();
  }

  bool get _effectiveConnecting {
    final ctrl = widget.controller;
    if (ctrl != null &&
        ctrl.state.callUuid == widget.callUuid &&
        ctrl.state.phase == ActiveCallPhase.connecting) {
      return true;
    }
    return _localConnecting || widget.isConnecting;
  }

  void _syncPulse() {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations || _effectiveConnecting) {
      _pulseController.stop();
      _pulseController.value = 0;
    } else if (!_pulseController.isAnimating) {
      _pulseController.repeat();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _triggerAnswerVideo() {
    setState(() => _localConnecting = true);
    _syncPulse();
    widget.onAnswerVideo?.call();
  }

  void _triggerAnswerAudio() {
    setState(() {
      _localConnecting = true;
      _localAudioOverride = true;
    });
    _syncPulse();
    widget.onAnswerAudio?.call();
  }

  void _triggerDecline() {
    widget.onDecline?.call();
    // Reset swipe pill key if screen stays mounted (e.g. caller error/test re-tap).
    if (mounted) {
      setState(() => _swipeAttempt++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    if (ctrl == null) {
      return _buildScaffold(context, connecting: _effectiveConnecting);
    }
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => _buildScaffold(context, connecting: _effectiveConnecting),
    );
  }

  Widget _buildScaffold(BuildContext context, {required bool connecting}) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final ctrl = widget.controller;
    final matchesCtrl = ctrl != null && ctrl.state.callUuid == widget.callUuid;
    final ctrlState = matchesCtrl ? ctrl.state : null;
    final isTelephony = (ctrlState?.isTelephony ?? false) || widget.isTelephony;
    final isAudio = isTelephony || _localAudioOverride || (ctrlState != null ? !ctrlState.isVideo : widget.isAudio);
    final effectiveParticipants = (ctrlState != null && ctrlState.participantDetails.isNotEmpty)
        ? ctrlState.participantDetails
        : widget.participantDetails;
    final effectiveParticipantHandles = (ctrlState != null && ctrlState.participants.isNotEmpty)
        ? ctrlState.participants
        : widget.participants;
    final isGroup = !isTelephony &&
        ((ctrlState?.isGroup ?? false) ||
            widget.isGroup ||
            effectiveParticipants.length > 1 ||
            effectiveParticipantHandles.length > 1);
    final kindLabel = ActiveCallController.callKindLabelFor(
      isVideo: !isAudio,
      isTelephony: isTelephony,
      isGroup: isGroup,
    );
    final effectiveAddress = (ctrlState?.callerAddress != null && ctrlState!.callerAddress!.trim().isNotEmpty)
        ? ctrlState.callerAddress!.trim()
        : (widget.callerAddress != null && widget.callerAddress!.trim().isNotEmpty ? widget.callerAddress!.trim() : null);
    final effectiveCallerName = (ctrlState != null && ctrlState.callerName.trim().isNotEmpty)
        ? ctrlState.displayCallerName
        : (widget.callerName.trim().isNotEmpty && !ActiveCallController.isGenericCallLabel(widget.callerName)
            ? widget.callerName.trim()
            : (effectiveAddress ?? kindLabel));
    final distinctHandle = ActiveCallState(
      callerName: effectiveCallerName,
      callerAddress: effectiveAddress,
      isGroup: isGroup,
      participants: effectiveParticipantHandles,
      participantDetails: effectiveParticipants,
    ).distinctCallerHandle;

    Uint8List? effectiveAvatar = ctrlState?.avatarBytes ?? widget.avatarBytes;
    if ((effectiveAvatar == null || effectiveAvatar.isEmpty) && effectiveParticipants.isNotEmpty) {
      for (final p in effectiveParticipants) {
        if (p.avatarBytes != null && p.avatarBytes!.isNotEmpty) {
          effectiveAvatar = p.avatarBytes;
          break;
        }
      }
    }
    final hasPhoto = effectiveAvatar != null && effectiveAvatar.isNotEmpty;
    final statusLabel = connecting ? 'Connecting…' : kindLabel;
    final statusSubtitle = connecting
        ? (isAudio || isTelephony ? 'Connecting audio…' : 'Connecting video…')
        : 'Incoming $kindLabel';
    final callAccent = isAudio ? FaceTimePalette.green : FaceTimePalette.m3Primary;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
      child: PopScope(
        canPop: false,
        child: Material(
          color: FaceTimePalette.m3Surface,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasPhoto) ...[
                RepaintBoundary(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 38, sigmaY: 38),
                    child: Transform.scale(
                      scale: 1.15,
                      child: Image.memory(
                        effectiveAvatar,
                        fit: BoxFit.cover,
                        cacheWidth: 96,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(color: FaceTimePalette.m3Scrim),
                ),
              ],
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.25),
                    radius: 0.95,
                    colors: [
                      callAccent.withValues(alpha: hasPhoto ? 0.12 : 0.16),
                      callAccent.withValues(alpha: 0.04),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, viewportConstraints) {
                    final windowSize = MediaQuery.sizeOf(context);
                    final isTall = windowSize.height >= 654;
                    final isCompact = windowSize.height < 640 || windowSize.width < 360;
                    final topPadding = isTall ? 72.0 : 16.0;

                    return SingleChildScrollView(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: 420,
                            minHeight: viewportConstraints.maxHeight,
                          ),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              FaceTimeDims.contactSideMargin,
                              topPadding,
                              FaceTimeDims.contactSideMargin,
                              isCompact ? 16 : 24,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _CallKindPill(
                                      label: statusLabel,
                                      icon: isTelephony
                                          ? Icons.phone_in_talk_rounded
                                          : (isAudio ? Icons.call_rounded : Icons.videocam_rounded),
                                      accentColor: callAccent,
                                      connecting: connecting,
                                    ),
                                    SizedBox(height: isTall ? 28 : 16),
                                    SizedBox(
                                      width: effectiveParticipants.length > 1 ? 180 : 140,
                                      height: 140,
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        alignment: Alignment.center,
                                        children: [
                                          if (!connecting && !disableAnimations) ...[
                                            _RingingHaloRing(
                                              key: const ValueKey('incoming_halo_ring_0'),
                                              animation: _pulseController,
                                              phaseOffset: 0.0,
                                              color: callAccent,
                                              maxAlpha: 0.30,
                                            ),
                                            _RingingHaloRing(
                                              key: const ValueKey('incoming_halo_ring_1'),
                                              animation: _pulseController,
                                              phaseOffset: 0.5,
                                              color: callAccent,
                                              maxAlpha: 0.22,
                                            ),
                                          ] else if (connecting)
                                            const SizedBox(
                                              width: 136,
                                              height: 136,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 3,
                                                color: FaceTimePalette.m3Primary,
                                              ),
                                            ),
                                          if (effectiveParticipants.length > 1)
                                            FaceTimeGroupedAvatar(
                                              participants: effectiveParticipants,
                                              size: 120,
                                              borderColor: FaceTimePalette.hairline,
                                            )
                                          else
                                            FaceTimeAvatar(
                                              callerName: effectiveCallerName,
                                              avatarBytes: effectiveAvatar,
                                              size: 120,
                                              borderColor: FaceTimePalette.hairline,
                                              borderWidth: 1,
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    Text(
                                      effectiveCallerName,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: kDefaultAppFontFamily,
                                        color: FaceTimePalette.m3OnSurface,
                                        fontSize: 28,
                                        fontWeight: FontWeight.w400,
                                        letterSpacing: -0.2,
                                        height: 1.2,
                                      ),
                                    ),
                                    if (distinctHandle != null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        distinctHandle,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: kDefaultAppFontFamily,
                                          color: FaceTimePalette.m3OnSurfaceVariant,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                        ),
                                      ),
                                    ],
                                    if (effectiveParticipants.length > 1) ...[
                                      const SizedBox(height: 10),
                                      FaceTimeParticipantChips(participants: effectiveParticipants),
                                    ],
                                    const SizedBox(height: 8),
                                    Text(
                                      statusSubtitle,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: kDefaultAppFontFamily,
                                        color: FaceTimePalette.m3OnSurface.withValues(alpha: 0.8),
                                        fontSize: 16,
                                        fontWeight: FontWeight.w400,
                                      ),
                                    ),
                                  ],
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 24),
                                  child: AnimatedSwitcher(
                                    duration: FaceTimeMotion.of(context, FaceTimeMotion.morph),
                                    switchInCurve: FaceTimeMotion.emphasized,
                                    switchOutCurve: FaceTimeMotion.emphasized,
                                    child: connecting
                                        ? _ConnectingActions(
                                            key: const ValueKey('connecting-actions'),
                                            compact: isCompact,
                                            onCancel: widget.onCancelConnecting ?? widget.onDecline,
                                          )
                                        : _IncomingActions(
                                            key: const ValueKey('incoming-actions'),
                                            swipeKey: ValueKey('incoming_swipe_pill_$_swipeAttempt'),
                                            isVideo: !isAudio,
                                            isTelephony: isTelephony,
                                            onDecline: _triggerDecline,
                                            onAnswerAudio: _triggerAnswerAudio,
                                            onAnswerVideo: _triggerAnswerVideo,
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallKindPill extends StatelessWidget {
  const _CallKindPill({
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.connecting,
  });

  final String label;
  final IconData icon;
  final Color accentColor;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: FaceTimePalette.m3SurfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: FaceTimePalette.m3SurfaceVariant.withValues(alpha: 0.7),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: connecting ? FaceTimePalette.m3Primary : accentColor,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: kDefaultAppFontFamily,
                color: FaceTimePalette.m3OnSurface,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingingHaloRing extends StatelessWidget {
  const _RingingHaloRing({
    super.key,
    required this.animation,
    required this.phaseOffset,
    required this.color,
    required this.maxAlpha,
  });

  final Animation<double> animation;
  final double phaseOffset;
  final Color color;
  final double maxAlpha;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final raw = (animation.value + phaseOffset) % 1.0;
        final t = FaceTimeMotion.emphasized.transform(raw);
        final scale = 1.0 + (t * 0.65);
        final opacity = (1.0 - t) * maxAlpha;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: opacity * 0.22),
              border: Border.all(
                color: color.withValues(alpha: opacity),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _IncomingActions extends StatelessWidget {
  const _IncomingActions({
    super.key,
    required this.swipeKey,
    required this.isVideo,
    required this.isTelephony,
    required this.onDecline,
    required this.onAnswerAudio,
    required this.onAnswerVideo,
  });

  final Key swipeKey;
  final bool isVideo;
  final bool isTelephony;
  final VoidCallback onDecline;
  final VoidCallback onAnswerAudio;
  final VoidCallback onAnswerVideo;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isVideo && !isTelephony) ...[
          FilledButton.tonalIcon(
            onPressed: onAnswerAudio,
            style: FilledButton.styleFrom(
              backgroundColor: FaceTimePalette.m3SurfaceContainerHigh,
              foregroundColor: FaceTimePalette.m3OnSurface,
              side: const BorderSide(color: FaceTimePalette.m3SurfaceVariant, width: 1),
              minimumSize: const Size(48, 40),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontFamily: kDefaultAppFontFamily,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            icon: const Icon(Icons.call_rounded, size: 18),
            label: const Text('Answer with audio'),
          ),
          const SizedBox(height: 8),
        ],
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.4,
          child: FaceTimeSwipeAnswerPill(
            key: swipeKey,
            onAccept: isVideo && !isTelephony ? onAnswerVideo : onAnswerAudio,
            onDecline: onDecline,
          ),
        ),
      ],
    );
  }
}

class _ConnectingActions extends StatelessWidget {
  const _ConnectingActions({
    super.key,
    required this.compact,
    this.onCancel,
  });

  final bool compact;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final height = compact ? 56.0 : FaceTimeDims.phoneEndPillHeight;
    final radius = BorderRadius.circular(height / 2);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: FaceTimeDims.swipeTrackMaxWidth),
        child: Semantics(
          button: true,
          label: 'Cancel',
          excludeSemantics: true,
          child: Material(
            color: FaceTimePalette.m3EndCallRed,
            borderRadius: radius,
            child: InkWell(
              onTap: onCancel,
              borderRadius: radius,
              child: SizedBox(
                width: double.infinity,
                height: height,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.call_end_rounded,
                      color: Colors.white,
                      size: compact ? 24.0 : 28.0,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Cancel',
                      style: TextStyle(
                        fontFamily: kDefaultAppFontFamily,
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
