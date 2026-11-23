import 'dart:math' as math;

import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:flutter/material.dart';

/// Snaps a floating PiP tile with [center] and [tile] size inside [area]
/// (deflated by [avoid] plus [FaceTimeDims.pipInset]) to the nearest of the
/// four safe corners, returning the snapped top-left [Offset].
Offset faceTimeSnapCorner(Offset center, Size area, Size tile, EdgeInsets avoid) {
  final inset = avoid + const EdgeInsets.all(FaceTimeDims.pipInset);
  final minX = inset.left;
  final minY = inset.top;
  final rawMaxX = area.width - inset.right - tile.width;
  final rawMaxY = area.height - inset.bottom - tile.height;

  final double leftX;
  final double rightX;
  if (rawMaxX < minX) {
    final fallbackX = ((area.width - tile.width) / 2).clamp(0.0, math.max(0.0, area.width - tile.width)).toDouble();
    leftX = fallbackX;
    rightX = fallbackX;
  } else {
    leftX = minX;
    rightX = rawMaxX;
  }

  final double topY;
  final double bottomY;
  if (rawMaxY < minY) {
    final fallbackY = ((area.height - tile.height) / 2).clamp(0.0, math.max(0.0, area.height - tile.height)).toDouble();
    topY = fallbackY;
    bottomY = fallbackY;
  } else {
    topY = minY;
    bottomY = rawMaxY;
  }

  final halfTile = Offset(tile.width / 2, tile.height / 2);
  final corners = <Offset>[
    Offset(leftX, topY),
    Offset(rightX, topY),
    Offset(leftX, bottomY),
    Offset(rightX, bottomY),
  ];

  var best = corners.first;
  var bestDistSq = ((best + halfTile) - center).distanceSquared;
  for (var i = 1; i < corners.length; i++) {
    final candidate = corners[i];
    final distSq = ((candidate + halfTile) - center).distanceSquared;
    if (distSq < bestDistSq) {
      bestDistSq = distSq;
      best = candidate;
    }
  }
  return best;
}

enum FaceTimeDockTone {
  neutral,
  mutedAlert,
  activePrimary,
  activeHighContrast,
}

class FaceTimeDockButton extends StatelessWidget {
  const FaceTimeDockButton({
    super.key,
    required this.icon,
    required this.label,
    this.engaged = false,
    this.enabled = true,
    this.dense = false,
    this.tone,
    this.showExpandCaret = false,
    this.width,
    this.height,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool engaged;
  final bool enabled;
  final bool dense;
  final FaceTimeDockTone? tone;
  final bool showExpandCaret;
  final double? width;
  final double? height;
  final VoidCallback? onPressed;

  (Color bg, Color fg) _resolveColors() {
    switch (tone) {
      case FaceTimeDockTone.neutral:
        return (FaceTimePalette.m3SurfaceContainerHighest, FaceTimePalette.m3OnSurface);
      case FaceTimeDockTone.mutedAlert:
        return (FaceTimePalette.m3MutedFill, FaceTimePalette.m3OnMutedFill);
      case FaceTimeDockTone.activePrimary:
        return (FaceTimePalette.m3Primary, FaceTimePalette.m3OnPrimary);
      case FaceTimeDockTone.activeHighContrast:
        return (FaceTimePalette.m3OnSurface, FaceTimePalette.m3SurfaceContainer);
      case null:
        return engaged
            ? (FaceTimePalette.engagedFill, FaceTimePalette.engagedIcon)
            : (FaceTimePalette.darkElevated, Colors.white);
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveHeight = height ?? (dense ? 40.0 : FaceTimeDims.dockButtonHeight);
    final effectiveWidth = width ?? FaceTimeDims.dockButtonMinWidth;
    final (bgColor, iconColor) = _resolveColors();
    final radiusValue = engaged
        ? FaceTimeDims.dockButtonMorphSelectedRadius
        : FaceTimeDims.dockContainerRadius;
    final radius = BorderRadius.circular(radiusValue);
    final reducedMotion = facetimeReducedMotionOf(context);
    final activeTap = enabled ? onPressed : null;
    final iconSize = dense ? 20.0 : FaceTimeDims.actionIconSize;

    Widget button = Semantics(
      button: true,
      enabled: enabled,
      toggled: engaged,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: _DockPressScale(
          enabled: activeTap != null,
          reducedMotion: reducedMotion,
          onTap: activeTap,
          borderRadius: radius,
          child: SizedBox(
            width: effectiveWidth,
            height: effectiveHeight,
            child: AnimatedContainer(
              duration: FaceTimeMotion.of(context, FaceTimeMotion.morph),
              curve: FaceTimeMotion.emphasized,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: radius,
              ),
              alignment: Alignment.center,
              child: showExpandCaret
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, color: iconColor, size: iconSize),
                        Transform.translate(
                          offset: const Offset(-4, 0),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: iconColor,
                            size: dense ? 14.0 : 16.0,
                          ),
                        ),
                      ],
                    )
                  : Icon(
                      icon,
                      color: iconColor,
                      size: iconSize,
                    ),
            ),
          ),
        ),
      ),
    );

    if (!enabled) {
      button = Opacity(opacity: 0.38, child: button);
    }
    return button;
  }
}

