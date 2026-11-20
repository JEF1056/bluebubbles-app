import 'dart:math' as math;

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_device_avatar.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

const Color _kLiveEmerald = Color(0xFF34C759);
const Color _kStaleAmber = Color(0xFFF59E0B);

/// Foreshortens ground-plane ellipses by `cos(pitch)` clamped to `[0.42, 1.0]`
/// so halos and contact shadows lie flat on 3D streets and form circles in 2D.
double _groundForeshorten(double pitchDegrees) {
  final clamped = pitchDegrees.clamp(0.0, 60.0);
  return math.cos(clamped * math.pi / 180.0).clamp(0.42, 1.0);
}

double _pitchNorm(double pitchDegrees) => pitchDegrees.clamp(0.0, 60.0) / 60.0;

bool _isDarkTheme(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

IconData _glyphForFindMyDevice(FindMyDevice device) {
  final id = (device.id ?? '').toLowerCase();
  final provider = (device.trackerProvider ?? '').toLowerCase();
  if (id.startsWith('utag:') || provider.contains('utag') || provider.contains('smarttag') || provider.contains('samsung')) {
    return Icons.bluetooth_searching_rounded;
  }
  if (id.startsWith('gfind:') || provider.contains('gfind') || provider.contains('google')) {
    return Icons.radar_rounded;
  }
  return iconForFindMyDevice(device);
}

bool _isStaleDevice(FindMyDevice device, DateTime now) {
  if (device.isLiveFresh(now)) return false;
  if (device.isOld || device.isInaccurate) return true;
  final updated = device.lastUpdated;
  return updated != null && now.difference(updated).inMinutes >= 30;
}

bool _isStaleFriend(FindMyFriend friend, DateTime now) {
  if (friend.isLiveFresh(now)) return false;
  if (friend.isOld || friend.isInaccurate) return true;
  final updated = friend.lastUpdated;
  return updated != null && now.difference(updated).inMinutes >= 30;
}

class FindMyFriendAvatar extends StatelessWidget {
  const FindMyFriendAvatar({
    super.key,
    required this.handle,
    required this.displayName,
    this.size = 38,
  });

  final Handle? handle;
  final String displayName;
  final double size;

  static String _initialsFor(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == '?' || RegExp(r'^[\+\d\s\-\(\)\.]+$').hasMatch(trimmed)) {
      return '';
    }
    final parts = trimmed.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    if (GetIt.I.isRegistered<ThemesService>() && GetIt.I.isRegistered<SettingsService>()) {
      return ContactAvatarWidget(
        handle: handle,
        borderThickness: 0,
        editable: false,
        size: size,
      );
    }
    final cs = context.theme.colorScheme;
    final initials = _initialsFor(displayName);
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: initials.isEmpty ? cs.surfaceContainerHighest : cs.primaryContainer,
      foregroundColor: initials.isEmpty ? cs.onSurfaceVariant : cs.onPrimaryContainer,
      child: initials.isEmpty
          ? Icon(Icons.person, size: size * 0.56)
          : Text(
              initials,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: initials.length > 1 ? size * 0.36 : size * 0.44,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}

/// Animated pulsing halo ring rendered on the ground plane behind live pins and detail-sheet avatars.
/// Foreshortens vertically by `cos(pitchDegrees)` (`0.42..1.0`) and disables its ticker when
/// `active` is false or `MediaQuery.disableAnimationsOf(context)` is true.
class FindMyPulsingHalo extends StatefulWidget {
  const FindMyPulsingHalo({
    super.key,
    required this.active,
    this.pulseNonce = 0,
    this.size = 64,
    this.color = _kLiveEmerald,
    this.pitchDegrees = 0.0,
  });

  final bool active;
  final int pulseNonce;
  final double size;
  final Color color;
  final double pitchDegrees;

  @override
  State<FindMyPulsingHalo> createState() => _FindMyPulsingHaloState();
}

class _FindMyPulsingHaloState extends State<FindMyPulsingHalo> with TickerProviderStateMixin {
  late final AnimationController _loopController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );
  late final AnimationController _burstController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  bool _animationsDisabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animationsDisabled = MediaQuery.disableAnimationsOf(context);
    _syncLoop();
  }

  @override
  void initState() {
    super.initState();
  }

  void _syncLoop() {
    final shouldRun = widget.active && !_animationsDisabled;
    if (shouldRun && !_loopController.isAnimating) {
      _loopController.repeat();
    } else if (!shouldRun && _loopController.isAnimating) {
      _loopController.stop();
      _loopController.reset();
    }
  }

  @override
  void didUpdateWidget(covariant FindMyPulsingHalo oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncLoop();
    if (!_animationsDisabled && widget.pulseNonce != oldWidget.pulseNonce && widget.pulseNonce > 0) {
      _burstController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _loopController.dispose();
    _burstController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active && !_burstController.isAnimating) {
      return const SizedBox.shrink();
    }

    final foreshorten = _groundForeshorten(widget.pitchDegrees);

    Widget ring(double scale, double borderAlpha, double borderWidth, {double fillAlpha = 0}) => Transform.scale(
          scale: scale,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fillAlpha > 0 ? widget.color.withValues(alpha: fillAlpha) : null,
              border: Border.all(color: widget.color.withValues(alpha: borderAlpha), width: borderWidth),
            ),
          ),
        );

    Widget content;
    if (_animationsDisabled) {
      content = ring(0.86, 0.34, 1.8, fillAlpha: 0.10);
    } else {
      content = Stack(
        alignment: Alignment.center,
        children: [
          if (widget.active)
            AnimatedBuilder(
              animation: _loopController,
              builder: (_, _) {
                final t = Curves.easeOutCubic.transform(_loopController.value);
                final alpha = (1.0 - t) * 0.44;
                return ring(0.56 + (0.52 * t), alpha, 2.0, fillAlpha: alpha * 0.38);
              },
            ),
          AnimatedBuilder(
            animation: _burstController,
            builder: (_, _) {
              if (!_burstController.isAnimating) return const SizedBox.shrink();
              final t = Curves.easeOutCubic.transform(_burstController.value);
              return ring(0.60 + (0.56 * t), (1.0 - t) * 0.68, 2.4);
            },
          ),
        ],
      );
    }

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(1.0, foreshorten, 1.0),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: content,
      ),
    );
  }
}

