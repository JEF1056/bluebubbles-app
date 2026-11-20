import 'dart:math';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_holder.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction_holder.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show StickerPlacement;
import 'package:bluebubbles/services/ui/chat/conversation_view_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';

/// Isolated widget for reaction display
/// Only rebuilds when MessageState.associatedMessages changes
///
/// Not used for media-collection parts on any skin — those show tapbacks per
/// attachment (`CollectionAttachmentReactions`), since a collection can bundle
/// several originally-separate message parts (see
/// MessagePart.collapseMediaCollections) and a tapback is only ever
/// associated with one of them.
class ReactionObserver extends StatelessWidget {
  const ReactionObserver({
    super.key,
    required this.part,
    required this.chatGuid,
    this.showInMaterial = true,
  });

  final MessagePart part;
  final String chatGuid;
  final bool showInMaterial;

  @override
  Widget build(BuildContext context) {
    final state = MessageStateScope.of(context);
    return Obx(() {
      final isMaterial = CurrentSkin.material;
      if (isMaterial && !showInMaterial) return const SizedBox.shrink();

      // Directly observe MessageState for all reactive data
      final isFromMe = state.isFromMe.value;
      final reactionList = state.tapbacksForBubble(part);
      if (reactionList.isEmpty) return const SizedBox.shrink();

      if (isMaterial) {
        return Positioned(
          bottom: -10.0,
          right: 4.0,
          child: ReactionHolder(
            reactions: reactionList,
          ),
        );
      }

      const top = ReactionHolder.bubbleOverhangTop;
      const side = ReactionHolder.bubbleOverhangSide;
      return Positioned(
        top: top,
        left: isFromMe ? side : null,
        right: isFromMe ? null : side,
        child: ReactionHolder(
          reactions: reactionList,
        ),
      );
    });
  }
}

/// Wraps a message bubble so Google Messages (`CurrentSkin.material`) reactions overlap the
/// bubble's bottom-end edge by `9dp` (`ezbb.java#L5863`) with `2dp` bottom padding (`ezbb.java#L5859`),
/// exact bottom clearance (`21dp` emoji / `29dp` sticker), and full hit-testing across the entire
/// overlapping pill — without ever reparenting [child] when reactions or skin toggle.
class MaterialReactionBubble extends StatelessWidget {
  const MaterialReactionBubble({
    super.key,
    required this.part,
    required this.child,
    this.enabled = true,
  });

  final MessagePart part;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final state = MessageStateScope.of(context);
    return Obx(() {
      final isFromMe = state.isFromMe.value;
      final reactions = (enabled && CurrentSkin.material) ? state.tapbacksForBubble(part) : const <Message>[];
      return _MaterialReactionBubbleLayout(
        isFromMe: isFromMe,
        children: [
          child,
          if (reactions.isNotEmpty)
            ReactionHolder(reactions: reactions)
          else
            const SizedBox.shrink(),
        ],
      );
    });
  }
}

class _MaterialReactionBubbleParentData extends ContainerBoxParentData<RenderBox> {}

class _MaterialReactionBubbleLayout extends MultiChildRenderObjectWidget {
  const _MaterialReactionBubbleLayout({
    required this.isFromMe,
    required super.children,
  });

  final bool isFromMe;

  @override
  _RenderMaterialReactionBubble createRenderObject(BuildContext context) {
    return _RenderMaterialReactionBubble(isFromMe);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderMaterialReactionBubble renderObject) {
    renderObject.isFromMe = isFromMe;
  }
}

class _RenderMaterialReactionBubble extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _MaterialReactionBubbleParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _MaterialReactionBubbleParentData> {
  _RenderMaterialReactionBubble(this._isFromMe);