class FaceTimeEndCallPill extends StatelessWidget {
  const FaceTimeEndCallPill({
    super.key,
    required this.onPressed,
    this.wide = false,
    this.dense = false,
  });

  final VoidCallback onPressed;
  final bool wide;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final width = dense ? 56.0 : (wide ? FaceTimeDims.endPillWideWidth : FaceTimeDims.endPillWidth);
    final height = dense ? 40.0 : FaceTimeDims.dockButtonHeight;
    final radius = BorderRadius.circular(FaceTimeDims.dockRadius);
    final reducedMotion = facetimeReducedMotionOf(context);

    return Semantics(
      button: true,
      label: 'End call',
      excludeSemantics: true,
      child: Tooltip(
        message: 'End call',
        excludeFromSemantics: true,
        child: _DockPressScale(
          enabled: true,
          reducedMotion: reducedMotion,
          onTap: onPressed,
          borderRadius: radius,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: FaceTimePalette.red,
              borderRadius: radius,
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.call_end_rounded,
              color: Colors.white,
              size: FaceTimeDims.actionIconSize,
            ),
          ),
        ),
      ),
    );
  }
}

class FaceTimeControlDock extends StatelessWidget {
  const FaceTimeControlDock({
    super.key,
    required this.controls,
    required this.endCall,
    this.translucent = false,
    this.showDivider = true,
  });

  final List<Widget> controls;
  final Widget endCall;
  final bool translucent;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final bgColor = translucent
        ? FaceTimePalette.m3SurfaceContainer.withValues(alpha: 0.92)
        : FaceTimePalette.m3SurfaceContainer;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final maxWidth = viewportWidth < FaceTimeDims.compactBreak ? 410.0 : FaceTimeDims.dockMaxWidth;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(FaceTimeDims.dockContainerRadius),
          border: Border.all(color: FaceTimePalette.m3SurfaceVariant, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FaceTimeDims.dockPadH,
            vertical: 14.0,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < controls.length; i++) ...[
                if (i > 0) const SizedBox(width: FaceTimeDims.dockGap),
                Flexible(fit: FlexFit.loose, child: controls[i]),
              ],
              if (controls.isNotEmpty && showDivider) ...[
                const SizedBox(width: FaceTimeDims.dockGap),
                Container(
                  width: 1,
                  height: FaceTimeDims.dockDividerH,
                  color: FaceTimePalette.m3SurfaceVariant,
                ),
                const SizedBox(width: FaceTimeDims.dockGap),
              ] else if (controls.isNotEmpty) ...[
                const SizedBox(width: FaceTimeDims.dockGap),
              ],
              endCall,
            ],
          ),
        ),
      ),
    );
  }
}

class FaceTimeHeaderPill extends StatelessWidget {
  const FaceTimeHeaderPill({
    super.key,
    this.leading,
    this.avatar,
    required this.title,
    this.subtitle,
    this.kindLabel,
    this.handle,
    this.trailing = const [],
  });

