import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/chat_event/chat_event.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/interactive/open_pigeon_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_holder_indicators.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_holder_reactions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_holder_timestamps.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_holder_wrappers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_reactions.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/reply_bubble_section.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/bubble_effects.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/message_edit_field.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/message_part_content.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/message_properties.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/message_sender.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/select_checkbox.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/slide_to_reply.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/swipe_to_reply_wrapper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_line_painter.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/text/text_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/message_timestamp.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/timestamp_separator.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class MessageHolder extends StatefulWidget {
  MessageHolder({
    super.key,
    required this.cvController,
    this.oldMessage,
    this.newMessage,
    required this.message,
    this.isReplyThread = false,
    this.replyPart,
  }) : ms = MessagesSvc(cvController.chat.guid).getOrCreateState(message);

  final MessageState ms;
  final Message message;
  final Message? oldMessage;
  final Message? newMessage;
  final ConversationViewController cvController;
  final bool isReplyThread;
  final int? replyPart;

  @override
  State<StatefulWidget> createState() => _MessageHolderState();
}

class _MessageHolderState extends State<MessageHolder> with AutomaticKeepAliveClientMixin, ThemeHelpers {
  @override
  bool get wantKeepAlive => true;

  MessageState get controller => widget.ms;

  Message get message => controller.message;

  Message? get olderMessage => controller.oldMessage;

  Message? get newerMessage => controller.newMessage;

  // Computed reactive replyTo getter (resolves root originator across reply chains/off-screen origins)
  Message? get replyTo {
    if (message.threadOriginatorGuid == null) return null;
    if (SettingsSvc.settings.repliesToPrevious.value && message.guid != null) {
      final prev = service.struct.getPreviousReply(
        message.threadOriginatorGuid!,
        message.normalizedThreadPart,
        message.guid!,
      );
      if (prev != null) return prev;
    }
    return resolveRootReplyTarget(message, message.normalizedThreadPart, service: service).message;
  }

  Chat get chat => widget.cvController.chat;

  MessagesService get service => MessagesSvc(widget.cvController.chat.guid);

  // Computed reactive properties
  bool get showSender =>
      !message.isGroupEvent &&
      (!message.sameSender(olderMessage) ||
          (olderMessage?.isGroupEvent ?? false) ||
          (olderMessage == null || !message.dateCreated!.isWithin(olderMessage!.dateCreated!, minutes: 30)));

  bool get canSwipeToReply =>
      SettingsSvc.settings.enablePrivateAPI.value &&
      SettingsSvc.serverDetails.isMinBigSur &&
      (chat.isIMessage || chat.isRCS) &&
      !widget.isReplyThread &&
      !controller.isSending.value &&
      !controller.hasError.value;

  bool get showAvatar => chat.isGroup;

  bool isEditing(int part) =>
      message.isFromMe! &&
      widget.cvController.editing.firstWhereOrNull((e2) => e2.message.guid == message.guid! && e2.part.part == part) !=
          null;

  List<RxDouble> replyOffsets = [];
  List<GlobalKey> keys = [];
  final RxBool tapped = false.obs;

  @override
  void initState() {
    super.initState();
    if (widget.isReplyThread) {
      replyOffsets = List.generate(widget.replyPart != null ? 1 : controller.parts.length, (_) => 0.0.obs);
      keys = List.generate(widget.replyPart != null ? 1 : controller.parts.length, (_) => GlobalKey());
    } else {
      controller.cvController = widget.cvController;
      controller.oldMessage = widget.oldMessage;
      controller.newMessage = widget.newMessage;
      replyOffsets = List.generate(controller.parts.length, (_) => 0.0.obs);
      keys = List.generate(controller.parts.length, (_) => GlobalKey());
    }
  }

  @override
  void didUpdateWidget(MessageHolder old) {
    super.didUpdateWidget(old);
    if (!widget.isReplyThread) {
      controller.oldMessage = widget.oldMessage;
      controller.newMessage = widget.newMessage;
    }
  }