  bool _isFromMe;
  bool get isFromMe => _isFromMe;
  set isFromMe(bool value) {
    if (_isFromMe == value) return;
    _isFromMe = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MaterialReactionBubbleParentData) {
      child.parentData = _MaterialReactionBubbleParentData();
    }
  }

  @override
  void performLayout() {
    final bubble = firstChild;
    if (bubble == null) {
      size = constraints.smallest;
      return;
    }
    final reactions = childAfter(bubble);
    final bubbleData = bubble.parentData as _MaterialReactionBubbleParentData;

    bubble.layout(constraints, parentUsesSize: true);
    if (reactions == null) {
      bubbleData.offset = Offset.zero;
      size = bubble.size;
      return;
    }

    final reactionsData = reactions.parentData as _MaterialReactionBubbleParentData;
    reactions.layout(
      BoxConstraints(maxWidth: constraints.maxWidth),
      parentUsesSize: true,
    );

    if (reactions.size.isEmpty) {
      bubbleData.offset = Offset.zero;
      reactionsData.offset = Offset.zero;
      size = bubble.size;
      return;
    }

    const double edgeInset = 4.0;
    const double overlap = ReactionHolder.materialBubbleOverlap;
    const double bottomPad = ReactionHolder.materialBottomPadding;

    final bubbleW = bubble.size.width;
    final bubbleH = bubble.size.height;
    final rxnW = reactions.size.width;
    final rxnH = reactions.size.height;

    late final double totalW;
    late final double bubbleX;
    late final double rxnX;

    if (_isFromMe) {
      // Sent bubble (right-aligned): pin bubble to right edge; anchor reactions to bottom-end,
      // expanding leftward inside bounds when wider than a short bubble.
      totalW = min(constraints.maxWidth, max(bubbleW, rxnW + edgeInset));
      bubbleX = max(0.0, totalW - bubbleW);
      rxnX = max(0.0, totalW - rxnW - edgeInset);
    } else {
      // Received bubble (left-aligned): pin bubble to left edge next to avatar; anchor reactions
      // to bottom-end when bubble fits, otherwise start at +4dp growing rightward away from avatar.
      bubbleX = 0.0;
      final candidateX = bubbleW >= rxnW + edgeInset * 2 ? bubbleW - rxnW - edgeInset : edgeInset;
      totalW = min(constraints.maxWidth, max(bubbleW, candidateX + rxnW));
      rxnX = min(candidateX, max(0.0, totalW - rxnW));
    }

    final rxnY = max(0.0, bubbleH - overlap);
    final totalH = max(bubbleH, rxnY + rxnH + bottomPad);

    bubbleData.offset = Offset(bubbleX, 0.0);
    reactionsData.offset = Offset(rxnX, rxnY);
    size = constraints.constrain(Size(totalW, totalH));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final bubble = firstChild;
    if (bubble == null) return;
    final bubbleData = bubble.parentData as _MaterialReactionBubbleParentData;
    context.paintChild(bubble, offset + bubbleData.offset);

    final reactions = childAfter(bubble);
    if (reactions != null && !reactions.size.isEmpty) {
      final reactionsData = reactions.parentData as _MaterialReactionBubbleParentData;
      context.paintChild(reactions, offset + reactionsData.offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final bubble = firstChild;
    if (bubble == null) return false;
    final reactions = childAfter(bubble);
    // Hit-test the overlapping reactions pill BEFORE the bubble so tapping any pixel on the badge wins.
    if (reactions != null && !reactions.size.isEmpty) {
      final reactionsData = reactions.parentData as _MaterialReactionBubbleParentData;
      final hitReactions = result.addWithPaintOffset(
        offset: reactionsData.offset,
        position: position,
        hitTest: (result, transformed) => reactions.hitTest(result, position: transformed),
      );
      if (hitReactions) return true;
    }
    final bubbleData = bubble.parentData as _MaterialReactionBubbleParentData;
    return result.addWithPaintOffset(
      offset: bubbleData.offset,
      position: position,
      hitTest: (result, transformed) => bubble.hitTest(result, position: transformed),
    );
  }
}

/// Isolated widget for sticker display.
/// Uses its own [Obx] so sticker rebuilds are decoupled from the outer
/// message-holder [Obx] (which tracks isSending, isFromMe, parts, etc.).
class StickerObserver extends StatelessWidget {
  const StickerObserver({
    super.key,
    required this.part,
    required this.cvController,
    this.placed = false,
  });

  final MessagePart part;
  final ConversationViewController cvController;

  /// Only stickers with a sender placement (filling the bubble's Stack), or only those without
  final bool placed;

  @override
  Widget build(BuildContext context) {
    // Media collection items render their own per-card placed stickers (CollectionAttachmentStickers),
    // matching how CollectionAttachmentReactions owns per-card tapbacks.
    if (placed && part.isMediaCollection) return const SizedBox.shrink();
    final state = MessageStateScope.of(context);
    return Obx(() {
      final stickersForPart = state
          .stickersForBubble(part)
          .where((e) => e.dbAttachments.any((a) => StickerPlacement.tryParse(a.stickerPlacement) != null) == placed)
          .toList();

      if (stickersForPart.isEmpty) return const SizedBox.shrink();

      final holder = StickerHolder(
        stickerMessages: stickersForPart,
        controller: cvController,
        placed: placed,
        hidden: state.showingPopup.value,
        isFromMe: state.message.isFromMe ?? false,
        tailGutter: CurrentSkin.iOS && !part.isMediaCollection,
      );
      return placed ? Positioned.fill(child: holder) : holder;
    });
  }
}

/// Isolated widget for reaction spacing calculation above a bubble (iOS/Samsung top overhang).
///
/// On Material skin (`CurrentSkin.material`), reactions overlap the bottom edge via
/// [MaterialReactionBubble], so top spacing returns [minHeightWhenNoReactions].
class ReactionSpacing extends StatelessWidget {
  const ReactionSpacing({
    super.key,
    required this.part,
    this.minHeightWhenNoReactions = 0,
    this.tapbackHeight,
  });

  final MessagePart part;
  final double minHeightWhenNoReactions;
  final double? tapbackHeight;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final state = MessageStateScope.of(context);
      // Reads associatedMessages, so this rebuilds when tapbacks change. Collapsed collection spans are
      // matched via MessagePart.coversPartId.
      if (!CurrentSkin.material && state.hasVisibleTapbacks(part)) {
        return SizedBox(height: tapbackHeight ?? (CurrentSkin.iOS ? 15.0 : 14.0));
      }

      if (minHeightWhenNoReactions > 0) {
        return SizedBox(height: minHeightWhenNoReactions);
      }

      return const SizedBox.shrink();
    });
  }
}

