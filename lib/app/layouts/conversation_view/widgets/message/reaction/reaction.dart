import 'package:bluebubbles/app/components/m3e/m3e_motion.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/widgets/reaction_details.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/sticker_tapback_image.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/shared/message_error_helper.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:defer_pointer/defer_pointer.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/tapback_icon.dart';
import 'package:get/get.dart';

class ReactionWidget extends StatefulWidget {
  const ReactionWidget({
    super.key,
    required this.reaction,
    this.reactions,
    this.groupedReactions,
    this.chatGuid,
    this.tailDirection,
    this.tailType = ReactionTailType.standard,
  });

  final Message reaction;
  final List<Message>? reactions;
  final List<Message>? groupedReactions;

  /// Explicit chat GUID used when outside a [MessageStateScope] (e.g. pinned tile context).
  /// Allows [ReactionWidgetState] to resolve MessageState from the correct
  /// MessagesService rather than falling back to [ChatsSvc.activeChat].
  final String? chatGuid;

  /// When set, overrides the computed tail direction for the reaction clippers.
  /// Useful in contexts with no [MessageStateScope] (e.g. pinned tiles) where
  /// the fallback would produce the wrong arc orientation.
  /// Bubble coloring is always driven by the reaction's own [isFromMe] field.
  final ReactionTailDirection? tailDirection;

  final ReactionTailType tailType;

  @override
  ReactionWidgetState createState() => ReactionWidgetState();
}

class ReactionWidgetState extends State<ReactionWidget> with SingleTickerProviderStateMixin, ThemeHelpers {
  late final AnimationController _springController;
  String? _lastReactionSignature;

  String _signatureFor(Message r) => '${r.associatedMessageType ?? ''}|${r.associatedMessageEmoji ?? ''}';

  void _triggerSpringBurst({double from = 0.65}) {
    if (!mounted) return;
    _springController.stop();
    _springController.animateWith(
      SpringSimulation(M3EMotion.springSpatialFast, from, 1.0, 2.5),
    );
  }

  @override
  void initState() {
    super.initState();
    _springController = AnimationController.unbounded(vsync: this, value: 1.0);
    _lastReactionSignature = _signatureFor(widget.reaction);
    _triggerSpringBurst(from: 0.65);
  }

  @override
  void didUpdateWidget(covariant ReactionWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSig = _signatureFor(widget.reaction);
    if (nextSig != _lastReactionSignature) {
      _lastReactionSignature = nextSig;
      _triggerSpringBurst(from: 0.72);
    }
  }

  @override
  void dispose() {
    _springController.dispose();
    super.dispose();
  }
  List<Message>? get reactions => widget.reactions;

  /// Parent [Message] resolved live from the nearest [MessageStateScope].
  /// Returns null when outside a scope (e.g. pinned-tile context).
  Message? get _parentMessage => MessageStateScope.maybeOf(context)?.message;

  // Observe the reaction from parent message's associatedMessages list
  // This is already an RxList in MessageState, so changes propagate automatically
  Message get reaction {
    // Resolution order:
    //  1. widget.chatGuid – explicitly provided (e.g. from a pinned tile)
    //  2. parent message's chat relation – used in conversation view
    //  3. ChatsSvc.activeChat – last-resort fallback
    final chatGuid = widget.chatGuid ?? _parentMessage?.chat.target?.guid ?? ChatsSvc.activeChat?.chat.guid;
    final parentController =
        chatGuid != null ? maybeFindMessagesSvc(chatGuid)?.getMessageStateIfExists(_parentMessage?.guid ?? '') : null;
    if (parentController != null) {
      // Find our reaction in the observable associatedMessages list
      // GUID first: every emoji tapback shares type 2006, so the tuple can match an older, replaced one
      final associated = parentController.associatedMessages;
      final found = associated.firstWhereOrNull((m) => m.guid == widget.reaction.guid) ??
          associated.firstWhereOrNull((m) =>
              m.associatedMessageType == widget.reaction.associatedMessageType &&
              m.associatedMessageEmoji == widget.reaction.associatedMessageEmoji &&
              (m.associatedMessagePart ?? 0) == (widget.reaction.associatedMessagePart ?? 0) &&
              m.isFromMe == widget.reaction.isFromMe);
      if (found != null) return found;
    }
    // Fallback to widget.reaction if not found in MessageState
    return widget.reaction;
  }

