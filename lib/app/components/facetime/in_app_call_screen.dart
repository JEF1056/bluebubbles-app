import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/call_controls.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/components/facetime/facetime_transfer_icon.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/services/facetime/facetime_media_models.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class _ToggleMuteIntent extends Intent {
  const _ToggleMuteIntent();
}

class _ToggleCameraIntent extends Intent {
  const _ToggleCameraIntent();
}

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

class _InAppCallScreenState extends State<InAppCallScreen> with SingleTickerProviderStateMixin {
  late ActiveCallPhase _lastPhase;
  late bool _speakerOn;
  bool _showKeypad = false;
  bool _popScheduled = false;
  bool _chromeVisible = true;
  bool _isSheetOpen = false;
  Timer? _autoHideTimer;

  // PiP corner index: 0=topLeft, 1=topRight, 2=bottomLeft, 3=bottomRight
  int _pipCorner = 3;
  bool _pipIsDragging = false;
  Offset? _pipDragTopLeft;
  bool _pipExpanded = false;
  bool _pipCollapsed = false;

  String _dtmfHistory = '';
  late final AnimationController _ringPulseController;
  final List<({dynamic rx, StreamSubscription<dynamic> sub})> _rxSubs =
      <({dynamic rx, StreamSubscription<dynamic> sub})>[];

  ActiveCallController get _controller => widget.controller ?? ActiveCallController.instance;

  @override
  void initState() {
    super.initState();
    _speakerOn = widget.initialSpeakerOn;
    _lastPhase = _controller.state.phase;
    _ringPulseController = AnimationController(
      vsync: this,
      duration: FaceTimeMotion.ring,
    );
    _controller.addListener(_onControllerChanged);
    _subscribeRx();
    unawaited(_controller.syncNativeVideoTextures());
    unawaited(_controller.refreshAudioDevices());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resetAutoHideTimer();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRingPulse();
  }

