import 'dart:math' as math;

import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

const double _margin = 8;

/// Opens [builder]'s content as a desktop popover above [anchorContext] (a composer button), as tall as fits up to
/// [height]. Click outside or press Escape to dismiss. Completes when it closes. Its content can hide it for a while
/// ([ComposerPopoverScope]).
Future<void> showComposerPopover(
  BuildContext anchorContext,
  ConversationViewController controller, {
  required WidgetBuilder builder,
  double width = 380,
  double height = 460,
}) async {
  final navigator = Navigator.of(anchorContext, rootNavigator: true);
  final overlayBox = navigator.overlay!.context.findRenderObject() as RenderBox;
  final anchorBox = anchorContext.findRenderObject() as RenderBox?;
  final anchor = anchorBox == null || !anchorBox.attached
      ? Rect.fromLTWH(_margin, overlayBox.size.height - _margin, 0, 0)
      : anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox) & anchorBox.size;

  // A route on the root navigator doesn't carry the conversation's Theme the way showDialog does
  final themes = InheritedTheme.capture(from: anchorContext, to: navigator.context);
  final hidden = ValueNotifier(false);
  controller.showingOverlays = true;
  try {
    await navigator.push(_PopoverRoute(
      hidden: hidden,
      pageBuilder: (context, _, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: hidden,
          builder: (_, isHidden, child) => IgnorePointer(
            ignoring: isHidden,
            child: Opacity(opacity: isHidden ? 0 : 1, child: child),
          ),
          child: _AdaptiveComposerPopover(
            overlayBox: overlayBox,
            initialAnchor: anchor,
            controller: controller,
            maxWidth: width,
            maxHeight: height,
            child: ComposerPopoverScope(hidden: hidden, child: themes.wrap(Builder(builder: builder))),
          ),
        );
      },
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(curved),
            alignment: Alignment.bottomLeft,
            child: child,
          ),
        );
      },
    ));
  } finally {
    // `hidden` isn't disposed: the route still listens to it through its closing transition
    controller.showingOverlays = false;
  }
}

/// Lets a popover's content hide it without closing it: set [hidden] while a drag that started in it is over what's
/// underneath, and pop the route once the drag ends. Popping mid-drag would cancel the drag, since the navigator
/// cancels every pointer down when it navigates.
class ComposerPopoverScope extends InheritedWidget {
  const ComposerPopoverScope({super.key, required this.hidden, required super.child});

  /// While true the popover is invisible and lets every pointer through, its barrier included
  final ValueNotifier<bool> hidden;

  static ValueNotifier<bool>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ComposerPopoverScope>()?.hidden;

  @override
  bool updateShouldNotify(ComposerPopoverScope oldWidget) => oldWidget.hidden != hidden;
}

class _PopoverRoute extends RawDialogRoute<void> {
  _PopoverRoute({required this.hidden, required super.pageBuilder, required super.transitionBuilder})
    : super(
        barrierDismissible: true,
        barrierLabel: "Dismiss",
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 160),
      );

  final ValueListenable<bool> hidden;

  @override
  Widget buildModalBarrier() => ValueListenableBuilder<bool>(
    valueListenable: hidden,
    builder: (_, isHidden, child) => IgnorePointer(ignoring: isHidden, child: child),
    child: super.buildModalBarrier(),
  );
}

class _AdaptiveComposerPopover extends StatefulWidget {
  const _AdaptiveComposerPopover({
    required this.overlayBox,
    required this.initialAnchor,
    required this.controller,
    required this.maxWidth,
    required this.maxHeight,
    required this.child,
  });

  final RenderBox overlayBox;
  final Rect initialAnchor;
  final ConversationViewController controller;
  final double maxWidth;
  final double maxHeight;
  final Widget child;

  @override
  State<_AdaptiveComposerPopover> createState() => _AdaptiveComposerPopoverState();
}

class _AdaptiveComposerPopoverState extends State<_AdaptiveComposerPopover> {
  late double _effectiveTop;
  bool _remeasureScheduled = false;

  @override
  void initState() {
    super.initState();
    _effectiveTop = _computeEffectiveTop();
    widget.controller.textController.addListener(_scheduleRemeasure);
    widget.controller.subjectTextController.addListener(_scheduleRemeasure);
  }

  @override
  void dispose() {
    widget.controller.textController.removeListener(_scheduleRemeasure);
    widget.controller.subjectTextController.removeListener(_scheduleRemeasure);
    super.dispose();
  }

  double _computeEffectiveTop() {
    var top = widget.initialAnchor.top;
    final composerBox = widget.controller.textFieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (composerBox != null && composerBox.attached && widget.overlayBox.attached) {
      final composerTop = composerBox.localToGlobal(Offset.zero, ancestor: widget.overlayBox).dy;
      top = math.min(top, composerTop);
    }
    return top;
  }

  void _scheduleRemeasure() {
    if (_remeasureScheduled || !mounted) return;
    _remeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _remeasureScheduled = false;
      if (!mounted) return;
      final nextTop = _computeEffectiveTop();
      if ((nextTop - _effectiveTop).abs() > 0.5) {
        setState(() => _effectiveTop = nextTop);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final w = math.min(widget.maxWidth, size.width - _margin * 2);
    final maxFit = math.max(0.0, _effectiveTop - _margin * 2);
    final h = math.min(widget.maxHeight, maxFit);
    final left = widget.initialAnchor.left
        .clamp(_margin, math.max(_margin, size.width - w - _margin))
        .toDouble();
    final bottom = math.max(_margin, size.height - _effectiveTop + 8);
    return Stack(
      children: [
        Positioned(
          left: left,
          bottom: bottom,
          width: w,
          height: h,
          child: widget.child,
        ),
      ],
    );
  }
}

/// The popover's card: rounded, raised, closing on Escape.
class ComposerPopoverCard extends StatelessWidget {
  const ComposerPopoverCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = context.theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop()},
        child: child,
      ),
    );
  }
}
