import 'dart:async';
import 'dart:ui';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:flutter/material.dart';

/// Unified layout-integrated call bar for incoming, outgoing, connecting,
/// ongoing, and cross-device Handoff calls.
class OngoingCallPillOverlay extends StatefulWidget {
  const OngoingCallPillOverlay({
    super.key,
    this.controller,
  });

  final ActiveCallController? controller;

  static bool hasActiveCall(ActiveCallState state) => state.phase != ActiveCallPhase.idle;

  @override
  State<OngoingCallPillOverlay> createState() => _OngoingCallPillOverlayState();
}

class _OngoingCallPillOverlayState extends State<OngoingCallPillOverlay> {
  final OverlayPortalController _keypadPortal = OverlayPortalController();
  final GlobalKey _keypadButtonKey = GlobalKey();
  Rect? _keypadAnchorRect;
  bool _showKeypad = false;

  ActiveCallController get _controller => widget.controller ?? ActiveCallController.instance;

  void _toggleKeypad() {
    setState(() {
      _showKeypad = !_showKeypad;
      if (_showKeypad) {
        final box = _keypadButtonKey.currentContext?.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          final origin = box.localToGlobal(Offset.zero);
          _keypadAnchorRect = origin & box.size;
        } else {
          _keypadAnchorRect = null;
        }
        _keypadPortal.show();
      } else {
        _keypadPortal.hide();
      }
    });
  }

  void _closeKeypad() {
    if (!_showKeypad) return;
    setState(() {
      _showKeypad = false;
      _keypadPortal.hide();
    });
  }

  @override
  void dispose() {
    if (_keypadPortal.isShowing) {
      _keypadPortal.hide();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = facetimeReducedMotionOf(context);
    final duration = reduceMotion ? Duration.zero : const Duration(milliseconds: 180);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final state = _controller.state;
        final isActive = OngoingCallPillOverlay.hasActiveCall(state);
        if (!isActive && _showKeypad) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _closeKeypad());
        }

        final content = !isActive
            ? const SizedBox.shrink(key: ValueKey('call_bar_idle'))
            : _buildBar(context, state);

        return Align(
          alignment: Alignment.topCenter,
          heightFactor: 1.0,
          child: AnimatedSize(
            duration: duration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: content,
          ),
        );
      },
    );
  }

  Widget _buildBar(BuildContext context, ActiveCallState state) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tone = state.isOnOtherDevice ? FaceTimePalette.blue : FaceTimePalette.green;
    final baseSurface = isDark ? FaceTimePalette.darkSurface : theme.colorScheme.surfaceContainerHigh;
    final bgColor = Color.alphaBlend(
      tone.withValues(alpha: isDark ? 0.16 : 0.09),
      baseSurface,
    ).withValues(alpha: isDark ? 0.72 : 0.76);
    final borderColor = Color.alphaBlend(
      tone.withValues(alpha: 0.24),
      isDark ? Colors.white : theme.colorScheme.outline,
    ).withValues(alpha: isDark ? 0.18 : 0.16);
    final fgColor = isDark ? Colors.white : theme.colorScheme.onSurface;
    final subColor = isDark ? Colors.white70 : theme.colorScheme.onSurfaceVariant;

    return OverlayPortal(
      controller: _keypadPortal,
      overlayChildBuilder: (overlayContext) => _KeypadOverlay(
        anchorRect: _keypadAnchorRect,
        onDismiss: _closeKeypad,
        onDigit: (d) => unawaited(_controller.sendDtmf(d)),
      ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              key: ValueKey('call_bar_${state.phase.name}'),
              width: double.infinity,
              decoration: BoxDecoration(
                color: bgColor,
                border: Border(bottom: BorderSide(color: borderColor, width: 1)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 600;
                  if (state.isIncoming) {
                    return _buildIncomingRow(context, state, fgColor, subColor, compact);
                  }
                  if (state.isOnOtherDevice || (!state.isHeldHere && state.hasCallUuid && (state.isOngoing || state.isOutgoingPhase))) {
                    return _buildHandoffRow(context, state, fgColor, subColor, compact);
                  }
                  if (state.isOutgoingPhase || state.isConnecting) {
                    return _buildOutgoingOrConnectingRow(context, state, fgColor, subColor, compact);
                  }
                  return _buildOngoingRow(context, state, fgColor, subColor, compact);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIncomingRow(
    BuildContext context,
    ActiveCallState state,
    Color fgColor,
    Color subColor,
    bool compact,
  ) {
    final callUuid = state.callUuid ?? '';
    final actions = faceTimeIncomingActions[callUuid];
    final isVideo = state.isVideo && !state.isTelephony;
    final subtitle = state.isTelephony
        ? 'iPhone Call'
        : (isVideo ? 'FaceTime' : 'FaceTime Audio');

    return Row(
      children: [
        Expanded(
          child: InkWell(
            key: const Key('incoming_call_banner_tap'),
            borderRadius: BorderRadius.circular(10),
            onTap: callUuid.isEmpty
                ? null
                : () => openIncomingFaceTimeScreen(
                      callUuid,
                      context: context,
                      controller: _controller,
                    ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                children: [
                  FaceTimeAvatar(
                    callerName: state.callerName,
                    avatarBytes: state.avatarBytes,
                    size: 32,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.callerName.isNotEmpty ? state.callerName : subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: fgColor, fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: subColor, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isVideo) ...[
          const SizedBox(width: 4),
          _BarIconAction(
            icon: Icons.call_rounded,
            tooltip: 'Accept audio',
            semanticsLabel: 'Accept audio',
            color: fgColor.withValues(alpha: 0.9),
            backgroundColor: fgColor.withValues(alpha: 0.1),
            onPressed: actions?.onAnswerAudio ??
                () => unawaited(_controller.answerCall(audioOnly: true, context: context)),
          ),
        ],
        const SizedBox(width: 6),
        _BarPillAction(
          label: compact ? null : 'Decline',
          icon: Icons.call_end_rounded,
          semanticsLabel: 'Decline call',
          backgroundColor: FaceTimePalette.red,
          foregroundColor: Colors.white,
          onPressed: actions?.onDecline ?? () => unawaited(_controller.declineCall()),
        ),
        const SizedBox(width: 6),
        _BarPillAction(
          label: compact ? null : 'Accept',
          icon: isVideo ? Icons.videocam_rounded : Icons.call_rounded,
          semanticsLabel: 'Accept call',
          backgroundColor: FaceTimePalette.green,
          foregroundColor: Colors.white,
          onPressed: (isVideo ? actions?.onAnswerVideo : actions?.onAnswerAudio) ??
              () => unawaited(_controller.answerCall(audioOnly: !isVideo, context: context)),
        ),
      ],
    );
  }

  Widget _buildOutgoingOrConnectingRow(
    BuildContext context,
    ActiveCallState state,
    Color fgColor,
    Color subColor,
    bool compact,
  ) {
    final subtitle = state.statusSubtitle.isNotEmpty
        ? state.statusSubtitle
        : (state.isConnecting ? 'Connecting…' : 'Calling…');

    return Row(
      children: [
        FaceTimeAvatar(
          callerName: state.callerName,
          avatarBytes: state.avatarBytes,
          size: 28,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.callerName.isNotEmpty ? state.callerName : 'FaceTime Call',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fgColor, fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: subColor, fontSize: 12),
              ),
            ],
          ),
        ),
        if (_controller.canReturn) ...[
          const SizedBox(width: 6),
          _BarPillAction(
            label: 'Join',
            icon: Icons.open_in_new_rounded,
            semanticsLabel: 'Return to call',
            backgroundColor: FaceTimePalette.green,
            foregroundColor: Colors.white,
            onPressed: () => unawaited(_controller.returnToCall(context)),
          ),
        ],
        const SizedBox(width: 6),
        _BarPillAction(
          label: 'End',
          icon: Icons.call_end_rounded,
          semanticsLabel: 'End call',
          backgroundColor: FaceTimePalette.red,
          foregroundColor: Colors.white,
          onPressed: () => unawaited(_controller.endCall()),
        ),
      ],
    );
  }

  Widget _buildHandoffRow(
    BuildContext context,
    ActiveCallState state,
    Color fgColor,
    Color subColor,
    bool compact,
  ) {
    final deviceName = (state.activeDeviceName != null && state.activeDeviceName!.isNotEmpty)
        ? state.activeDeviceName!
        : null;
    final statusText = state.isOutgoingPhase
        ? (deviceName != null ? 'Calling on $deviceName' : 'Calling…')
        : (deviceName != null ? 'On $deviceName · ${_controller.formattedDuration}' : _controller.formattedDuration);

    return Row(
      children: [
        FaceTimeAvatar(
          callerName: state.callerName,
          avatarBytes: state.avatarBytes,
          size: 28,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.callerName.isNotEmpty ? state.callerName : 'Active Call',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fgColor, fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              Text(
                statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: subColor,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        if (state.canTransferHere) ...[
          const SizedBox(width: 6),
          _BarPillAction(
            label: 'Switch',
            icon: Icons.devices_rounded,
            semanticsLabel: 'Switch to this device',
            backgroundColor: FaceTimePalette.blue,
            foregroundColor: Colors.white,
            onPressed: () => unawaited(_controller.transferHere(context: context)),
          ),
        ],
        const SizedBox(width: 6),
        _BarPillAction(
          label: compact ? null : 'End',
          icon: Icons.call_end_rounded,
          semanticsLabel: 'End call',
          backgroundColor: FaceTimePalette.red,
          foregroundColor: Colors.white,
          onPressed: () => unawaited(_controller.endCall()),
        ),
      ],
    );
  }

  Widget _buildOngoingRow(
    BuildContext context,
    ActiveCallState state,
    Color fgColor,
    Color subColor,
    bool compact,
  ) {
    final showKeypadButton = !state.isVideo && state.hasCallUuid;
    final muted = state.isMuted;

    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: FaceTimePalette.green,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        FaceTimeAvatar(
          callerName: state.callerName,
          avatarBytes: state.avatarBytes,
          size: 26,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  state.callerName.isNotEmpty ? state.callerName : 'Active Call',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fgColor, fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _controller.formattedDuration,
                style: TextStyle(
                  color: subColor,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        _BarPillAction(
          label: muted ? 'Unmute' : 'Mute',
          icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          semanticsLabel: 'Mute mic',
          backgroundColor: muted ? Colors.white : fgColor.withValues(alpha: 0.12),
          foregroundColor: muted ? FaceTimePalette.darkCanvas : fgColor,
          showLabelInCompact: !compact,
          onPressed: () => _controller.toggleMute(),
        ),
        if (showKeypadButton) ...[
          const SizedBox(width: 4),
          KeyedSubtree(
            key: _keypadButtonKey,
            child: _BarPillAction(
              label: 'Keypad',
              icon: Icons.dialpad_rounded,
              semanticsLabel: 'Keypad',
              backgroundColor: _showKeypad ? fgColor.withValues(alpha: 0.22) : fgColor.withValues(alpha: 0.12),
              foregroundColor: fgColor,
              showLabelInCompact: !compact,
              onPressed: _toggleKeypad,
            ),
          ),
        ],
        if (_controller.canReturn) ...[
          const SizedBox(width: 4),
          _BarPillAction(
            label: 'Return',
            icon: Icons.open_in_new_rounded,
            semanticsLabel: 'Return to call',
            backgroundColor: fgColor.withValues(alpha: 0.12),
            foregroundColor: fgColor,
            showLabelInCompact: !compact,
            onPressed: () => unawaited(_controller.returnToCall(context)),
          ),
        ],
        const SizedBox(width: 6),
        _BarPillAction(
          label: 'End',
          icon: Icons.call_end_rounded,
          semanticsLabel: 'End call',
          backgroundColor: FaceTimePalette.red,
          foregroundColor: Colors.white,
          showLabelInCompact: !compact,
          onPressed: () => unawaited(_controller.endCall()),
        ),
      ],
    );
  }
}

class _BarIconAction extends StatelessWidget {
  const _BarIconAction({
    required this.icon,
    required this.tooltip,
    required this.semanticsLabel,
    required this.color,
    required this.backgroundColor,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final String semanticsLabel;
  final Color color;
  final Color backgroundColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: semanticsLabel,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            child: Center(
              widthFactor: 1.0,
              heightFactor: 1.0,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: backgroundColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 18, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BarPillAction extends StatelessWidget {
  const _BarPillAction({
    required this.label,
    required this.icon,
    required this.semanticsLabel,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onPressed,
    this.showLabelInCompact = true,
  });

  final String? label;
  final IconData icon;
  final String semanticsLabel;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onPressed;
  final bool showLabelInCompact;

  @override
  Widget build(BuildContext context) {
    final displayLabel = showLabelInCompact ? label : null;
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: semanticsLabel,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            widthFactor: 1.0,
            heightFactor: 1.0,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: displayLabel != null ? 12 : 10,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: foregroundColor),
                  if (displayLabel != null) ...[
                    const SizedBox(width: 5),
                    Text(
                      displayLabel,
                      style: TextStyle(
                        color: foregroundColor,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeypadOverlay extends StatelessWidget {
  const _KeypadOverlay({
    required this.anchorRect,
    required this.onDismiss,
    required this.onDigit,
  });

  final Rect? anchorRect;
  final VoidCallback onDismiss;
  final ValueChanged<String> onDigit;

  static const _digits = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
  static const _panelWidth = 216.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final base = isDark ? FaceTimePalette.darkElevated : theme.colorScheme.surfaceContainerHighest;
    final bg = base.withValues(alpha: isDark ? 0.74 : 0.78);
    final fg = isDark ? Colors.white : theme.colorScheme.onSurface;
    final border = (isDark ? Colors.white : theme.colorScheme.outline).withValues(alpha: isDark ? 0.18 : 0.16);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final top = (anchorRect?.bottom ?? 56.0) + 6.0;
    final targetCenterX = anchorRect?.center.dx ?? (screenWidth - _panelWidth / 2 - 12);
    final left = (targetCenterX - _panelWidth / 2).clamp(12.0, (screenWidth - _panelWidth - 12.0).clamp(12.0, double.infinity));

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const Key('keypad_outside_dismiss'),
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        Positioned(
          top: top,
          left: left,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.shadow.withValues(alpha: isDark ? 0.34 : 0.14),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    width: _panelWidth,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: border),
                    ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var row = 0; row < 4; row++) ...[
                    if (row > 0) const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var col = 0; col < 3; col++) ...[
                          if (col > 0) const SizedBox(width: 6),
                          SizedBox(
                            width: 60,
                            height: 44,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => onDigit(_digits[row * 3 + col]),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: fg.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Center(
                                  child: Text(
                                    _digits[row * 3 + col],
                                    style: TextStyle(
                                      color: fg,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
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
],
    );
  }
}
