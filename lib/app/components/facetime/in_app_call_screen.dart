import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Full-screen in-app FaceTime / iPhone Continuity call screen backed by
/// [ActiveCallController].
class InAppCallScreen extends StatefulWidget {
  const InAppCallScreen({
    super.key,
    this.controller,
    this.videoView,
    this.onMinimize,
    this.onToggleSpeaker,
    this.initialSpeakerOn = false,
  });

  final ActiveCallController? controller;
  final Widget? videoView;
  final VoidCallback? onMinimize;
  final Future<bool> Function(bool enabled)? onToggleSpeaker;
  final bool initialSpeakerOn;

  @override
  State<InAppCallScreen> createState() => _InAppCallScreenState();
}

class _InAppCallScreenState extends State<InAppCallScreen> {
  late ActiveCallPhase _lastPhase;
  late bool _speakerOn;
  bool _showKeypad = false;
  bool _popScheduled = false;
  Offset? _pipOffset;
  String _dtmfHistory = '';

  ActiveCallController get _controller => widget.controller ?? ActiveCallController.instance;

  @override
  void initState() {
    super.initState();
    _speakerOn = widget.initialSpeakerOn;
    _lastPhase = _controller.state.phase;
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.syncNativeVideoTextures());
  }

  @override
  void didUpdateWidget(covariant InAppCallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldCtrl = oldWidget.controller ?? ActiveCallController.instance;
    if (!identical(oldCtrl, _controller)) {
      oldCtrl.removeListener(_onControllerChanged);
      _lastPhase = _controller.state.phase;
      _controller.addListener(_onControllerChanged);
      unawaited(_controller.syncNativeVideoTextures());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final phase = _controller.state.phase;
    if (phase == ActiveCallPhase.idle && _lastPhase != ActiveCallPhase.idle && !_popScheduled) {
      _popScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route != null && route.isActive && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }
    _lastPhase = phase;
  }

  Future<void> _toggleSpeaker() async {
    final next = !_speakerOn;
    setState(() => _speakerOn = next);
    final handler = widget.onToggleSpeaker;
    if (handler == null) return;
    try {
      final applied = await handler(next);
      if (mounted && !applied) {
        setState(() => _speakerOn = !next);
      }
    } catch (_) {
      // Graceful no-op when speaker routing isn't supported on this platform.
    }
  }

  void _handleDtmfDigit(String digit) {
    unawaited(_controller.sendDtmf(digit));
    setState(() {
      final updated = '$_dtmfHistory$digit';
      _dtmfHistory = updated.length > 24 ? updated.substring(updated.length - 24) : updated;
    });
  }

  void _handleMinimize() {
    if (widget.onMinimize != null) {
      widget.onMinimize!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
      child: Material(
        color: FaceTimePalette.darkCanvas,
        child: DefaultTextStyle.merge(
          // Pin GoogleSans inside Material while preserving emoji fontFamilyFallback for contact names.
          style: const TextStyle(fontFamily: kDefaultAppFontFamily),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return Obx(() {
                final activeVideo = widget.videoView ?? _controller.remoteVideoWidget.value;
                return _buildBody(
                  context,
                  _controller.state,
                  activeVideo,
                  localVideo: _controller.localVideoWidget.value,
                  cameraEnabled: _controller.cameraEnabled.value,
                  canFlipCamera: _controller.canFlipCamera.value,
                  isFrontCamera: _controller.isFrontCamera.value,
                );
              });
            },
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ActiveCallState state,
    Widget? activeVideo, {
    required Widget? localVideo,
    required bool cameraEnabled,
    required bool canFlipCamera,
    required bool isFrontCamera,
  }) {
    final hasVideo = activeVideo != null;
    final showVideoControls = hasVideo || localVideo != null || (state.isVideo && !state.isTelephony);
    final showPip = !_showKeypad && (hasVideo || localVideo != null || (state.isVideo && !state.isTelephony && cameraEnabled));
    final hasPhoto = state.avatarBytes != null && state.avatarBytes!.isNotEmpty;
    final reducedMotion = facetimeReducedMotionOf(context);
    final displayCaller = state.callerName.isNotEmpty
        ? state.callerName
        : (state.isTelephony ? 'iPhone Call' : 'FaceTime Call');
    final secondaryAddress = state.callerAddress?.trim() ?? '';
    final showAddress = secondaryAddress.isNotEmpty && secondaryAddress != displayCaller;

    final String callTypeBadge = state.isTelephony
        ? 'iPhone Call'
        : (state.isVideo ? 'FaceTime Video' : 'FaceTime Audio');
    final IconData callTypeIcon = state.isTelephony
        ? Icons.phone_in_talk_rounded
        : (state.isVideo ? Icons.videocam_rounded : Icons.call_rounded);
    final Color callTypeAccent = state.isTelephony ? FaceTimePalette.green : FaceTimePalette.blueDark;

    final String statusText;
    final bool showDuration;
    switch (state.phase) {
      case ActiveCallPhase.ongoing:
        final deviceName = state.activeDeviceName;
        statusText = (state.isOnOtherDevice && deviceName != null && deviceName.isNotEmpty)
            ? 'On $deviceName'
            : 'Connected';
        showDuration = true;
        break;
      case ActiveCallPhase.connecting:
        statusText = state.statusSubtitle.isNotEmpty ? state.statusSubtitle : 'Connecting…';
        showDuration = false;
        break;
      case ActiveCallPhase.outgoing:
        statusText = state.statusSubtitle.isNotEmpty ? state.statusSubtitle : 'Calling…';
        showDuration = false;
        break;
      case ActiveCallPhase.incoming:
        statusText = 'Ringing…';
        showDuration = false;
        break;
      case ActiveCallPhase.idle:
        statusText = 'Call Ended';
        showDuration = false;
        break;
    }

    final surfaceColor = FaceTimePalette.darkSurface.withValues(alpha: hasVideo ? 0.88 : 1.0);
    const hairlineColor = FaceTimePalette.hairline;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasVideo) ...[
          Positioned.fill(child: activeVideo),
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      FaceTimePalette.overlay,
                      Colors.transparent,
                      Colors.transparent,
                      FaceTimePalette.overlay,
                    ],
                    stops: [0.0, 0.24, 0.62, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ] else if (hasPhoto) ...[
          Positioned.fill(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: Image.memory(
                state.avatarBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: FaceTimePalette.darkCanvas.withValues(alpha: 0.78),
              ),
            ),
          ),
        ],
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: FaceTimeDims.contactSideMargin, vertical: 16),
            child: Column(
              children: [
                // Top bar: Minimize, call-type badge, balanced spacer
                Row(
                  children: [
                    _TopIconButton(
                      key: const Key('in_app_call_minimize'),
                      icon: Icons.keyboard_arrow_down_rounded,
                      tooltip: 'Minimize',
                      semanticsLabel: 'Minimize call',
                      surfaceColor: surfaceColor,
                      borderColor: hairlineColor,
                      reducedMotion: reducedMotion,
                      onPressed: _handleMinimize,
                    ),
                    Expanded(
                      child: Center(
                        child: Container(
                          key: const Key('in_app_call_type_badge'),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: surfaceColor,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: hairlineColor),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(callTypeIcon, color: callTypeAccent, size: 14),
                              const SizedBox(width: 7),
                              Flexible(
                                child: Text(
                                  callTypeBadge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: FaceTimePalette.onCanvas,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (state.hasJoinLink)
                      _TopIconButton(
                        key: const Key('in_app_call_open_link'),
                        icon: Icons.open_in_new_rounded,
                        tooltip: 'Open FaceTime Link',
                        semanticsLabel: 'Open FaceTime Link',
                        surfaceColor: surfaceColor,
                        borderColor: hairlineColor,
                        reducedMotion: reducedMotion,
                        onPressed: () => unawaited(_controller.openFaceTimeLink(context: context)),
                      )
                    else
                      const SizedBox(width: FaceTimeDims.actionButtonSize),
                  ],
                ),

                if (hasVideo) ...[
                  const SizedBox(height: FaceTimeDims.contactTopMargin),
                  _CompactCallerHeader(
                    callerName: displayCaller,
                    avatarBytes: state.avatarBytes,
                    statusText: statusText,
                    durationText: showDuration ? _controller.formattedDuration : null,
                    isMuted: state.isMuted,
                  ),
                  if (_showKeypad)
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: _DtmfKeypadPanel(
                            history: _dtmfHistory,
                            reducedMotion: reducedMotion,
                            onDigit: _handleDtmfDigit,
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: _DraggableSelfPreview(
                        pipOffset: _pipOffset,
                        onOffsetChanged: (next) => setState(() => _pipOffset = next),
                        child: _SelfPreviewTile(
                          cameraEnabled: cameraEnabled,
                          isFrontCamera: isFrontCamera,
                          localVideo: localVideo,
                          callerName: displayCaller,
                        ),
                      ),
                    ),
                ] else ...[
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: _showKeypad
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _CompactCallerHeader(
                                        callerName: displayCaller,
                                        avatarBytes: state.avatarBytes,
                                        statusText: statusText,
                                        durationText: showDuration ? _controller.formattedDuration : null,
                                        isMuted: state.isMuted,
                                      ),
                                      const SizedBox(height: FaceTimeDims.contactTopMargin),
                                      _DtmfKeypadPanel(
                                        history: _dtmfHistory,
                                        reducedMotion: reducedMotion,
                                        onDigit: _handleDtmfDigit,
                                      ),
                                    ],
                                  )
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      FaceTimeAvatar(
                                        callerName: displayCaller,
                                        avatarBytes: state.avatarBytes,
                                        size: 112,
                                        borderColor: hairlineColor,
                                        borderWidth: 1,
                                      ),
                                      const SizedBox(height: FaceTimeDims.contactTopMargin),
                                      Text(
                                        displayCaller,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: FaceTimePalette.onCanvas,
                                          fontSize: 24,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: -0.3,
                                          height: 1.2,
                                        ),
                                      ),
                                      if (showAddress) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          secondaryAddress,
                                          textAlign: TextAlign.center,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: FaceTimePalette.secondaryText,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w400,
                                            letterSpacing: 0.1,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 8),
                                      _StatusAndTimerRow(
                                        statusText: statusText,
                                        durationText: showDuration ? _controller.formattedDuration : null,
                                        isMuted: state.isMuted,
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                        if (showPip)
                          _DraggableSelfPreview(
                            pipOffset: _pipOffset,
                            onOffsetChanged: (next) => setState(() => _pipOffset = next),
                            child: _SelfPreviewTile(
                              cameraEnabled: cameraEnabled,
                              isFrontCamera: isFrontCamera,
                              localVideo: localVideo,
                              callerName: displayCaller,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],

                // Bottom controls: 48dp actions (60dp video toggle in video mode) + 64dp End oval
                Padding(
                  padding: EdgeInsets.only(
                    bottom: hasVideo ? FaceTimeDims.videoEndCallBottomMargin : FaceTimeDims.endCallBottomMargin,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: FaceTimeDims.dialpadMaxWidth),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              flex: 4,
                              child: _CallControlButton(
                                icon: state.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                                label: state.isMuted ? 'Unmute' : 'Mute',
                                semanticsLabel: 'Mute mic',
                                isActive: state.isMuted,
                                idleColor: surfaceColor,
                                borderColor: hairlineColor,
                                reducedMotion: reducedMotion,
                                onPressed: _controller.toggleMute,
                              ),
                            ),
                            if (widget.onToggleSpeaker == null)
                              Expanded(
                                flex: 4,
                                child: Obx(() {
                                  final speakerOn = _controller.isSpeakerOn.value;
                                  return _CallControlButton(
                                    icon: speakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                                    label: 'Speaker',
                                    semanticsLabel: 'Speaker',
                                    isActive: speakerOn,
                                    idleColor: surfaceColor,
                                    borderColor: hairlineColor,
                                    reducedMotion: reducedMotion,
                                    onPressed: () => unawaited(_controller.toggleSpeaker()),
                                  );
                                }),
                              )
                            else
                              Expanded(
                                flex: 4,
                                child: _CallControlButton(
                                  icon: _speakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                                  label: 'Speaker',
                                  semanticsLabel: 'Speaker',
                                  isActive: _speakerOn,
                                  idleColor: surfaceColor,
                                  borderColor: hairlineColor,
                                  reducedMotion: reducedMotion,
                                  onPressed: _toggleSpeaker,
                                ),
                              ),
                            if (showVideoControls)
                              Expanded(
                                flex: 5,
                                child: _VideoToggleButton(
                                  isVideoOn: cameraEnabled,
                                  reducedMotion: reducedMotion,
                                  onPressed: () => unawaited(_controller.toggleCamera()),
                                ),
                              ),
                            if (showVideoControls && canFlipCamera && cameraEnabled)
                              Expanded(
                                flex: 4,
                                child: _CallControlButton(
                                  key: const Key('in_app_call_flip_camera'),
                                  icon: Icons.cameraswitch_rounded,
                                  label: 'Flip',
                                  semanticsLabel: 'Flip camera',
                                  idleColor: surfaceColor,
                                  borderColor: hairlineColor,
                                  reducedMotion: reducedMotion,
                                  onPressed: () => unawaited(_controller.flipCamera()),
                                ),
                              ),
                            Expanded(
                              flex: 4,
                              child: _CallControlButton(
                                icon: Icons.dialpad_rounded,
                                label: 'Keypad',
                                semanticsLabel: 'Keypad',
                                isActive: _showKeypad,
                                idleColor: surfaceColor,
                                borderColor: hairlineColor,
                                reducedMotion: reducedMotion,
                                onPressed: () => setState(() => _showKeypad = !_showKeypad),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _EndCallButton(
                          reducedMotion: reducedMotion,
                          onPressed: () => unawaited(_controller.endCall()),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TactilePress extends StatefulWidget {
  const _TactilePress({
    required this.onTap,
    required this.reducedMotion,
    required this.borderRadius,
    required this.child,
  });

  final VoidCallback onTap;
  final bool reducedMotion;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  State<_TactilePress> createState() => _TactilePressState();
}

class _TactilePressState extends State<_TactilePress> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scale = (!widget.reducedMotion && _pressed) ? 0.96 : 1.0;
    return AnimatedScale(
      scale: scale,
      duration: widget.reducedMotion ? Duration.zero : const Duration(milliseconds: 100),
      curve: Curves.easeOut,
      child: InkWell(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        borderRadius: widget.borderRadius,
        child: widget.child,
      ),
    );
  }
}

class _TopIconButton extends StatelessWidget {
  const _TopIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.semanticsLabel,
    required this.surfaceColor,
    required this.borderColor,
    required this.reducedMotion,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final String semanticsLabel;
  final Color surfaceColor;
  final Color borderColor;
  final bool reducedMotion;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: semanticsLabel,
      child: Tooltip(
        message: tooltip,
        child: _TactilePress(
          onTap: onPressed,
          reducedMotion: reducedMotion,
          borderRadius: BorderRadius.circular(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Center(
              widthFactor: 1.0,
              heightFactor: 1.0,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: surfaceColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: borderColor),
                ),
                child: Icon(icon, color: Colors.white, size: 22),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactCallerHeader extends StatelessWidget {
  const _CompactCallerHeader({
    required this.callerName,
    required this.avatarBytes,
    required this.statusText,
    required this.durationText,
    required this.isMuted,
  });

  final String callerName;
  final Uint8List? avatarBytes;
  final String statusText;
  final String? durationText;
  final bool isMuted;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        FaceTimeAvatar(
          callerName: callerName,
          avatarBytes: avatarBytes,
          size: 44,
          borderColor: Colors.white.withValues(alpha: 0.14),
          borderWidth: 1,
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                callerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: FaceTimePalette.onCanvas,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 2),
              _StatusAndTimerRow(
                statusText: statusText,
                durationText: durationText,
                isMuted: isMuted,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusAndTimerRow extends StatelessWidget {
  const _StatusAndTimerRow({
    required this.statusText,
    required this.durationText,
    required this.isMuted,
  });

  final String statusText;
  final String? durationText;
  final bool isMuted;

  @override
  Widget build(BuildContext context) {
    final text = durationText != null ? '$statusText · $durationText' : statusText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (durationText != null) ...[
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: FaceTimePalette.green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: durationText != null ? FaceTimePalette.onCanvas : FaceTimePalette.secondaryText,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (isMuted) ...[
          const SizedBox(width: 8),
          const Icon(Icons.mic_off_rounded, size: 15, color: FaceTimePalette.amber),
        ],
      ],
    );
  }
}

class _DtmfKeypadPanel extends StatelessWidget {
  const _DtmfKeypadPanel({
    required this.history,
    required this.reducedMotion,
    required this.onDigit,
  });

  final String history;
  final bool reducedMotion;
  final ValueChanged<String> onDigit;

  static const _digits = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
  static const _letters = ['', 'ABC', 'DEF', 'GHI', 'JKL', 'MNO', 'PQRS', 'TUV', 'WXYZ', '', '+', ''];

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('in_app_dtmf_keypad'),
      constraints: const BoxConstraints(maxWidth: FaceTimeDims.dialpadMaxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: FaceTimePalette.darkSurface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(FaceTimeDims.dtmfOptionRadius),
        border: Border.all(
          color: FaceTimePalette.hairline,
          width: FaceTimeDims.dtmfOptionStroke,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (history.isNotEmpty) ...[
            Text(
              'DTMF: $history',
              key: const Key('in_app_dtmf_history'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: FaceTimePalette.onCanvas,
                fontSize: FaceTimeDims.dialpadDigitsFieldSize,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.2,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 10),
          ],
          for (var row = 0; row < 4; row++) ...[
            if (row > 0) const SizedBox(height: 8),
            Row(
              children: [
                for (var col = 0; col < 3; col++) ...[
                  if (col > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _DtmfKeyButton(
                      digit: _digits[row * 3 + col],
                      letters: _letters[row * 3 + col],
                      reducedMotion: reducedMotion,
                      onTap: () => onDigit(_digits[row * 3 + col]),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DtmfKeyButton extends StatelessWidget {
  const _DtmfKeyButton({
    required this.digit,
    required this.letters,
    required this.reducedMotion,
    required this.onTap,
  });

  final String digit;
  final String letters;
  final bool reducedMotion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'DTMF $digit',
      child: _TactilePress(
        onTap: onTap,
        reducedMotion: reducedMotion,
        borderRadius: BorderRadius.circular(FaceTimeDims.dtmfOptionRadius),
        child: Container(
          height: FaceTimeDims.dialpadKeyHeight,
          decoration: BoxDecoration(
            color: FaceTimePalette.darkElevated,
            borderRadius: BorderRadius.circular(FaceTimeDims.dtmfOptionRadius),
            border: Border.all(
              color: FaceTimePalette.hairline,
              width: FaceTimeDims.dtmfOptionStroke,
            ),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                digit,
                style: const TextStyle(
                  color: FaceTimePalette.onCanvas,
                  fontSize: FaceTimeDims.dialpadDigitSize,
                  fontWeight: FontWeight.w400,
                  height: 1.0,
                ),
              ),
              if (letters.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  letters,
                  style: const TextStyle(
                    color: FaceTimePalette.secondaryText,
                    fontSize: FaceTimeDims.dialpadIncallLettersSize,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.0,
                    height: 1.0,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CallControlButton extends StatelessWidget {
  const _CallControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.reducedMotion,
    required this.onPressed,
    this.isActive = false,
    this.idleColor,
    this.borderColor,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final bool reducedMotion;
  final VoidCallback onPressed;
  final bool isActive;
  final Color? idleColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final bg = isActive ? FaceTimePalette.onCanvas : (idleColor ?? FaceTimePalette.darkSurface);
    final fg = isActive ? FaceTimePalette.darkCanvas : FaceTimePalette.onCanvas;
    final showBorder = !isActive && borderColor != null;

    return Semantics(
      button: true,
      excludeSemantics: true,
      toggled: isActive,
      label: semanticsLabel,
      child: _TactilePress(
        onTap: onPressed,
        reducedMotion: reducedMotion,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 2,
            vertical: FaceTimeDims.actionVerticalPad,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: FaceTimeDims.actionButtonSize,
              minHeight: FaceTimeDims.actionButtonSize,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  width: FaceTimeDims.actionButtonSize,
                  height: FaceTimeDims.actionButtonSize,
                  decoration: BoxDecoration(
                    color: bg,
                    shape: BoxShape.circle,
                    border: showBorder ? Border.all(color: borderColor!) : null,
                  ),
                  child: Icon(icon, color: fg, size: FaceTimeDims.actionIconSize),
                ),
                const SizedBox(height: FaceTimeDims.actionLabelGap),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: FaceTimePalette.onCanvas,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoToggleButton extends StatelessWidget {
  const _VideoToggleButton({
    required this.isVideoOn,
    required this.reducedMotion,
    required this.onPressed,
  });

  final bool isVideoOn;
  final bool reducedMotion;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bg = isVideoOn ? Colors.white : FaceTimePalette.videoToggleOffBg;
    final fg = isVideoOn ? FaceTimePalette.darkCanvas : Colors.white;

    return Semantics(
      button: true,
      excludeSemantics: true,
      toggled: isVideoOn,
      label: 'Video',
      child: _TactilePress(
        onTap: onPressed,
        reducedMotion: reducedMotion,
        borderRadius: BorderRadius.circular(FaceTimeDims.videoToggleSize / 2),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: FaceTimeDims.actionVerticalPad),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                width: FaceTimeDims.videoToggleSize,
                height: FaceTimeDims.videoToggleSize,
                padding: const EdgeInsets.all(FaceTimeDims.videoTogglePad),
                decoration: BoxDecoration(
                  color: bg,
                  shape: BoxShape.circle,
                  border: isVideoOn
                      ? null
                      : Border.all(color: FaceTimePalette.videoToggleOffStroke, width: 1),
                ),
                child: Icon(
                  isVideoOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                  color: fg,
                  size: FaceTimeDims.actionIconSize,
                ),
              ),
              const SizedBox(height: FaceTimeDims.actionLabelGap),
              const Text(
                'Video',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: FaceTimePalette.onCanvas,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EndCallButton extends StatelessWidget {
  const _EndCallButton({
    required this.reducedMotion,
    required this.onPressed,
  });

  final bool reducedMotion;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: 'End call',
      child: _TactilePress(
        onTap: onPressed,
        reducedMotion: reducedMotion,
        borderRadius: BorderRadius.circular(FaceTimeDims.endCallSize / 2),
        child: Container(
          width: FaceTimeDims.endCallSize,
          height: FaceTimeDims.endCallSize,
          decoration: const BoxDecoration(
            color: FaceTimePalette.red,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.call_end_rounded,
            color: Colors.white,
            size: FaceTimeDims.endCallIconSize,
          ),
        ),
      ),
    );
  }
}

class _DraggableSelfPreview extends StatelessWidget {
  const _DraggableSelfPreview({
    required this.pipOffset,
    required this.onOffsetChanged,
    required this.child,
  });

  final Offset? pipOffset;
  final ValueChanged<Offset> onOffsetChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = math.min(FaceTimeDims.previewSize, constraints.maxWidth);
        final tileHeight = math.min(FaceTimeDims.previewSize, constraints.maxHeight);
        final maxLeft = math.max(0.0, constraints.maxWidth - tileWidth);
        final maxTop = math.max(0.0, constraints.maxHeight - tileHeight);
        final defaultTop = math.max(0.0, maxTop - FaceTimeDims.previewBottomMargin);
        final left = (pipOffset?.dx ?? maxLeft).clamp(0.0, maxLeft).toDouble();
        final top = (pipOffset?.dy ?? defaultTop).clamp(0.0, maxTop).toDouble();

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: left,
              top: top,
              width: tileWidth,
              height: tileHeight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) {
                  onOffsetChanged(
                    Offset(
                      (left + details.delta.dx).clamp(0.0, maxLeft).toDouble(),
                      (top + details.delta.dy).clamp(0.0, maxTop).toDouble(),
                    ),
                  );
                },
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SelfPreviewTile extends StatelessWidget {
  const _SelfPreviewTile({
    required this.cameraEnabled,
    required this.isFrontCamera,
    required this.localVideo,
    required this.callerName,
  });

  final bool cameraEnabled;
  final bool isFrontCamera;
  final Widget? localVideo;
  final String callerName;

  @override
  Widget build(BuildContext context) {
    final showLiveVideo = cameraEnabled && localVideo != null;
    final radius = BorderRadius.circular(FaceTimeDims.previewRadius);

    return Semantics(
      label: showLiveVideo ? 'Self preview' : 'Camera off',
      child: Container(
        key: const Key('in_app_call_self_preview'),
        width: FaceTimeDims.previewSize,
        height: FaceTimeDims.previewSize,
        decoration: BoxDecoration(
          color: FaceTimePalette.darkElevated,
          borderRadius: radius,
          border: Border.all(color: FaceTimePalette.hairline, width: 1),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: showLiveVideo
              ? SizedBox.expand(
                  child: IgnorePointer(
                    child: Transform.flip(
                      // Web `<video>` already mirrors via CSS scaleX(-1) in web_webrtc_client_web.dart.
                      flipX: !kIsWeb && isFrontCamera,
                      child: localVideo,
                    ),
                  ),
                )
              : const Center(
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.videocam_off_rounded,
                          color: FaceTimePalette.secondaryText,
                          size: 24,
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Camera off',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: FaceTimePalette.secondaryText,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
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
