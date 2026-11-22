import 'dart:ui';

import 'package:flutter/widgets.dart';

/// Returns [Duration.zero] when the platform prefers reduced motion.
Duration motionDuration(BuildContext context, Duration duration) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

/// Softly cross-fades between keyed [child] states with a transient blur that
/// disables its [ImageFiltered] layer once settled (`sigma < 0.01`) without
/// remounting the child subtree.
class BlurFadeSwitcher extends StatelessWidget {
  const BlurFadeSwitcher({
    super.key,
    required this.child,
    this.alignment = AlignmentDirectional.center,
    this.animateSize = false,
  });

  final Widget child;
  final AlignmentGeometry alignment;
  final bool animateSize;

  static const _duration = Duration(milliseconds: 200);
  static const _maxSigma = 3.0;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;

    final switcher = AnimatedSwitcher(
      duration: _duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        children: [
          ...previousChildren,
          ?currentChild,
        ],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, inner) {
            final sigma = (1.0 - animation.value) * _maxSigma;
            return ImageFiltered(
              enabled: sigma >= 0.01,
              imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: inner,
            );
          },
          child: child,
        ),
      ),
      child: child,
    );

    if (!animateSize) return switcher;
    return AnimatedSize(
      duration: _duration,
      curve: Curves.easeOutCubic,
      alignment: alignment,
      child: switcher,
    );
  }
}