  @override
  void didUpdateWidget(covariant InAppCallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldCtrl = oldWidget.controller ?? ActiveCallController.instance;
    if (!identical(oldCtrl, _controller)) {
      oldCtrl.removeListener(_onControllerChanged);
      _unsubscribeRx();
      _lastPhase = _controller.state.phase;
      _controller.addListener(_onControllerChanged);
      _subscribeRx();
      unawaited(_controller.syncNativeVideoTextures());
      unawaited(_controller.refreshAudioDevices());
      _syncRingPulse();
      _resetAutoHideTimer();
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _ringPulseController.dispose();
    _unsubscribeRx();
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _subscribeRx() {
    void listenRx(dynamic rx) {
      final sub = (rx.stream as Stream<dynamic>).listen((_) {
        if (mounted) setState(() {});
      });
      _rxSubs.add((rx: rx, sub: sub));
    }

    listenRx(_controller.remoteVideoWidget);
    listenRx(_controller.localVideoWidget);
    listenRx(_controller.cameraEnabled);
    listenRx(_controller.canFlipCamera);
    listenRx(_controller.isFrontCamera);
    listenRx(_controller.isSpeakerOn);
    listenRx(_controller.isReconnecting);
    listenRx(_controller.canSelectAudioOutput);
    listenRx(_controller.activeAudioOutputId);
    listenRx(_controller.videoEffect);
    listenRx(_controller.videoDenoiseEnabled);
  }

  void _unsubscribeRx() {
    for (final entry in _rxSubs) {
      try {
        if (!(entry.rx.subject.isClosed as bool)) {
          unawaited(entry.sub.cancel().catchError((_) {}));
        }
      } catch (_) {}
    }
    _rxSubs.clear();
  }

  void _syncRingPulse() {
    final state = _controller.state;
    final shouldPulse = (state.isOutgoingPhase || state.isConnecting) &&
        mounted &&
        !facetimeReducedMotionOf(context);
    if (shouldPulse && !_ringPulseController.isAnimating) {
      _ringPulseController.repeat();
    } else if (!shouldPulse && _ringPulseController.isAnimating) {
      _ringPulseController.stop();
      _ringPulseController.reset();
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final phase = _controller.state.phase;
    if (phase == ActiveCallPhase.idle && _lastPhase != ActiveCallPhase.idle && !_popScheduled) {
      _popScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        final nav = Navigator.of(context);
        if (route != null && route.isActive && nav.canPop()) {
          nav.popUntil((r) => r == route);
          if (nav.canPop()) {
            nav.pop();
          }
        }
      });
    }
    final phaseChanged = phase != _lastPhase;
    _lastPhase = phase;
    _syncRingPulse();
    if (phaseChanged) {
      _resetAutoHideTimer();
    }
  }

  bool _canAutoHide(BuildContext context) {
    final activeVideo = widget.videoView ?? _controller.remoteVideoWidget.value;
    final state = _controller.state;
    return state.isOngoing &&
        activeVideo != null &&
        !_showKeypad &&
        !_controller.isReconnecting.value &&
        !_isSheetOpen &&
        !MediaQuery.accessibleNavigationOf(context);
  }

  void _resetAutoHideTimer() {
    _autoHideTimer?.cancel();
    if (!mounted) return;
    if (!_canAutoHide(context)) {
      if (!_chromeVisible) {
        setState(() => _chromeVisible = true);
      }
      return;
    }
    _autoHideTimer = Timer(FaceTimeMotion.autoHide, () {
      if (!mounted) return;
      if (_canAutoHide(context) && _chromeVisible) {
        setState(() => _chromeVisible = false);
      }
    });
  }

  void _onStageTap() {
    if (!mounted) return;
    if (!_canAutoHide(context)) {
      if (!_chromeVisible) setState(() => _chromeVisible = true);
      return;
    }
    setState(() => _chromeVisible = !_chromeVisible);
    if (_chromeVisible) {
      _resetAutoHideTimer();
    } else {
      _autoHideTimer?.cancel();
    }
  }

  void _onControlInteraction() {
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
    _resetAutoHideTimer();
  }

  Future<void> _toggleSpeaker() async {
    _onControlInteraction();
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
    _onControlInteraction();
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

  Future<void> _openAudioSheet() async {
    _onControlInteraction();
    setState(() => _isSheetOpen = true);
    _autoHideTimer?.cancel();
    unawaited(_controller.refreshAudioDevices());
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: FaceTimePalette.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(FaceTimeDims.sheetTopRadius)),
      ),
      isScrollControlled: true,
      builder: (sheetCtx) => _AudioRouteSheet(controller: _controller),
    );
    if (mounted) {
      setState(() => _isSheetOpen = false);
      _resetAutoHideTimer();
    }
  }

  Future<void> _openMoreTray() async {
    _onControlInteraction();
    setState(() => _isSheetOpen = true);
    _autoHideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: FaceTimePalette.m3SurfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(FaceTimeDims.sheetTopRadius)),
      ),
      isScrollControlled: true,
      builder: (sheetCtx) => _MoreTraySheet(
        controller: _controller,
        canShowKeypad: _controller.state.canShowKeypad,
        onOpenAudioRoute: () => unawaited(_openAudioSheet()),
        onOpenVideoEffects: () => unawaited(_openVideoEffectsSheet()),
        onOpenKeypad: () {
          setState(() => _showKeypad = true);
          _onControlInteraction();
        },
      ),
    );
    if (mounted) {
      setState(() => _isSheetOpen = false);
      _resetAutoHideTimer();
    }
  }

  IconData _liveAudioRouteIcon(bool speakerOn) {
    final activeOutId = _controller.activeAudioOutputId.value;
    FaceTimeAudioDevice? active;
    for (final d in _controller.audioOutputs) {
      if (d.id == activeOutId || (activeOutId == null && d.isActive)) {
        active = d;
        break;
      }
    }
    if (active != null) {
      switch (active.kind) {
        case FaceTimeAudioDeviceKind.bluetooth:
          return Icons.bluetooth_audio_rounded;
        case FaceTimeAudioDeviceKind.wired:
          return Icons.headphones_rounded;
        case FaceTimeAudioDeviceKind.usb:
          return Icons.usb_rounded;
        case FaceTimeAudioDeviceKind.speaker:
          return Icons.volume_up_rounded;
        case FaceTimeAudioDeviceKind.earpiece:
          return Icons.phone_in_talk_rounded;
        case FaceTimeAudioDeviceKind.builtinMic:
        case FaceTimeAudioDeviceKind.unknown:
          break;
      }
    }
    return speakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded;
  }

  Future<void> _openVideoEffectsSheet() async {
    _onControlInteraction();
    setState(() => _isSheetOpen = true);
    _autoHideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: FaceTimePalette.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(FaceTimeDims.sheetTopRadius)),
      ),
      isScrollControlled: true,
      builder: (sheetCtx) => _VideoEffectsSheet(controller: _controller),
    );
    if (mounted) {
      setState(() => _isSheetOpen = false);
      _resetAutoHideTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.keyD, control: true): const _ToggleMuteIntent(),
      const SingleActivator(LogicalKeyboardKey.keyD, meta: true): const _ToggleMuteIntent(),
      const SingleActivator(LogicalKeyboardKey.keyE, control: true): const _ToggleCameraIntent(),
      const SingleActivator(LogicalKeyboardKey.keyE, meta: true): const _ToggleCameraIntent(),
    };
    final actions = <Type, Action<Intent>>{
      _ToggleMuteIntent: CallbackAction<_ToggleMuteIntent>(
        onInvoke: (_) {
          _onControlInteraction();
          _controller.toggleMute();
          return null;
        },
      ),
      _ToggleCameraIntent: CallbackAction<_ToggleCameraIntent>(
        onInvoke: (_) {
          _onControlInteraction();
          unawaited(_controller.toggleCamera());
          return null;
        },
      ),
    };

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: actions,
        child: Focus(
          autofocus: true,
          child: AnnotatedRegion<SystemUiOverlayStyle>(
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
                    final activeVideo = widget.videoView ?? _controller.remoteVideoWidget.value;
                    return _buildBody(
                      context,
                      _controller.state,
                      activeVideo,
                      localVideo: _controller.localVideoWidget.value,
                      cameraEnabled: _controller.cameraEnabled.value,
                      canFlipCamera: _controller.canFlipCamera.value,
                      isFrontCamera: _controller.isFrontCamera.value,
                      isReconnecting: _controller.isReconnecting.value,
                      speakerOn: _controller.isSpeakerOn.value,
                      canSelectAudioOutput: _controller.canSelectAudioOutput.value,
                      activeAudioOutputId: _controller.activeAudioOutputId.value,
                      effectsOn: _controller.videoEffect.value != FaceTimeVideoEffectType.none ||
                          _controller.videoDenoiseEnabled.value,
                    );
                  },
                ),
              ),
            ),
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
    required bool isReconnecting,
    required bool speakerOn,
    required bool canSelectAudioOutput,
    required String? activeAudioOutputId,
    required bool effectsOn,
  }) {
    final size = MediaQuery.sizeOf(context);
    final isExpanded = size.shortestSide >= FaceTimeDims.expandedBreak;
    final hasVideo = activeVideo != null && state.isOngoing;
    final showVideoControls = hasVideo || localVideo != null || (state.isVideo && !state.isTelephony);
    final isPreConnectVideo = (state.isOutgoingPhase || state.isConnecting) && state.isVideo && !state.isTelephony && !hasVideo;
    final showPip = !_showKeypad &&
        !isPreConnectVideo &&
        state.isOngoing &&
        (hasVideo || localVideo != null || (state.isVideo && !state.isTelephony && cameraEnabled));

    final reducedMotion = facetimeReducedMotionOf(context);
    final displayCaller = state.displayCallerName;
    final secondaryAddress = state.distinctCallerHandle ?? '';
    final showAddress = secondaryAddress.isNotEmpty;

    final String statusText;
    final bool showDuration;
    if (isReconnecting) {
      statusText = 'Reconnecting…';
      showDuration = false;
    } else {
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
    }

    final headerSubtitle = showDuration ? '$statusText · ${_controller.formattedDuration}' : statusText;
    final chromeVisible = _chromeVisible || !_canAutoHide(context);

    final dock = _buildControlDock(
      context,
      state: state,
      width: size.width,
      hasVideo: hasVideo,
      showVideoControls: showVideoControls,
      cameraEnabled: cameraEnabled,
      canFlipCamera: canFlipCamera,
      speakerOn: speakerOn,
      canSelectAudioOutput: canSelectAudioOutput,
      activeAudioOutputId: activeAudioOutputId,
      effectsOn: effectsOn,
    );

    if (isExpanded) {
      return _buildExpandedLayout(
        context,
        state: state,
        hasVideo: hasVideo,
        showVideoControls: showVideoControls,
        activeVideo: activeVideo,
        localVideo: localVideo,
        cameraEnabled: cameraEnabled,
        canFlipCamera: canFlipCamera,
        isFrontCamera: isFrontCamera,
        isReconnecting: isReconnecting,
        isPreConnectVideo: isPreConnectVideo,
        showPip: showPip,
        speakerOn: speakerOn,
        canSelectAudioOutput: canSelectAudioOutput,
        effectsOn: effectsOn,
        displayCaller: displayCaller,
        secondaryAddress: secondaryAddress,
        showAddress: showAddress,
        statusText: statusText,
        showDuration: showDuration,
        headerSubtitle: headerSubtitle,
        reducedMotion: reducedMotion,
        dock: dock,
      );
    }

    return _buildCompactMediumLayout(
      context,
      state: state,
      hasVideo: hasVideo,
      showVideoControls: showVideoControls,
      activeVideo: activeVideo,
      localVideo: localVideo,
      cameraEnabled: cameraEnabled,
      canFlipCamera: canFlipCamera,
      isFrontCamera: isFrontCamera,
      isReconnecting: isReconnecting,
      isPreConnectVideo: isPreConnectVideo,
      showPip: showPip,
      speakerOn: speakerOn,
      canSelectAudioOutput: canSelectAudioOutput,
      effectsOn: effectsOn,
      displayCaller: displayCaller,
      secondaryAddress: secondaryAddress,
      showAddress: showAddress,
      statusText: statusText,
      showDuration: showDuration,
      headerSubtitle: headerSubtitle,
      chromeVisible: chromeVisible,
      reducedMotion: reducedMotion,
      dock: dock,
    );
  }

  Widget _buildControlDock(
    BuildContext context, {
    required ActiveCallState state,
    required double width,
    required bool hasVideo,
    required bool showVideoControls,
    required bool cameraEnabled,
    required bool canFlipCamera,
    required bool speakerOn,
    required bool canSelectAudioOutput,
    required String? activeAudioOutputId,
    required bool effectsOn,
  }) {
    final canPickAudioSheet = (canSelectAudioOutput && _controller.audioOutputs.length > 1) ||
        _controller.audioInputs.isNotEmpty;

    final List<Widget> controls;
    if (showVideoControls || hasVideo) {
      controls = <Widget>[
        FaceTimeDockButton(
          icon: cameraEnabled ? Icons.videocam_rounded : Icons.videocam_off_rounded,
          label: cameraEnabled ? 'Turn off camera' : 'Turn on camera',
          engaged: !cameraEnabled,
          tone: cameraEnabled ? FaceTimeDockTone.neutral : FaceTimeDockTone.mutedAlert,
          onPressed: () {
            _onControlInteraction();
            unawaited(_controller.toggleCamera());
          },
        ),
        FaceTimeDockButton(
          icon: state.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: state.isMuted ? 'Unmute' : 'Mute',
          engaged: state.isMuted,
          tone: state.isMuted ? FaceTimeDockTone.mutedAlert : FaceTimeDockTone.neutral,
          onPressed: () {
            _onControlInteraction();
            _controller.toggleMute();
          },
        ),
        FaceTimeDockButton(
          key: const Key('in_app_call_flip_camera'),
          icon: Icons.cameraswitch_rounded,
          label: 'Flip camera',
          enabled: cameraEnabled && canFlipCamera,
          tone: FaceTimeDockTone.neutral,
          onPressed: () {
            _onControlInteraction();
            unawaited(_controller.flipCamera());
          },
        ),
        FaceTimeDockButton(
          key: const Key('in_app_call_more_tray'),
          icon: Icons.more_vert_rounded,
          label: 'More',
          tone: FaceTimeDockTone.neutral,
          onPressed: () => unawaited(_openMoreTray()),
        ),
      ];
    } else {
      controls = <Widget>[
        FaceTimeDockButton(
          icon: state.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: state.isMuted ? 'Unmute' : 'Mute',
          engaged: state.isMuted,
          tone: state.isMuted ? FaceTimeDockTone.activeHighContrast : FaceTimeDockTone.neutral,
          onPressed: () {
            _onControlInteraction();
            _controller.toggleMute();
          },
        ),
        if (widget.onToggleSpeaker != null)
          FaceTimeDockButton(
            icon: _speakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded,
            label: 'Speaker',
            engaged: _speakerOn,
            tone: _speakerOn ? FaceTimeDockTone.activeHighContrast : FaceTimeDockTone.neutral,
            onPressed: _toggleSpeaker,
          )
        else
          GestureDetector(
            onLongPress: _openAudioSheet,
            child: FaceTimeDockButton(
              icon: _liveAudioRouteIcon(speakerOn),
              label: canPickAudioSheet ? 'Audio & microphone' : 'Speaker',
              engaged: !canPickAudioSheet && speakerOn,
              showExpandCaret: canPickAudioSheet,
              tone: (!canPickAudioSheet && speakerOn)
                  ? FaceTimeDockTone.activeHighContrast
                  : FaceTimeDockTone.neutral,
              onPressed: () {
                if (canPickAudioSheet) {
                  unawaited(_openAudioSheet());
                } else {
                  _onControlInteraction();
                  unawaited(_controller.toggleSpeaker());
                }
              },
            ),
          ),
        if (state.canShowKeypad && (state.isTelephony || width >= FaceTimeDims.compactBreak))
          FaceTimeDockButton(
            icon: Icons.dialpad_rounded,
            label: 'Keypad',
            engaged: _showKeypad,
            tone: _showKeypad ? FaceTimeDockTone.activeHighContrast : FaceTimeDockTone.neutral,
            onPressed: () {
              _onControlInteraction();
              setState(() => _showKeypad = !_showKeypad);
            },
          ),
        FaceTimeDockButton(
          key: const Key('in_app_call_more_tray'),
          icon: Icons.more_vert_rounded,
          label: 'More',
          tone: FaceTimeDockTone.neutral,
          onPressed: () => unawaited(_openMoreTray()),
        ),
      ];
    }

    final dock = FaceTimeControlDock(
      translucent: hasVideo,
      controls: controls,
      endCall: FaceTimeEndCallPill(
        wide: !hasVideo && !showVideoControls,
        onPressed: () {
          _onControlInteraction();
          unawaited(_controller.endCall());
        },
      ),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: math.max(0.0, width - FaceTimeDims.dockMargin * 2)),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: dock,
      ),
    );
  }

  Widget _buildStageBackdrop(
    BuildContext context, {
    required ActiveCallState state,
    required bool hasVideo,
    required Widget? activeVideo,
    required Widget? localVideo,
    required bool cameraEnabled,
    required bool isFrontCamera,
    required bool isReconnecting,
    required bool isPreConnectVideo,
    required bool isExpanded,
    required String displayCaller,
    required String secondaryAddress,
    required bool showAddress,
    required String statusText,
    required bool showDuration,
    required bool reducedMotion,
  }) {
    final kindLabel = state.callKindLabel;
    Uint8List? stageAvatar = state.avatarBytes;
    if ((stageAvatar == null || stageAvatar.isEmpty) && state.participantDetails.isNotEmpty) {
      for (final p in state.participantDetails) {
        if (p.avatarBytes != null && p.avatarBytes!.isNotEmpty) {
          stageAvatar = p.avatarBytes;
          break;
        }
      }
    }
    final hasPhoto = stageAvatar != null && stageAvatar.isNotEmpty;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasVideo)
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: isReconnecting ? 0.40 : 1.0,
              duration: FaceTimeMotion.of(context, FaceTimeMotion.short),
              curve: FaceTimeMotion.emphasized,
              child: activeVideo,
            ),
          )
        else if (isPreConnectVideo) ...[
          if (cameraEnabled && localVideo != null)
            Positioned.fill(
              child: Transform.flip(
                flipX: !kIsWeb && isFrontCamera,
                child: localVideo,
              ),
            ),
          const Positioned.fill(
            child: ColoredBox(color: FaceTimePalette.scrim),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.participantDetails.length > 1)
                    FaceTimeGroupedAvatar(
                      participants: state.participantDetails,
                      size: 96,
                    )
                  else
                    FaceTimeAvatar(
                      callerName: displayCaller,
                      avatarBytes: stageAvatar,
                      handle: (state.callerAddress?.isNotEmpty ?? false) ? Handle(address: state.callerAddress!) : null,
                      size: 96,
                    ),
                  const SizedBox(height: 16),
                  Text(
                    displayCaller,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: FaceTimePalette.onCanvas,
                      fontSize: 28,
                      height: 36 / 28,
                      fontWeight: FontWeight.w400,
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
                      ),
                    ),
                  ],
                  if (state.participantDetails.length > 1) ...[
                    const SizedBox(height: 10),
                    FaceTimeParticipantChips(participants: state.participantDetails),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    kindLabel,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kDefaultAppFontFamily,
                      color: FaceTimePalette.secondaryText,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  FaceTimeStatusText(statusText, muted: state.isMuted),
                ],
              ),
            ),
          ),
        ] else ...[
          if (hasPhoto) ...[
            Positioned.fill(
              child: RepaintBoundary(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                  child: Image.memory(
                    stageAvatar,
                    fit: BoxFit.cover,
                    cacheWidth: 96,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: ColoredBox(
                color: FaceTimePalette.darkCanvas.withValues(alpha: 0.82),
              ),
            ),
          ],
          if (!_showKeypad || isExpanded)
            Builder(
              builder: (context) {
                final viewSize = MediaQuery.sizeOf(context);
                final isCompactViewport = viewSize.height < 640 || viewSize.width < 360;
                final avatarSize = isCompactViewport ? 88.0 : 120.0;
                final showRingPulse = (state.isOutgoingPhase || state.isConnecting) && !reducedMotion;
                return Align(
                  alignment: const Alignment(0, -0.24),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (state.participantDetails.length > 1)
                          FaceTimeGroupedAvatar(
                            participants: state.participantDetails,
                            size: avatarSize,
                          )
                        else
                          _AvatarWithOptionalPulse(
                            callerName: displayCaller,
                            avatarBytes: stageAvatar,
                            handle: (state.callerAddress?.isNotEmpty ?? false) ? Handle(address: state.callerAddress!) : null,
                            size: avatarSize,
                            showPulse: showRingPulse,
                            pulseAnimation: _ringPulseController,
                          ),
                        const SizedBox(height: 20),
                        Text(
                          displayCaller,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: FaceTimePalette.m3OnSurface,
                            fontSize: 28,
                            height: 36 / 28,
                            fontWeight: FontWeight.w400,
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
                              color: FaceTimePalette.m3OnSurfaceVariant,
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                        if (state.participantDetails.length > 1) ...[
                          const SizedBox(height: 10),
                          FaceTimeParticipantChips(participants: state.participantDetails),
                        ],
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: FaceTimePalette.m3SurfaceContainerHigh,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            kindLabel,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: kDefaultAppFontFamily,
                              color: FaceTimePalette.m3OnSurfaceVariant,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        FaceTimeStatusText(
                          statusText,
                          duration: showDuration ? _controller.formattedDuration : null,
                          muted: state.isMuted,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ],
    );
  }

  Widget _buildCompactMediumLayout(
    BuildContext context, {
    required ActiveCallState state,
    required bool hasVideo,
    required bool showVideoControls,
    required Widget? activeVideo,
    required Widget? localVideo,
    required bool cameraEnabled,
    required bool canFlipCamera,
    required bool isFrontCamera,
    required bool isReconnecting,
    required bool isPreConnectVideo,
    required bool showPip,
    required bool speakerOn,
    required bool canSelectAudioOutput,
    required bool effectsOn,
    required String displayCaller,
    required String secondaryAddress,
    required bool showAddress,
    required String statusText,
    required bool showDuration,
    required String headerSubtitle,
    required bool chromeVisible,
    required bool reducedMotion,
    required Widget dock,
  }) {
    final padding = MediaQuery.paddingOf(context);
    final size = MediaQuery.sizeOf(context);
    final isVideoSurface = hasVideo || showVideoControls;
    final headerVisible = chromeVisible || !hasVideo;
    final dockVisible = chromeVisible || !hasVideo;
    final motionDuration = FaceTimeMotion.of(context, FaceTimeMotion.chromeFade);
    final canPickAudioSheet = (canSelectAudioOutput && _controller.audioOutputs.length > 1) ||
        _controller.audioInputs.isNotEmpty;

    Uint8List? stageAvatar = state.avatarBytes;
    if ((stageAvatar == null || stageAvatar.isEmpty) && state.participantDetails.isNotEmpty) {
      for (final p in state.participantDetails) {
        if (p.avatarBytes != null && p.avatarBytes!.isNotEmpty) {
          stageAvatar = p.avatarBytes;
          break;
        }
      }
    }

    final double pipWidth;
    final Size pipSize;
    if (_pipCollapsed) {
      pipWidth = 48.0;
      pipSize = const Size(48.0, 48.0);
    } else if (_pipExpanded) {
      pipWidth = (size.shortestSide * 0.44).clamp(168.0, 196.0).toDouble();
      pipSize = Size(pipWidth, pipWidth * 4 / 3);
    } else {
      pipWidth = (size.shortestSide * 0.28).clamp(112.0, 132.0).toDouble();
      pipSize = Size(pipWidth, pipWidth * 4 / 3);
    }
    final pipAvoid = EdgeInsets.only(
      top: padding.top + (headerVisible ? FaceTimeDims.headerHeight + 16 : 0),
      bottom: padding.bottom + (dockVisible ? FaceTimeDims.dockButtonHeight + FaceTimeDims.dockPadV * 2 + FaceTimeDims.dockMargin + 8 : 0),
      left: padding.left,
      right: padding.right,
    );

    if (!isVideoSurface) {
      final isCompactSheet = size.height < 640 || size.width < 360;
      final sheetBottomClearance = padding.bottom + (isCompactSheet ? 164.0 : 204.0);
      final phoneItems = <FaceTimePhoneControlItem>[
        FaceTimePhoneControlItem(
          icon: state.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: state.isMuted ? 'Unmute' : 'Mute',
          selected: state.isMuted,
          onPressed: () {
            _onControlInteraction();
            _controller.toggleMute();
          },
        ),
        if (state.canShowKeypad && (state.isTelephony || size.width >= FaceTimeDims.compactBreak))
          FaceTimePhoneControlItem(
            icon: Icons.dialpad_rounded,
            label: 'Keypad',
            selected: _showKeypad,
            onPressed: () {
              _onControlInteraction();
              setState(() => _showKeypad = !_showKeypad);
            },
          ),
        FaceTimePhoneControlItem(
          icon: widget.onToggleSpeaker != null
              ? (_speakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded)
              : _liveAudioRouteIcon(speakerOn),
          label: canPickAudioSheet ? 'Audio' : 'Speaker',
          semanticsLabel: canPickAudioSheet ? 'Audio & microphone' : 'Speaker',
          selected: canPickAudioSheet
              ? false
              : (widget.onToggleSpeaker != null ? _speakerOn : speakerOn),
          showExpandCaret: canPickAudioSheet,
          onPressed: () {
            if (widget.onToggleSpeaker != null) {
              unawaited(_toggleSpeaker());
            } else if (canPickAudioSheet) {
              unawaited(_openAudioSheet());
            } else {
              _onControlInteraction();
              unawaited(_controller.toggleSpeaker());
            }
          },
        ),
        if (!state.isTelephony)
          FaceTimePhoneControlItem(
            icon: Icons.videocam_rounded,
            label: 'Video',
            selected: cameraEnabled,
            onPressed: () {
              _onControlInteraction();
              unawaited(_controller.toggleCamera());
            },
          ),
        if (state.isTelephony || (!state.isTelephony && size.width < FaceTimeDims.compactBreak))
          FaceTimePhoneControlItem(
            key: const Key('in_app_call_more_tray'),
            icon: Icons.more_vert_rounded,
            label: 'More',
            onPressed: () => unawaited(_openMoreTray()),
          ),
      ];

      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            bottom: sheetBottomClearance * 0.65,
            child: _buildStageBackdrop(
              context,
              state: state,
              hasVideo: false,
              activeVideo: activeVideo,
              localVideo: localVideo,
              cameraEnabled: cameraEnabled,
              isFrontCamera: isFrontCamera,
              isReconnecting: isReconnecting,
              isPreConnectVideo: false,
              isExpanded: false,
              displayCaller: displayCaller,
              secondaryAddress: secondaryAddress,
              showAddress: showAddress,
              statusText: statusText,
              showDuration: showDuration,
              reducedMotion: reducedMotion,
            ),
          ),
          // Top bar
          Positioned(
            top: padding.top + 8,
            left: padding.left + 12,
            right: padding.right + 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _CircleHeaderButton(
                      key: const Key('in_app_call_minimize'),
                      icon: Icons.keyboard_arrow_down_rounded,
                      tooltip: 'Minimize call',
                      backgroundColor: FaceTimePalette.m3SurfaceContainerHigh,
                      onPressed: _handleMinimize,
                    ),
                    if (state.hasJoinLink)
                      _CircleHeaderButton(
                        key: const Key('in_app_call_open_link'),
                        icon: Icons.open_in_new_rounded,
                        tooltip: 'Open FaceTime Link',
                        backgroundColor: FaceTimePalette.m3SurfaceContainerHigh,
                        onPressed: () {
                          _onControlInteraction();
                          unawaited(_controller.openFaceTimeLink(context: context));
                        },
                      ),
                  ],
                ),
                if (isReconnecting) ...[
                  const SizedBox(height: 8),
                  const _ReconnectingChip(),
                ],
              ],
            ),
          ),
          // Inline DTMF Keypad panel
          if (_showKeypad)
            Positioned(
              left: padding.left + 16,
              right: padding.right + 16,
              bottom: sheetBottomClearance + 12,
              top: padding.top + FaceTimeDims.headerHeight + 20,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SingleChildScrollView(
                  child: _DtmfKeypadPanel(
                    history: _dtmfHistory,
                    reducedMotion: reducedMotion,
                    onDigit: _handleDtmfDigit,
                  ),
                ),
              ),
            ),
          // Bottom Google Phone M3E control sheet
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: FaceTimePhoneControlSheet(
                items: phoneItems,
                onEndCall: () {
                  _onControlInteraction();
                  unawaited(_controller.endCall());
                },
              ),
            ),
          ),
        ],
      );
    }

    return MouseRegion(
      onHover: kIsWeb ? (_) => _resetAutoHideTimer() : null,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _onStageTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildStageBackdrop(
              context,
              state: state,
              hasVideo: hasVideo,
              activeVideo: activeVideo,
              localVideo: localVideo,
              cameraEnabled: cameraEnabled,
              isFrontCamera: isFrontCamera,
              isReconnecting: isReconnecting,
              isPreConnectVideo: isPreConnectVideo,
              isExpanded: false,
              displayCaller: displayCaller,
              secondaryAddress: secondaryAddress,
              showAddress: showAddress,
              statusText: statusText,
              showDuration: showDuration,
              reducedMotion: reducedMotion,
            ),
            // Top & bottom scrims (auto-hide with chrome)
            if (hasVideo) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: padding.top + 112,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: headerVisible ? 1.0 : 0.0,
                    duration: motionDuration,
                    curve: FaceTimeMotion.emphasized,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            FaceTimePalette.m3Surface.withValues(alpha: 0.72),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: padding.bottom + 140,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: dockVisible ? 1.0 : 0.0,
                    duration: motionDuration,
                    curve: FaceTimeMotion.emphasized,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            FaceTimePalette.m3Scrim,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (showPip)
              _SnappingPipOverlay(
                area: size,
                tileSize: pipSize,
                avoid: pipAvoid,
                cornerIndex: _pipCorner,
                isDragging: _pipIsDragging,
                dragTopLeft: _pipDragTopLeft,
                duration: motionDuration,
                onDragStart: (startTopLeft) {
                  setState(() {
                    _pipIsDragging = true;
                    _pipDragTopLeft = startTopLeft;
                  });
                },
                onDragUpdate: (delta) {
                  setState(() {
                    final base = _pipDragTopLeft ?? Offset.zero;
                    _pipDragTopLeft = Offset(
                      (base.dx + delta.dx).clamp(0.0, math.max(0.0, size.width - pipSize.width)).toDouble(),
                      (base.dy + delta.dy).clamp(0.0, math.max(0.0, size.height - pipSize.height)).toDouble(),
                    );
                  });
                },
                onDragEnd: () {
                  final finalTopLeft = _pipDragTopLeft ?? Offset.zero;
                  final center = finalTopLeft + Offset(pipSize.width / 2, pipSize.height / 2);
                  final snapped = faceTimeSnapCorner(center, size, pipSize, pipAvoid);
                  final corner = _cornerIndexForOffset(snapped, size, pipSize, pipAvoid);
                  setState(() {
                    _pipIsDragging = false;
                    _pipDragTopLeft = null;
                    _pipCorner = corner;
                  });
                },
                child: _SelfPreviewTile(
                  width: pipSize.width,
                  height: pipSize.height,
                  cameraEnabled: cameraEnabled,
                  isFrontCamera: isFrontCamera,
                  localVideo: localVideo,
                  collapsed: _pipCollapsed,
                  canFlipCamera: canFlipCamera,
                  effectsOn: effectsOn,
                  onToggleExpand: () {
                    _onControlInteraction();
                    setState(() {
                      if (_pipCollapsed) {
                        _pipCollapsed = false;
                      } else {
                        _pipExpanded = !_pipExpanded;
                      }
                    });
                  },
                  onToggleCollapse: () {
                    _onControlInteraction();
                    setState(() => _pipCollapsed = !_pipCollapsed);
                  },
                  onFlipCamera: () {
                    _onControlInteraction();
                    unawaited(_controller.flipCamera());
                  },
                  onOpenEffects: localVideo != null ? () => unawaited(_openVideoEffectsSheet()) : null,
                ),
              ),
            // Meet Top Action Bar + Reconnecting chip
            Positioned(
              top: padding.top + 8,
              left: padding.left + 12,
              right: padding.right + 16,
              child: IgnorePointer(
                ignoring: !headerVisible,
                child: AnimatedSlide(
                  offset: headerVisible ? Offset.zero : const Offset(0, -0.35),
                  duration: motionDuration,
                  curve: FaceTimeMotion.emphasized,
                  child: AnimatedOpacity(
                    opacity: headerVisible ? 1.0 : 0.0,
                    duration: motionDuration,
                    curve: FaceTimeMotion.emphasized,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            if (hasVideo)
                              Flexible(
                                child: FaceTimeHeaderPill(
                                  leading: _CircleHeaderButton(
                                    key: const Key('in_app_call_minimize'),
                                    icon: Icons.keyboard_arrow_down_rounded,
                                    tooltip: 'Minimize call',
                                    onPressed: _handleMinimize,
                                  ),
                                  avatar: state.participantDetails.length > 1
                                      ? FaceTimeGroupedAvatar(
                                          participants: state.participantDetails,
                                          size: 28,
                                        )
                                      : FaceTimeAvatar(
                                          callerName: displayCaller,
                                          avatarBytes: stageAvatar,
                                          handle: (state.callerAddress?.isNotEmpty ?? false)
                                              ? Handle(address: state.callerAddress!)
                                              : null,
                                          size: 28,
                                        ),
                                  title: displayCaller,
                                  kindLabel: state.callKindLabel,
                                  handle: showAddress ? secondaryAddress : null,
                                  subtitle: headerSubtitle,
                                ),
                              )
                            else
                              _CircleHeaderButton(
                                key: const Key('in_app_call_minimize'),
                                icon: Icons.keyboard_arrow_down_rounded,
                                tooltip: 'Minimize call',
                                backgroundColor: FaceTimePalette.m3SurfaceContainerHigh,
                                onPressed: _handleMinimize,
                              ),
                            const SizedBox(width: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _CircleHeaderButton(
                                  icon: widget.onToggleSpeaker != null
                                      ? (_speakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded)
                                      : _liveAudioRouteIcon(speakerOn),
                                  tooltip: canPickAudioSheet ? 'Audio & microphone' : 'Speaker',
                                  backgroundColor: FaceTimePalette.m3SurfaceContainerHigh,
                                  onPressed: () {
                                    if (widget.onToggleSpeaker != null) {
                                      unawaited(_toggleSpeaker());
                                    } else if (canPickAudioSheet) {
                                      unawaited(_openAudioSheet());
                                    } else {
                                      _onControlInteraction();
                                      unawaited(_controller.toggleSpeaker());
                                    }
                                  },
                                ),
                                if (localVideo == null || !showPip) ...[
                                  const SizedBox(width: 8),
                                  _CircleHeaderButton(
                                    key: const Key('in_app_call_video_effects'),
                                    icon: Icons.auto_awesome_rounded,
                                    tooltip: 'Video effects',
                                    backgroundColor: effectsOn
                                        ? FaceTimePalette.m3Primary
                                        : FaceTimePalette.m3SurfaceContainerHigh,
                                    iconColor: effectsOn
                                        ? FaceTimePalette.m3OnPrimary
                                        : FaceTimePalette.m3OnSurface,
                                    onPressed: () => unawaited(_openVideoEffectsSheet()),
                                  ),
                                ],
                                if (state.hasJoinLink) ...[
                                  const SizedBox(width: 8),
                                  _CircleHeaderButton(
                                    key: const Key('in_app_call_open_link'),
                                    icon: Icons.open_in_new_rounded,
                                    tooltip: 'Open FaceTime Link',
                                    backgroundColor: FaceTimePalette.m3SurfaceContainerHigh,
                                    onPressed: () {
                                      _onControlInteraction();
                                      unawaited(_controller.openFaceTimeLink(context: context));
                                    },
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                        if (isReconnecting) ...[
                          const SizedBox(height: 8),
                          const _ReconnectingChip(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Keypad panel (compact/medium)
            if (_showKeypad)
              Positioned(
                left: padding.left + 16,
                right: padding.right + 16,
                bottom: padding.bottom + FaceTimeDims.dockButtonHeight + FaceTimeDims.dockPadV * 2 + FaceTimeDims.dockMargin + 12,
                top: padding.top + FaceTimeDims.headerHeight + 24,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SingleChildScrollView(
                    child: _DtmfKeypadPanel(
                      history: _dtmfHistory,
                      reducedMotion: reducedMotion,
                      onDigit: _handleDtmfDigit,
                    ),
                  ),
                ),
              ),
            // Control dock
            Positioned(
              left: padding.left + FaceTimeDims.dockMargin,
              right: padding.right + FaceTimeDims.dockMargin,
              bottom: padding.bottom + FaceTimeDims.dockMargin,
              child: IgnorePointer(
                ignoring: !dockVisible,
                child: AnimatedSlide(
                  offset: dockVisible ? Offset.zero : const Offset(0, 0.35),
                  duration: motionDuration,
                  curve: FaceTimeMotion.emphasized,
                  child: AnimatedOpacity(
                    opacity: dockVisible ? 1.0 : 0.0,
                    duration: motionDuration,
                    curve: FaceTimeMotion.emphasized,
                    child: Center(child: dock),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpandedLayout(
    BuildContext context, {
    required ActiveCallState state,
    required bool hasVideo,
    required bool showVideoControls,
    required Widget? activeVideo,
    required Widget? localVideo,
    required bool cameraEnabled,
    required bool canFlipCamera,
    required bool isFrontCamera,
    required bool isReconnecting,
    required bool isPreConnectVideo,
    required bool showPip,
    required bool speakerOn,
    required bool canSelectAudioOutput,
    required bool effectsOn,
    required String displayCaller,
    required String secondaryAddress,
    required bool showAddress,
    required String statusText,
    required bool showDuration,
    required String headerSubtitle,
    required bool reducedMotion,
    required Widget dock,
  }) {
    final motionDuration = FaceTimeMotion.of(context, FaceTimeMotion.medium);
    final Uint8List? stageAvatar = state.avatarBytes ??
        (state.participantDetails.isNotEmpty ? state.participantDetails.first.avatarBytes : null);
    final canPickAudioSheet = (canSelectAudioOutput && _controller.audioOutputs.length > 1) ||
        _controller.audioInputs.isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Plain 64h header row: name + timer on left, link + minimize on right
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  if (state.participantDetails.length > 1)
                    FaceTimeGroupedAvatar(
                      participants: state.participantDetails,
                      size: 36,
                    )
                  else
                    FaceTimeAvatar(
                      callerName: displayCaller,
                      avatarBytes: stageAvatar,
                      handle: (state.callerAddress?.isNotEmpty ?? false)
                          ? Handle(address: state.callerAddress!)
                          : null,
                      size: 36,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayCaller,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: FaceTimePalette.onCanvas,
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                [
                                  state.callKindLabel,
                                  if (showAddress) secondaryAddress,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: kDefaultAppFontFamily,
                                  color: FaceTimePalette.secondaryText,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const Text(
                              ' · ',
                              style: TextStyle(
                                fontFamily: kDefaultAppFontFamily,
                                color: FaceTimePalette.secondaryText,
                                fontSize: 12,
                              ),
                            ),
                            FaceTimeStatusText(
                              statusText,
                              duration: showDuration ? _controller.formattedDuration : null,
                              muted: state.isMuted,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (isReconnecting) ...[
                    const _ReconnectingChip(),
                    const SizedBox(width: 12),
                  ],
                  _CircleHeaderButton(
                    icon: widget.onToggleSpeaker != null
                        ? (_speakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded)
                        : _liveAudioRouteIcon(speakerOn),
                    tooltip: canPickAudioSheet ? 'Audio & microphone' : 'Speaker',
                    backgroundColor: FaceTimePalette.m3SurfaceContainerHigh,
                    onPressed: () {
                      if (widget.onToggleSpeaker != null) {
                        unawaited(_toggleSpeaker());
                      } else if (canPickAudioSheet) {
                        unawaited(_openAudioSheet());
                      } else {
                        _onControlInteraction();
                        unawaited(_controller.toggleSpeaker());
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  if (showVideoControls && (localVideo == null || !showPip)) ...[
                    _CircleHeaderButton(
                      key: const Key('in_app_call_video_effects'),
                      icon: Icons.auto_awesome_rounded,
                      tooltip: 'Video effects',
                      backgroundColor: effectsOn
                          ? FaceTimePalette.m3Primary
                          : FaceTimePalette.m3SurfaceContainerHigh,
                      iconColor: effectsOn
                          ? FaceTimePalette.m3OnPrimary
                          : FaceTimePalette.m3OnSurface,
                      onPressed: () => unawaited(_openVideoEffectsSheet()),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (state.hasJoinLink) ...[
                    _CircleHeaderButton(
                      key: const Key('in_app_call_open_link'),
                      icon: Icons.open_in_new_rounded,
                      tooltip: 'Open FaceTime Link',
                      backgroundColor: FaceTimePalette.darkSurface,
                      onPressed: () => unawaited(_controller.openFaceTimeLink(context: context)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  _CircleHeaderButton(
                    key: const Key('in_app_call_minimize'),
                    icon: Icons.keyboard_arrow_down_rounded,
                    tooltip: 'Minimize call',
                    backgroundColor: FaceTimePalette.darkSurface,
                    onPressed: _handleMinimize,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Centered 16:9 stage + optional 360-wide keypad side panel
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: _controller.remoteAspectRatio,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(FaceTimeDims.dockRadius),
                          child: Container(
                            color: FaceTimePalette.darkSurface,
                            child: LayoutBuilder(
                              builder: (context, stageConstraints) {
                                final stageSize = stageConstraints.biggest;
                                final double pipWidth;
                                final Size pipSize;
                                if (_pipCollapsed) {
                                  pipWidth = 48.0;
                                  pipSize = const Size(48.0, 48.0);
                                } else if (_pipExpanded) {
                                  pipWidth = (stageSize.shortestSide * 0.36)
                                      .clamp(168.0, 196.0)
                                      .toDouble();
                                  pipSize = Size(pipWidth, pipWidth * 4 / 3);
                                } else {
                                  pipWidth = (stageSize.shortestSide * 0.24)
                                      .clamp(112.0, FaceTimeDims.pipWebMax)
                                      .toDouble();
                                  pipSize = Size(pipWidth, pipWidth * 4 / 3);
                                }
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _buildStageBackdrop(
                                      context,
                                      state: state,
                                      hasVideo: hasVideo,
                                      activeVideo: activeVideo,
                                      localVideo: localVideo,
                                      cameraEnabled: cameraEnabled,
                                      isFrontCamera: isFrontCamera,
                                      isReconnecting: isReconnecting,
                                      isPreConnectVideo: isPreConnectVideo,
                                      isExpanded: true,
                                      displayCaller: displayCaller,
                                      secondaryAddress: secondaryAddress,
                                      showAddress: showAddress,
                                      statusText: statusText,
                                      showDuration: showDuration,
                                      reducedMotion: reducedMotion,
                                    ),
                                    if (showPip)
                                      _SnappingPipOverlay(
                                        area: stageSize,
                                        tileSize: pipSize,
                                        avoid: EdgeInsets.zero,
                                        cornerIndex: _pipCorner,
                                        isDragging: _pipIsDragging,
                                        dragTopLeft: _pipDragTopLeft,
                                        duration: motionDuration,
                                        onDragStart: (startTopLeft) {
                                          setState(() {
                                            _pipIsDragging = true;
                                            _pipDragTopLeft = startTopLeft;
                                          });
                                        },
                                        onDragUpdate: (delta) {
                                          setState(() {
                                            final base = _pipDragTopLeft ?? Offset.zero;
                                            _pipDragTopLeft = Offset(
                                              (base.dx + delta.dx)
                                                  .clamp(0.0, math.max(0.0, stageSize.width - pipSize.width))
                                                  .toDouble(),
                                              (base.dy + delta.dy)
                                                  .clamp(0.0, math.max(0.0, stageSize.height - pipSize.height))
                                                  .toDouble(),
                                            );
                                          });
                                        },
                                        onDragEnd: () {
                                          final finalTopLeft = _pipDragTopLeft ?? Offset.zero;
                                          final center = finalTopLeft + Offset(pipSize.width / 2, pipSize.height / 2);
                                          final snapped = faceTimeSnapCorner(center, stageSize, pipSize, EdgeInsets.zero);
                                          final corner = _cornerIndexForOffset(snapped, stageSize, pipSize, EdgeInsets.zero);
                                          setState(() {
                                            _pipIsDragging = false;
                                            _pipDragTopLeft = null;
                                            _pipCorner = corner;
                                          });
                                        },
                                        child: _SelfPreviewTile(
                                          width: pipSize.width,
                                          height: pipSize.height,
                                          cameraEnabled: cameraEnabled,
                                          isFrontCamera: isFrontCamera,
                                          localVideo: localVideo,
                                          collapsed: _pipCollapsed,
                                          canFlipCamera: canFlipCamera,
                                          effectsOn: effectsOn,
                                          onToggleExpand: () {
                                            _onControlInteraction();
                                            setState(() {
                                              if (_pipCollapsed) {
                                                _pipCollapsed = false;
                                              } else {
                                                _pipExpanded = !_pipExpanded;
                                              }
                                            });
                                          },
                                          onToggleCollapse: () {
                                            _onControlInteraction();
                                            setState(() => _pipCollapsed = !_pipCollapsed);
                                          },
                                          onFlipCamera: () {
                                            _onControlInteraction();
                                            unawaited(_controller.flipCamera());
                                          },
                                          onOpenEffects: localVideo != null ? () => unawaited(_openVideoEffectsSheet()) : null,
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_showKeypad) ...[
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 360,
                      child: Center(
                        child: SingleChildScrollView(
                          child: _DtmfKeypadPanel(
                            history: _dtmfHistory,
                            reducedMotion: reducedMotion,
                            onDigit: _handleDtmfDigit,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Dock sits below the stage on expanded layout
            Center(child: dock),
          ],
        ),
      ),
    );
  }

  int _cornerIndexForOffset(Offset snapped, Size area, Size tile, EdgeInsets avoid) {
    final inset = avoid + const EdgeInsets.all(FaceTimeDims.pipInset);
    final midX = (inset.left + (area.width - inset.right - tile.width)) / 2;
    final midY = (inset.top + (area.height - inset.bottom - tile.height)) / 2;
    final isRight = snapped.dx >= midX;
    final isBottom = snapped.dy >= midY;
    return (isBottom ? 2 : 0) + (isRight ? 1 : 0);
  }
}

class _CircleHeaderButton extends StatelessWidget {
  const _CircleHeaderButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.backgroundColor,
    this.iconColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? backgroundColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Material(
          color: backgroundColor ?? Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(icon, color: iconColor ?? FaceTimePalette.m3OnSurface, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReconnectingChip extends StatelessWidget {
  const _ReconnectingChip();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FaceTimePalette.darkSurface,
      borderRadius: BorderRadius.circular(FaceTimeDims.dockRadius),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: FaceTimePalette.blueDark,
              ),
            ),
            SizedBox(width: 8),
            Text(
              'Reconnecting…',
              style: TextStyle(
                color: FaceTimePalette.onCanvas,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarWithOptionalPulse extends StatelessWidget {
  const _AvatarWithOptionalPulse({
    required this.callerName,
    required this.avatarBytes,
    this.handle,
    required this.size,
    required this.showPulse,
    required this.pulseAnimation,
  });

  final String callerName;
  final Uint8List? avatarBytes;
  final Handle? handle;
  final double size;
  final bool showPulse;
  final Animation<double> pulseAnimation;

  @override
  Widget build(BuildContext context) {
    final avatar = FaceTimeAvatar(
      callerName: callerName,
      avatarBytes: avatarBytes,
      handle: handle,
      size: size,
    );
    if (!showPulse) return avatar;

    return SizedBox(
      width: size * 1.7,
      height: size * 1.7,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: pulseAnimation,
            builder: (context, _) {
              final t = FaceTimeMotion.emphasized.transform(pulseAnimation.value);
              final scale = 1.0 + 0.7 * t;
              final alpha = 0.24 * (1.0 - t);
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: alpha),
                      width: 2,
                    ),
                  ),
                ),
              );
            },
          ),
          avatar,
        ],
      ),
    );
  }
}

class _SnappingPipOverlay extends StatelessWidget {
  const _SnappingPipOverlay({
    required this.area,
    required this.tileSize,
    required this.avoid,
    required this.cornerIndex,
    required this.isDragging,
    required this.dragTopLeft,
    required this.duration,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.child,
  });

  final Size area;
  final Size tileSize;
  final EdgeInsets avoid;
  final int cornerIndex;
  final bool isDragging;
  final Offset? dragTopLeft;
  final Duration duration;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final Widget child;

  Offset _cornerTarget() {
    final inset = avoid + const EdgeInsets.all(FaceTimeDims.pipInset);
    final isRight = (cornerIndex & 1) != 0;
    final isBottom = (cornerIndex & 2) != 0;
    final probeCenter = Offset(
      isRight ? area.width - inset.right : inset.left,
      isBottom ? area.height - inset.bottom : inset.top,
    );
    return faceTimeSnapCorner(probeCenter, area, tileSize, avoid);
  }

  @override
  Widget build(BuildContext context) {
    final snapped = _cornerTarget();
    final current = isDragging && dragTopLeft != null ? dragTopLeft! : snapped;
    final maxLeft = math.max(0.0, area.width - tileSize.width);
    final maxTop = math.max(0.0, area.height - tileSize.height);

    return AnimatedPositioned(
      left: current.dx.clamp(0.0, maxLeft).toDouble(),
      top: current.dy.clamp(0.0, maxTop).toDouble(),
      width: tileSize.width,
      height: tileSize.height,
      duration: isDragging ? Duration.zero : duration,
      curve: FaceTimeMotion.emphasized,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onDragStart(current),
        onPanUpdate: (details) => onDragUpdate(details.delta),
        onPanEnd: (_) => onDragEnd(),
        child: child,
      ),
    );
  }
}

class _SelfPreviewTile extends StatelessWidget {
  const _SelfPreviewTile({
    required this.width,
    required this.height,
    required this.cameraEnabled,
    required this.isFrontCamera,
    required this.localVideo,
    this.collapsed = false,
    this.canFlipCamera = false,
    this.effectsOn = false,
    this.onToggleExpand,
    this.onToggleCollapse,
    this.onFlipCamera,
    this.onOpenEffects,
  });

  final double width;
  final double height;
  final bool cameraEnabled;
  final bool isFrontCamera;
  final Widget? localVideo;
  final bool collapsed;
  final bool canFlipCamera;
  final bool effectsOn;
  final VoidCallback? onToggleExpand;
  final VoidCallback? onToggleCollapse;
  final VoidCallback? onFlipCamera;
  final VoidCallback? onOpenEffects;

  @override
  Widget build(BuildContext context) {
    final showLiveVideo = cameraEnabled && localVideo != null;
    final radius = BorderRadius.circular(collapsed ? 24.0 : FaceTimeDims.pipCornerRadius);

    if (collapsed) {
      return Semantics(
        container: true,
        button: true,
        label: 'Expand self preview',
        child: GestureDetector(
          key: const Key('in_app_call_self_preview'),
          onTap: onToggleCollapse ?? onToggleExpand,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: FaceTimePalette.m3SurfaceContainerHigh,
              borderRadius: radius,
              border: Border.all(color: FaceTimePalette.m3SurfaceVariant, width: 1),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.picture_in_picture_alt_rounded,
              color: FaceTimePalette.m3OnSurface,
              size: 20,
            ),
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: showLiveVideo ? 'Self preview' : 'Camera off',
      child: GestureDetector(
        onDoubleTap: onToggleExpand,
        child: Container(
          key: const Key('in_app_call_self_preview'),
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: FaceTimePalette.m3SurfaceContainerHigh,
            borderRadius: radius,
            border: Border.all(color: FaceTimePalette.m3SurfaceVariant, width: 1),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (showLiveVideo)
                  IgnorePointer(
                    child: Transform.flip(
                      // Web `<video>` already mirrors via CSS scaleX(-1) in web_webrtc_client_web.dart.
                      flipX: !kIsWeb && isFrontCamera,
                      child: localVideo,
                    ),
                  )
                else
                  const Center(
                    child: Icon(
                      Icons.videocam_off_rounded,
                      color: FaceTimePalette.m3OnSurfaceVariant,
                      size: 20,
                    ),
                  ),
                if (onToggleCollapse != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _PipOverlayActionButton(
                      icon: Icons.close_fullscreen_rounded,
                      tooltip: 'Collapse self preview',
                      onPressed: onToggleCollapse!,
                    ),
                  ),
                if (showLiveVideo && (canFlipCamera || onOpenEffects != null))
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 6,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (canFlipCamera && onFlipCamera != null)
                            _PipOverlayActionButton(
                              icon: Icons.cameraswitch_rounded,
                              tooltip: 'Flip camera',
                              onPressed: onFlipCamera!,
                            ),
                          if (canFlipCamera && onFlipCamera != null && onOpenEffects != null)
                            const SizedBox(width: 8),
                          if (onOpenEffects != null)
                            _PipOverlayActionButton(
                              key: const Key('in_app_call_video_effects'),
                              icon: Icons.auto_awesome_rounded,
                              tooltip: 'Video effects',
                              active: effectsOn,
                              onPressed: onOpenEffects!,
                            ),
                        ],
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

class _PipOverlayActionButton extends StatelessWidget {
  const _PipOverlayActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Material(
        color: active
            ? FaceTimePalette.m3Primary
            : FaceTimePalette.m3Surface.withValues(alpha: 0.72),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: FaceTimeDims.pipActionButtonSize,
            height: FaceTimeDims.pipActionButtonSize,
            child: Icon(
              icon,
              size: FaceTimeDims.pipActionIconSize,
              color: active ? FaceTimePalette.m3OnPrimary : FaceTimePalette.m3OnSurface,
            ),
          ),
        ),
      ),
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
        borderRadius: BorderRadius.circular(FaceTimeDims.dockRadius),
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

class _DtmfKeyButton extends StatefulWidget {
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
  State<_DtmfKeyButton> createState() => _DtmfKeyButtonState();
}

class _DtmfKeyButtonState extends State<_DtmfKeyButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'DTMF ${widget.digit}',
      child: Material(
        color: _pressed ? FaceTimePalette.darkElevated : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged: (v) {
            if (_pressed != v && mounted) setState(() => _pressed = v);
          },
          customBorder: const CircleBorder(),
          splashColor: FaceTimePalette.darkElevated,
          child: SizedBox(
            height: FaceTimeDims.dialpadKeyHeight,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.digit,
                    style: const TextStyle(
                      color: FaceTimePalette.onCanvas,
                      fontSize: 32,
                      fontWeight: FontWeight.w400,
                      height: 1.0,
                    ),
                  ),
                  if (widget.letters.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.letters,
                      style: const TextStyle(
                        color: FaceTimePalette.secondaryText,
                        fontSize: 10,
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
        ),
      ),
    );
  }
}

class _AudioRouteSheet extends StatelessWidget {
  const _AudioRouteSheet({required this.controller});

  final ActiveCallController controller;

  IconData _iconForDevice(FaceTimeAudioDevice device) {
    switch (device.kind) {
      case FaceTimeAudioDeviceKind.speaker:
        return Icons.volume_up_rounded;
      case FaceTimeAudioDeviceKind.bluetooth:
        return Icons.bluetooth_audio_rounded;
      case FaceTimeAudioDeviceKind.wired:
        return Icons.headphones_rounded;
      case FaceTimeAudioDeviceKind.usb:
        return Icons.usb_rounded;
      case FaceTimeAudioDeviceKind.earpiece:
        return Icons.phone_in_talk_rounded;
      case FaceTimeAudioDeviceKind.builtinMic:
      case FaceTimeAudioDeviceKind.unknown:
        return device.isInput ? Icons.mic_rounded : Icons.speaker_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
        final outputs = controller.audioOutputs.toList(growable: false);
        final inputs = controller.audioInputs.toList(growable: false);
        final activeOutId = controller.activeAudioOutputId.value;
        final activeInId = controller.activeAudioInputId.value;
        final voiceIsolation = controller.voiceIsolationEnabled.value;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: FaceTimePalette.secondaryText.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Audio & microphone',
                style: TextStyle(
                  color: FaceTimePalette.onCanvas,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),
              if (controller.wearWatchConnected) ...[
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) {
                    final onWatch = controller.audioOnWatch.value;
                    return Container(
                      decoration: BoxDecoration(
                        color: FaceTimePalette.darkElevated,
                        borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
                        border: Border.all(
                          color: onWatch
                              ? FaceTimePalette.blueDark.withValues(alpha: 0.7)
                              : Colors.white.withValues(alpha: 0.08),
                          width: 1,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: const ValueKey('audio-sheet-transfer-watch'),
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(
                              onWatch
                                  ? controller.transferCallToPhone()
                                  : controller.transferCallToWatch(),
                            );
                          },
                          borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 56),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Row(
                                children: [
                                  if (onWatch)
                                    const PhoneTransferIcon(
                                      size: 22,
                                      color: FaceTimePalette.blueDark,
                                    )
                                  else
                                    const WatchTransferIcon(
                                      size: 22,
                                      color: FaceTimePalette.blueDark,
                                    ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          onWatch ? 'Audio on Pixel Watch' : 'Transfer to Watch',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: FaceTimePalette.onCanvas,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          onWatch
                                              ? 'Tap to return audio to phone'
                                              : 'Route call audio & controls to Pixel Watch',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: FaceTimePalette.secondaryText,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
              ],
              Material(
                color: FaceTimePalette.darkElevated,
                borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
                child: SwitchListTile(
                  key: const Key('in_app_call_voice_isolation_toggle'),
                  value: voiceIsolation,
                  onChanged: (v) => unawaited(controller.setVoiceIsolation(v)),
                  secondary: const Icon(Icons.graphic_eq_rounded, color: FaceTimePalette.onCanvas),
                  title: const Text(
                    'Voice Isolation',
                    style: TextStyle(color: FaceTimePalette.onCanvas, fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  subtitle: const Text(
                    'Reduces background noise',
                    style: TextStyle(color: FaceTimePalette.secondaryText, fontSize: 13),
                  ),
                  activeThumbColor: FaceTimePalette.darkCanvas,
                  activeTrackColor: FaceTimePalette.blueDark,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
                  ),
                ),
              ),
              if (outputs.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  'Speaker & output',
                  style: TextStyle(
                    color: FaceTimePalette.secondaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                for (final device in outputs) ...[
                  _DeviceOptionTile(
                    icon: _iconForDevice(device),
                    label: device.label,
                    selected: device.id == activeOutId || (activeOutId == null && device.isActive),
                    onTap: () => unawaited(controller.selectAudioOutput(device.id)),
                  ),
                  const SizedBox(height: 6),
                ],
              ],
              if (inputs.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Microphone',
                  style: TextStyle(
                    color: FaceTimePalette.secondaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                for (final device in inputs) ...[
                  _DeviceOptionTile(
                    icon: _iconForDevice(device),
                    label: device.label,
                    selected: device.id == activeInId || (activeInId == null && device.isActive),
                    onTap: () => unawaited(controller.selectAudioInput(device.id)),
                  ),
                  const SizedBox(height: 6),
                ],
              ],
            ],
          ),
        );
        },
      ),
    );
  }
}

class _DeviceOptionTile extends StatelessWidget {
  const _DeviceOptionTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? FaceTimePalette.darkElevated : Colors.transparent,
      borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected ? FaceTimePalette.blueDark : FaceTimePalette.onCanvas,
                  size: 22,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: FaceTimePalette.onCanvas,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (selected)
                  const Icon(Icons.check_rounded, color: FaceTimePalette.blueDark, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoEffectsSheet extends StatelessWidget {
  const _VideoEffectsSheet({required this.controller});

  final ActiveCallController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final denoise = controller.videoDenoiseEnabled.value;
          final voiceIsolation = controller.voiceIsolationEnabled.value;
          final effect = controller.videoEffect.value;
          final bgId = controller.virtualBackgroundId.value;

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: FaceTimePalette.secondaryText.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Video effects',
                  style: TextStyle(
                    color: FaceTimePalette.onCanvas,
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Enhancements',
                  style: TextStyle(
                    color: FaceTimePalette.secondaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Material(
                  color: FaceTimePalette.darkElevated,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
                    side: const BorderSide(color: FaceTimePalette.hairline, width: 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SwitchListTile(
                        key: const Key('in_app_call_video_denoise_toggle'),
                        value: denoise,
                        onChanged: (v) => unawaited(controller.setVideoDenoise(v)),
                        secondary: Icon(
                          Icons.auto_fix_high_rounded,
                          color: denoise ? FaceTimePalette.blueDark : FaceTimePalette.onCanvas,
                        ),
                        title: const Text(
                          'Studio Video Enhancement',
                          style: TextStyle(color: FaceTimePalette.onCanvas, fontSize: 15, fontWeight: FontWeight.w500),
                        ),
                        subtitle: const Text(
                          'Denoise, low-light lift & sharpening',
                          style: TextStyle(color: FaceTimePalette.secondaryText, fontSize: 13),
                        ),
                        activeThumbColor: FaceTimePalette.darkCanvas,
                        activeTrackColor: FaceTimePalette.blueDark,
                      ),
                      const Divider(height: 1, thickness: 1, color: FaceTimePalette.hairline),
                      SwitchListTile(
                        key: const Key('in_app_call_voice_isolation_toggle'),
                        value: voiceIsolation,
                        onChanged: (v) => unawaited(controller.setVoiceIsolation(v)),
                        secondary: Icon(
                          Icons.graphic_eq_rounded,
                          color: voiceIsolation ? FaceTimePalette.blueDark : FaceTimePalette.onCanvas,
                        ),
                        title: const Text(
                          'Voice Isolation',
                          style: TextStyle(color: FaceTimePalette.onCanvas, fontSize: 15, fontWeight: FontWeight.w500),
                        ),
                        subtitle: const Text(
                          'Neural noise & background suppression',
                          style: TextStyle(color: FaceTimePalette.secondaryText, fontSize: 13),
                        ),
                        activeThumbColor: FaceTimePalette.darkCanvas,
                        activeTrackColor: FaceTimePalette.blueDark,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Background',
                  style: TextStyle(
                    color: FaceTimePalette.secondaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _EffectChipTile(
                      icon: Icons.block_rounded,
                      label: 'None',
                      selected: effect == FaceTimeVideoEffectType.none,
                      onTap: () => unawaited(controller.setVideoEffect(FaceTimeVideoEffectType.none)),
                    ),
                    _EffectChipTile(
                      icon: Icons.blur_on_rounded,
                      label: 'Light blur',
                      selected: effect == FaceTimeVideoEffectType.blurLight,
                      onTap: () => unawaited(controller.setVideoEffect(FaceTimeVideoEffectType.blurLight)),
                    ),
                    _EffectChipTile(
                      icon: Icons.blur_circular_rounded,
                      label: 'Strong blur',
                      selected: effect == FaceTimeVideoEffectType.blurStrong,
                      onTap: () => unawaited(controller.setVideoEffect(FaceTimeVideoEffectType.blurStrong)),
                    ),
                    for (final preset in FaceTimeBackgroundPreset.presets)
                      _EffectChipTile(
                        previewColors: preset.previewColors,
                        label: preset.label,
                        selected: effect == FaceTimeVideoEffectType.virtualBackground && bgId == preset.id,
                        onTap: () => unawaited(
                          controller.setVideoEffect(
                            FaceTimeVideoEffectType.virtualBackground,
                            backgroundId: preset.id,
                            backgroundPath: preset.assetOrPath,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EffectChipTile extends StatelessWidget {
  const _EffectChipTile({
    this.icon,
    this.previewColors,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData? icon;
  final List<int>? previewColors;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: FaceTimePalette.darkElevated,
        borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
        border: Border.all(
          color: selected ? FaceTimePalette.blueDark : FaceTimePalette.hairline,
          width: selected ? 2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 96),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (previewColors != null && previewColors!.isNotEmpty)
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: previewColors!.length == 1
                              ? [Color(previewColors!.first), Color(previewColors!.first)]
                              : previewColors!.map(Color.new).toList(),
                        ),
                        border: Border.all(
                          color: FaceTimePalette.hairline,
                          width: 1,
                        ),
                      ),
                    )
                  else if (icon != null)
                    Icon(
                      icon,
                      color: selected ? FaceTimePalette.blueDark : FaceTimePalette.onCanvas,
                      size: 18,
                    ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: FaceTimePalette.onCanvas,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.check_rounded,
                      color: FaceTimePalette.blueDark,
                      size: 16,
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

class _MoreTraySheet extends StatelessWidget {
  const _MoreTraySheet({
    required this.controller,
    required this.canShowKeypad,
    required this.onOpenAudioRoute,
    required this.onOpenVideoEffects,
    required this.onOpenKeypad,
  });

  final ActiveCallController controller;
  final bool canShowKeypad;
  final VoidCallback onOpenAudioRoute;
  final VoidCallback onOpenVideoEffects;
  final VoidCallback onOpenKeypad;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final state = controller.state;
          final voiceIsolation = controller.voiceIsolationEnabled.value;
          final denoise = controller.videoDenoiseEnabled.value;
          final tiles = <Widget>[
            _MoreTrayTile(
              key: const Key('in_app_call_voice_isolation_toggle'),
              icon: Icons.graphic_eq_rounded,
              label: 'Voice Isolation',
              selected: voiceIsolation,
              onTap: () => unawaited(controller.setVoiceIsolation(!voiceIsolation)),
            ),
            if (state.isVideo && !state.isTelephony)
              _MoreTrayTile(
                key: const Key('in_app_call_video_denoise_toggle'),
                icon: Icons.auto_awesome_rounded,
                label: 'Video Effects & Blur',
                selected: denoise || controller.videoEffect.value != FaceTimeVideoEffectType.none,
                onTap: () => unawaited(controller.setVideoDenoise(!denoise)),
                onLongPress: () {
                  Navigator.of(context).pop();
                  onOpenVideoEffects();
                },
              ),
            _MoreTrayTile(
              icon: Icons.volume_up_rounded,
              label: 'Audio Route',
              onTap: () {
                Navigator.of(context).pop();
                onOpenAudioRoute();
              },
            ),
            if (canShowKeypad)
              _MoreTrayTile(
                icon: Icons.dialpad_rounded,
                label: 'Keypad',
                onTap: () {
                  Navigator.of(context).pop();
                  onOpenKeypad();
                },
              ),
            if (controller.wearWatchConnected)
              _MoreTrayTile(
                icon: Icons.watch_rounded,
                iconWidget: controller.audioOnWatch.value
                    ? const PhoneTransferIcon(size: 22, color: FaceTimePalette.m3OnPrimary)
                    : const WatchTransferIcon(size: 22, color: FaceTimePalette.m3OnSurface),
                label: controller.audioOnWatch.value ? 'On Watch' : 'Transfer to Watch',
                selected: controller.audioOnWatch.value,
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(
                    controller.audioOnWatch.value
                        ? controller.transferCallToPhone()
                        : controller.transferCallToWatch(),
                  );
                },
              ),
            if (state.hasJoinLink)
              _MoreTrayTile(
                icon: Icons.open_in_new_rounded,
                label: 'Open Link',
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(controller.openFaceTimeLink(context: context));
                },
              ),
          ];

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: FaceTimePalette.m3OnSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final tileWidth = math.max(120.0, (constraints.maxWidth - 10) / 2);
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final tile in tiles)
                            SizedBox(width: tileWidth, child: tile),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MoreTrayTile extends StatelessWidget {
  const _MoreTrayTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconWidget,
    this.onLongPress,
    this.selected = false,
  });

  final IconData icon;
  final Widget? iconWidget;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(selected ? 24.0 : 34.0);
    final bgColor = selected
        ? FaceTimePalette.m3Primary
        : FaceTimePalette.m3SurfaceContainerHigh;
    final fgColor = selected
        ? FaceTimePalette.m3OnPrimary
        : FaceTimePalette.m3OnSurface;

    return Semantics(
      button: true,
      toggled: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: FaceTimeMotion.of(context, FaceTimeMotion.morph),
            curve: FaceTimeMotion.emphasized,
            height: 68,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: radius,
            ),
            child: Row(
              children: [
                iconWidget ?? Icon(icon, color: fgColor, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: kDefaultAppFontFamily,
                      color: fgColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
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
