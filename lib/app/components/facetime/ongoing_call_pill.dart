import 'dart:ui';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/helpers/types/helpers/misc_helpers.dart';
import 'package:flutter/material.dart';

/// Floating Dynamic Island / Google Meet style ongoing FaceTime call bar.
class OngoingCallPillOverlay extends StatefulWidget {
  const OngoingCallPillOverlay({
    super.key,
    this.controller,
  });

  final ActiveCallController? controller;

  @override
  State<OngoingCallPillOverlay> createState() => _OngoingCallPillOverlayState();
}

class _OngoingCallPillOverlayState extends State<OngoingCallPillOverlay> {
  bool _expanded = true;

  ActiveCallController get _controller => widget.controller ?? ActiveCallController.instance;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = facetimeReducedMotionOf(context);
    final topPadding = MediaQuery.viewPaddingOf(context).top;
    final topOffset = topPadding + (kIsDesktop ? 36.0 : 8.0);

    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final state = _controller.state;
        final visible = state.phase == ActiveCallPhase.ongoing;

        if (!visible) {
          return const SizedBox.shrink();
        }

        return Positioned(
          top: topOffset,
          left: 16,
          right: 16,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Material(
                type: MaterialType.transparency,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: FaceTimePalette.darkCanvas.withValues(alpha: 0.90),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.34),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: AnimatedSize(
                        duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _PillHeaderRow(
                                state: state,
                                formattedDuration: _controller.formattedDuration,
                                expanded: _expanded,
                                onToggleExpand: () => setState(() => _expanded = !_expanded),
                              ),
                              if (_expanded) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _PillControlButton(
                                        icon: state.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                                        label: state.isMuted ? 'Unmute' : 'Mute',
                                        semanticsLabel: state.isMuted ? 'Unmute mic' : 'Mute mic',
                                        backgroundColor: state.isMuted
                                            ? Colors.white
                                            : Colors.white.withValues(alpha: 0.12),
                                        foregroundColor: state.isMuted
                                            ? FaceTimePalette.darkCanvas
                                            : Colors.white,
                                        onPressed: _controller.toggleMute,
                                      ),
                                    ),
                                    if (_controller.canReturn) ...[
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _PillControlButton(
                                          icon: state.isVideo ? Icons.videocam_rounded : Icons.open_in_new_rounded,
                                          label: 'Return',
                                          semanticsLabel: 'Return to call',
                                          backgroundColor: FaceTimePalette.blue.withValues(alpha: 0.24),
                                          foregroundColor: Colors.white,
                                          borderColor: FaceTimePalette.blue.withValues(alpha: 0.55),
                                          onPressed: () => _controller.returnToCall(context),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _PillControlButton(
                                        icon: Icons.call_end_rounded,
                                        label: 'End',
                                        semanticsLabel: 'End call',
                                        backgroundColor: FaceTimePalette.red,
                                        foregroundColor: Colors.white,
                                        onPressed: _controller.endCall,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PillHeaderRow extends StatelessWidget {
  const _PillHeaderRow({
    required this.state,
    required this.formattedDuration,
    required this.expanded,
    required this.onToggleExpand,
  });

  final ActiveCallState state;
  final String formattedDuration;
  final bool expanded;
  final VoidCallback onToggleExpand;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggleExpand,
      borderRadius: BorderRadius.circular(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  FaceTimeAvatar(
                    callerName: state.callerName,
                    avatarBytes: state.avatarBytes,
                    size: 32,
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: FaceTimePalette.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: FaceTimePalette.darkCanvas, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: (state.isVideo ? FaceTimePalette.blue : FaceTimePalette.green).withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Icon(
                  state.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                  size: 13,
                  color: state.isVideo ? const Color(0xFF60A5FA) : FaceTimePalette.green,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.callerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: FaceTimePalette.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      formattedDuration,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                color: Colors.white.withValues(alpha: 0.72),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PillControlButton extends StatelessWidget {
  const _PillControlButton({
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onPressed,
    this.borderColor,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color? borderColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: Material(
        color: backgroundColor,
        shape: StadiumBorder(
          side: borderColor != null ? BorderSide(color: borderColor!, width: 1) : BorderSide.none,
        ),
        child: InkWell(
          onTap: onPressed,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 17, color: foregroundColor),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foregroundColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
