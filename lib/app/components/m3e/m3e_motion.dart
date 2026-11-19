import 'package:flutter/material.dart';

class M3EMotionSpec {
  final Duration duration;
  final Curve curve;

  const M3EMotionSpec(this.duration, this.curve);
}

extension M3EMotionX on M3EMotionSpec {
  /// Convenience for driving an [AnimatedContainer] / [AnimatedSwitcher] with this spec.
  Widget container({
    required Widget child,
    Color? color,
    BoxDecoration? decoration,
    BorderRadius? borderRadius,
    EdgeInsetsGeometry? padding,
    double? width,
    double? height,
  }) {
    return AnimatedContainer(
      duration: duration,
      curve: curve,
      color: decoration == null ? color : null,
      decoration: decoration ?? (borderRadius != null ? BoxDecoration(borderRadius: borderRadius) : null),
      padding: padding,
      width: width,
      height: height,
      child: child,
    );
  }
}

/// Wraps the Material motion tokens from `material/motion.dart` (`Durations.*` / `Easing.*`)
/// into the small set of specs this app's M3E surfaces use.
abstract final class M3EMotion {
  // Spatial — anything that moves or resizes.
  static const spatialFast = M3EMotionSpec(Durations.short4, Easing.emphasizedDecelerate);
  static const spatialDefault = M3EMotionSpec(Durations.medium2, emphasized);
  static const spatialSlow = M3EMotionSpec(Durations.long2, emphasized);

  // Effects — color, opacity, elevation. No overshoot.
  static const effectsFast = M3EMotionSpec(Durations.short3, Easing.standard);
  static const effectsDefault = M3EMotionSpec(Durations.medium1, Easing.standard);

  // Physics — M3E dimensionless springs (damping ratio + stiffness) for SpringSimulation.
  static final SpringDescription springSpatialFast =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 800, ratio: 0.6);
  static final SpringDescription springSpatialDefault =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 380, ratio: 0.8);
  static final SpringDescription springSpatialSlow =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 200, ratio: 0.8);

  static final SpringDescription springEffectsFast =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 3800, ratio: 1.0);
  static final SpringDescription springEffectsDefault =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 1600, ratio: 1.0);
  static final SpringDescription springEffectsSlow =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 800, ratio: 1.0);

  static final SpringDescription springFast = springSpatialFast;
  static final SpringDescription springDefault = springSpatialDefault;
  static final SpringDescription springSlow = springSpatialSlow;

  /// M3E expressive spatial overshoot curve (`expressive_spatial_interpolator.xml`).
  static const Curve spatialOvershoot = Cubic(0.38, 1.21, 0.22, 1.0);

  /// The Material 3 "emphasized" easing curve. The Flutter SDK pinned by this repo (3.44.6)
  /// only ships the accelerate/decelerate halves (`Easing.emphasizedAccelerate` /
  /// `Easing.emphasizedDecelerate`) — this joins them at the M3 spec midpoint.
  static const Curve emphasized = ThreePointCubic(
    Offset(0.05, 0),
    Offset(0.133333, 0.06),
    Offset(0.166666, 0.4),
    Offset(0.208333, 0.82),
    Offset(0.25, 1),
  );
}