  final Widget? leading;
  final Widget? avatar;
  final String title;
  final String? subtitle;
  final String? kindLabel;
  final String? handle;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    final hasKind = kindLabel != null && kindLabel!.trim().isNotEmpty;
    final hasHandle = handle != null && handle!.trim().isNotEmpty;
    final metaLine = [
      if (hasKind) kindLabel!.trim(),
      if (hasHandle) handle!.trim(),
    ].join(' · ');

    return Material(
      color: FaceTimePalette.darkSurface,
      borderRadius: BorderRadius.circular(FaceTimeDims.dockRadius),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: FaceTimeDims.headerHeight),
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: leading != null ? 4.0 : 12.0,
            end: trailing.isNotEmpty ? 4.0 : 16.0,
            top: 4.0,
            bottom: 4.0,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: FaceTimeDims.dockGap),
              ],
              if (avatar != null) ...[
                avatar!,
                const SizedBox(width: 8),
              ],
              Flexible(
                fit: FlexFit.loose,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: FaceTimeDims.headerTitleMaxWidth),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kDefaultAppFontFamily,
                          color: FaceTimePalette.onCanvas,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                        ),
                      ),
                      if (metaLine.isNotEmpty)
                        Text(
                          metaLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: kDefaultAppFontFamily,
                            color: FaceTimePalette.secondaryText,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 1.15,
                          ),
                        ),
                      if (hasSubtitle)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: kDefaultAppFontFamily,
                            color: FaceTimePalette.secondaryText,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            height: 1.2,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              for (final item in trailing) ...[
                const SizedBox(width: FaceTimeDims.dockGap),
                item,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class FaceTimeStatusText extends StatelessWidget {
  const FaceTimeStatusText(
    this.text, {
    super.key,
    this.duration,
    this.muted = false,
  });

  final String text;
  final String? duration;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final surfaceColor = Material.maybeOf(context)?.color;
    final isDarkSurface = surfaceColor != null
        ? ThemeData.estimateBrightnessForColor(surfaceColor) == Brightness.dark
        : Theme.of(context).brightness == Brightness.dark;
    final color = isDarkSurface ? FaceTimePalette.secondaryText : Theme.of(context).colorScheme.onSurfaceVariant;
    final display = (duration != null && duration!.isNotEmpty) ? '$text · $duration' : text;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (muted) ...[
          Icon(Icons.mic_off_rounded, size: 14, color: color),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: kDefaultAppFontFamily,
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _DockPressScale extends StatefulWidget {
  const _DockPressScale({
    required this.enabled,
    required this.reducedMotion,
    required this.onTap,
    required this.borderRadius,
    required this.child,
  });

  final bool enabled;
  final bool reducedMotion;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  State<_DockPressScale> createState() => _DockPressScaleState();
}

class _DockPressScaleState extends State<_DockPressScale> {
  static const Duration _pressDuration = Duration(milliseconds: 120);
  bool _pressed = false;

  void _setPressed(bool next) {
    if (_pressed == next || !mounted) return;
    setState(() => _pressed = next);
  }

  @override
  Widget build(BuildContext context) {
    final scale = (!widget.enabled || widget.reducedMotion || !_pressed) ? 1.0 : 0.96;
    return AnimatedScale(
      scale: scale,
      duration: widget.reducedMotion ? Duration.zero : _pressDuration,
      curve: FaceTimeMotion.emphasized,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: widget.borderRadius,
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
          onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
          onTapCancel: widget.enabled ? () => _setPressed(false) : null,
          borderRadius: widget.borderRadius,
          splashColor: Colors.white.withValues(alpha: 0.14),
          highlightColor: Colors.white.withValues(alpha: 0.08),
          child: widget.child,
        ),
      ),
    );
  }
}

class FaceTimePhoneControlItem {
  const FaceTimePhoneControlItem({
    this.key,
    required this.icon,
    required this.label,
    this.selected = false,
    this.enabled = true,
    this.showExpandCaret = false,
    this.semanticsLabel,
    this.onPressed,
  });

  final Key? key;
  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final bool showExpandCaret;
  final String? semanticsLabel;
  final VoidCallback? onPressed;
}

class FaceTimePhoneControlSheet extends StatelessWidget {
  const FaceTimePhoneControlSheet({
    super.key,
    required this.items,
    required this.onEndCall,
    this.compact,
    this.landscape,
    this.endCallLabel = 'End call',
  });

  final List<FaceTimePhoneControlItem> items;
  final VoidCallback onEndCall;
  final bool? compact;
  final bool? landscape;
  final String endCallLabel;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isCompact = compact ?? (size.height < 640 || size.width < 360);
    final isLandscape = landscape ?? (size.width > size.height && size.height < 540);
    final toggleHeight = isCompact ? 48.0 : FaceTimeDims.phoneToggleHeight;
    final endHeight = isCompact ? 56.0 : FaceTimeDims.phoneEndPillHeight;
    final iconSize = isCompact ? 24.0 : 32.0;
    final reducedMotion = facetimeReducedMotionOf(context);

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: FaceTimePalette.m3SurfaceContainer,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(FaceTimeDims.phoneSheetTopRadius),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          isCompact ? 12.0 : 24.0,
          16.0,
          isCompact ? 12.0 : 24.0,
          isCompact ? 16.0 : 28.0,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (items.isNotEmpty) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: _PhoneMorphButton(
                        item: items[i],
                        height: toggleHeight,
                        iconSize: iconSize,
                        reducedMotion: reducedMotion,
                      ),
                    ),
                  ],
                ],
              ),
              SizedBox(height: isCompact ? 12.0 : 16.0),
            ],
            Center(
              child: Semantics(
                button: true,
                label: endCallLabel,
                excludeSemantics: true,
                child: Tooltip(
                  message: endCallLabel,
                  excludeFromSemantics: true,
                  child: _DockPressScale(
                    enabled: true,
                    reducedMotion: reducedMotion,
                    onTap: onEndCall,
                    borderRadius: BorderRadius.circular(endHeight / 2),
                    child: Container(
                      width: isLandscape ? 192.0 : double.infinity,
                      height: endHeight,
                      decoration: BoxDecoration(
                        color: FaceTimePalette.m3EndCallRed,
                        borderRadius: BorderRadius.circular(endHeight / 2),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.call_end_rounded,
                        color: Colors.white,
                        size: isCompact ? 28.0 : 32.0,
                      ),
                    ),
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

class _PhoneMorphButton extends StatelessWidget {
  const _PhoneMorphButton({
    required this.item,
    required this.height,
    required this.iconSize,
    required this.reducedMotion,
  });

  final FaceTimePhoneControlItem item;
  final double height;
  final double iconSize;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    final radiusValue = item.selected ? height * 0.25 : height * 0.5;
    final radius = BorderRadius.circular(radiusValue);
    final bgColor = item.selected
        ? FaceTimePalette.m3OnSurface
        : FaceTimePalette.m3SurfaceContainerHighest;
    final fgColor = item.selected
        ? FaceTimePalette.m3SurfaceContainer
        : FaceTimePalette.m3OnSurface;
    final activeTap = item.enabled ? item.onPressed : null;

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DockPressScale(
          enabled: activeTap != null,
          reducedMotion: reducedMotion,
          onTap: activeTap,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: reducedMotion ? Duration.zero : FaceTimeMotion.morph,
            curve: FaceTimeMotion.emphasized,
            height: height,
            width: double.infinity,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: radius,
            ),
            alignment: Alignment.center,
            child: item.showExpandCaret
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(item.icon, color: fgColor, size: iconSize),
                      Transform.translate(
                        offset: const Offset(-4, 0),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: fgColor,
                          size: iconSize * 0.65,
                        ),
                      ),
                    ],
                  )
                : Icon(item.icon, color: fgColor, size: iconSize),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          item.label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: kDefaultAppFontFamily,
            color: FaceTimePalette.m3OnSurface,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            height: 1.2,
          ),
        ),
      ],
    );

    if (!item.enabled) {
      content = Opacity(opacity: 0.38, child: content);
    }

    return Semantics(
      key: item.key,
      button: true,
      enabled: item.enabled,
      toggled: item.selected,
      label: item.semanticsLabel ?? item.label,
      excludeSemantics: true,
      child: content,
    );
  }
}