  void completeEdit(String newEdit, int part) async {
    widget.cvController.editing.removeWhere((e2) => e2.message.guid == message.guid! && e2.part.part == part);
    if (newEdit.isNotEmpty && newEdit != controller.parts.firstWhere((element) => element.part == part).text) {
      await service.editMessage(message, part, newEdit);
    }
    widget.cvController.lastFocusedNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    controller.built = true;

    // Cache settings values to avoid repeated observable reads
    final alwaysShowAvatars = material ? false : SettingsSvc.settings.alwaysShowAvatars.value;
    final avatarScale = SettingsSvc.settings.avatarScale.value;

    /// Layout tree
    /// - Timestamp
    /// - Stack (see code comment)
    ///    - avatar | message row
    ///                - spacing (for avatar) | message column | message timestamp
    ///                                          - message part column
    ///                                             - message sender
    ///                                             - reaction spacing box
    ///                                             - previous edits
    ///                                             - message content row
    ///                                                - text / attachment / chat event / interactive | slide to reply
    ///                                                   |-> stack: stickers & reactions
    ///                                             - message properties
    ///                                          - delivered indicator
    // Item Type 5 indicates a kept audio message, we don't need to show this
    if (message.itemType == 5 && message.subject != null) {
      return const SizedBox.shrink();
    }
    final messageState = controller;
    return MessageStateScope(
      messageState: messageState,
      child: Obx(() {
        // Ensure this Obx always has direct reactive dependencies from MessageState & MessagesService.
        // Some render paths can avoid touching other Rx fields.
        // ignore: unused_local_variable
        final _rxGuard = (
          controller.isSending.value,
          controller.hasError.value,
          controller.parts.length,
          controller.threadReplyCount.value,
          message.guid != null ? service.messageUpdateTrigger[message.guid!] : null,
          service.messageUpdateTrigger.length,
        );

        // Read controller.parts reactively so Obx rebuilds when parts change.
        // replyPart is a message-part id, not a list index. A miss must not fall
        // through to the full parts list — that would show the whole message.
        final targetingPart = widget.isReplyThread && widget.replyPart != null;
        final matchedPart = targetingPart ? controller.partById(widget.replyPart!) : null;
        // displayParts is memoized, so collection parts keep their identity across rebuilds of this Obx.
        final messageParts = targetingPart
            ? MessagePart.collapseMediaCollections([
                if (matchedPart != null)
                  matchedPart
                else
                  MessagePart(
                    part: widget.replyPart!,
                    text: "This message is no longer available",
                  ),
              ])
            : controller.displayParts;

        // Grow per-part arrays so replyOffsets[index] and keys[index] are
        // always safe to access, even when parts are added after initState.
        while (replyOffsets.length < messageParts.length) {
          replyOffsets.add(0.0.obs);
          keys.add(GlobalKey());
        }

        // Use MessageState observables for proper reactivity
        final isFromMe = controller.message.isFromMe!;
        // Read so a game turn collapses when an update marks it replaced
        controller.associatedMessageType.value;
        if (!widget.isReplyThread && AppSessionTypes.isEarlierTurn(message)) {
          // Hidden, but the next message's time is measured against this one, so it keeps any separator it starts
          if (isFromMe) return Center(child: TimestampSeparator(olderMessage: olderMessage));
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: TimestampSeparator(olderMessage: olderMessage)),
              Padding(
                padding: EdgeInsets.only(left: showAvatar || alwaysShowAvatars ? 35.0 * avatarScale + 15 : 15),
                child: OpenPigeonEarlierTurn(
                  data: message.payloadData?.appData?.firstOrNull,
                  onTap: OpenPigeon.offered ? () => openOpenPigeonGame(context, message, widget.cvController.chat) : null,
                ),
              ),
            ],
          );
        }

        return AnimatedPadding(
          duration: const Duration(milliseconds: 100),
          padding: EdgeInsets.only(
            left: material ? 12.0 : 0.0,
            right: material ? 12.0 : 0.0,
            top: olderMessage != null && !message.sameSender(olderMessage!) ? 5.0 : 0,
            bottom: newerMessage != null && !message.sameSender(newerMessage!) ? 5.0 : 0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // large timestamp between messages
              TimestampSeparator(olderMessage: olderMessage),
              // use stack so avatar can be placed at bottom
              Row(
                children: [
                  if (!isFromMe && !message.isGroupEvent) SelectCheckbox(controller: widget.cvController),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: isFromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      children: [
                        // message column
                        ...messageParts.mapIndexed((index, e) {
                          final canShowReplyPill = !widget.isReplyThread &&
                              !message.isGroupEvent &&
                              !e.isUnsent &&
                              message.guid != null &&
                              message.threadOriginatorGuid == null;
                          final threadReplies = canShowReplyPill
                              ? collectThreadMessages(
                                  message,
                                  e.coveredPartIds,
                                  service,
                                  includeOriginator: false,
                                  useDb: false,
                                )
                              : const <Message>[];
                          return Padding(
                              padding: e.isMediaCollection
                                  ? const EdgeInsets.only(top: 2.0, bottom: 4.0)
                                  : const EdgeInsets.symmetric(vertical: 2.0),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: isFromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                children: [
                                  // add previous edits if needed
                                  if (e.isEdited)
                                    EditHistoryObserver(
                                      part: e,
                                      newerMessage: newerMessage,
                                      showAvatar: showAvatar,
                                      alwaysShowAvatars: alwaysShowAvatars,
                                      avatarScale: avatarScale,
                                    ),
                                  if (iOS &&
                                      index == 0 &&
                                      !widget.isReplyThread &&
                                      message.threadOriginatorGuid != null &&
                                      (olderMessage == null || message.showUpperMessage(olderMessage!)) &&
                                      replyTo != null &&
                                      replyTo!.guid != null)
                                    Padding(
                                      padding: EdgeInsets.only(
                                          left: (showAvatar || alwaysShowAvatars) && replyTo!.isFromMe! ? 35 : 0),
                                      child: DecoratedBox(
                                        decoration: replyTo!.isFromMe == message.isFromMe
                                            ? ReplyLineDecoration(
                                                isFromMe: message.isFromMe!,
                                                color: context.theme.colorScheme.surfaceContainerHighest,
                                                connectUpper: false,
                                                connectLower: true,
                                                context: context,
                                              )
                                            : const BoxDecoration(),
                                        child: ReplyBubbleSection(
                                          replyTo: replyTo!,
                                          cvController: widget.cvController,
                                          showAvatar: showAvatar,
                                          alwaysShowAvatars: alwaysShowAvatars,
                                          avatarScale: avatarScale,
                                          isIOS: true,
                                          isFirstPart: true,
                                        ),
                                      ),
                                    ),
                                  // show sender, if needed
                                  if (chat.isGroup &&
                                      !message.isFromMe! &&
                                      showSender &&
                                      e.part == (messageParts.firstWhereOrNull((e) => !e.isUnsent)?.part))
                                    Padding(
                                      padding: showAvatar || alwaysShowAvatars
                                          ? EdgeInsets.only(left: 35.0 * avatarScale)
                                          : EdgeInsets.zero,
                                      child: iOS && !widget.isReplyThread && message.threadOriginatorGuid != null
                                          ? SizedBox(
                                              width: double.infinity,
                                              child: CustomPaint(
                                                painter: _ReplyLinePainter(
                                                  color: context.theme.colorScheme.surfaceContainerHighest,
                                                  isFromMe: message.isFromMe!,
                                                ),
                                                child: MessageSender(olderMessage: olderMessage),
                                              ),
                                            )
                                          : MessageSender(olderMessage: olderMessage),
                                    ),
                                  // add a box to account for height of reactions.
                                  // iOS stacks reserve space between the "X Items" label and cards
                                  // instead; skip the bubble-level spacer so it doesn't sit above the label.
                                  iOS &&
                                          !widget.isReplyThread &&
                                          message.threadOriginatorGuid != null &&
                                          replyTo != null &&
                                          replyTo!.isFromMe!
                                      ? Padding(
                                          // Same inset as the bubble below, so this segment meets its reply line
                                          padding: (showAvatar || alwaysShowAvatars) &&
                                                  !(message.isGroupEvent || e.isUnsent)
                                              ? EdgeInsets.only(left: 35.0 * avatarScale)
                                              : EdgeInsets.zero,
                                          child: SizedBox(
                                            width: double.infinity,
                                            child: CustomPaint(
                                              painter: _ReplyLinePainter(
                                                color: context.theme.colorScheme.surfaceContainerHighest,
                                                isFromMe: message.isFromMe!,
                                              ),
                                              child: e.isMediaCollection
                                                  ? SizedBox(height: message.isFromMe! ? 8 : 0)
                                                  : ReactionSpacing(
                                                      part: e,
                                                      minHeightWhenNoReactions: message.isFromMe! ? 8 : 0,
                                                    ),
                                            ),
                                          ),
                                        )
                                      : iOS && e.isMediaCollection
                                          ? SizedBox(
                                              height: iOS &&
                                                      !widget.isReplyThread &&
                                                      message.threadOriginatorGuid != null &&
                                                      message.isFromMe!
                                                  ? 8
                                                  : 0,
                                            )
                                          : ReactionSpacing(
                                              part: e,
                                              minHeightWhenNoReactions: iOS &&
                                                      !widget.isReplyThread &&
                                                      message.threadOriginatorGuid != null &&
                                                      message.isFromMe!
                                                  ? 8
                                                  : 0,
                                            ),
                                  if (!iOS &&
                                      index == 0 &&
                                      !widget.isReplyThread &&
                                      message.threadOriginatorGuid != null &&
                                      replyTo != null &&
                                      replyTo!.guid != null &&
                                      (olderMessage == null || message.showUpperMessage(olderMessage!)))
                                    ReplyBubbleSection(
                                      replyTo: replyTo!,
                                      cvController: widget.cvController,
                                      showAvatar: showAvatar,
                                      alwaysShowAvatars: alwaysShowAvatars,
                                      avatarScale: avatarScale,
                                      isIOS: false,
                                      isFirstPart: true,
                                    ),
                                  Stack(
                                    alignment: Alignment.bottomLeft,
                                    children: [
                                      // avatar, if needed
                                      if (message.showTail(newerMessage) &&
                                          controller.isTrailingMessagePart(e) &&
                                          (showAvatar || alwaysShowAvatars) &&
                                          !message.isFromMe! &&
                                          !message.isGroupEvent)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 5.0),
                                          child: ContactAvatarWidget(
                                            handle: message.handleRelation.target,
                                            size: iOS ? 30 : 35,
                                            fontSize: context.theme.textTheme.bodyLarge!.fontSize!,
                                            borderThickness: 0.1,
                                          ),
                                        ),
                                      Padding(
                                        padding:
                                            (showAvatar || alwaysShowAvatars) && !(message.isGroupEvent || e.isUnsent)
                                                ? EdgeInsets.only(left: 35.0 * avatarScale)
                                                : EdgeInsets.zero,
                                        child: SelectModeWrapper(
                                          cvController: widget.cvController,
                                          tapped: tapped,
                                          child: LayoutBuilder(
                                            builder: (context, constraints) {
                                              final hasBackground =
                                                  ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false;
                                              final lineColor = hasBackground
                                                  ? Colors.white.withValues(alpha: 0.42)
                                                  : (iOS
                                                      ? context.theme.colorScheme.surfaceContainerHighest
                                                      : context.theme.colorScheme.outlineVariant);
                                              final iosEnabled = iOS &&
                                                  !widget.isReplyThread &&
                                                  ((index == 0 &&
                                                          message.threadOriginatorGuid != null &&
                                                          olderMessage != null) ||
                                                      (index == messageParts.length - 1 &&
                                                          threadReplies.isNotEmpty &&
                                                          newerMessage != null));
                                              // Material: draw a single subtle L-hook only when replying directly
                                              // across opposite senders (never full-width loops between stacked same-sender replies).
                                              final materialConnectUpper = !iOS &&
                                                  !widget.isReplyThread &&
                                                  index == 0 &&
                                                  message.threadOriginatorGuid != null &&
                                                  olderMessage != null &&
                                                  olderMessage!.isFromMe != message.isFromMe &&
                                                  !message.showUpperMessage(olderMessage!);
                                              final connectUpper = iosEnabled
                                                  ? message.connectToUpper()
                                                  : materialConnectUpper;
                                              final connectLower = iosEnabled
                                                  ? (newerMessage != null && message.connectToLower(newerMessage!))
                                                  : false;
                                              return ReplyLineBox(
                                                enabled: iosEnabled || materialConnectUpper,
                                                isFromMe: message.isFromMe!,
                                                color: lineColor,
                                                connectUpper: connectUpper,
                                                connectLower: connectLower,
                                                compactHook: !iOS,
                                                child: Align(
                                                  alignment:
                                                      message.isFromMe! ? Alignment.centerRight : Alignment.centerLeft,
                                                  child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    // show group event
                                                    if (message.isGroupEvent || e.isUnsent)
                                                      ChatEvent(
                                                        part: e,
                                                      ),
                                                    if (samsung)
                                                      SamsungTimestampObserver(
                                                        part: e,
                                                        cvController: widget.cvController,
                                                      ),
                                                    // otherwise show content
                                                    if (!message.isGroupEvent && !e.isUnsent)
                                                      Column(
                                                        crossAxisAlignment:
                                                            isFromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                                        children: [
                                                          // interactive messages may have subjects, so render them here
                                                          // also render the subject for attachments that may have not rendered already
                                                          if ((message.hasApplePayloadData ||
                                                                  message.isLegacyUrlPreview ||
                                                                  message.isInteractive ||
                                                                  (controller.isLeadingMessagePart(e) &&
                                                                      isNullOrEmpty(e.text) &&
                                                                      e.attachments.isNotEmpty)) &&
                                                              !isNullOrEmpty(message.subject))
                                                            Padding(
                                                              padding: const EdgeInsets.only(bottom: 6.0),
                                                              child: ClipPath(
                                                                clipper: TailClipper(
                                                                  isFromMe: isFromMe,
                                                                  showTail: false,
                                                                  // The collection grid tightens its top corners
                                                                  // against this subject (hasSubjectAbove), so
                                                                  // the subject tightens its bottom to match.
                                                                  connectLower: BubbleConnect.lower(controller, e) ||
                                                                      (!iOS && e.isMediaCollection),
                                                                  connectUpper: BubbleConnect.upper(controller, e),
                                                                ),
                                                                child: TextBubble(
                                                                  subjectOnly: true,
                                                                  message: MessagePart(
                                                                    subject: message.subject,
                                                                    part: e.part,
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          Stack(
                                                            alignment:
                                                                isFromMe ? Alignment.centerRight : Alignment.centerLeft,
                                                            fit: StackFit.loose,
                                                            clipBehavior: Clip.none,
                                                            children: [
                                                              // Inner Stack: bubble + reactions, sized by the bubble alone
                                                              // so reactions are always anchored to the bubble edge
                                                              StickerSpace(
                                                                part: e,
                                                                columnWidth: constraints.maxWidth,
                                                                child: Stack(
                                                                  alignment: isFromMe
                                                                      ? Alignment.centerRight
                                                                      : Alignment.centerLeft,
                                                                  fit: StackFit.loose,
                                                                  clipBehavior: Clip.none,
                                                                  children: [
                                                                    // actual message content
                                                                    BubbleEffects(
                                                                      part: e.part,
                                                                      globalKey: keys.length > index ? keys[index] : null,
                                                                      showTail: message.showTail(newerMessage) &&
                                                                          controller.isTrailingMessagePart(e),
                                                                      messageState: controller,
                                                                      child: MessagePopupHolder(
                                                                        key: keys.length > index ? keys[index] : null,
                                                                        controller: controller,
                                                                        cvController: widget.cvController,
                                                                        part: e,
                                                                        isEditing: isEditing(e.part),
                                                                        enableGestures: !e.isMediaCollection,
                                                                        child: SwipeToReplyWrapper(
                                                                          enabled: canSwipeToReply &&
                                                                              !isEditing(e.part) &&
                                                                              !e.isMediaCollection,
                                                                          partIndex: e.part,
                                                                          replyOffset: replyOffsets[index],
                                                                          cvController: widget.cvController,
                                                                          child: Builder(
                                                                            builder: (_) {
                                                                              final isCollection = e.isMediaCollection;
                                                                              final inner = Stack(
                                                                                alignment: Alignment.centerRight,
                                                                                children: [
                                                                                  MessagePartContent(
                                                                                    messagePart: e,
                                                                                    cvController: widget.cvController,
                                                                                    canSwipeToReply: canSwipeToReply,
                                                                                  ),
                                                                                  if (message.isFromMe!)
                                                                                    Obx(() {
                                                                                      final editStuff = widget
                                                                                          .cvController.editing
                                                                                          .firstWhereOrNull((e2) =>
                                                                                              e2.message.guid ==
                                                                                                  message.guid! &&
                                                                                              e2.part.part == e.part);
                                                                                      return AnimatedSize(
                                                                                          duration: const Duration(
                                                                                              milliseconds: 250),
                                                                                          alignment: Alignment.centerRight,
                                                                                          curve: Curves.easeOutBack,
                                                                                          child: editStuff == null
                                                                                              ? const SizedBox.shrink()
                                                                                              : MessageEditField(
                                                                                                  part: e.part,
                                                                                                  editController:
                                                                                                      editStuff.controller,
                                                                                                  cvController:
                                                                                                      widget.cvController,
                                                                                                  onComplete: completeEdit,
                                                                                                ));
                                                                                    }),
                                                                                ],
                                                                              );
                                                                              if (isCollection) return inner;
                                                                              return ClipPath(
                                                                                clipper: TailClipper(
                                                                                  isFromMe: message.isFromMe!,
                                                                                  showTail: !e.isPkPass &&
                                                                                      message.showTail(newerMessage) &&
                                                                                      controller.isTrailingMessagePart(e),
                                                                                  connectLower:
                                                                                      BubbleConnect.lower(controller, e),
                                                                                  connectUpper:
                                                                                      BubbleConnect.upper(controller, e),
                                                                                ),
                                                                                child: inner,
                                                                              );
                                                                            },
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                    StickerObserver(
                                                                      part: e,
                                                                      cvController: widget.cvController,
                                                                      placed: true,
                                                                    ),
                                                                    // Reactions are in the inner Stack so they are always
                                                                    // positioned relative to the bubble, not the sticker.
                                                                    // Collection parts show a reaction per attachment instead
                                                                    // (inside CollectionAttachmentCard), since a tapback can be
                                                                    // associated with just one image/video in the collection.
                                                                    if (!e.isMediaCollection)
                                                                      MessageReactions(
                                                                        part: e,
                                                                        chatGuid: chat.guid,
                                                                      ),
                                                                  ],
                                                                ),
                                                              ),
                                                              // Stickers are in the outer Stack so they contribute to
                                                              // the message holder's size but don't affect bubble alignment
                                                              StickerObserver(
                                                                part: e,
                                                                cvController: widget.cvController,
                                                              ),
                                                            ],
                                                          ),
                                                        ],
                                                      ),
                                                    // swipe to reply
                                                    if (canSwipeToReply &&
                                                        !message.isGroupEvent &&
                                                        !e.isUnsent &&
                                                        !widget.isReplyThread &&
                                                        index < replyOffsets.length)
                                                      Obx(() => SlideToReply(
                                                          width: replyOffsets[index].value.abs(),
                                                          isFromMe: message.isFromMe!)),
                                                  ].conditionalReverse(message.isFromMe!),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                  ),
                                  // message properties (edits, effect) & tappable multi-response reply count pill
                                  ..._buildThreadAndPropertiesSection(
                                    context,
                                    index,
                                    e,
                                    keys,
                                    showAvatar,
                                    alwaysShowAvatars,
                                    avatarScale,
                                    isFromMe,
                                    canShowReplyPill,
                                    threadReplies,
                                  ),
                                ],
                              ),
                            );
                        }),
                        // delivered / read receipt
                        DeliveredIndicatorObserver(tapped: tapped),
                      ],
                    ),
                  ),
                  if (isFromMe && !message.isGroupEvent) SelectCheckbox(controller: widget.cvController),
                  ErrorIndicatorObserver(chat: chat, service: service),
                  // slide to view timestamp
                  if (iOS) MessageTimestamp(controller: controller, cvController: widget.cvController),
                ],
              ),
            ],
          ),
        );
      }),
    );
  }

  List<Widget> _buildThreadAndPropertiesSection(
    BuildContext context,
    int index,
    MessagePart e,
    List<GlobalKey> keys,
    bool showAvatar,
    bool alwaysShowAvatars,
    double avatarScale,
    bool isFromMe,
    bool canShowReplyPill,
    List<Message> threadReplies,
  ) {
    final avatarPad =
        !isFromMe && (showAvatar || alwaysShowAvatars) ? EdgeInsets.only(left: 35.0 * avatarScale) : EdgeInsets.zero;

    final propsShowsReplies = canShowReplyPill &&
        !e.isMediaCollection &&
        service.struct.threads(message.guid!, e.part, returnOriginator: false).isNotEmpty;
    final hasNonReplyProperties = e.isEdited || message.expressiveSendStyleId != null;

    final widgets = <Widget>[];
    if (hasNonReplyProperties || (!widget.isReplyThread && threadReplies.isEmpty)) {
      widgets.add(
        Padding(
          padding: avatarPad,
          child: MessageProperties(globalKey: keys.length > index ? keys[index] : null, part: e),
        ),
      );
    }

    if (threadReplies.isNotEmpty && (!hasNonReplyProperties || !propsShowsReplies)) {
      final label = formatReplyCountLabel(threadReplies.length);
      final theme = context.theme;
      final pill = iOS
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showReplyThread(context, message, e, service, widget.cvController),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      label,
                      textHeightBehavior: const TextHeightBehavior(
                        applyHeightToFirstAscent: true,
                        applyHeightToLastDescent: true,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              ),
            )
          : (ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false)
              ? InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => showReplyThread(context, message, e, service, widget.cvController),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          label,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontWeight: FontWeight.w600,
                            shadows: const [Shadow(color: Colors.black54, blurRadius: 3)],
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 15,
                          color: Colors.white.withValues(alpha: 0.88),
                        ),
                      ],
                    ),
                  ),
                )
              : Material(
                  color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => showReplyThread(context, message, e, service, widget.cvController),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.reply_rounded,
                            size: 13,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            label,
                            textHeightBehavior: const TextHeightBehavior(
                              applyHeightToFirstAscent: true,
                              applyHeightToLastDescent: true,
                              leadingDistribution: TextLeadingDistribution.even,
                            ),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );

      widgets.add(
        Padding(
          padding: iOS
              ? avatarPad.add(const EdgeInsets.symmetric(horizontal: 15).add(const EdgeInsets.only(top: 4)))
              : avatarPad.add(const EdgeInsets.only(top: 4)),
          child: pill,
        ),
      );
    }
    return widgets;
  }
}

/// Custom painter to draw a simple vertical line for the reply thread
/// connecting through the message sender
class _ReplyLinePainter extends CustomPainter {
  final Color color;
  final bool isFromMe;

  _ReplyLinePainter({required this.color, required this.isFromMe});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    // Draw vertical line at the same position as the reply line
    // Position depends on message direction: left side if from me, right side if not
    final x = isFromMe ? 35.0 : size.width - 35;
    canvas.drawLine(
      Offset(x, -5),
      Offset(x, size.height - (!isFromMe ? 0 : 5)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ReplyLinePainter oldDelegate) => oldDelegate.color != color || oldDelegate.isFromMe != isFromMe;
}
