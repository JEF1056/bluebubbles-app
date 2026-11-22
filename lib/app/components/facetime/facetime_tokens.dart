import 'dart:typed_data';

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

/// High-contrast, violet-free GM3 Dialer/Meet palette tokens for FaceTime calling surfaces.
abstract final class FaceTimePalette {
  static const Color blue = Color(0xFF0B57D0);
  static const Color blueDark = Color(0xFFA8C7FA);
  static const Color green = Color(0xFF34A853);
  static const Color answerIcon = Color(0xFF00C853);
  static const Color red = Color(0xFFD93025);
  static const Color redDarkSkin = Color(0xFFEE675C);
  static const Color darkCanvas = Color(0xFF131314);
  static const Color darkSurface = Color(0xFF1E1F20);
  static const Color darkElevated = Color(0xFF282A2C);
  static const Color darkHighest = Color(0xFF333537);
  static const Color onCanvas = Color(0xFFF1F3F4);
  static const Color secondaryText = Color(0xFFC4C7C5);
  static const Color overlay = Color(0x99000000);
  static const Color amber = Color(0xFFF59E0B);
  static const Color videoToggleOffBg = Color(0x4DFFFFFF);
  static const Color videoToggleOffStroke = Color(0x59FFFFFF);
  static const Color hairline = Color(0x1FFFFFFF);
}

/// GM3 GoogleDialer / Meet dimensions and radii for FaceTime calling surfaces.
abstract final class FaceTimeDims {
  static const double endCallSize = 64.0;
  static const double endCallIconSize = 36.0;
  static const double endCallBottomMargin = 24.0;
  static const double videoEndCallBottomMargin = 36.0;

  static const double actionButtonSize = 48.0;
  static const double actionIconSize = 24.0;
  static const double actionLabelGap = 8.0;
  static const double actionVerticalPad = 8.0;

  static const double videoToggleSize = 60.0;
  static const double videoTogglePad = 12.0;

  static const double previewSize = 72.0;
  static const double previewRadius = 8.0;
  static const double previewBottomMargin = 24.0;

  static const double contactTopMargin = 24.0;
  static const double contactSideMargin = 24.0;

  static const double dialpadKeyHeight = 64.0;
  static const double dialpadMaxWidth = 480.0;
  static const double dialpadDigitSize = 36.0;
  static const double dialpadLettersSize = 12.0;
  static const double dialpadIncallLettersSize = 9.0;
  static const double dialpadDigitsFieldSize = 20.0;
  static const double dtmfOptionRadius = 16.0;
  static const double dtmfOptionStroke = 1.0;

  static const double ongoingPillRadius = 16.0;
  static const double estimatePillRadius = 20.0;
  static const double sheetTopRadius = 28.0;
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
        color: FaceTimePalette.darkElevated,
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
