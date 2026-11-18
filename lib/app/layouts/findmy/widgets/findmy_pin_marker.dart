import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

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

/// Animated pulsing halo ring rendered behind live pins and detail-sheet avatars.
/// Pulses continuously while [active] and triggers an extra ripple burst when [pulseNonce] changes.
class FindMyPulsingHalo extends StatefulWidget {
  const FindMyPulsingHalo({
    super.key,
    required this.active,
    this.pulseNonce = 0,
    this.size = 64,
    this.color = const Color(0xFF22C55E),
  });

  final bool active;
  final int pulseNonce;
  final double size;
  final Color color;

  @override
  State<FindMyPulsingHalo> createState() => _FindMyPulsingHaloState();
}

class _FindMyPulsingHaloState extends State<FindMyPulsingHalo> with TickerProviderStateMixin {
  late final AnimationController _loopController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1650),
  );
  late final AnimationController _burstController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _loopController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant FindMyPulsingHalo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_loopController.isAnimating) {
      _loopController.repeat();
    } else if (!widget.active && _loopController.isAnimating) {
      _loopController.stop();
      _loopController.reset();
    }
    if (widget.pulseNonce != oldWidget.pulseNonce && widget.pulseNonce > 0) {
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
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.active)
            AnimatedBuilder(
              animation: _loopController,
              builder: (context, _) {
                final t = Curves.easeOut.transform(_loopController.value);
                final scale = 0.62 + (0.48 * t);
                final alpha = (1.0 - t) * 0.42;
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color.withValues(alpha: alpha * 0.45),
                      border: Border.all(
                        color: widget.color.withValues(alpha: alpha),
                        width: 2,
                      ),
                    ),
                  ),
                );
              },
            ),
          AnimatedBuilder(
            animation: _burstController,
            builder: (context, _) {
              if (!_burstController.isAnimating) return const SizedBox.shrink();
              final t = Curves.easeOutCubic.transform(_burstController.value);
              final scale = 0.65 + (0.55 * t);
              final alpha = (1.0 - t) * 0.7;
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: widget.color.withValues(alpha: alpha),
                      width: 2.5,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
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
  )..repeat(reverse: true);

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
/// Observes selection, freshness, and live-update pulse directly so markers animate smoothly without rebuild jank.
class FindMyFriendMarker extends StatelessWidget {
  const FindMyFriendMarker({
    super.key,
    required this.controller,
    required this.friend,
    this.avatarHandle,
  });

  final FindMyController controller;
  final FindMyFriend friend;
  final Handle? avatarHandle;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final _ = controller.freshnessTick.value;
      if (GetIt.I.isRegistered<ContactServiceV2>()) {
        ContactsSvcV2.cacheVersion.value;
      }
      final pulseNonce = controller.livePulseNonce.value;
      final isSelected = controller.selectedFriendId.value == friend.stableId;
      final current = controller.friends.firstWhereOrNull((f) => f.stableId == friend.stableId) ?? friend;
      final now = controller.currentTime;
      final isLive = current.isLiveFresh(now);
      final isLocating = current.locatingInProgress ||
          (current.stableId != null && controller.locatingFriendId.value == current.stableId);
      final cs = context.theme.colorScheme;
      const liveGreen = Color(0xFF22C55E);
      final ringColor = isLive ? liveGreen : (isSelected ? cs.primary : Colors.white);
      final label = shouldRedactFindMyContactInfo() ? 'Friend' : current.resolveDisplayName();

      return Semantics(
        label: label,
        selected: isSelected,
        excludeSemantics: true,
        child: SizedBox(
          width: 84,
          height: 84,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              FindMyPulsingHalo(
                active: isLive || isLocating,
                pulseNonce: pulseNonce,
                size: isSelected ? 78 : 60,
                color: isLive ? liveGreen : cs.primary,
              ),
              AnimatedScale(
                scale: isSelected ? 1.32 : 1.0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: cs.surface,
                        border: Border.all(
                          color: ringColor,
                          width: isSelected ? 2.6 : (isLive ? 2.4 : 2.0),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isSelected ? 0.36 : 0.24),
                            blurRadius: isSelected ? 10 : 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: FindMyFriendAvatar(
                          handle: avatarHandle,
                          displayName: label,
                          size: 36,
                        ),
                      ),
                    ),
                    if (isSelected)
                      Transform.translate(
                        offset: const Offset(0, -1),
                        child: _PinPointerTriangle(color: ringColor),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// Interactive map pin for a FindMy device or AirTag/item.
class FindMyDeviceMarker extends StatelessWidget {
  const FindMyDeviceMarker({
    super.key,
    required this.controller,
    required this.device,
  });

  final FindMyController controller;
  final FindMyDevice device;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final _ = controller.freshnessTick.value;
      final pulseNonce = controller.livePulseNonce.value;
      final current = controller.devices.firstWhereOrNull((d) => d.id == device.id) ?? device;
      final isSelected = controller.selectedDeviceId.value == device.id;
      final isLive = current.isLiveFresh(controller.currentTime);
      final isLocating = current.isLocatingInProgress;
      final cs = context.theme.colorScheme;
      const liveGreen = Color(0xFF22C55E);
      final ringColor = isSelected
          ? Colors.white.withValues(alpha: 0.92)
          : (isLive ? liveGreen : Colors.white.withValues(alpha: 0.34));
      final label = shouldRedactFindMyContactInfo()
          ? (current.isConsideredAccessory ? 'Item' : 'Device')
          : (current.name ?? 'Device');

      return Semantics(
        label: label,
        selected: isSelected,
        excludeSemantics: true,
        child: SizedBox(
          width: 84,
          height: 84,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              FindMyPulsingHalo(
                active: isLive || isLocating,
                pulseNonce: pulseNonce,
                size: isSelected ? 76 : 58,
                color: isLive ? liveGreen : cs.primary,
              ),
              AnimatedScale(
                scale: isSelected ? 1.35 : 1.0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF2C2C2E),
                        border: Border.all(
                          color: ringColor,
                          width: isSelected ? 2.2 : 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isSelected ? 0.38 : 0.28),
                            blurRadius: isSelected ? 10 : 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Center(
                        child: (current.role?['emoji'] != null && !shouldRedactFindMyContactInfo())
                            ? Text(
                                current.role!['emoji'].toString(),
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 17),
                              )
                            : Icon(
                                iconForFindMyDevice(current),
                                color: Colors.white,
                                size: 19,
                              ),
                      ),
                    ),
                    if (isSelected)
                      Transform.translate(
                        offset: const Offset(0, -1),
                        child: _PinPointerTriangle(color: ringColor),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _PinPointerTriangle extends StatelessWidget {
  const _PinPointerTriangle({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(12, 7),
      painter: _PinPointerPainter(color: color),
    );
  }
}

class _PinPointerPainter extends CustomPainter {
  const _PinPointerPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _PinPointerPainter oldDelegate) => oldDelegate.color != color;
}