/// Pulsing green "Live" badge with centered label used on map pills, list tiles, and detail sheet.
class FindMyLiveBadge extends StatefulWidget {
  const FindMyLiveBadge({
    super.key,
    this.label = 'Live',
    this.compact = false,
  });

  final String label;
  final bool compact;

  @override
  State<FindMyLiveBadge> createState() => _FindMyLiveBadgeState();
}

class _FindMyLiveBadgeState extends State<FindMyLiveBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  bool _animationsDisabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animationsDisabled = MediaQuery.disableAnimationsOf(context);
    if (_animationsDisabled && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.reset();
    } else if (!_animationsDisabled && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const liveColor = Color(0xFF16A34A);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 7 : 9,
        vertical: widget.compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: liveColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: liveColor.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_animationsDisabled)
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: liveColor),
            )
          else
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, _) {
                final t = _pulse.value;
                return SizedBox(
                  width: 10,
                  height: 10,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 6 + (4 * t),
                        height: 6 + (4 * t),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: liveColor.withValues(alpha: 0.35 * (1 - t * 0.5)),
                        ),
                      ),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: liveColor,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(width: 4),
          Text(
            widget.label,
            textAlign: TextAlign.center,
            style: context.theme.textTheme.labelSmall?.copyWith(
              color: liveColor,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Interactive map pin for a FindMy friend.
/// Anchored at `Alignment.bottomCenter` on the ground contact dot.
class FindMyFriendMarker extends StatelessWidget {
  const FindMyFriendMarker({
    super.key,
    required this.controller,
    required this.friend,
    this.avatarHandle,
    this.pitchDegrees = 0.0,
    this.isHovered = false,
    this.staggerIndex = 0,
  });

  final FindMyController controller;
  final FindMyFriend friend;
  final Handle? avatarHandle;
  final double pitchDegrees;
  final bool isHovered;
  final int staggerIndex;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      controller.freshnessTick.value;
      if (GetIt.I.isRegistered<ContactServiceV2>()) {
        ContactsSvcV2.cacheVersion.value;
      }
      final isSelected = controller.selectedFriendId.value == friend.stableId;
      final current = controller.friends.firstWhereOrNull((f) => f.stableId == friend.stableId) ?? friend;
      final now = controller.currentTime;
      final isLive = current.isLiveFresh(now);
      final isLocating = current.locatingInProgress ||
          (current.stableId != null && controller.locatingFriendId.value == current.stableId);
      final isStale = _isStaleFriend(current, now);
      final cs = context.theme.colorScheme;
      final isDark = _isDarkTheme(context);
      final ringColor = isLive
          ? _kLiveEmerald
          : (isSelected
              ? cs.primary
              : (isStale
                  ? (isDark ? const Color(0xFF6B7280) : const Color(0xFF9CA3AF))
                  : (isDark ? const Color(0xFFE5E7EB) : Colors.white)));
      final label = shouldRedactFindMyContactInfo() ? 'Friend' : current.resolveDisplayName();

      return _FindMyPinShell(
        label: label,
        isSelected: isSelected,
        isHovered: isHovered,
        isLive: isLive,
        isStale: isStale,
        haloActive: isLive || isLocating,
        pulseNonce: controller.livePulseNonce.value,
        haloSize: isSelected ? 76 : 60,
        haloColor: isLive ? _kLiveEmerald : cs.primary,
        pitchDegrees: pitchDegrees,
        staggerIndex: staggerIndex,
        diameter: 40,
        fillColor: isDark ? const Color(0xFF1F242D) : Colors.white,
        ringColor: ringColor,
        ringWidth: isSelected ? 2.8 : (isLive ? 2.5 : 2.2),
        child: ClipOval(
          child: FindMyFriendAvatar(handle: avatarHandle, displayName: label, size: 34),
        ),
      );
    });
  }
}