class FaceTimeSwipeAnswerPill extends StatefulWidget {
  const FaceTimeSwipeAnswerPill({
    super.key,
    required this.onAccept,
    required this.onDecline,
    this.acceptLabel = 'Accept',
    this.declineLabel = 'Decline',
    this.enabled = true,
  });

  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final String acceptLabel;
  final String declineLabel;
  final bool enabled;

  @override
  State<FaceTimeSwipeAnswerPill> createState() => _FaceTimeSwipeAnswerPillState();
}

class _FaceTimeSwipeAnswerPillState extends State<FaceTimeSwipeAnswerPill>
    with TickerProviderStateMixin {
  late final AnimationController _shimmerController;
  late final AnimationController _springController;
  double _dragDx = 0.0;
  double _springStartDx = 0.0;
  bool _committed = false;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(() {
        if (!mounted) return;
        final t = FaceTimeMotion.emphasized.transform(_springController.value);
        setState(() {
          _dragDx = _springStartDx * (1.0 - t);
        });
      });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = facetimeReducedMotionOf(context);
    if (reducedMotion || !widget.enabled) {
      if (_shimmerController.isAnimating) {
        _shimmerController.stop();
      }
    } else if (!_shimmerController.isAnimating) {
      _shimmerController.repeat();
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    _springController.dispose();
    super.dispose();
  }

  void _springBack() {
    if (facetimeReducedMotionOf(context)) {
      setState(() => _dragDx = 0.0);
      return;
    }
    _springStartDx = _dragDx;
    _springController.forward(from: 0.0);
  }

  void _commitAccept() {
    if (_committed || !widget.enabled) return;
    _committed = true;
    setState(() => _dragDx = 0.0);
    widget.onAccept();
  }

  void _commitDecline() {
    if (_committed || !widget.enabled) return;
    _committed = true;
    setState(() => _dragDx = 0.0);
    widget.onDecline();
  }

  @override
  Widget build(BuildContext context) {
    final accessibleNav = MediaQuery.accessibleNavigationOf(context);
    final reducedMotion = facetimeReducedMotionOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (accessibleNav || constraints.maxWidth < 260) {
          return _buildDualPuckFallback(reducedMotion);
        }

        final trackWidth = math.min(
          constraints.maxWidth.isFinite ? constraints.maxWidth : FaceTimeDims.swipeTrackMaxWidth,
          FaceTimeDims.swipeTrackMaxWidth,
        );
        final trackHeight = MediaQuery.sizeOf(context).height < 640
            ? 72.0
            : FaceTimeDims.swipeTrackHeight;
        final puckPadding = trackHeight * 0.125;
        final puckSize = trackHeight - puckPadding * 2;
        final dragBound = math.max(1.0, (trackWidth - puckSize - 2 * puckPadding) / 2);
        final progress = (_dragDx / dragBound).clamp(-1.0, 1.0);
        final absProgress = progress.abs();
        final lerpFactor = ((absProgress - 0.30) / 0.20).clamp(0.0, 1.0);

        final targetColor = progress >= 0
            ? FaceTimePalette.m3AcceptGreen
            : FaceTimePalette.m3EndCallRed;
        final trackColor = Color.lerp(
          FaceTimePalette.m3SurfaceContainerHigh,
          targetColor,
          lerpFactor * 0.55,
        )!;
        final puckColor = Color.lerp(
          FaceTimePalette.m3OnSurface,
          targetColor,
          lerpFactor,
        )!;
        final puckIconColor = Color.lerp(
          FaceTimePalette.m3Surface,
          Colors.white,
          lerpFactor,
        )!;
        final iconAngle = progress < 0 ? lerpFactor * (135 * math.pi / 180) : 0.0;

        return Center(
          child: SizedBox(
            width: trackWidth,
            height: trackHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: widget.enabled
                  ? (_) {
                      _springController.stop();
                      _committed = false;
                    }
                  : null,
              onHorizontalDragUpdate: widget.enabled
                  ? (details) {
                      setState(() {
                        _dragDx = (_dragDx + details.delta.dx).clamp(-dragBound, dragBound);
                      });
                    }
                  : null,
              onHorizontalDragEnd: widget.enabled
                  ? (details) {
                      final vx = details.velocity.pixelsPerSecond.dx;
                      final currentProgress = (_dragDx / dragBound).clamp(-1.0, 1.0);
                      if (currentProgress >= 0.72 || vx >= 600) {
                        _commitAccept();
                      } else if (currentProgress <= -0.72 || vx <= -600) {
                        _commitDecline();
                      } else {
                        _springBack();
                      }
                    }
                  : null,
              onHorizontalDragCancel: widget.enabled ? _springBack : null,
              child: Container(
                decoration: BoxDecoration(
                  color: trackColor,
                  borderRadius: BorderRadius.circular(trackHeight / 2),
                  border: Border.all(color: FaceTimePalette.m3SurfaceVariant, width: 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (!reducedMotion)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _shimmerController,
                            builder: (context, _) {
                              final sweep = _shimmerController.value * 2.5 - 1.25;
                              return DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment(sweep - 0.35, 0),
                                    end: Alignment(sweep + 0.35, 0),
                                    colors: [
                                      Colors.white.withValues(alpha: 0.0),
                                      Colors.white.withValues(alpha: 0.08),
                                      Colors.white.withValues(alpha: 0.0),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildEndpointTapTarget(
                          label: widget.declineLabel,
                          color: FaceTimePalette.m3MutedFill,
                          onTap: widget.enabled ? _commitDecline : null,
                          alignment: Alignment.centerLeft,
                          padding: EdgeInsets.only(left: puckPadding + 8),
                        ),
                        _buildEndpointTapTarget(
                          label: widget.acceptLabel,
                          color: FaceTimePalette.m3OnSurface,
                          onTap: widget.enabled ? _commitAccept : null,
                          alignment: Alignment.centerRight,
                          padding: EdgeInsets.only(right: puckPadding + 8),
                        ),
                      ],
                    ),
                    Transform.translate(
                      offset: Offset(_dragDx, 0),
                      child: Container(
                        width: puckSize,
                        height: puckSize,
                        decoration: BoxDecoration(
                          color: puckColor,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Transform.rotate(
                          angle: iconAngle,
                          child: Icon(
                            Icons.call_rounded,
                            color: puckIconColor,
                            size: puckSize * 0.45,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEndpointTapTarget({
    required String label,
    required Color color,
    required VoidCallback? onTap,
    required Alignment alignment,
    required EdgeInsets padding,
  }) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(48),
        child: Container(
          constraints: const BoxConstraints(minWidth: 72, minHeight: 48),
          padding: padding,
          alignment: alignment,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: kDefaultAppFontFamily,
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDualPuckFallback(bool reducedMotion) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildFallbackPuck(
          label: widget.declineLabel,
          icon: Icons.call_end_rounded,
          color: FaceTimePalette.m3EndCallRed,
          onTap: widget.enabled ? _commitDecline : null,
          reducedMotion: reducedMotion,
        ),
        const SizedBox(width: FaceTimeDims.puckGap),
        _buildFallbackPuck(
          label: widget.acceptLabel,
          icon: Icons.call_rounded,
          color: FaceTimePalette.m3AcceptGreen,
          onTap: widget.enabled ? _commitAccept : null,
          reducedMotion: reducedMotion,
        ),
      ],
    );
  }

  Widget _buildFallbackPuck({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
    required bool reducedMotion,
  }) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: _DockPressScale(
          enabled: onTap != null,
          reducedMotion: reducedMotion,
          onTap: onTap,
          borderRadius: BorderRadius.circular(FaceTimeDims.puckSize / 2),
          child: Container(
            width: FaceTimeDims.puckSize,
            height: FaceTimeDims.puckSize,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              color: Colors.white,
              size: FaceTimeDims.puckIcon,
            ),
          ),
        ),
      ),
    );
  }
}
