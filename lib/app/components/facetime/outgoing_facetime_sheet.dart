import 'dart:typed_data';
import 'dart:ui';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

enum _OutgoingSheetPhase {
  chooseMode,
  connecting,
  telecomSetup,
  permissionsRequired,
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
    this.callController,
    required this.checkTelecomEnabled,
    required this.onOpenCallingAccounts,
    required this.requestCallPermissions,
    required this.onPlaceNativeAudioCall,
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
  final ActiveCallController? callController;
  final Future<bool> Function() checkTelecomEnabled;
  final Future<void> Function() onOpenCallingAccounts;
  final Future<bool> Function() requestCallPermissions;
  final Future<bool> Function() onPlaceNativeAudioCall;
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

  @override
  void initState() {
    super.initState();
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

  Future<void> _beginCall(bool video) async {
    _cancelled = false;
    _selectedVideo = video;

    if (!video && widget.isAndroid) {
      final hasPerms = await widget.requestCallPermissions();
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
      final placedNative = await widget.onPlaceNativeAudioCall();
      if (_cancelled || !mounted) return;
      if (!placedNative) {
        setState(() {
          _errorMessage = "Couldn't start native FaceTime Audio call.";
          _phase = _OutgoingSheetPhase.error;
        });
        return;
      }

      (widget.callController ?? ActiveCallController.instance).startOngoing(
        callerName: widget.callerName,
        callerAddress: widget.callerAddress,
        avatarBytes: widget.avatarBytes,
        isVideo: false,
        isTelecomCall: true,
      );
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _errorMessage = null;
      _ringingCall = null;
      _phase = _OutgoingSheetPhase.connecting;
    });

    PlacedFaceTimeCall? placed;
    FaceTimeException? refusal;
    try {
      placed = await widget.onStartServerCall(video);
    } on FaceTimeException catch (e) {
      refusal = e;
    } catch (_) {
      refusal = const FaceTimeException("Couldn't reach the server.");
    }

    if (_cancelled || !mounted) return;

    if (placed != null) {
      final link = placed.link;
      if (link == null || link.isEmpty) {
        setState(() {
          _errorMessage = "Couldn't get a call link from the server.";
          _phase = _OutgoingSheetPhase.error;
        });
        return;
      }

      (widget.callController ?? ActiveCallController.instance).startOngoing(
        callUuid: placed.call.callUuid,
        callerName: widget.callerName,
        callerAddress: widget.callerAddress,
        avatarBytes: widget.avatarBytes,
        isVideo: video,
        joinLink: link,
      );
      Navigator.of(context).pop();
      await widget.onOpenJoinLink(link);
      return;
    }

    final ringing = refusal?.call;
    if (ringing != null) {
      setState(() {
        _ringingCall = ringing;
        _phase = _OutgoingSheetPhase.ringingNoLink;
      });
      return;
    }

    setState(() {
      _errorMessage = refusal?.message ?? "Couldn't start FaceTime.";
      _phase = _OutgoingSheetPhase.error;
    });
  }

  void _cancelConnecting() {
    _cancelled = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reducedMotion = facetimeReducedMotionOf(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    final sheetSurface = widget.isIOS
        ? (isDark ? const Color(0xE0161D27) : const Color(0xE6F8FAFC))
        : (isDark ? FaceTimePalette.darkSurface : theme.colorScheme.surfaceContainerLow);

    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    Widget content = Container(
      decoration: BoxDecoration(
        color: sheetSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: borderColor, width: 1)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + bottomInset),
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
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
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
                          color: theme.colorScheme.onSurfaceVariant,
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
              child: _buildPhaseBody(context, theme),
            ),
          ],
        ),
      ),
    );

    if (widget.isIOS) {
      content = ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
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

  Widget _buildPhaseBody(BuildContext context, ThemeData theme) {
    switch (_phase) {
      case _OutgoingSheetPhase.chooseMode:
        return Column(
          key: const ValueKey('choose-mode'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _OutgoingOptionCard(
              icon: widget.isIOS ? CupertinoIcons.videocam_fill : Icons.videocam_rounded,
              accentColor: FaceTimePalette.blue,
              title: 'Start video call',
              subtitle: 'Opens FaceTime video link',
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
          body: 'Turn on BlueBubbles FaceTime in Android Calling Accounts to place native FaceTime Audio calls.',
          actions: [
            OutlinedButton(
              onPressed: () => setState(() => _phase = _OutgoingSheetPhase.chooseMode),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(88, 48),
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
                  await _beginCall(false);
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: FaceTimePalette.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(140, 48),
                shape: const StadiumBorder(),
              ),
              child: const Text('Open calling settings'),
            ),
          ],
        );

      case _OutgoingSheetPhase.permissionsRequired:
        return _InlineStatusPanel(
          key: const ValueKey('permissions-required'),
          icon: Icons.mic_off_rounded,
          accentColor: FaceTimePalette.amber,
          title: 'Microphone & Phone access needed',
          body: 'Allow Microphone and Phone permissions to place native FaceTime Audio calls.',
          actions: [
            OutlinedButton(
              onPressed: () => setState(() => _phase = _OutgoingSheetPhase.chooseMode),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(88, 48),
                shape: const StadiumBorder(),
              ),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => _beginCall(false),
              style: FilledButton.styleFrom(
                backgroundColor: FaceTimePalette.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(120, 48),
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
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: FaceTimePalette.blue,
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
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _selectedVideo ? 'Preparing FaceTime Video link' : 'Starting FaceTime Audio',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
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
                    minimumSize: const Size(double.infinity, 48),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text('Cancel call'),
                ),
              ),
            ],
          ),
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
                minimumSize: const Size(110, 48),
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
                      if (mounted) {
                        nav.pop();
                      }
                    },
              style: FilledButton.styleFrom(
                backgroundColor: FaceTimePalette.red,
                foregroundColor: Colors.white,
                minimumSize: const Size(124, 48),
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
          accentColor: FaceTimePalette.red,
          title: "Couldn't start FaceTime",
          body: _errorMessage ?? 'Unable to connect right now.',
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(96, 48),
                shape: const StadiumBorder(),
              ),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () => setState(() => _phase = _OutgoingSheetPhase.chooseMode),
              style: FilledButton.styleFrom(
                backgroundColor: FaceTimePalette.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(112, 48),
                shape: const StadiumBorder(),
              ),
              child: const Text('Try again'),
            ),
          ],
        );
    }
  }
}

class _OutgoingOptionCard extends StatelessWidget {
  const _OutgoingOptionCard({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color accentColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark
        ? FaceTimePalette.darkElevated
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.72);

    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
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
                    color: accentColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: accentColor, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: FaceTimePalette.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
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
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onOpenSettings,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: FaceTimePalette.blue,
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
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
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
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
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
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? FaceTimePalette.darkSurface
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'FaceTime link ready',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Your browser blocked opening the FaceTime tab automatically.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                  minimumSize: const Size(112, 48),
                  shape: const StadiumBorder(),
                ),
                child: const Text('Copy link'),
              ),
              FilledButton(
                onPressed: onJoinCall,
                style: FilledButton.styleFrom(
                  backgroundColor: FaceTimePalette.blue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(112, 48),
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
