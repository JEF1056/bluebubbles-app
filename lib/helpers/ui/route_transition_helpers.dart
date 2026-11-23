import 'dart:ui';

import 'package:flutter/widgets.dart';

bool _isRouteAnimationActive(Animation<double>? anim) {
  if (anim == null) return false;
  return anim.status == AnimationStatus.forward || anim.status == AnimationStatus.reverse;
}

/// Runs [action] once the enclosing [ModalRoute]'s push animation has settled
/// (`AnimationStatus.completed`), or right after the current frame if no active
/// route transition is running (e.g., instant tablet swaps or direct mounts).
///
/// Safe to invoke from `initState`; returns a cancel callback for `dispose()`.
VoidCallback runAfterRouteTransition(BuildContext context, VoidCallback action) {
  var cancelled = false;
  Animation<double>? trackedAnim;
  AnimationStatusListener? statusListener;

  void cleanup() {
    if (trackedAnim != null && statusListener != null) {
      trackedAnim!.removeStatusListener(statusListener!);
    }
    trackedAnim = null;
    statusListener = null;
  }

  void cancel() {
    cancelled = true;
    cleanup();
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (cancelled || !context.mounted) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.status == AnimationStatus.completed) {
      action();
      return;
    }
    if (anim.status == AnimationStatus.dismissed) return;
    trackedAnim = anim;
    statusListener = (status) {
      if (cancelled) {
        cleanup();
        return;
      }
      if (status == AnimationStatus.completed) {
        cleanup();
        if (context.mounted) action();
      } else if (status == AnimationStatus.dismissed) {
        cleanup();
      }
    };
    anim.addStatusListener(statusListener!);
  });

  return cancel;
}

/// Renders a [BackdropFilter] only when [enabled] is true and the enclosing
/// [ModalRoute] is at rest (not pushing, popping, or under an active back-swipe
/// gesture), avoiding per-frame full-surface blur readbacks during navigation.
class RouteSettledBackdropFilter extends StatefulWidget {
  final ImageFilter filter;
  final Widget child;
  final bool enabled;
  final BlendMode blendMode;

  const RouteSettledBackdropFilter({
    super.key,
    required this.filter,
    required this.child,
    this.enabled = true,
    this.blendMode = BlendMode.srcOver,
  });

  @override
  State<RouteSettledBackdropFilter> createState() => _RouteSettledBackdropFilterState();
}

class _RouteSettledBackdropFilterState extends State<RouteSettledBackdropFilter> {
  Animation<double>? _primaryAnim;
  Animation<double>? _secondaryAnim;
  ValueNotifier<bool>? _gestureNotifier;
  bool _animating = false;

  bool get _currentlyAnimating =>
      _isRouteAnimationActive(_primaryAnim) ||
      _isRouteAnimationActive(_secondaryAnim) ||
      (_gestureNotifier?.value ?? false);

  void _handleTransitionStateChanged([AnimationStatus? _]) {
    final next = _currentlyAnimating;
    if (next != _animating && mounted) {
      setState(() => _animating = next);
    }
  }

  void _detachListeners() {
    _primaryAnim?.removeStatusListener(_handleTransitionStateChanged);
    _secondaryAnim?.removeStatusListener(_handleTransitionStateChanged);
    _gestureNotifier?.removeListener(_handleTransitionStateChanged);
    _primaryAnim = null;
    _secondaryAnim = null;
    _gestureNotifier = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final nextPrimary = route?.animation;
    final nextSecondary = route?.secondaryAnimation;
    final nextGesture = Navigator.maybeOf(context)?.userGestureInProgressNotifier;

    if (nextPrimary == _primaryAnim && nextSecondary == _secondaryAnim && nextGesture == _gestureNotifier) {
      return;
    }

    _detachListeners();
    _primaryAnim = nextPrimary;
    _secondaryAnim = nextSecondary;
    _gestureNotifier = nextGesture;

    _primaryAnim?.addStatusListener(_handleTransitionStateChanged);
    _secondaryAnim?.addStatusListener(_handleTransitionStateChanged);
    _gestureNotifier?.addListener(_handleTransitionStateChanged);
    _animating = _currentlyAnimating;
  }

  @override
  void dispose() {
    _detachListeners();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep a constant BackdropFilter node so toggling blur during route
    // transitions never unmounts/remounts stateful child subtrees.
    return BackdropFilter(
      enabled: widget.enabled && !_animating,
      filter: widget.filter,
      blendMode: widget.blendMode,
      child: widget.child,
    );
  }
}
