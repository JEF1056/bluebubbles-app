import 'dart:math' as math;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_library_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_holder.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/sticker_placement.dart';
import 'package:bluebubbles/services/network/api/sticker_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Fills a message part's bubble so a sticker dragged from the sticker library (the desktop/web popover, or the mobile
/// picker's grid) can be dropped on it, placing it where it was dropped. Lets every other pointer event through to the
/// bubble.
class StickerDropTarget extends StatefulWidget {
  const StickerDropTarget({
    super.key,
    required this.message,
    required this.part,
    required this.chat,
    required this.tailGutter,
  });

  final Message message;
  final int part;
  final Chat chat;

  /// As [StickerHolder.tailGutter]
  final bool tailGutter;

  static const double _minScale = 0.4;
  static const double _maxScale = StickerHolder.maxPoints / StickerLibraryTile.dragSize;

  /// Adjusts [drag]'s live scale and rotation (used on desktop/web via scroll wheel or keyboard shortcuts).
  @visibleForTesting
  static void adjustTransform(StickerDrag drag, {double scaleDelta = 0, double rotationDelta = 0}) {
    final current = drag.transform.value;
    drag.transform.value = (
      scale: (current.scale + scaleDelta).clamp(_minScale, _maxScale).toDouble(),
      rotation: current.rotation + rotationDelta,
    );
  }

  @override
  State<StickerDropTarget> createState() => _StickerDropTargetState();
}

class _StickerDropTargetState extends State<StickerDropTarget> {
  StickerDrag? _hoverDrag;
  Offset? _hoverLocal;
  bool _keyHandlerRegistered = false;

  @override
  void dispose() {
    _detachKeyHandler();
    super.dispose();
  }

  bool get _accepts => !(widget.message.guid?.startsWith("temp") ?? true);

  void _attachKeyHandler() {
    if (_keyHandlerRegistered) return;
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _keyHandlerRegistered = true;
  }

  void _detachKeyHandler() {
    if (!_keyHandlerRegistered) return;
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _keyHandlerRegistered = false;
  }

  void _setHover(StickerDrag drag, Offset globalOffset) {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final local = box.globalToLocal(globalOffset);
    _attachKeyHandler();
    if (identical(_hoverDrag, drag) && _hoverLocal == local) return;
    setState(() {
      _hoverDrag = drag;
      _hoverLocal = local;
    });
  }

  void _clearHover() {
    _detachKeyHandler();
    if (_hoverDrag == null && _hoverLocal == null) return;
    if (!mounted) return;
    setState(() {
      _hoverDrag = null;
      _hoverLocal = null;
    });
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    final drag = _hoverDrag;
    if (drag == null || event is! PointerScrollEvent) return;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final horizontal = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs();
    if (shift || horizontal) {
      final delta = shift && !horizontal ? event.scrollDelta.dy : event.scrollDelta.dx;
      StickerDropTarget.adjustTransform(drag, rotationDelta: delta * 0.004);
    } else {
      StickerDropTarget.adjustTransform(drag, scaleDelta: -event.scrollDelta.dy * 0.0015);
    }
  }

  bool _handleKeyEvent(KeyEvent event) {
    final drag = _hoverDrag;
    if (drag == null || (event is! KeyDownEvent && event is! KeyRepeatEvent)) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      StickerDropTarget.adjustTransform(drag, scaleDelta: 0.12);
      return true;
    }
    if (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract) {
      StickerDropTarget.adjustTransform(drag, scaleDelta: -0.12);
      return true;
    }
    if (key == LogicalKeyboardKey.bracketLeft || key == LogicalKeyboardKey.keyQ) {
      StickerDropTarget.adjustTransform(drag, rotationDelta: -math.pi / 12);
      return true;
    }
    if (key == LogicalKeyboardKey.bracketRight || key == LogicalKeyboardKey.keyE) {
      StickerDropTarget.adjustTransform(drag, rotationDelta: math.pi / 12);
      return true;
    }
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      drag.transform.value = (scale: 1.0, rotation: 0.0);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _handlePointerSignal,
      child: DragTarget<StickerDrag>(
        onWillAcceptWithDetails: (details) {
          if (!_accepts) return false;
          _setHover(details.data, details.offset);
          return true;
        },
        onMove: (details) {
          if (_accepts) _setHover(details.data, details.offset);
        },
        onLeave: (_) => _clearHover(),
        onAcceptWithDetails: (details) {
          _clearHover();
          _place(context, details);
        },
        builder: (context, candidateData, _) {
          final active = candidateData.isNotEmpty;
          final drag = candidateData.whereType<StickerDrag>().firstOrNull ?? (active ? _hoverDrag : null);
          if (!active) return const SizedBox.expand();

          final scheme = Theme.of(context).colorScheme;
          return IgnorePointer(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final local = _hoverLocal;
                Offset? center;
                if (drag != null && local != null) {
                  final isFromMe = widget.message.isFromMe ?? false;
                  final at = StickerHolder.placementAt(
                    local,
                    constraints.biggest,
                    isFromMe,
                    widget.tailGutter,
                  );
                  center = StickerHolder.placedCenter(at, constraints.biggest, isFromMe, widget.tailGutter);
                }

                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Crisp restrained accent ring on hover; zero shadow glow
                    Positioned.fill(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOutCubic,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: scheme.primary.withValues(alpha: 0.06),
                          border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.72),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    if (drag != null)
                      Positioned.fill(
                        child: ValueListenableBuilder<({double scale, double rotation})>(
                          valueListenable: drag.transform,
                          builder: (_, transform, _) {
                            final ghostSize = _ghostSize(transform.scale);
                            final degrees = (transform.rotation * 180 / math.pi).round();
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                if (center != null)
                                  Positioned(
                                    left: center.dx - ghostSize.width / 2,
                                    top: center.dy - ghostSize.height / 2,
                                    width: ghostSize.width,
                                    height: ghostSize.height,
                                    child: Transform.rotate(
                                      angle: transform.rotation,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(12),
                                          color: scheme.primary.withValues(alpha: 0.08),
                                          border: Border.all(
                                            color: scheme.primary.withValues(alpha: 0.65),
                                            width: 1.25,
                                          ),
                                        ),
                                        child: Center(
                                          child: Container(
                                            width: 6,
                                            height: 6,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: scheme.primary.withValues(alpha: 0.9),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  top: -26,
                                  left: 0,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: scheme.surface.withValues(alpha: 0.94),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: scheme.outlineVariant.withValues(alpha: 0.75),
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      child: Text(
                                        "${(transform.scale * 100).round()}% · $degrees°",
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: scheme.onSurface,
                                          fontFeatures: const [FontFeature.tabularFigures()],
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
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  static Size _ghostSize(double scale) => Size.square(StickerLibraryTile.dragSize * scale);

  Future<void> _place(BuildContext context, DragTargetDetails<StickerDrag> details) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    // The drag feedback is centered on the pointer, which is where the drop reports
    final at = StickerHolder.placementAt(
      box.globalToLocal(details.offset),
      box.size,
      widget.message.isFromMe ?? false,
      widget.tailGutter,
    );
    final transform = details.data.transform.value;
    final sticker = details.data.sticker;
    try {
      final bytes = await StickerLibrarySvc.imageForSending(sticker);
      // As large as it looked while dragged: the drag draws its longest side at dragSize, times the pinch/scroll scale
      final scale = StickerHolder.scaleForPoints(
        StickerLibraryTile.dragSize * transform.scale,
        sticker.longestSide,
      );
      await OutgoingMsgHandler.queuePlacedSticker(
        chat: widget.chat,
        selected: widget.message,
        part: widget.part,
        bytes: bytes,
        fileName: "sticker.${sticker.fileExtension}",
        placement: StickerPlacement(
          xScalar: at.xScalar,
          yScalar: at.yScalar,
          scale: scale,
          rotation: transform.rotation,
          parentPreviewWidth: at.parentPreviewWidth,
        ),
      );
    } catch (e, s) {
      Logger.warn("Failed to place a sticker", error: e, trace: s, tag: "StickerDrop");
      showSnackbar("Error", stickerRefusal(e).message ?? "Couldn't send the sticker", type: SnackbarType.error);
    }
  }
}
