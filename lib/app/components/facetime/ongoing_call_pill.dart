import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/call_controls.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:flutter/material.dart';

/// Unified layout-integrated flat M3 Expressive call bar for incoming,
/// outgoing, connecting, ongoing, and cross-device Handoff calls.
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
    if (!mounted || !_showKeypad) return;
    setState(() {
      _showKeypad = false;
      if (_keypadPortal.isShowing) {
        _keypadPortal.hide();
      }
    });
  }

  @override
  void dispose() {
    _showKeypad = false;
    if (_keypadPortal.isShowing) {
      _keypadPortal.hide();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = FaceTimeMotion.of(context, FaceTimeMotion.short);

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
          child: duration == Duration.zero
              ? content
              : AnimatedSize(
                  duration: duration,
                  curve: FaceTimeMotion.emphasized,
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
    final bgColor = isDark ? FaceTimePalette.darkSurface : theme.colorScheme.surfaceContainerHigh;
    final borderColor = theme.colorScheme.outlineVariant;
    final fgColor = isDark ? FaceTimePalette.onCanvas : theme.colorScheme.onSurface;

    return OverlayPortal(
      controller: _keypadPortal,
      overlayChildBuilder: (overlayContext) => _KeypadOverlay(
        anchorRect: _keypadAnchorRect,
        onDismiss: _closeKeypad,
        onDigit: (d) => unawaited(_controller.sendDtmf(d)),
      ),
      child: Material(
        color: bgColor,
        child: Container(
          key: ValueKey('call_bar_${state.phase.name}'),
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 56),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: borderColor, width: 1)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Builder(
            builder: (context) {
              if (state.isIncoming) {
                return _buildIncomingRow(context, state, fgColor);
              }
              if (state.isOnOtherDevice ||
                  (!state.isHeldHere && state.hasCallUuid && (state.isOngoing || state.isOutgoingPhase))) {
                return _buildHandoffRow(context, state, fgColor, isDark, theme);
              }
              if (state.isOutgoingPhase || state.isConnecting) {
                return _buildOutgoingOrConnectingRow(context, state, fgColor);
              }
              return _buildOngoingRow(context, state, fgColor);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildInfoLead({
    required Key tapKey,
    required VoidCallback? onTap,
    required ActiveCallState state,
    required String title,
    required String statusText,
    required Color fgColor,
    String? kindLabel,
    String? duration,
    bool muted = false,
  }) {
    final displayTitle = state.displayCallerName;
    final distinctHandle = state.distinctCallerHandle;
    final hasKind = kindLabel != null && kindLabel.isNotEmpty;
    final statusWithHandle = (distinctHandle != null && statusText.isNotEmpty)
        ? '$statusText · $distinctHandle'
        : statusText;

    Uint8List? stageAvatar = state.avatarBytes;
    if ((stageAvatar == null || stageAvatar.isEmpty) && state.participantDetails.isNotEmpty) {
      for (final p in state.participantDetails) {
        if (p.avatarBytes != null && p.avatarBytes!.isNotEmpty) {
          stageAvatar = p.avatarBytes;
          break;
        }
      }
    }

    return Expanded(
      child: InkWell(
        key: tapKey,
        borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            children: [
              if (state.participantDetails.length > 1)
                FaceTimeGroupedAvatar(
                  participants: state.participantDetails,
                  size: 32,
                )
              else
                FaceTimeAvatar(
                  callerName: displayTitle,
                  avatarBytes: stageAvatar,
                  handle: (state.callerAddress?.isNotEmpty ?? false) ? Handle(address: state.callerAddress!) : null,
                  size: 32,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kDefaultAppFontFamily,
                        color: fgColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                      ),
                    ),
                    if (hasKind)
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              kindLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: kDefaultAppFontFamily,
                                color: FaceTimePalette.secondaryText,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                height: 1.2,
                              ),
                            ),
                          ),
                          const Text(
                            ' · ',
                            style: TextStyle(
                              fontFamily: kDefaultAppFontFamily,
                              color: FaceTimePalette.secondaryText,
                              fontSize: 12,
                              height: 1.2,
                            ),
                          ),
                          Flexible(
                            child: FaceTimeStatusText(
                              statusWithHandle,
                              duration: duration,
                              muted: muted,
                            ),
                          ),
                        ],
                      )
                    else
                      FaceTimeStatusText(
                        statusWithHandle,
                        duration: duration,
                        muted: muted,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIncomingRow(
    BuildContext context,
    ActiveCallState state,
    Color fgColor,
  ) {
    final callUuid = state.callUuid ?? '';
    final actions = faceTimeIncomingActions[callUuid];
    final isVideo = state.isVideo && !state.isTelephony;
    final kindLabel = state.callKindLabel;
    final subtitle = 'Incoming $kindLabel';

    return Row(
      children: [
        _buildInfoLead(
          tapKey: const Key('incoming_call_banner_tap'),
          onTap: callUuid.isEmpty
              ? null
              : () => openIncomingFaceTimeScreen(
                    callUuid,
                    context: context,
                    controller: _controller,
                  ),
          state: state,
          title: state.displayCallerName,
          statusText: subtitle,
          fgColor: fgColor,
        ),
        const SizedBox(width: 8),
        _DenseCircleAction(
          icon: Icons.call_end_rounded,
          semanticsLabel: 'Decline call',
          backgroundColor: FaceTimePalette.decline,
          onPressed: actions?.onDecline ?? () => unawaited(_controller.declineCall()),
        ),
        const SizedBox(width: 8),
        _DenseCircleAction(
          icon: isVideo ? Icons.videocam_rounded : Icons.call_rounded,
          semanticsLabel: 'Accept call',
          backgroundColor: FaceTimePalette.accept,
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
  ) {
    final phaseLabel = state.statusSubtitle.isNotEmpty
        ? state.statusSubtitle
        : (state.isConnecting ? 'Connecting…' : 'Calling…');

    return Row(
      children: [
        _buildInfoLead(
          tapKey: const Key('ongoing_call_banner_tap'),
          onTap: () => openInAppCallScreen(
            context: context,
            controller: _controller,
          ),
          state: state,
          title: state.displayCallerName,
          kindLabel: state.callKindLabel,
          statusText: phaseLabel,
          fgColor: fgColor,
        ),
        if (_controller.canReturn) ...[
          const SizedBox(width: 6),
          FaceTimeDockButton(
            dense: true,
            icon: Icons.open_in_new_rounded,
            label: 'Return to call',
            onPressed: () => unawaited(_controller.returnToCall(context)),
          ),
        ],
        const SizedBox(width: 6),
        FaceTimeEndCallPill(
          dense: true,
          onPressed: () => unawaited(_controller.endCall()),
        ),
      ],
    );
  }

  Widget _buildHandoffRow(
    BuildContext context,
    ActiveCallState state,
    Color fgColor,
    bool isDark,
    ThemeData theme,
  ) {
    final deviceName = (state.activeDeviceName != null && state.activeDeviceName!.isNotEmpty)
        ? state.activeDeviceName!
        : null;
    final statusLabel = state.isOutgoingPhase
        ? (deviceName != null ? 'Calling on $deviceName' : 'Calling…')
        : (deviceName != null ? 'On $deviceName' : state.callKindLabel);
    final duration = state.isOutgoingPhase ? null : _controller.formattedDuration;

    return Row(
      children: [
        _buildInfoLead(
          tapKey: const Key('ongoing_call_banner_tap'),
          onTap: () => openInAppCallScreen(
            context: context,
            controller: _controller,
          ),
          state: state,
          title: state.displayCallerName,
          kindLabel: deviceName != null ? state.callKindLabel : null,
          statusText: statusLabel,
          duration: duration,
          fgColor: fgColor,
        ),
        if (state.canTransferHere) ...[
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: () => unawaited(_controller.transferHere(context: context)),
            style: FilledButton.styleFrom(
              backgroundColor: isDark ? FaceTimePalette.darkElevated : theme.colorScheme.secondaryContainer,
              foregroundColor: isDark ? FaceTimePalette.blueDark : theme.colorScheme.onSecondaryContainer,
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontFamily: kDefaultAppFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            child: const Text('Move here'),
          ),
        ],
        const SizedBox(width: 8),
        FaceTimeEndCallPill(
          dense: true,
          onPressed: () => unawaited(_controller.endCall()),
        ),
      ],
    );
  }

  Widget _buildOngoingRow(
    BuildContext context,
    ActiveCallState state,
    Color fgColor,
  ) {
    final showKeypadButton = !state.isVideo && state.canShowKeypad;
    final muted = state.isMuted;
    final callerLabel = state.displayCallerName;
    final statusLabel = state.callKindLabel;

    return Row(
      children: [
        _buildInfoLead(
          tapKey: const Key('ongoing_call_banner_tap'),
          onTap: () => openInAppCallScreen(
            context: context,
            controller: _controller,
          ),
          state: state,
          title: callerLabel,
          statusText: statusLabel,
          duration: _controller.formattedDuration,
          muted: muted,
          fgColor: fgColor,
        ),
        const SizedBox(width: 6),
        FaceTimeDockButton(
          dense: true,
          engaged: muted,
          icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: muted ? 'Unmute mic' : 'Mute mic',
          onPressed: () => _controller.toggleMute(),
        ),
        if (showKeypadButton) ...[
          const SizedBox(width: 6),
          KeyedSubtree(
            key: _keypadButtonKey,
            child: FaceTimeDockButton(
              dense: true,
              engaged: _showKeypad,
              icon: Icons.dialpad_rounded,
              label: 'Keypad',
              onPressed: _toggleKeypad,
            ),
          ),
        ],
        if (_controller.canReturn) ...[
          const SizedBox(width: 6),
          FaceTimeDockButton(
            dense: true,
            icon: Icons.open_in_new_rounded,
            label: 'Return to call',
            onPressed: () => unawaited(_controller.returnToCall(context)),
          ),
        ],
        if (state.fromIphone && state.hasCallUuid) ...[
          const SizedBox(width: 6),
          FaceTimeDockButton(
            dense: true,
            icon: Icons.phone_iphone_rounded,
            label: 'Move to iPhone',
            onPressed: () => unawaited(_controller.transferBack()),
          ),
        ],
        const SizedBox(width: 6),
        FaceTimeEndCallPill(
          dense: true,
          onPressed: () => unawaited(_controller.endCall()),
        ),
      ],
    );
  }
}

class _DenseCircleAction extends StatelessWidget {
  const _DenseCircleAction({
    required this.icon,
    required this.semanticsLabel,
    required this.backgroundColor,
    required this.onPressed,
  });

  final IconData icon;
  final String semanticsLabel;
  final Color backgroundColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: semanticsLabel,
      child: Tooltip(
        message: semanticsLabel,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 48),
              child: Center(
                widthFactor: 1.0,
                heightFactor: 1.0,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 20, color: Colors.white),
                ),
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
  static const _letters = ['', 'ABC', 'DEF', 'GHI', 'JKL', 'MNO', 'PQRS', 'TUV', 'WXYZ', '', '+', ''];
  static const _keySize = FaceTimeDims.dialpadKeyHeight;
  static const _panelWidth = (_keySize * 3) + 16.0 + 24.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? FaceTimePalette.darkSurface : theme.colorScheme.surfaceContainerHigh;
    final fg = isDark ? FaceTimePalette.onCanvas : theme.colorScheme.onSurface;
    final subFg = isDark ? FaceTimePalette.secondaryText : theme.colorScheme.onSurfaceVariant;
    final border = theme.colorScheme.outlineVariant;
    final pressedFill = isDark ? FaceTimePalette.darkElevated : theme.colorScheme.surfaceContainerHighest;
    final panelRadius = BorderRadius.circular(FaceTimeDims.dockRadius);

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final screenHeight = constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        final top = (anchorRect?.bottom ?? 56.0) + 6.0;
        final targetCenterX = anchorRect?.center.dx ?? (screenWidth - _panelWidth / 2 - 12);
        final left = (targetCenterX - _panelWidth / 2)
            .clamp(12.0, math.max(12.0, screenWidth - _panelWidth - 12.0))
            .toDouble();
        final maxHeight = math.max(120.0, screenHeight - top - 12.0);

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
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Material(
                  color: bg,
                  elevation: 3,
                  shadowColor: theme.colorScheme.shadow.withValues(alpha: isDark ? 0.4 : 0.16),
                  shape: RoundedRectangleBorder(
                    borderRadius: panelRadius,
                    side: BorderSide(color: border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: _keySize * 3 + 16,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var row = 0; row < 4; row++) ...[
                            if (row > 0) const SizedBox(height: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (var col = 0; col < 3; col++) ...[
                                  if (col > 0) const SizedBox(width: 8),
                                  _OverlayKeypadButton(
                                    digit: _digits[row * 3 + col],
                                    letters: _letters[row * 3 + col],
                                    fg: fg,
                                    subFg: subFg,
                                    pressedFill: pressedFill,
                                    onTap: () => onDigit(_digits[row * 3 + col]),
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
          ],
        );
      },
    );
  }
}

class _OverlayKeypadButton extends StatelessWidget {
  const _OverlayKeypadButton({
    required this.digit,
    required this.letters,
    required this.fg,
    required this.subFg,
    required this.pressedFill,
    required this.onTap,
  });

  final String digit;
  final String letters;
  final Color fg;
  final Color subFg;
  final Color pressedFill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'DTMF $digit',
      child: SizedBox(
        width: FaceTimeDims.dialpadKeyHeight,
        height: FaceTimeDims.dialpadKeyHeight,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            highlightColor: pressedFill,
            splashColor: pressedFill,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    digit,
                    style: TextStyle(
                      fontFamily: kDefaultAppFontFamily,
                      color: fg,
                      fontSize: 32,
                      fontWeight: FontWeight.w400,
                      height: 1.0,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (letters.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      letters,
                      style: TextStyle(
                        fontFamily: kDefaultAppFontFamily,
                        color: subFg,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.8,
                        height: 1.0,
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
