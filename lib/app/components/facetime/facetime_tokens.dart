import 'dart:typed_data';

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

/// High-contrast, violet-free palette tokens for FaceTime calling surfaces.
abstract final class FaceTimePalette {
  static const Color blue = Color(0xFF147EFB);
  static const Color green = Color(0xFF22C55E);
  static const Color red = Color(0xFFEA4335);
  static const Color darkCanvas = Color(0xFF0B0F14);
  static const Color darkSurface = Color(0xFF141B24);
  static const Color darkElevated = Color(0xFF1D2633);
  static const Color amber = Color(0xFFF59E0B);
}

bool facetimeReducedMotionOf(BuildContext context) {
  return MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

bool facetimeIsIOSSkin() {
  if (!GetIt.I.isRegistered<SettingsService>()) return false;
  return SettingsSvc.settings.skin.value == Skins.iOS;
}

String facetimeInitialsFor(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  if (parts.length == 1) {
    final first = parts.first;
    // Avoid showing punctuation-only initials for raw phone numbers.
    final cleaned = first.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (cleaned.isEmpty) return '';
    return cleaned.substring(0, 1).toUpperCase();
  }
  return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'.toUpperCase();
}

/// Renders a circular caller avatar from raw [avatarBytes], a [Chat] handle when
/// services are registered, or a clean monogram/person fallback.
class FaceTimeAvatar extends StatelessWidget {
  const FaceTimeAvatar({
    super.key,
    required this.callerName,
    this.avatarBytes,
    this.handle,
    this.size = 56,
    this.borderColor,
    this.borderWidth = 0,
  });

  final String callerName;
  final Uint8List? avatarBytes;
  final Handle? handle;
  final double size;
  final Color? borderColor;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    Widget inner;
    if (avatarBytes != null && avatarBytes!.isNotEmpty) {
      inner = Image.memory(
        avatarBytes!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _fallbackCircle(),
      );
    } else if (handle != null &&
        GetIt.I.isRegistered<SettingsService>() &&
        GetIt.I.isRegistered<ContactServiceV2>() &&
        GetIt.I.isRegistered<ThemesService>()) {
      inner = ContactAvatarWidget(
        handle: handle,
        size: size,
        editable: false,
        scaleSize: false,
      );
    } else {
      inner = _fallbackCircle();
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: borderWidth > 0 && borderColor != null
            ? Border.all(color: borderColor!, width: borderWidth)
            : null,
      ),
      child: ClipOval(child: SizedBox(width: size, height: size, child: inner)),
    );
  }

  Widget _fallbackCircle() {
    final initials = facetimeInitialsFor(callerName);
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E3A5F), FaceTimePalette.darkElevated],
        ),
      ),
      child: Center(
        child: initials.isNotEmpty
            ? Text(
                initials,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.36,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  height: 1.0,
                ),
              )
            : Icon(
                Icons.person_rounded,
                color: Colors.white.withValues(alpha: 0.88),
                size: size * 0.48,
              ),
      ),
    );
  }
}
