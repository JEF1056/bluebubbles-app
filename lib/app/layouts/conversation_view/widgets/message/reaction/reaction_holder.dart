import 'dart:math';

import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction_clipper.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:defer_pointer/defer_pointer.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Stateful widget that animates a reaction pop-in only once
class _ReactionAnimator extends StatefulWidget {
  const _ReactionAnimator({
    super.key,
    required this.stableKey,
    required this.shouldAnimate,
    required this.child,
  });

  final String stableKey;
  final bool shouldAnimate;
  final Widget child;

  @override
  State<_ReactionAnimator> createState() => _ReactionAnimatorState();
}

class _ReactionAnimatorState extends State<_ReactionAnimator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _scaleAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
    );

    // Animate in only if this is a new reaction
    if (widget.shouldAnimate) {
      _controller.forward();
    } else {
      // Skip animation - set to final state immediately
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: widget.child,
    );
  }
}

class ReactionHolder extends StatefulWidget {
  const ReactionHolder({
    super.key,
    required this.reactions,
    this.tailType = ReactionTailType.standard,
    this.tailDirection,
  });

  final Iterable<Message> reactions;
  final ReactionTailType tailType;
  final ReactionTailDirection? tailDirection;

  /// How far a holder pinned to a bubble's top corner hangs past the bubble's top / side edge (iOS).
  static const double bubbleOverhangTop = -14;
  static const double bubbleOverhangSide = -20;

  /// Google Messages bottom-corner badge row layout tokens (APK `ezbb.java#L5227,5859-5863,6414`,
  /// `ewsm.java#L2833-2843`, `amqp.java#L168`).
  static const double materialBubbleOverlap = 9.0;
  static const double materialBottomPadding = 2.0;
  static const double materialBadgeGap = 4.0;
  static const int materialMaxVisibleGroups = 5;

  /// Tallest badge height in [reactions] under Material skin (28dp emoji, 36dp sticker).
  static double materialMaxBadgeHeight(Iterable<Message> reactions) {
    if (reactions.isEmpty) return 0.0;
    final hasSticker = reactions.any((m) => ReactionTypes.isStickerTapback(m.associatedMessageType));
    return hasSticker ? ReactionWidget.materialStickerBadgeSize : ReactionWidget.materialBadgeSize;
  }

  /// Vertical clearance reserved below a bubble in Material skin (`ezbb.java#L5227,6414`:
  /// `max(badgeHeight - 9dp + 2dp, 0)` -> 21dp for emoji, 29dp for sticker).
  static double materialBottomClearance(Iterable<Message> reactions) {
    if (reactions.isEmpty) return 0.0;
    return max(0.0, materialMaxBadgeHeight(reactions) - materialBubbleOverlap + materialBottomPadding);
  }

  @override
  State<ReactionHolder> createState() => _ReactionHolderState();
}

class _ReactionHolderState extends State<ReactionHolder> {
  Iterable<Message> get reactions => getUniqueReactionMessages(widget.reactions.toList());

  // Each sender's latest reaction, worked out once per update rather than on every build
  late List<Message> _cachedReactions;

  // Track which reaction keys have been animated
  // This prevents re-animation on rebuilds, but allows animation on first appearance
  final Set<String> _seenReactionKeys = {};