/// Grows [child], the bubble's Stack, by [StickerHolder.space] so its placed stickers always have room in the message
/// list instead of drawing over neighboring messages or off-screen. Presses in that room go to the bubble.
class StickerSpace extends StatelessWidget {
  const StickerSpace({super.key, required this.part, required this.columnWidth, required this.child});

  final MessagePart part;

  /// Width of the message column the bubble sits against; the room around it never grows past this
  final double columnWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (part.isMediaCollection) return child;
    final state = MessageStateScope.of(context);
    return Obx(() => _StickerOverhang(
          stickers: state
              .stickersForBubble(part)
              .expand((e) => e.dbAttachments)
              .map((a) => PlacedSticker.of(a, a.guid == null ? null : state.stickerSizes[a.guid]))
              .nonNulls
              .toList(),
          isFromMe: state.message.isFromMe ?? false,
          tailGutter: CurrentSkin.iOS && !part.isMediaCollection,
          columnWidth: columnWidth,
          child: child,
        ));
  }
}

class _StickerOverhang extends SingleChildRenderObjectWidget {
  const _StickerOverhang({
    required this.stickers,
    required this.isFromMe,
    required this.tailGutter,
    required this.columnWidth,
    required Widget super.child,
  });

  final List<PlacedSticker> stickers;
  final bool isFromMe;
  final bool tailGutter;
  final double columnWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderStickerOverhang(stickers, isFromMe, tailGutter, columnWidth);

  @override
  void updateRenderObject(BuildContext context, _RenderStickerOverhang renderObject) => renderObject
    ..stickers = stickers
    ..isFromMe = isFromMe
    ..tailGutter = tailGutter
    ..columnWidth = columnWidth;
}

// The overhang depends on the bubble's laid-out size, which no Padding can know ahead of time
class _RenderStickerOverhang extends RenderShiftedBox {
  _RenderStickerOverhang(this._stickers, this._isFromMe, this._tailGutter, this._columnWidth) : super(null);

  List<PlacedSticker> _stickers;
  set stickers(List<PlacedSticker> value) {
    if (listEquals(_stickers, value)) return;
    _stickers = value;
    markNeedsLayout();
  }

  bool _isFromMe;
  set isFromMe(bool value) {
    if (_isFromMe == value) return;
    _isFromMe = value;
    markNeedsLayout();
  }

  bool _tailGutter;
  set tailGutter(bool value) {
    if (_tailGutter == value) return;
    _tailGutter = value;
    markNeedsLayout();
  }

  double _columnWidth;
  set columnWidth(double value) {
    if (_columnWidth == value) return;
    _columnWidth = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints, parentUsesSize: true);
    final space = StickerHolder.space(_stickers, child.size, _isFromMe, _tailGutter, _columnWidth);
    (child.parentData as BoxParentData).offset = space.topLeft;
    size = constraints.constrain(space.inflateSize(child.size));
  }

  // A press in the room kept for placed stickers lands on the bubble's center, so it opens details like the bubble
  // does. A miss on the bubble itself (its tail gutter, its rounded corners) stays a miss, as it would without this.
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTestChildren(result, position: position)) return true;
    final child = this.child!;
    final offset = (child.parentData as BoxParentData).offset;
    if (_stickers.isEmpty || (offset & child.size).contains(position)) return false;
    return super.hitTestChildren(result, position: offset + child.size.center(Offset.zero));
  }
}