  /// Guard against isFromMe being null on partially-hydrated messages.
  bool get reactionIsFromMe => reaction.isFromMe ?? false;
  bool get messageIsFromMe => _parentMessage?.isFromMe ?? true;

  /// Effective tail direction for the clippers.
  /// Matches the [messageIsFromMe] semantics: sent (right) vs received (left).
  /// Can be overridden via [widget.tailDirection] (e.g. pinned tile context).
  ReactionTailDirection get _effectiveTailDirection =>
      widget.tailDirection ?? (messageIsFromMe ? ReactionTailDirection.left : ReactionTailDirection.right);

  /// Layout follows [_effectiveTailDirection] so icon + clip stay consistent.
  bool get _alignToEnd => _effectiveTailDirection == ReactionTailDirection.left;

  /// Guard against associatedMessageType being null.
  /// An empty string produces no SVG match, which is handled in build().
  // A failed removal is drawn as the tapback it was taking back
  String get reactionType => ReactionTypes.addedType(reaction.associatedMessageType) ?? '';

  MessageState? get reactionController {
    // Use same resolution order as reaction getter
    final chatGuid = widget.chatGuid ?? _parentMessage?.chat.target?.guid ?? ChatsSvc.activeChat?.chat.guid;
    if (chatGuid == null || reaction.guid == null) return null;
    return maybeFindMessagesSvc(chatGuid)?.getMessageStateIfExists(reaction.guid!);
  }

  static const double iosSize = 35;

  /// Inside tails extend ~5px past [iosSize] on y.
  static const double iosClipHeight = 40;

  double get _clipHeight => widget.tailType == ReactionTailType.inside ? iosClipHeight : iosSize;

  /// Around the glyph in the iOS bubble. The SVGs are drawn inset; emoji and stickers would look shrunken with the
  /// same padding.
  static EdgeInsetsGeometry _glyphPadding(String type) => ReactionTypes.toList().contains(type)
      ? const EdgeInsets.all(6.5).add(EdgeInsets.only(right: type == "emphasize" ? 1 : 0))
      : const EdgeInsets.all(3);

  // Named tapbacks are their icons on every skin, so they don't look like the same emoji sent as an emoji tapback
  Widget _circleGlyph(Message reaction, String type) =>
      SizedBox.square(dimension: _circleGlyphSize, child: _customGlyph(reaction) ?? TapbackIcon(type));

  // The same share of the 30px circle as the iOS bubble's glyph takes of its round part (15 of 28)
  static const double _circleGlyphSize = 30 * 15 / 28;

  /// Emoji and sticker tapbacks have no SVG, so they're drawn from the reaction itself.
  Widget? _customGlyph(Message reaction) {
    final type = reaction.associatedMessageType;
    if (ReactionTypes.isStickerTapback(type)) {
      return StickerTapbackImage(attachment: reaction.dbAttachments.firstOrNull);
    }
    if (!ReactionTypes.isEmojiTapback(type)) return null;
    return FittedBox(
      child: Text(ReactionTypes.emojiFor(reaction),
          style: const TextStyle(
            height: 1,
            leadingDistribution: TextLeadingDistribution.even,
            fontFamilyFallback: ["Apple Color Emoji", "Noto Color Emoji", "Segoe UI Emoji"],
          )),
    );
  }

  String _reactorTooltip(List<Message> group) {
    final names = <String>[];
    for (final m in group) {
      if (m.isFromMe ?? false) {
        names.add(SettingsSvc.effectiveUserName);
      } else {
        final handle = m.handleRelation.target;
        final name = handle != null ? (HandleSvc.getOrCreateHandleState(handle).reactionDisplayName.value ?? "") : "";
        names.add(name.isNotEmpty ? name : "Someone");
      }
    }
    return names.toSet().join(", ");
  }

  void _toggleOwnReactionOff(BuildContext context, Message ownReaction) {
    final parent = _parentMessage;
    if (parent == null) return;
    final chat = ChatStateScope.maybeChatOf(context) ??
        ChatsSvc.getChatState(widget.chatGuid ?? parent.chat.target?.guid ?? '')?.chat ??
        ChatsSvc.activeChat?.chat;
    if (chat == null) return;
    if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
      Get.find<ConversationViewController>(tag: chat.guid).onUserChatInteraction(immediate: true);
    }
    final rawType = ownReaction.associatedMessageType ?? '';
    final isEmoji = ReactionTypes.isEmojiTapback(rawType);
    final removalType = isEmoji
        ? ReactionTypes.REMOVED_EMOJI
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

