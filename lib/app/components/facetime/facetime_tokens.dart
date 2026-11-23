import 'dart:typed_data';

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
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

  static const Color accept = Color(0xFF1D873B);
  static const Color decline = Color(0xFFD93E36);
  static const Color engagedFill = Colors.white;
  static const Color engagedIcon = Color(0xFF5F6368);
  static const Color speakerOutline = Color(0xFF0842A0);
  static const Color scrim = Color(0x99000000);

  // Google Meet / Google Phone M3E dark palette tokens.
  static const Color m3Surface = Color(0xFF131314);
  static const Color m3SurfaceContainer = Color(0xFF1E1F20);
  static const Color m3SurfaceContainerHigh = Color(0xFF282A2C);
  static const Color m3SurfaceContainerHighest = Color(0xFF333537);
  static const Color m3SurfaceVariant = Color(0xFF444746);
  static const Color m3OnSurface = Color(0xFFE3E3E3);
  static const Color m3OnSurfaceVariant = Color(0xFFC4C7C5);
  static const Color m3Primary = Color(0xFFA8C7FA);
  static const Color m3OnPrimary = Color(0xFF062E6F);
  static const Color m3MutedFill = Color(0xFFF2B8B5);
  static const Color m3OnMutedFill = Color(0xFF601410);
  static const Color m3EndCallRed = Color(0xFFD93025);
  static const Color m3AcceptGreen = Color(0xFF137333);
  static const Color m3Scrim = Color(0x99000000);
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

  static const double dockRadius = 24.0;
  static const double dockMaxWidth = 600.0;
  static const double dockButtonHeight = 48.0;
  static const double dockButtonMinWidth = 48.0;
  static const double dockButtonMaxWidth = 64.0;
  static const double dockGap = 8.0;
  static const double dockPadH = 12.0;
  static const double dockPadV = 12.0;
  static const double dockMargin = 16.0;
  static const double dockDividerH = 20.0;
  static const double endPillWidth = 72.0;
  static const double endPillWideWidth = 96.0;

  static const double headerHeight = 48.0;
  static const double headerTitleMaxWidth = 200.0;

  static const double pipMin = 88.0;
  static const double pipMax = 156.0;
  static const double pipWebMax = 240.0;
  static const double pipRadius = 12.0;
  static const double pipInset = 12.0;

  static const double puckSize = 72.0;
  static const double puckIcon = 36.0;
  static const double puckGap = 32.0;
  static const double puckGapWide = 40.0;

  static const double tileRadius = 12.0;
  static const double compactBreak = 600.0;
  static const double expandedBreak = 840.0;

  // Google Meet / Google Phone M3E dimensions and radii.
  static const double dockContainerRadius = 24.0;
  static const double dockButtonMorphSelectedRadius = 16.0;
  static const double phoneSheetTopRadius = 32.0;
  static const double phoneToggleHeight = 68.0;
  static const double phoneEndPillHeight = 72.0;
  static const double pipCornerRadius = 24.0;
  static const double pipActionButtonSize = 32.0;
  static const double pipActionIconSize = 18.0;
  static const double swipeTrackHeight = 96.0;
  static const double swipeTrackMaxWidth = 344.0;
}

/// Shared motion tokens for FaceTime calling surfaces.
abstract final class FaceTimeMotion {
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Duration short = Duration(milliseconds: 200);
  static const Duration morph = Duration(milliseconds: 250);
  static const Duration medium = Duration(milliseconds: 300);
  static const Duration chromeFade = Duration(milliseconds: 300);
  static const Duration ring = Duration(milliseconds: 2000);
  static const Duration autoHide = Duration(seconds: 4);

  static Duration of(BuildContext context, Duration duration) =>
      facetimeReducedMotionOf(context) ? Duration.zero : duration;
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

class FaceTimeGroupedAvatar extends StatelessWidget {
  const FaceTimeGroupedAvatar({
    super.key,
    required this.participants,
    this.size = 56,
    this.borderColor,
  });

  final List<CallParticipant> participants;
  final double size;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    if (participants.length <= 1) {
      final first = participants.isEmpty ? null : participants.first;
      return FaceTimeAvatar(
        callerName: first?.label ?? '',
        avatarBytes: first?.avatarBytes,
        size: size,
        borderColor: borderColor,
        borderWidth: borderColor != null ? 1.5 : 0,
      );
    }

    final sorted = List<CallParticipant>.from(participants)
      ..sort((a, b) {
        final hasA = a.avatarBytes != null && a.avatarBytes!.isNotEmpty;
        final hasB = b.avatarBytes != null && b.avatarBytes!.isNotEmpty;
        if (hasA != hasB) return hasA ? -1 : 1;
        return 0;
      });
    final shown = sorted.take(3).toList(growable: false);
    final count = shown.length;
    final itemSize = size * (count == 2 ? 0.72 : 0.64);
    final step = itemSize * 0.62;
    final totalWidth = itemSize + step * (count - 1);
    final strokeColor = borderColor ?? FaceTimePalette.darkCanvas;

    return SizedBox(
      width: totalWidth,
      height: size,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          for (var i = 0; i < count; i++)
            Positioned(
              left: i * step,
              child: FaceTimeAvatar(
                callerName: shown[i].label,
                avatarBytes: shown[i].avatarBytes,
                size: itemSize,
                borderColor: strokeColor,
                borderWidth: 2,
              ),
            ),
        ],
      ),
    );
  }
}

class FaceTimeParticipantChips extends StatelessWidget {
  const FaceTimeParticipantChips({
    super.key,
    required this.participants,
  });

  final List<CallParticipant> participants;

  @override
  Widget build(BuildContext context) {
    if (participants.length <= 1) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        for (final p in participants)
          Container(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 3, 10, 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FaceTimeAvatar(
                  callerName: p.label,
                  avatarBytes: p.avatarBytes,
                  size: 20,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    p.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kDefaultAppFontFamily,
                      color: FaceTimePalette.onCanvas,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
