import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

enum _OutgoingSheetPhase {
  chooseMode,
  connecting,
  telecomSetup,
  permissionsRequired,
  ringingJoinReady,
  ringingNoLink,
  error,
}

/// Skin-aware outgoing FaceTime bottom sheet handling mode selection,
/// inline Android Telecom setup, connecting state, and failure recovery.
class OutgoingFaceTimeSheet extends StatefulWidget {
  const OutgoingFaceTimeSheet({
    super.key,
    required this.callerName,
    this.callerAddress,
    this.chatHandle,
    this.avatarBytes,
    this.initialVideo,
    this.isAndroid = false,
    this.isIOS = false,
    this.isTelephony = false,
    this.callController,
    this.initialPendingTab,
    this.onPreOpenTab,
    this.onTryOpenJoinLink,
    required this.checkTelecomEnabled,
    required this.onOpenCallingAccounts,
    required this.requestCallPermissions,
    this.requestVideoPermissions,
    required this.onPlaceNativeAudioCall,
    this.onPlaceNativeCall,
    required this.onStartServerCall,
    required this.onOpenJoinLink,
    required this.onHangUpRingingCall,
  });

  final String callerName;
  final String? callerAddress;
  final Handle? chatHandle;
  final Uint8List? avatarBytes;
  final bool? initialVideo;
  final bool isAndroid;
  final bool isIOS;
  final bool isTelephony;
  final ActiveCallController? callController;
  final PendingCallTab? initialPendingTab;
  final PendingCallTab? Function()? onPreOpenTab;
  final Future<bool> Function(String link)? onTryOpenJoinLink;
  final Future<bool> Function() checkTelecomEnabled;
  final Future<void> Function() onOpenCallingAccounts;
  final Future<bool> Function() requestCallPermissions;
  final Future<bool> Function()? requestVideoPermissions;
  final Future<bool> Function() onPlaceNativeAudioCall;
  final Future<bool> Function(bool isVideo)? onPlaceNativeCall;
  final Future<PlacedFaceTimeCall> Function(bool video) onStartServerCall;
  final Future<void> Function(String link) onOpenJoinLink;
  final Future<void> Function(String callUuid) onHangUpRingingCall;

  @override
  State<OutgoingFaceTimeSheet> createState() => _OutgoingFaceTimeSheetState();
}

class _OutgoingFaceTimeSheetState extends State<OutgoingFaceTimeSheet> {
  late _OutgoingSheetPhase _phase;
  bool _selectedVideo = true;
  bool? _telecomEnabled;
  bool _cancelled = false;
  bool _hangingUp = false;
  String? _errorMessage;
  FaceTimeCall? _ringingCall;
  String? _joinLink;
  PendingCallTab? _pendingTab;
  ActiveCallFailure? _handledFailure;

  ActiveCallController get _controller => widget.callController ?? ActiveCallController.instance;