  void _removeOwnReaction(BuildContext context, Message ownReaction) {
    if (!context.mounted) return;
    final parent = MessageStateScope.maybeOf(context)?.message;
    if (parent == null) return;
    final chat = ChatStateScope.maybeChatOf(context) ??
        ChatsSvc.getChatState(parent.chat.target?.guid ?? '')?.chat ??
        ChatsSvc.activeChat?.chat;
    if (chat == null) return;
    if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
      Get.find<ConversationViewController>(tag: chat.guid).onUserChatInteraction(immediate: true);
    }
    final rawType = ownReaction.associatedMessageType ?? '';
    final isEmoji = ReactionTypes.isEmojiTapback(rawType);
    final isSticker = ReactionTypes.isStickerTapback(rawType);
    final removalType = isEmoji
        ? ReactionTypes.REMOVED_EMOJI
        : isSticker
            ? ReactionTypes.REMOVED_STICKER
            : (rawType.startsWith('-') ? rawType : '-$rawType');
    OutgoingMsgHandler.queue(
      OutgoingReaction(
        chat: chat,
        message: Message(
          associatedMessageGuid: parent.guid,
          associatedMessageType: removalType,
          associatedMessageEmoji: isEmoji ? ownReaction.associatedMessageEmoji : null,
          associatedMessagePart: ownReaction.associatedMessagePart,
          dateCreated: DateTime.now(),
          hasAttachments: false,
          isFromMe: true,
          handleId: 0,
        ),
        selectedMessage: parent,
        reaction: removalType,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _cachedReactions = reactions.toList();
  }

  @override
  void didUpdateWidget(ReactionHolder oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Always: a send that fails changes its reaction in place (same GUID, same object), so comparing the old list
    // with the new can't see it, and a failed removal is drawn where the pending one wasn't. Pop-ins are tracked by
    // _seenReactionKeys, not by this list, so recomputing doesn't replay them.
    _cachedReactions = reactions.toList();
  }

  @override
  Widget build(BuildContext context) {
    // If the reactions are empty, return nothing
    if (_cachedReactions.isEmpty) {
      return const SizedBox.shrink();
    }

    final isFromMe = MessageStateScope.of(context).isFromMe.value;
    if (CurrentSkin.material) {
      // Group identical emoji / tapbacks (merging classic Apple tapbacks with matching custom emoji)
      // into side-by-side Google Messages pills with 4dp gap and up to 5 badges (`amqp.java#L168`).
      final Map<String, List<Message>> grouped = {};
      for (final r in _cachedReactions) {
        final type = r.associatedMessageType ?? '';
        final key = ReactionTypes.isStickerTapback(type)
            ? 'sticker:${r.dbAttachments.firstOrNull?.guid ?? r.guid}'
            : 'emoji:${ReactionTypes.emojiFor(r)}';
        grouped.putIfAbsent(key, () => []).add(r);
      }
      final entries = grouped.entries.toList();
      final isTruncated = entries.length > ReactionHolder.materialMaxVisibleGroups;
      final visibleEntries =
          isTruncated ? entries.sublist(0, ReactionHolder.materialMaxVisibleGroups - 1) : entries;
      final hiddenCount = isTruncated
          ? entries
              .sublist(ReactionHolder.materialMaxVisibleGroups - 1)
              .fold<int>(0, (sum, e) => sum + e.value.length)
          : 0;

      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (int i = 0; i < visibleEntries.length; i++) ...[
            if (i > 0) const SizedBox(width: ReactionHolder.materialBadgeGap),
            Builder(builder: (context) {
              final groupKey = visibleEntries[i].key;
              final group = visibleEntries[i].value;
              final rep = group.firstWhereOrNull((m) => m.isFromMe ?? false) ?? group.first;
              final stableKey = '${rep.associatedMessageGuid}-$groupKey';
              final shouldAnimate = !_seenReactionKeys.contains(stableKey);
              if (shouldAnimate) {
                _seenReactionKeys.add(stableKey);
              }
              return DeferPointer(
                key: ValueKey(stableKey),
                child: _ReactionAnimator(
                  key: ValueKey(stableKey),
                  stableKey: stableKey,
                  shouldAnimate: shouldAnimate,
                  child: ReactionWidget(
                    reaction: rep,
                    reactions: _cachedReactions,
                    groupedReactions: group,
                    tailType: widget.tailType,
                    tailDirection: widget.tailDirection,
                  ),
                ),
              );
            }),
          ],
          if (isTruncated) ...[
            const SizedBox(width: ReactionHolder.materialBadgeGap),
            DeferPointer(
              key: const ValueKey('material-rxn-overflow'),
              child: MaterialReactionOverflowBadge(
                extraCount: hiddenCount,
                reactions: _cachedReactions,
                onRemoveOwnReaction: (own) => _removeOwnReaction(context, own),
              ),
            ),
          ],
        ],
      );
    }

    // Explicit tailDirection stacks along that edge (e.g. collection trailing).
    final stackFromEnd = widget.tailDirection != null
        ? widget.tailDirection == ReactionTailDirection.left
        : isFromMe;
    return SizedBox(
      height:
          widget.tailType == ReactionTailType.inside ? ReactionWidgetState.iosClipHeight : ReactionWidgetState.iosSize,
      width: ReactionWidgetState.iosSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: _cachedReactions
            .asMap()
            .entries
            .map((entry) {
              final i = entry.key;
              final e = entry.value;
              // Use a stable key based on parent + reaction type + sender
              // This prevents re-animation when temp GUID -> real GUID replacement happens
              final sender = e.isFromMe! ? 0 : e.handleId ?? 0;
              final stableKey = '${e.associatedMessageGuid}-${e.associatedMessageType}-$sender';

              // Check if this is a new reaction that should animate
              final shouldAnimate = !_seenReactionKeys.contains(stableKey);
              if (shouldAnimate) {
                // Mark as seen for future rebuilds
                _seenReactionKeys.add(stableKey);
              }

              return Positioned(
                key: ValueKey(stableKey),
                top: 0,
                left: stackFromEnd ? -i * 2.0 : null,
                right: stackFromEnd ? null : -i * 2.0,
                child: DeferPointer(
                  child: _ReactionAnimator(
                    key: ValueKey(stableKey),
                    stableKey: stableKey,
                    shouldAnimate: shouldAnimate,
                    child: ReactionWidget(
                      reaction: e,
                      reactions: _cachedReactions,
                      tailType: widget.tailType,
                      tailDirection: widget.tailDirection,
                    ),
                  ),
                ),
              );
            })
            .toList()
            .reversed
            .toList(),
      ),
    );
  }
}