  void _openReactionDetails(BuildContext context) {
    final list = reactions;
    if (list == null) return;
    // Capture the conversation's theme before pushing — if adaptive
    // theming is active, context.theme is already the per-chat theme.
    final capturedTheme = context.theme;
    final capturedIsM3 = ThemeSvc.isMaterialYouActive(context);
    final capturedBubbleExt = capturedTheme.extensions[BubbleColors] as BubbleColors?;
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: M3EMotion.spatialDefault.duration,
        reverseTransitionDuration: M3EMotion.spatialFast.duration,
        pageBuilder: (routeCtx, animation, secondaryAnimation) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: M3EMotion.spatialDefault.curve,
              reverseCurve: M3EMotion.effectsFast.curve,
            )),
            child: Theme(
              data: capturedTheme.copyWith(
                primaryColor: capturedBubbleExt?.iMessageBubbleColor ?? capturedTheme.colorScheme.primary,
                colorScheme: capturedTheme.colorScheme.copyWith(
                  primary: capturedBubbleExt?.iMessageBubbleColor ?? capturedTheme.colorScheme.primary,
                  onPrimary: capturedBubbleExt?.oniMessageBubbleColor ?? capturedTheme.colorScheme.onPrimary,
                  surface: capturedIsM3 ? null : capturedBubbleExt?.receivedBubbleColor,
                  onSurface: capturedIsM3 ? null : capturedBubbleExt?.onReceivedBubbleColor,
                ),
              ),
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  GestureDetector(onTap: () => Navigator.of(routeCtx).pop()),
                  Positioned(
                    bottom: 10 + MediaQuery.viewPaddingOf(routeCtx).bottom,
                    left: 15,
                    right: 15,
                    child: ReactionDetails(reactions: list),
                  ),
                ],
              ),
            ),
          );
        },
        fullscreenDialog: true,
        opaque: false,
        barrierDismissible: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // When there is no parent message (e.g. pinned-tile context), there is no
    // MessageState or MessageWidgetController to observe.  Wrapping in Obx with
    // no observables causes GetX to emit "improper use" and suppresses the render.
    // Use a plain Builder for this case so we just render the reaction statically.
    if (_parentMessage == null) {
      return ScaleTransition(
        scale: _springController,
        child: _buildStatic(context, widget.reaction),
      );
    }

    // Full conversation-view path: wrap in Obx so we reactively follow any
    // changes to the parent's associatedMessages RxList (e.g. temp→real GUID).
    return Obx(() {
      // Reading `reaction` subscribes to MessageState.associatedMessages so the
      // widget rebuilds when the reaction changes (temp→real GUID, error state…).
      final current = reaction;
      final signature = _signatureFor(current);
      if (signature != _lastReactionSignature) {
        _lastReactionSignature = signature;
        WidgetsBinding.instance.addPostFrameCallback((_) => _triggerSpringBurst(from: 0.72));
      }

      // Guard: if the reaction type is unknown we cannot render the SVG asset safely.
      if (reactionType.isEmpty) return const SizedBox.shrink();

      if (SettingsSvc.settings.skin.value != Skins.iOS) {
        final isMaterial = SettingsSvc.settings.skin.value == Skins.Material;
        final group = widget.groupedReactions ?? [current];
        final ownReaction = group.firstWhereOrNull((m) => m.isFromMe ?? false);
        final hasOwn = ownReaction != null;
        final count = group.length;
        final badgeColor = hasOwn
            ? (isMaterial
                ? context.theme.colorScheme.primaryContainer
                : context.theme.colorScheme.primary)
            : (isMaterial
                ? (context.isDarkMode ? const Color(0xFF1F1F1F) : Colors.white)
                : ((context.theme.extensions[BubbleColors] as BubbleColors?)?.receivedBubbleColor ??
                    context.theme.colorScheme.surfaceContainerHighest));

        Widget pill = Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: badgeColor,
            border: Border.all(
              color: context.theme.colorScheme.surface,
              width: isMaterial ? 1.5 : 1.0,
            ),
            shape: BoxShape.circle,
            boxShadow: isMaterial
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.14),
                      blurRadius: 6,
                      offset: const Offset(0, 1.5),
                    ),
                  ]
                : null,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if ((kIsWeb || kIsDesktop) && ownReaction != null) {
                _toggleOwnReactionOff(context, ownReaction);
              } else {
                _openReactionDetails(context);
              }
            },
            onSecondaryTap: reactions != null ? () => _openReactionDetails(context) : null,
            child: Center(child: _circleGlyph(current, reactionType)),
          ),
        );

        if (isMaterial && count > 1) {
          pill = Stack(
            clipBehavior: Clip.none,
            children: [
              pill,
              Positioned(
                right: -3,
                top: -3,
                child: Container(
                  width: 14,
                  height: 14,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: hasOwn
                        ? context.theme.colorScheme.primary
                        : context.theme.colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    border: Border.all(color: context.theme.colorScheme.surface, width: 1),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      height: 1,
                      color: hasOwn
                          ? context.theme.colorScheme.onPrimary
                          : context.theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        if (kIsWeb || kIsDesktop) {
          pill = MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message: _reactorTooltip(group),
              waitDuration: const Duration(milliseconds: 250),
              child: pill,
            ),
          );
        }

        return ScaleTransition(
          scale: _springController,
          child: pill,
        );
      }
      return ScaleTransition(
        scale: _springController,
        child: Stack(
        alignment: _alignToEnd ? Alignment.centerRight : Alignment.centerLeft,
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: -1,
            left: _alignToEnd ? 0 : -1,
            right: !_alignToEnd ? 0 : -1,
            child: ClipPath(
              clipper: ReactionBorderClipper(
                tailDirection: _effectiveTailDirection,
                tailType: widget.tailType,
              ),
              child: Container(
                width: iosSize + 2,
                height: _clipHeight + 2,
                color: context.theme.colorScheme.surface,
              ),
            ),
          ),
          ClipPath(
              clipper: ReactionClipper(
                tailDirection: _effectiveTailDirection,
                tailType: widget.tailType,
              ),
              child: Obx(() {
                // reactionController is null when no MessageState exists for the reaction (typical).
                // Fall back to checking the GUID prefix so temp reactions always show as pending.
                final isSending = reactionController?.isSending.value ??
                    (reaction.guid?.startsWith('temp') == true && reaction.error == 0);
                return Container(
                    width: iosSize,
                    height: _clipHeight,
                    color: reactionIsFromMe
                        ? context.theme.colorScheme.primary.darkenAmount(isSending ? 0.2 : 0)
                        : ((context.theme.extensions[BubbleColors] as BubbleColors?)?.receivedBubbleColor ??
                            context.theme.colorScheme.surfaceContainerHighest),
                    alignment: _alignToEnd ? Alignment.topRight : Alignment.topLeft,
                    child: SizedBox(
                      width: iosSize * 0.8,
                      height: iosSize * 0.8,
                      child: Center(
                          child: Padding(
                        padding: _glyphPadding(reactionType),
                        child: _customGlyph(reaction) ?? TapbackIcon(reactionType),
                      )),
                    ));
              })),
          Positioned(
            left: !_alignToEnd ? 0 : -75,
            right: _alignToEnd ? 0 : -75,
            child: Obx(() {
              final hasError = reactionController?.hasError.value ?? false;
              if (reaction.error > 0 || hasError) {
                final errorCode = reaction.error;
                final errorText = ErrorHelper.getErrorText(reaction);

                return DeferPointer(
                  child: GestureDetector(
                    child: Icon(
                      SettingsSvc.settings.skin.value == Skins.iOS
                          ? CupertinoIcons.exclamationmark_circle
                          : Icons.error_outline,
                      color: context.theme.colorScheme.error,
                    ),
                    onTap: () {
                      final chat = ChatStateScope.maybeChatOf(context) ??
                          ChatsSvc.getChatState(widget.chatGuid ?? _parentMessage?.chat.target?.guid ?? '')?.chat ??
                          ChatsSvc.activeChat!.chat;
                      final selected = maybeFindMessagesSvc(chat.guid)
                              ?.getMessageStateIfExists(reaction.associatedMessageGuid!)
                              ?.message ??
                          _parentMessage;
                      if (selected == null) return;

                      showMessageErrorDialog(
                        context,
                        errorCode: errorCode,
                        errorText: errorText,
                        chatId: chat.id!,
                        onRetry: () => retryReaction(
                          reaction: reaction,
                          chat: chat,
                          selected: selected,
                        ),
                        onRemove: () => removeReaction(
                          reaction: reaction,
                          chat: chat,
                        ),
                        removeLabel: ReactionTypes.isRemoval(reaction.associatedMessageType) ? "OK" : "Remove",
                        title: ReactionTypes.isRemoval(reaction.associatedMessageType)
                            ? "Couldn't Remove Reaction"
                            : null,
                      );
                    },
                  ),
                );
              }
              return const SizedBox.shrink();
            }),
          )
        ],
      ),
      );
    }); // Close outer Obx
  }

  /// Static (non-reactive) render used when there is no parent [message]
  /// (e.g. pinned-tile context).  Reads straight from [reaction] without
  /// subscribing to any RxList so GetX never fires the "improper use" warning.
  Widget _buildStatic(BuildContext context, Message reaction) {
    final rType = reaction.associatedMessageType ?? '';
    final isFromMe = reaction.isFromMe ?? false;
    final tailDirection = widget.tailDirection ?? (isFromMe ? ReactionTailDirection.left : ReactionTailDirection.right);
    final tailIsRight = tailDirection == ReactionTailDirection.right;

    if (rType.isEmpty) return const SizedBox.shrink();

    if (SettingsSvc.settings.skin.value != Skins.iOS) {
      final isMaterial = SettingsSvc.settings.skin.value == Skins.Material;
      return Container(
        width: isMaterial ? null : 30,
        height: isMaterial ? 26 : 30,
        constraints: isMaterial ? const BoxConstraints(minWidth: 34) : null,
        padding: isMaterial ? const EdgeInsets.symmetric(horizontal: 8) : null,
        decoration: BoxDecoration(
          color: isFromMe
              ? (isMaterial
                  ? context.theme.colorScheme.primaryContainer
                  : context.theme.colorScheme.primary)
              : (isMaterial
                  ? context.theme.colorScheme.surfaceContainerHighest
                  : ((context.theme.extensions[BubbleColors] as BubbleColors?)?.receivedBubbleColor ??
                      context.theme.colorScheme.surfaceContainerHighest)),
          border: Border.all(
            color: context.theme.colorScheme.surface,
            width: isMaterial ? 1.5 : 1.0,
          ),
          shape: isMaterial ? BoxShape.rectangle : BoxShape.circle,
          borderRadius: isMaterial ? BorderRadius.circular(999) : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 8,
              spreadRadius: 2,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(child: _circleGlyph(reaction, rType)),
      );
    }

    // iOS skin — the pinned tile only shows reactions received (isFromMe==false).
    // Use isFromMe to orient the clipper correctly.
    // Shadow wraps outside the ClipPath so it is not clipped.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            spreadRadius: 0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        alignment: !tailIsRight ? Alignment.centerRight : Alignment.centerLeft,
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: -1,
            left: !tailIsRight ? 0 : -1,
            right: tailIsRight ? 0 : -1,
            child: ClipPath(
              clipper: ReactionBorderClipper(
                tailDirection: tailDirection,
                tailType: widget.tailType,
              ),
              child: Container(
                width: iosSize + 2,
                height: _clipHeight + 2,
                color: context.theme.colorScheme.surface,
              ),
            ),
          ),
          ClipPath(
            clipper: ReactionClipper(
              tailDirection: tailDirection,
              tailType: widget.tailType,
            ),
            child: Container(
              width: iosSize,
              height: _clipHeight,
              color: isFromMe
                  ? context.theme.colorScheme.primary
                  : ((context.theme.extensions[BubbleColors] as BubbleColors?)?.receivedBubbleColor ??
                      context.theme.colorScheme.surfaceContainerHighest),
              alignment: !tailIsRight ? Alignment.topRight : Alignment.topLeft,
              child: SizedBox(
                width: iosSize * 0.8,
                height: iosSize * 0.8,
                child: Center(
                  child: Padding(
                    padding: _glyphPadding(rType),
                    child: _customGlyph(reaction) ?? TapbackIcon(rType),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