  @override
  void initState() {
    super.initState();
    _pendingTab = widget.initialPendingTab;
    _controller.addListener(_onControllerChanged);
    if (widget.initialVideo != null) {
      _selectedVideo = widget.initialVideo!;
      _phase = _OutgoingSheetPhase.connecting;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _beginCall(_selectedVideo);
      });
    } else {
      _phase = _OutgoingSheetPhase.chooseMode;
      if (widget.isAndroid) {
        _probeTelecom();
      }
    }
  }

  @override
  void didUpdateWidget(covariant OutgoingFaceTimeSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldCtrl = oldWidget.callController ?? ActiveCallController.instance;
    if (!identical(oldCtrl, _controller)) {
      oldCtrl.removeListener(_onControllerChanged);
      _controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _cancelled = true;
    _closePendingTab();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final failure = _controller.lastFailure;
    if (failure == null || failure == _handledFailure) return;
    final isWaitingPhase = _phase == _OutgoingSheetPhase.connecting ||
        _phase == _OutgoingSheetPhase.ringingJoinReady ||
        _phase == _OutgoingSheetPhase.ringingNoLink;
    if (!isWaitingPhase) return;
    if (_ringingCall != null && _ringingCall!.callUuid.isNotEmpty && failure.callUuid != _ringingCall!.callUuid) {
      return;
    }
    _handledFailure = failure;
    _closePendingTab();
    setState(() {
      _errorMessage = failure.message;
      _phase = _OutgoingSheetPhase.error;
    });
  }

  void _closePendingTab() {
    _pendingTab?.close();
    _pendingTab = null;
  }

  Future<void> _probeTelecom() async {
    try {
      final enabled = await widget.checkTelecomEnabled();
      if (mounted) {
        setState(() => _telecomEnabled = enabled);
      }
    } catch (_) {
      // Non-fatal probe; checked again when user taps audio.
    }
  }

  bool _usesNativeAndroid(bool video) =>
      widget.isAndroid && (!video || (!widget.isTelephony && widget.onPlaceNativeCall != null));

  Future<void> _beginCall(bool video) async {
    _cancelled = false;
    _selectedVideo = video;

    if (_usesNativeAndroid(video)) {
      final hasPerms = video && widget.requestVideoPermissions != null
          ? await widget.requestVideoPermissions!()
          : await widget.requestCallPermissions();
      if (_cancelled || !mounted) return;
      if (!hasPerms) {
        setState(() => _phase = _OutgoingSheetPhase.permissionsRequired);
        return;
      }

      final telecomReady = await widget.checkTelecomEnabled();
      if (_cancelled || !mounted) return;
      setState(() => _telecomEnabled = telecomReady);
      if (!telecomReady) {
        setState(() => _phase = _OutgoingSheetPhase.telecomSetup);
        return;
      }

      setState(() => _phase = _OutgoingSheetPhase.connecting);
      final placedNative = widget.onPlaceNativeCall != null
          ? await widget.onPlaceNativeCall!(video)
          : await widget.onPlaceNativeAudioCall();
      if (_cancelled || !mounted) return;
      if (!placedNative) {
        final msg = widget.isTelephony
            ? "Couldn't start iPhone cellular call."
            : (video ? "Couldn't start native FaceTime Video call." : "Couldn't start native FaceTime Audio call.");
        _controller.reportError(msg);
        setState(() {
          _errorMessage = msg;
          _phase = _OutgoingSheetPhase.error;
        });
        return;
      }

      final rootNav = Navigator.of(context, rootNavigator: true);
      _controller.startOngoing(
        callerName: widget.callerName,
        callerAddress: widget.callerAddress,
        avatarBytes: widget.avatarBytes,
        isVideo: video && !widget.isTelephony,
        isTelecomCall: true,
        isTelephony: widget.isTelephony,
      );
      Navigator.of(context).pop();
      if (rootNav.mounted) {
        openInAppCallScreen(context: rootNav.context, controller: _controller);
      }
      return;
    }

    setState(() {
      _errorMessage = null;
      _ringingCall = null;
      _joinLink = null;
      _phase = _OutgoingSheetPhase.connecting;
    });

    // Synchronously reserve a tab inside the user gesture before awaiting the server.
    _pendingTab ??= widget.onPreOpenTab?.call();

    PlacedFaceTimeCall? placed;
    FaceTimeException? refusal;
    try {
      placed = await widget.onStartServerCall(video);
    } on FaceTimeException catch (e) {
      refusal = e;
    } catch (_) {
      refusal = const FaceTimeException("Couldn't reach the server.");
    }

    if (_cancelled || !mounted) {
      _closePendingTab();
      if (placed != null && placed.call.callUuid.isNotEmpty) {
        unawaited(widget.onHangUpRingingCall(placed.call.callUuid));
      }
      return;
    }

    if (placed != null) {
      final link = placed.link;
      if (link == null || link.isEmpty) {
        _closePendingTab();
        if (placed.call.callUuid.isNotEmpty) {
          setState(() {
            _ringingCall = placed!.call;
            _phase = _OutgoingSheetPhase.ringingNoLink;
          });
        } else {
          const msg = "Couldn't get a call link from the server.";
          _controller.reportError(msg);
          setState(() {
            _errorMessage = msg;
            _phase = _OutgoingSheetPhase.error;
          });
        }
        return;
      }

      _controller.startOngoing(
        callUuid: placed.call.callUuid,
        callerName: widget.callerName,
        callerAddress: widget.callerAddress,
        avatarBytes: widget.avatarBytes,
        isVideo: video,
        joinLink: link,
      );

      final navigatedPendingTab = _pendingTab?.navigate(link) ?? false;
      if (navigatedPendingTab) {
        _controller.attachPendingCallTab(_pendingTab);
        _pendingTab = null;
        Navigator.of(context).pop();
        return;
      }
      _closePendingTab();

      if (widget.onTryOpenJoinLink != null) {
        final launched = await widget.onTryOpenJoinLink!(link);
        if (!mounted) return;
        if (launched) {
          Navigator.of(context).pop();
          return;
        }
        setState(() {
          _ringingCall = placed!.call;
          _joinLink = link;
          _phase = _OutgoingSheetPhase.ringingJoinReady;
        });
        return;
      }

      Navigator.of(context).pop();
      await widget.onOpenJoinLink(link);
      return;
    }

    _closePendingTab();

    final ringing = refusal?.call;
    if (ringing != null) {
      setState(() {
        _ringingCall = ringing;
        _phase = _OutgoingSheetPhase.ringingNoLink;
      });
      return;
    }

    final msg = refusal?.message ?? "Couldn't start FaceTime.";
    _controller.reportError(msg);
    setState(() {
      _errorMessage = msg;
      _phase = _OutgoingSheetPhase.error;
    });
  }

  void _cancelConnecting() {
    _cancelled = true;
    _closePendingTab();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reducedMotion = facetimeReducedMotionOf(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    final sheetSurface = widget.isIOS
        ? (isDark
            ? FaceTimePalette.darkSurface.withValues(alpha: 0.88)
            : theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.90))
        : (isDark ? FaceTimePalette.darkSurface : theme.colorScheme.surfaceContainerLow);

    final borderColor = isDark
        ? FaceTimePalette.hairline
        : theme.colorScheme.outlineVariant.withValues(alpha: 0.5);

    final titleColor = isDark ? FaceTimePalette.onCanvas : theme.colorScheme.onSurface;
    final subtitleColor = isDark ? FaceTimePalette.secondaryText : theme.colorScheme.onSurfaceVariant;

    Widget content = Container(
      decoration: BoxDecoration(
        color: sheetSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(FaceTimeDims.sheetTopRadius)),
        border: Border(top: BorderSide(color: borderColor, width: 1)),
      ),
      padding: EdgeInsets.fromLTRB(
        FaceTimeDims.contactSideMargin,
        12,
        FaceTimeDims.contactSideMargin,
        FaceTimeDims.contactSideMargin + bottomInset,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: subtitleColor.withValues(alpha: 0.38),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Caller header
            Row(
              children: [
                FaceTimeAvatar(
                  callerName: widget.callerName,
                  avatarBytes: widget.avatarBytes,
                  handle: widget.chatHandle,
                  size: 56,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.callerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: titleColor,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.callerAddress?.isNotEmpty == true
                            ? 'FaceTime · ${widget.callerAddress}'
                            : 'FaceTime',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            AnimatedSwitcher(
              duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 200),
              child: _buildPhaseBody(context, theme, isDark, reducedMotion),
            ),
          ],
        ),
      ),
    );

    if (widget.isIOS) {
      content = ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(FaceTimeDims.sheetTopRadius)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: content,
        ),
      );
    }

    return SafeArea(
      top: true,
      bottom: false,
      child: content,
    );
  }

  Widget _buildPhaseBody(BuildContext context, ThemeData theme, bool isDark, bool reducedMotion) {
    final titleColor = isDark ? FaceTimePalette.onCanvas : theme.colorScheme.onSurface;
    final subtitleColor = isDark ? FaceTimePalette.secondaryText : theme.colorScheme.onSurfaceVariant;
    final outlinedForeground = isDark ? FaceTimePalette.onCanvas : null;
    final outlinedSide = isDark ? BorderSide(color: FaceTimePalette.secondaryText.withValues(alpha: 0.4)) : null;

    switch (_phase) {
      case _OutgoingSheetPhase.chooseMode:
        return Column(
          key: const ValueKey('choose-mode'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _OutgoingOptionCard(
              icon: widget.isIOS ? CupertinoIcons.videocam_fill : Icons.videocam_rounded,
              accentColor: isDark ? FaceTimePalette.blueDark : FaceTimePalette.blue,
              title: 'Start video call',
              subtitle: (widget.isAndroid && !widget.isTelephony && widget.onPlaceNativeCall != null)
                  ? (_telecomEnabled == false
                      ? 'Needs Calling Account setup'
                      : 'Native video via Android Calling')
                  : 'Opens FaceTime video link',
              reducedMotion: reducedMotion,
              onTap: () => _beginCall(true),
            ),
            const SizedBox(height: 12),
            _OutgoingOptionCard(
              icon: widget.isIOS ? CupertinoIcons.phone_fill : Icons.call_rounded,
              accentColor: FaceTimePalette.green,
              title: 'Start audio call',
              subtitle: widget.isAndroid
                  ? (_telecomEnabled == false
                      ? 'Needs Calling Account setup'
                      : 'Native audio via Android Calling')
                  : 'Opens FaceTime audio link',
              reducedMotion: reducedMotion,
              onTap: () => _beginCall(false),
            ),
            if (widget.isAndroid && _telecomEnabled == false) ...[
              const SizedBox(height: 12),
              _InlineTelecomBanner(
                onOpenSettings: () async {
                  await widget.onOpenCallingAccounts();
                  await _probeTelecom();
                },
              ),
            ],
          ],
        );

      case _OutgoingSheetPhase.telecomSetup:
        return _InlineStatusPanel(
          key: const ValueKey('telecom-setup'),
          icon: Icons.phone_in_talk_rounded,
          accentColor: FaceTimePalette.amber,
          title: 'Enable Calling Account',
          body: _selectedVideo
              ? 'Turn on BlueBubbles FaceTime in Android Calling Accounts to place native FaceTime Video calls.'
              : 'Turn on BlueBubbles FaceTime in Android Calling Accounts to place native FaceTime Audio calls.',
          actions: [
            OutlinedButton(
              onPressed: () => setState(() => _phase = _OutgoingSheetPhase.chooseMode),
              style: OutlinedButton.styleFrom(
                foregroundColor: outlinedForeground,
                side: outlinedSide,
                minimumSize: const Size(88, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () async {
                await widget.onOpenCallingAccounts();
                final enabled = await widget.checkTelecomEnabled();
                if (!mounted) return;
                setState(() => _telecomEnabled = enabled);
                if (enabled) {
                  await _beginCall(_selectedVideo);
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: FaceTimePalette.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(140, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Open calling settings'),
            ),
          ],
        );

      case _OutgoingSheetPhase.permissionsRequired:
        return _InlineStatusPanel(
          key: const ValueKey('permissions-required'),
          icon: _selectedVideo ? Icons.videocam_off_rounded : Icons.mic_off_rounded,
          accentColor: FaceTimePalette.amber,
          title: _selectedVideo ? 'Microphone, Camera & Phone access needed' : 'Microphone & Phone access needed',
          body: _selectedVideo
              ? 'Allow Microphone, Camera, and Phone permissions to place native FaceTime Video calls.'
              : 'Allow Microphone and Phone permissions to place native FaceTime Audio calls.',
          actions: [
            OutlinedButton(
              onPressed: () => setState(() => _phase = _OutgoingSheetPhase.chooseMode),
              style: OutlinedButton.styleFrom(
                foregroundColor: outlinedForeground,
                side: outlinedSide,
                minimumSize: const Size(88, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => _beginCall(_selectedVideo),
              style: FilledButton.styleFrom(
                backgroundColor: FaceTimePalette.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(120, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Try again'),
            ),
          ],
        );

      case _OutgoingSheetPhase.connecting:
        return Container(
          key: const ValueKey('connecting'),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: isDark
                ? FaceTimePalette.darkElevated
                : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(FaceTimeDims.estimatePillRadius),
            border: Border.all(
              color: isDark ? FaceTimePalette.hairline : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: isDark ? FaceTimePalette.blueDark : FaceTimePalette.blue,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Calling ${widget.callerName}…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: titleColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _selectedVideo
                              ? (_usesNativeAndroid(true) ? 'Starting FaceTime Video' : 'Preparing FaceTime Video link')
                              : (widget.isTelephony ? 'Calling via iPhone Cellular' : 'Starting FaceTime Audio'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: subtitleColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _cancelConnecting,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: outlinedForeground,
                    side: outlinedSide,
                    minimumSize: const Size(double.infinity, FaceTimeDims.actionButtonSize),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text('Cancel call'),
                ),
              ),
            ],
          ),
        );

      case _OutgoingSheetPhase.ringingJoinReady:
        final dangerColor = isDark ? FaceTimePalette.redDarkSkin : FaceTimePalette.red;
        return _InlineStatusPanel(
          key: const ValueKey('ringing-join-ready'),
          icon: widget.isIOS ? CupertinoIcons.videocam_fill : Icons.videocam_rounded,
          accentColor: FaceTimePalette.green,
          title: 'Ringing — Join FaceTime',
          body: 'Your browser blocked opening the FaceTime tab automatically. Tap Join Call to open it.',
          actions: [
            OutlinedButton(
              onPressed: _hangingUp || _ringingCall == null
                  ? null
                  : () async {
                      final nav = Navigator.of(context);
                      setState(() => _hangingUp = true);
                      await widget.onHangUpRingingCall(_ringingCall!.callUuid);
                      (widget.callController ?? ActiveCallController.instance).clear();
                      if (mounted) {
                        nav.pop();
                      }
                    },
              style: OutlinedButton.styleFrom(
                foregroundColor: dangerColor,
                side: BorderSide(color: dangerColor.withValues(alpha: 0.55)),
                minimumSize: const Size(112, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Hang Up'),
            ),
            FilledButton(
              onPressed: _joinLink == null
                  ? null
                  : () {
                      final link = _joinLink!;
                      widget.onOpenJoinLink(link);
                      Navigator.of(context).pop();
                    },
              style: FilledButton.styleFrom(
                backgroundColor: FaceTimePalette.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(124, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Join Call'),
            ),
          ],
        );

      case _OutgoingSheetPhase.ringingNoLink:
        return _InlineStatusPanel(
          key: const ValueKey('ringing-no-link'),
          icon: Icons.link_off_rounded,
          accentColor: FaceTimePalette.amber,
          title: 'No link to join',
          body: "The call is ringing, but the server couldn't create a join link.",
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: outlinedForeground,
                side: outlinedSide,
                minimumSize: const Size(110, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Leave ringing'),
            ),
            FilledButton(
              onPressed: _hangingUp || _ringingCall == null
                  ? null
                  : () async {
                      final nav = Navigator.of(context);
                      setState(() => _hangingUp = true);
                      await widget.onHangUpRingingCall(_ringingCall!.callUuid);
                      _controller.clear();
                      if (mounted) {
                        nav.pop();
                      }
                    },
              style: FilledButton.styleFrom(
                backgroundColor: FaceTimePalette.red,
                foregroundColor: Colors.white,
                minimumSize: const Size(124, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Hang up call'),
            ),
          ],
        );

      case _OutgoingSheetPhase.error:
        return _InlineStatusPanel(
          key: const ValueKey('error'),
          icon: Icons.error_outline_rounded,
          accentColor: isDark ? FaceTimePalette.redDarkSkin : FaceTimePalette.red,
          title: "Couldn't start FaceTime",
          body: _errorMessage ?? 'Unable to connect right now.',
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: outlinedForeground,
                side: outlinedSide,
                minimumSize: const Size(96, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () => setState(() => _phase = _OutgoingSheetPhase.chooseMode),
              style: FilledButton.styleFrom(
                backgroundColor: FaceTimePalette.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(112, FaceTimeDims.actionButtonSize),
                shape: const StadiumBorder(),
              ),
              child: const Text('Try again'),
            ),
          ],
        );
    }
  }
}

class _OutgoingOptionCard extends StatefulWidget {
  const _OutgoingOptionCard({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.reducedMotion,
    required this.onTap,
  });

  final IconData icon;
  final Color accentColor;
  final String title;
  final String subtitle;
  final bool reducedMotion;
  final VoidCallback onTap;

  @override
  State<_OutgoingOptionCard> createState() => _OutgoingOptionCardState();
}

class _OutgoingOptionCardState extends State<_OutgoingOptionCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark
        ? FaceTimePalette.darkElevated
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.72);
    final titleColor = isDark ? FaceTimePalette.onCanvas : theme.colorScheme.onSurface;
    final subtitleColor = isDark ? FaceTimePalette.secondaryText : theme.colorScheme.onSurfaceVariant;
    final cardRadius = BorderRadius.circular(FaceTimeDims.ongoingPillRadius);
    final scale = (!widget.reducedMotion && _pressed) ? 0.96 : 1.0;

    return AnimatedScale(
      scale: scale,
      duration: widget.reducedMotion ? Duration.zero : const Duration(milliseconds: 100),
      curve: Curves.easeOut,
      child: Material(
        color: cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: cardRadius,
          side: BorderSide(
            color: isDark ? FaceTimePalette.hairline : theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          borderRadius: cardRadius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 68),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: widget.accentColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(widget.icon, color: widget.accentColor, size: FaceTimeDims.actionIconSize),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: titleColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: subtitleColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 16,
                    color: subtitleColor,
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

class _InlineTelecomBanner extends StatelessWidget {
  const _InlineTelecomBanner({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: FaceTimePalette.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(FaceTimeDims.ongoingPillRadius),
        border: Border.all(color: FaceTimePalette.amber.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, size: 20, color: FaceTimePalette.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Enable Calling Accounts for native FaceTime Audio.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: isDark ? FaceTimePalette.onCanvas : theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onOpenSettings,
            style: TextButton.styleFrom(
              minimumSize: const Size(FaceTimeDims.actionButtonSize, FaceTimeDims.actionButtonSize),
              foregroundColor: isDark ? FaceTimePalette.blueDark : FaceTimePalette.blue,
            ),
            child: const Text('Setup'),
          ),
        ],
      ),
    );
  }
}

class _InlineStatusPanel extends StatelessWidget {
  const _InlineStatusPanel({
    super.key,
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.body,
    required this.actions,
  });

  final IconData icon;
  final Color accentColor;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark
            ? FaceTimePalette.darkElevated
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(FaceTimeDims.estimatePillRadius),
        border: Border.all(
          color: isDark ? FaceTimePalette.hairline : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: accentColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: isDark ? FaceTimePalette.onCanvas : theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: isDark ? FaceTimePalette.secondaryText : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 8,
            children: actions,
          ),
        ],
      ),
    );
  }
}

/// Sleek bottom sheet fallback when a web browser blocks opening the FaceTime join link.
class FaceTimeJoinFallbackSheet extends StatelessWidget {
  const FaceTimeJoinFallbackSheet({
    super.key,
    required this.onCopyLink,
    required this.onJoinCall,
  });

  final VoidCallback onCopyLink;
  final VoidCallback onJoinCall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final titleColor = isDark ? FaceTimePalette.onCanvas : theme.colorScheme.onSurface;
    final subtitleColor = isDark ? FaceTimePalette.secondaryText : theme.colorScheme.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? FaceTimePalette.darkSurface : theme.colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(FaceTimeDims.sheetTopRadius)),
        border: Border(
          top: BorderSide(
            color: isDark ? FaceTimePalette.hairline : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        FaceTimeDims.contactSideMargin,
        12,
        FaceTimeDims.contactSideMargin,
        FaceTimeDims.contactSideMargin + bottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: subtitleColor.withValues(alpha: 0.38),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'FaceTime link ready',
            style: theme.textTheme.titleLarge?.copyWith(
              color: titleColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Your browser blocked opening the FaceTime tab automatically.',
            style: theme.textTheme.bodyMedium?.copyWith(color: subtitleColor),
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: onCopyLink,
                style: OutlinedButton.styleFrom(
                  foregroundColor: isDark ? FaceTimePalette.onCanvas : null,
                  side: isDark ? BorderSide(color: FaceTimePalette.secondaryText.withValues(alpha: 0.4)) : null,
                  minimumSize: const Size(112, FaceTimeDims.actionButtonSize),
                  shape: const StadiumBorder(),
                ),
                child: const Text('Copy link'),
              ),
              FilledButton(
                onPressed: onJoinCall,
                style: FilledButton.styleFrom(
                  backgroundColor: FaceTimePalette.blue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(112, FaceTimeDims.actionButtonSize),
                  shape: const StadiumBorder(),
                ),
                child: const Text('Join call'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
