import 'dart:typed_data';
import 'dart:ui';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-bleed frosted incoming / ringing / connecting FaceTime call screen.
class IncomingFaceTimeScreen extends StatefulWidget {
  const IncomingFaceTimeScreen({
    super.key,
    required this.callUuid,
    required this.callerName,
    this.avatarBytes,
    this.isAudio = false,
    this.isTelephony = false,
    this.isConnecting = false,
    this.controller,
    this.onAnswerVideo,
    this.onAnswerAudio,
    this.onDecline,
    this.onCancelConnecting,
  });

  final String callUuid;
  final String callerName;
  final Uint8List? avatarBytes;
  final bool isAudio;
  final bool isTelephony;
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

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
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
    final reducedMotion = facetimeReducedMotionOf(context);
    if (reducedMotion || _effectiveConnecting) {
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
    final reducedMotion = facetimeReducedMotionOf(context);
    final ctrl = widget.controller;
    final matchesCtrl = ctrl != null && ctrl.state.callUuid == widget.callUuid;
    final isTelephony = (matchesCtrl ? ctrl.state.isTelephony : false) || widget.isTelephony;
    final isAudio = isTelephony || _localAudioOverride || (matchesCtrl ? !ctrl.state.isVideo : widget.isAudio);
    final hasPhoto = widget.avatarBytes != null && widget.avatarBytes!.isNotEmpty;
    final statusBadge = connecting
        ? 'Connecting…'
        : isTelephony
            ? 'iPhone Call'
            : isAudio
                ? 'FaceTime Audio'
                : 'FaceTime Video';
    final statusSubtitle = connecting
        ? (isTelephony ? 'Connecting audio…' : 'Generating call link…')
        : isTelephony
            ? 'Incoming iPhone Call'
            : isAudio
                ? 'Incoming FaceTime Audio'
                : 'Incoming FaceTime Video';

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
        color: FaceTimePalette.darkCanvas,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Full-bleed frosted caller backdrop
            if (hasPhoto)
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 38, sigmaY: 38),
                child: Transform.scale(
                  scale: 1.15,
                  child: Image.memory(
                    widget.avatarBytes!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              )
            else
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.25),
                      radius: 1.1,
                      colors: [
                        FaceTimePalette.blue.withValues(alpha: 0.22),
                        FaceTimePalette.darkSurface,
                        FaceTimePalette.darkCanvas,
                      ],
                    ),
                  ),
                ),
              ),

            // Dark readability scrim
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: hasPhoto ? 0.56 : 0.35),
                    FaceTimePalette.darkCanvas.withValues(alpha: hasPhoto ? 0.72 : 0.60),
                    FaceTimePalette.darkCanvas.withValues(alpha: 0.92),
                  ],
                ),
              ),
            ),

            // Foreground layout
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Column(
                  children: [
                    // Top call type pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isAudio ? Icons.call_rounded : Icons.videocam_rounded,
                            size: 16,
                            color: connecting ? FaceTimePalette.blue : FaceTimePalette.green,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            statusBadge,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(flex: 2),

                    // Hero caller avatar + ambient pulse
                    SizedBox(
                      width: 176,
                      height: 176,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (!connecting)
                            AnimatedBuilder(
                              animation: _pulseController,
                              builder: (context, _) {
                                final t = reducedMotion ? 0.25 : _pulseController.value;
                                final scale = 1.0 + (t * 0.28);
                                final opacity = reducedMotion ? 0.24 : (1.0 - t) * 0.36;
                                return Transform.scale(
                                  scale: scale,
                                  child: Container(
                                    width: 128,
                                    height: 128,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: FaceTimePalette.green.withValues(alpha: opacity),
                                        width: 2.5,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            )
                          else
                            const SizedBox(
                              width: 144,
                              height: 144,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: FaceTimePalette.blue,
                              ),
                            ),
                          FaceTimeAvatar(
                            callerName: widget.callerName,
                            avatarBytes: widget.avatarBytes,
                            size: 124,
                            borderColor: Colors.white.withValues(alpha: 0.22),
                            borderWidth: 2,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    Text(
                      widget.callerName,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      statusSubtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    const Spacer(flex: 3),

                    AnimatedSwitcher(
                      duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 220),
                      child: connecting
                          ? _ConnectingActions(
                              key: const ValueKey('connecting-actions'),
                              onCancel: widget.onCancelConnecting ?? widget.onDecline,
                            )
                          : _IncomingActions(
                              key: const ValueKey('incoming-actions'),
                              isAudio: isAudio,
                              onDecline: widget.onDecline,
                              onAnswerAudio: _triggerAnswerAudio,
                              onAnswerVideo: _triggerAnswerVideo,
                            ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _IncomingActions extends StatelessWidget {
  const _IncomingActions({
    super.key,
    required this.isAudio,
    required this.onDecline,
    required this.onAnswerAudio,
    required this.onAnswerVideo,
  });

  final bool isAudio;
  final VoidCallback? onDecline;
  final VoidCallback onAnswerAudio;
  final VoidCallback onAnswerVideo;

  @override
  Widget build(BuildContext context) {
    if (isAudio) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _CircleCallAction(
            icon: Icons.call_end_rounded,
            label: 'Decline',
            backgroundColor: FaceTimePalette.red,
            foregroundColor: Colors.white,
            size: 68,
            onPressed: onDecline,
          ),
          _CircleCallAction(
            icon: Icons.call_rounded,
            label: 'Answer Audio',
            backgroundColor: FaceTimePalette.green,
            foregroundColor: Colors.white,
            size: 68,
            onPressed: onAnswerAudio,
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CircleCallAction(
          icon: Icons.call_end_rounded,
          label: 'Decline',
          backgroundColor: FaceTimePalette.red,
          foregroundColor: Colors.white,
          size: 64,
          onPressed: onDecline,
        ),
        _CircleCallAction(
          icon: Icons.call_rounded,
          label: 'Audio Only',
          backgroundColor: Colors.white.withValues(alpha: 0.16),
          foregroundColor: Colors.white,
          borderColor: Colors.white.withValues(alpha: 0.24),
          size: 64,
          onPressed: onAnswerAudio,
        ),
        _CircleCallAction(
          icon: Icons.videocam_rounded,
          label: 'Answer Video',
          backgroundColor: FaceTimePalette.green,
          foregroundColor: Colors.white,
          size: 64,
          onPressed: onAnswerVideo,
        ),
      ],
    );
  }
}

class _ConnectingActions extends StatelessWidget {
  const _ConnectingActions({super.key, this.onCancel});

  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 160, minHeight: 52),
        child: FilledButton.icon(
          onPressed: onCancel,
          style: FilledButton.styleFrom(
            backgroundColor: FaceTimePalette.red,
            foregroundColor: Colors.white,
            minimumSize: const Size(160, 52),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: const StadiumBorder(),
          ),
          icon: const Icon(Icons.call_end_rounded, size: 20),
          label: const Text(
            'Cancel Call',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _CircleCallAction extends StatelessWidget {
  const _CircleCallAction({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.size,
    required this.onPressed,
    this.borderColor,
  });

  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color? borderColor;
  final double size;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final effectiveSize = size < 48 ? 48.0 : size;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: backgroundColor,
            shape: CircleBorder(
              side: borderColor != null ? BorderSide(color: borderColor!, width: 1) : BorderSide.none,
            ),
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: effectiveSize,
                height: effectiveSize,
                child: Center(
                  child: Icon(icon, color: foregroundColor, size: 28),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        ExcludeSemantics(
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.92),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