/// Interactive map pin for a FindMy device, Apple AirTag, `utag:*` SmartTag, or `gfind:*` Find Hub tracker.
/// Anchored at `Alignment.bottomCenter` on the ground contact dot.
class FindMyDeviceMarker extends StatelessWidget {
  const FindMyDeviceMarker({
    super.key,
    required this.controller,
    required this.device,
    this.pitchDegrees = 0.0,
    this.isHovered = false,
    this.staggerIndex = 0,
  });

  final FindMyController controller;
  final FindMyDevice device;
  final double pitchDegrees;
  final bool isHovered;
  final int staggerIndex;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      controller.freshnessTick.value;
      final current = controller.devices.firstWhereOrNull((d) => d.id == device.id) ?? device;
      final isSelected = controller.selectedDeviceId.value == device.id;
      final now = controller.currentTime;
      final isLive = current.isLiveFresh(now);
      final isStale = _isStaleDevice(current, now);
      final cs = context.theme.colorScheme;
      final isDark = _isDarkTheme(context);
      final ringColor = isSelected
          ? cs.primary
          : (isLive
              ? _kLiveEmerald
              : (isStale
                  ? const Color(0xFF6B7280)
                  : (isDark ? Colors.white.withValues(alpha: 0.72) : Colors.white)));
      final label = shouldRedactFindMyContactInfo()
          ? (current.isConsideredAccessory ? 'Item' : 'Device')
          : (current.name ?? 'Device');

      return _FindMyPinShell(
        label: label,
        isSelected: isSelected,
        isHovered: isHovered,
        isLive: isLive,
        isStale: isStale,
        haloActive: isLive || current.isLocatingInProgress,
        pulseNonce: controller.livePulseNonce.value,
        haloSize: isSelected ? 74 : 58,
        haloColor: isLive ? _kLiveEmerald : cs.primary,
        pitchDegrees: pitchDegrees,
        staggerIndex: staggerIndex,
        diameter: 38,
        fillColor: isDark ? const Color(0xFF23252A) : const Color(0xFF1E242B),
        ringColor: ringColor,
        ringWidth: isSelected ? 2.6 : (isLive ? 2.4 : 2.0),
        child: ClipOval(
          child: FindMyDeviceAvatar(
            device: current,
            size: 34,
            showSurface: false,
            surfaceForImageOnly: true,
            showEmojiBadge: false,
            fallbackIcon: _glyphForFindMyDevice(current),
            fallbackIconColor: Colors.white,
            redacted: shouldRedactFindMyContactInfo(),
          ),
        ),
      );
    });
  }
}

/// Redesigned 2D/3D self-location puck with foreshortened ground-plane halo and heading cone.
/// Anchored at `Alignment.center`.
class FindMySelfMarker extends StatelessWidget {
  const FindMySelfMarker({
    super.key,
    this.headingRadians,
    this.pitchDegrees = 0.0,
    this.isHovered = false,
    this.showAvatar,
    this.label = 'You',
  });

  final double? headingRadians;
  final double pitchDegrees;
  final bool isHovered;
  final bool? showAvatar;
  final String label;

  bool _resolveShowAvatar() {
    if (showAvatar != null) return showAvatar!;
    if (!GetIt.I.isRegistered<SettingsService>() || !GetIt.I.isRegistered<ThemesService>()) {
      return false;
    }
    final hasPath = !isNullOrEmpty(SettingsSvc.settings.userAvatarPath.value);
    final hasBytes = SettingsSvc.userAvatarBytes.value != null;
    final hasName = SettingsSvc.effectiveUserName != 'You';
    return hasPath || hasBytes || hasName;
  }

  @override
  Widget build(BuildContext context) {
    final primary = context.theme.colorScheme.primary;
    final foreshorten = _groundForeshorten(pitchDegrees);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final hasHeading = headingRadians != null && headingRadians!.isFinite;
    final useAvatar = _resolveShowAvatar();
    final diameter = useAvatar ? 28.0 : 24.0;
    final scale = isHovered ? 1.06 : 1.0;

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        width: 72,
        height: 72,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            FindMyPulsingHalo(
              active: true,
              size: 56,
              color: primary,
              pitchDegrees: pitchDegrees,
            ),
            if (hasHeading)
              Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(1.0, foreshorten, 1.0),
                child: Transform.rotate(
                  angle: headingRadians!,
                  child: ClipPath(
                    clipper: const _SelfHeadingConeClipper(),
                    child: Container(
                      width: 28,
                      height: 58,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: AlignmentDirectional.center,
                          end: Alignment.topCenter,
                          colors: [
                            primary.withValues(alpha: 0.72),
                            primary.withValues(alpha: 0.08),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            AnimatedScale(
              scale: scale,
              duration: disableAnimations ? Duration.zero : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: Container(
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: Colors.black.withValues(alpha: 0.12), width: 0.8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 7,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                padding: EdgeInsets.all(useAvatar ? 2.0 : 4.0),
                child: useAvatar
                    ? const ContactAvatarWidget(handle: null, size: 22, borderThickness: 0, editable: false)
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: primary,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelfHeadingConeClipper extends CustomClipper<Path> {
  const _SelfHeadingConeClipper();

  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(size.width / 2, size.height / 2)
      ..lineTo(0, 0)
      ..quadraticBezierTo(size.width / 2, -size.height * 0.12, size.width, 0)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _PinEntrance extends StatefulWidget {
  const _PinEntrance({
    required this.staggerIndex,
    required this.child,
  });

  final int staggerIndex;
  final Widget child;

  @override
  State<_PinEntrance> createState() => _PinEntranceState();
}

class _PinEntranceState extends State<_PinEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1.0;
      return;
    }
    final delayMs = widget.staggerIndex.clamp(0, 8) * 28;
    if (delayMs == 0) {
      _controller.forward();
    } else {
      Future<void>.delayed(Duration(milliseconds: delayMs), () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.value == 1.0) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (_, child) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        return Opacity(
          opacity: t,
          child: Transform.scale(
            scale: 0.84 + (0.16 * t),
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        );
      },
    );
  }
}

class _FindMyPinShell extends StatelessWidget {
  const _FindMyPinShell({
    required this.label,
    required this.isSelected,
    required this.isHovered,
    required this.isLive,
    required this.isStale,
    required this.haloActive,
    required this.pulseNonce,
    required this.haloSize,
    required this.haloColor,
    required this.pitchDegrees,
    required this.staggerIndex,
    required this.diameter,
    required this.fillColor,
    required this.ringColor,
    required this.ringWidth,
    required this.child,
  });

  final String label;
  final bool isSelected;
  final bool isHovered;
  final bool isLive;
  final bool isStale;
  final bool haloActive;
  final int pulseNonce;
  final double haloSize;
  final Color haloColor;
  final double pitchDegrees;
  final int staggerIndex;
  final double diameter;
  final Color fillColor;
  final Color ringColor;
  final double ringWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final isDark = _isDarkTheme(context);
    final foreshorten = _groundForeshorten(pitchDegrees);
    final pitchT = _pitchNorm(pitchDegrees);
    final targetState = isSelected ? 1.0 : (isHovered ? 0.36 : 0.0);
    final showPill = isSelected || isHovered;
    final stemHeight = 5.5 + (4.5 * pitchT) + (isSelected ? 4.0 : (isHovered ? 1.5 : 0.0));
    const anchorDotDiameter = 7.5;
    const boxWidth = 96.0;
    const boxHeight = 76.0;

    return Semantics(
      label: label,
      selected: isSelected,
      excludeSemantics: true,
      child: _PinEntrance(
        staggerIndex: staggerIndex,
        child: SizedBox(
          width: boxWidth,
          height: boxHeight,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: targetState),
            duration: disableAnimations ? Duration.zero : const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            builder: (context, animT, _) {
              final selectT = isSelected ? animT : (animT / 0.36).clamp(0.0, 1.0) * 0.0;
              final medallionScale = 1.0 + (0.14 * animT);
              final liftY = -(7.0 * animT);
              final shadowWidth = (22.0 + (9.0 * pitchT)) * (1.0 + (0.22 * animT));
              final shadowHeight = shadowWidth * foreshorten * 0.56;
              final shadowAlpha = (0.26 + (0.10 * pitchT) + (0.10 * animT)).clamp(0.0, 0.52);

              return Stack(
                alignment: Alignment.bottomCenter,
                clipBehavior: Clip.none,
                children: [
                  // Ground-plane live/locating pulse ripple centered on the anchor coordinate.
                  Positioned(
                    bottom: -(haloSize / 2) + (anchorDotDiameter / 2),
                    child: FindMyPulsingHalo(
                      active: haloActive,
                      pulseNonce: pulseNonce,
                      size: haloSize,
                      color: haloColor,
                      pitchDegrees: pitchDegrees,
                    ),
                  ),
                  // Soft elliptical ground contact shadow widening/softening with pitch & selection.
                  Positioned(
                    bottom: (anchorDotDiameter / 2) - (shadowHeight / 2),
                    child: IgnorePointer(
                      child: Container(
                        width: shadowWidth,
                        height: shadowHeight,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.all(Radius.elliptical(shadowWidth, shadowHeight)),
                          gradient: RadialGradient(
                            colors: [
                              Colors.black.withValues(alpha: shadowAlpha),
                              Colors.black.withValues(alpha: shadowAlpha * 0.35),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.55, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Precision rimmed ground anchor dot at exact bottom-center coordinate.
                  Positioned(
                    bottom: 0,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(1.0, foreshorten.clamp(0.6, 1.0), 1.0),
                      child: Container(
                        width: anchorDotDiameter,
                        height: anchorDotDiameter,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isLive ? _kLiveEmerald : ringColor,
                          border: Border.all(
                            color: isDark ? const Color(0xFF141820) : Colors.white,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Slim stem + sculpted medallion head with smooth lift & scale.
                  Positioned(
                    bottom: anchorDotDiameter * 0.55,
                    child: Transform.translate(
                      offset: Offset(0, liftY),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Transform.scale(
                            scale: medallionScale,
                            alignment: Alignment.bottomCenter,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Container(
                                  width: diameter,
                                  height: diameter,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: fillColor,
                                    border: Border.all(color: ringColor, width: ringWidth),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.24 + (0.14 * selectT)),
                                        blurRadius: 8 + (5 * animT),
                                        offset: Offset(0, 3 + (2 * pitchT)),
                                      ),
                                    ],
                                  ),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isDark
                                            ? Colors.white.withValues(alpha: 0.14)
                                            : Colors.black.withValues(alpha: 0.08),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: child,
                                  ),
                                ),
                                if (isStale)
                                  Positioned(
                                    top: -1,
                                    right: -1,
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: _kStaleAmber,
                                        border: Border.all(
                                          color: isDark ? const Color(0xFF141820) : Colors.white,
                                          width: 1.5,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Slim stem connecting medallion to ground anchor.
                          Container(
                            width: isSelected ? 3.2 : 2.6,
                            height: stemHeight,
                            decoration: BoxDecoration(
                              color: ringColor,
                              borderRadius: BorderRadius.circular(2),
                              border: Border.all(
                                color: isDark
                                    ? Colors.black.withValues(alpha: 0.35)
                                    : Colors.black.withValues(alpha: 0.12),
                                width: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Clean non-clipping high-contrast pill label beneath anchor when selected or hovered.
                  if (showPill && label.trim().isNotEmpty)
                    Positioned(
                      top: boxHeight + 5,
                      child: IgnorePointer(
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 148),
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xE8181C22) : const Color(0xF5FFFFFF),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: isSelected
                                  ? ringColor.withValues(alpha: 0.85)
                                  : (isDark
                                      ? Colors.white.withValues(alpha: 0.18)
                                      : Colors.black.withValues(alpha: 0.12)),
                              width: isSelected ? 1.2 : 0.8,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.18),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                              letterSpacing: -0.1,
                              color: isDark ? Colors.white : const Color(0xFF111827),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
