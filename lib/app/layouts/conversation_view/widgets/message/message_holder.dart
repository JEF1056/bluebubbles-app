import 'package:bluebubbles/app/components/blur_fade_switcher.dart';
import 'package:bluebubbles/app/components/wallpaper/wallpaper_contrast.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_drop_target.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/chat_event/chat_event.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/interactive/open_pigeon_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/hover_action_bar.dart';
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
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/vertical_reply_line.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/text/text_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/message_timestamp.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/timestamp_separator.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/unread_separator.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
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

  Message? get olderMessage => widget.isReplyThread ? widget.oldMessage : controller.oldMessage;

  Message? get newerMessage => widget.isReplyThread ? widget.newMessage : controller.newMessage;

  bool get _isThreadOriginator => widget.isReplyThread && widget.oldMessage == null;

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
      (chat.isIMessage ||
          chat.isRCS ||
          (ChatServiceType.fromServiceName(message.service)?.supportsTapbackAndReply ?? false)) &&
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

  bool get _isBreakAbove =>
      olderMessage != null &&
      (olderMessage!.isGroupEvent || message.isGroupEvent || olderMessage!.showTail(message));

  bool get _isBreakBelow =>
      newerMessage != null &&
      (newerMessage!.isGroupEvent || message.isGroupEvent || message.showTail(newerMessage));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    controller.built = true;

    // Cache settings values to avoid repeated observable reads
    final alwaysShowAvatars = material ? false : SettingsSvc.settings.alwaysShowAvatars.value;
    final avatarScale = SettingsSvc.settings.avatarScale.value;
    final avatarIndent = BubbleConnect.incomingAvatarIndent(isIOS: iOS, avatarScale: avatarScale);

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
          controller.updateVersion.value,
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
        final showUnreadDivider = !widget.isReplyThread &&
            message.guid != null &&
            widget.cvController.unreadDividerGuid.value == message.guid;
        final hasTimestampBelow = showUnreadDivider &&
            (SettingsSvc.settings.skin.value == Skins.Samsung
                ? message.dateCreated?.day != olderMessage?.dateCreated?.day
                : (olderMessage != null &&
                    olderMessage!.dateCreated != null &&
                    message.dateCreated != null &&
                    olderMessage!.dateCreated!.difference(message.dateCreated!).inMinutes.abs() > 30));
        // Read so a game turn collapses when an update marks it replaced
        controller.associatedMessageType.value;
        if (!widget.isReplyThread && AppSessionTypes.isEarlierTurn(message)) {
          // Hidden, but the next message's time is measured against this one, so it keeps any separator it starts
          if (isFromMe) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showUnreadDivider) UnreadSeparator(hasTimestampBelow: hasTimestampBelow),
                Center(child: TimestampSeparator(olderMessage: olderMessage)),
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showUnreadDivider) UnreadSeparator(hasTimestampBelow: hasTimestampBelow),
              Center(child: TimestampSeparator(olderMessage: olderMessage)),
              Padding(
                padding: EdgeInsets.only(left: showAvatar || alwaysShowAvatars ? avatarIndent + 15 : 15),
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
            // 2px total inner gap within a same-sender group (1+1) vs 10px at group breaks (5+5).
            top: olderMessage == null ? 0.0 : (_isBreakAbove ? 5.0 : 1.0),
            bottom: newerMessage == null ? 0.0 : (_isBreakBelow ? 5.0 : 1.0),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showUnreadDivider) UnreadSeparator(hasTimestampBelow: hasTimestampBelow),
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
                          final hasMaterialReplyAbove = !iOS &&
                              index == 0 &&
                              !widget.isReplyThread &&
                              message.threadOriginatorGuid != null &&
                              replyTo != null &&
                              replyTo!.guid != null &&
                              (olderMessage == null || message.showUpperMessage(olderMessage!));
                          final isLastPart = index == messageParts.length - 1;
                          return Padding(
                              padding: EdgeInsets.only(
                                top: index == 0 ? 0.0 : 1.0,
                                bottom: isLastPart ? 0.0 : (e.isMediaCollection ? 2.0 : 1.0),
                              ),
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
                                      child: ReplyLineBox(
                                        enabled: replyTo!.isFromMe == message.isFromMe,
                                        isFromMe: message.isFromMe!,
                                        color: context.theme.colorScheme.surfaceContainerHighest,
                                        connectUpper: false,
                                        connectLower: true,
                                        fallbackMaxWidth: NavigationSvc.width(context) * MessageState.maxBubbleSizeFactor,
                                        onTapLine: () {
                                          if (widget.cvController.inSelectMode.value) return;
                                          showReplyThread(context, message, e, service, widget.cvController);
                                        },
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
                                          ? EdgeInsets.only(left: avatarIndent)
                                          : EdgeInsets.zero,
                                      child: iOS && !widget.isReplyThread && message.threadOriginatorGuid != null
                                          ? VerticalReplyLine(
                                              color: context.theme.colorScheme.surfaceContainerHighest,
                                              isFromMe: message.isFromMe!,
                                              onTap: () {
                                                if (widget.cvController.inSelectMode.value) return;
                                                showReplyThread(context, message, e, service, widget.cvController);
                                              },
                                              child: MessageSender(olderMessage: olderMessage),
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
                                          child: VerticalReplyLine(
                                            color: context.theme.colorScheme.surfaceContainerHighest,
                                            isFromMe: message.isFromMe!,
                                            onTap: () {
                                              if (widget.cvController.inSelectMode.value) return;
                                              showReplyThread(context, message, e, service, widget.cvController);
                                            },
                                            child: e.isMediaCollection
                                                ? SizedBox(height: message.isFromMe! ? 8 : 0)
                                                : ReactionSpacing(
                                                    part: e,
                                                    minHeightWhenNoReactions: message.isFromMe! ? 8 : 0,
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
                                          : (!hasMaterialReplyAbove
                                              ? ReactionSpacing(
                                                  part: e,
                                                  minHeightWhenNoReactions: iOS &&
                                                          !widget.isReplyThread &&
                                                          message.threadOriginatorGuid != null &&
                                                          message.isFromMe!
                                                      ? 8
                                                      : 0,
                                                )
                                              : const SizedBox.shrink()),
                                  if (hasMaterialReplyAbove) ...[
                                    ReplyBubbleSection(
                                      replyTo: replyTo!,
                                      cvController: widget.cvController,
                                      showAvatar: showAvatar,
                                      alwaysShowAvatars: alwaysShowAvatars,
                                      avatarScale: avatarScale,
                                      isIOS: false,
                                      isFirstPart: true,
                                    ),
                                    // Clear tapback overhang below the quoted reply preview without overlapping it.
                                    ReactionSpacing(part: e, tapbackHeight: 8.0),
                                  ],
                                  Stack(
                                    alignment: Alignment.bottomLeft,
                                    children: [
                                      // avatar, if needed (anchored to last bubble in group)
                                      if ((newerMessage == null ||
                                              newerMessage!.isGroupEvent ||
                                              message.showTail(newerMessage)) &&
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
                                                ? EdgeInsets.only(left: avatarIndent)
                                                : EdgeInsets.zero,
                                        child: SelectModeWrapper(
                                          cvController: widget.cvController,
                                          tapped: tapped,
                                          child: LayoutBuilder(
                                            builder: (context, constraints) {
                                              final hasBackground =
                                                  ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false;
                                              final lineColor = WallpaperContrast.replyLineColor(
                                                context,
                                                hasWallpaper: hasBackground,
                                                isIOS: iOS,
                                              );
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
                                                onTapLine: () =>
                                                    showReplyThread(context, message, e, service, widget.cvController),
                                                child: Align(
                                                  alignment:
                                                      message.isFromMe! ? Alignment.centerRight : Alignment.centerLeft,
                                                  child: (message.isGroupEvent || e.isUnsent)
                                                      ? Row(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            ChatEvent(part: e),
                                                            if (samsung)
                                                              SamsungTimestampObserver(
                                                                part: e,
                                                                cvController: widget.cvController,
                                                              ),
                                                          ].conditionalReverse(message.isFromMe!),
                                                        )
                                                      : HoverablePartRow(
                                                          enabled: (kIsWeb || kIsDesktop) &&
                                                              !widget.cvController.inSelectMode.value &&
                                                              !isEditing(e.part) &&
                                                              !samsung,
                                                          showHoverBar: !kIsWeb && constraints.maxWidth >= 440,
                                                          isFromMe: message.isFromMe!,
                                                          controller: controller,
                                                          part: e,
                                                          cvController: widget.cvController,
                                                          service: service,
                                                          isReplyThread: widget.isReplyThread,
                                                          leadingChildren: [
                                                            if (samsung)
                                                              SamsungTimestampObserver(
                                                                part: e,
                                                                cvController: widget.cvController,
                                                              ),
                                                          ],
                                                          bubbleChild: Column(
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
                                                              padding: const EdgeInsets.only(bottom: 2.0),
                                                              child: ClipPath(
                                                                clipper: TailClipper(
                                                                  isFromMe: isFromMe,
                                                                  showTail: false,
                                                                  // The collection grid tightens its top corners
                                                                  // against this subject (hasSubjectAbove), so
                                                                  // the subject tightens its bottom to match.
                                                                  connectLower: _isThreadOriginator
                                                                      ? false
                                                                      : (BubbleConnect.lower(controller, e,
                                                                              newerMessage: newerMessage) ||
                                                                          (!iOS && e.isMediaCollection)),
                                                                  connectUpper: _isThreadOriginator
                                                                      ? false
                                                                      : BubbleConnect.upper(controller, e,
                                                                          olderMessage: olderMessage),
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
                                                            alignment: isFromMe
                                                                ? Alignment.centerRight
                                                                : Alignment.centerLeft,
                                                            fit: StackFit.loose,
                                                            clipBehavior: Clip.none,
                                                            children: [
                                                              // Inner Stack: bubble + reactions, sized by the bubble alone
                                                              // so reactions are always anchored to the bubble edge
                                                              StickerSpace(
                                                                part: e,
                                                                columnWidth: constraints.maxWidth,
                                                                child: MaterialReactionBubble(
                                                                  part: e,
                                                                  enabled: !e.isMediaCollection,
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
                                                                      showTail: !_isThreadOriginator &&
                                                                          message.showTail(newerMessage) &&
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
                                                                              final partContent = MessagePartContent(
                                                                                messagePart: e,
                                                                                cvController: widget.cvController,
                                                                                canSwipeToReply: canSwipeToReply,
                                                                              );
                                                                              final inner = Stack(
                                                                                alignment: Alignment.centerRight,
                                                                                children: [
                                                                                  _isThreadOriginator
                                                                                      ? GhostBubbleScope(
                                                                                          child: partContent,
                                                                                        )
                                                                                      : partContent,
                                                                                  if (message.isFromMe!)
                                                                                    Obx(() {
                                                                                      final editStuff = widget
                                                                                          .cvController.editing
                                                                                          .firstWhereOrNull((e2) =>
                                                                                              e2.message.guid ==
                                                                                                  message.guid! &&
                                                                                              e2.part.part == e.part);
                                                                                      return AnimatedSize(
                                                                                          duration: motionDuration(
                                                                                              context,
                                                                                              const Duration(
                                                                                                  milliseconds: 200)),
                                                                                          alignment: Alignment.centerRight,
                                                                                          curve: Curves.easeOutCubic,
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
                                                                                  showTail: !_isThreadOriginator &&
                                                                                      !e.isPkPass &&
                                                                                      message.showTail(newerMessage) &&
                                                                                      controller.isTrailingMessagePart(e),
                                                                                  connectLower: _isThreadOriginator
                                                                                      ? false
                                                                                      : BubbleConnect.lower(controller, e,
                                                                                          newerMessage: newerMessage),
                                                                                  connectUpper: _isThreadOriginator
                                                                                      ? false
                                                                                      : BubbleConnect.upper(controller, e,
                                                                                          olderMessage: olderMessage),
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
                                                                    ),
                                                                    if (SettingsSvc.getServerDetails().supportsStickers)
                                                                      Positioned.fill(
                                                                        child: StickerDropTarget(
                                                                          message: message,
                                                                          part: e.part,
                                                                          chat: widget.cvController.chat,
                                                                          tailGutter: CurrentSkin.iOS && !e.isMediaCollection,
                                                                        ),
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
                                                                        showInMaterial: false,
                                                                      ),
                                                                  ],
                                                                ),
                                                              ),
                                                              ),
                                                            ],
                                                          ),
                                                        ],
                                                        ),
                                                        trailingChildren: [
                                                          if (canSwipeToReply &&
                                                              !widget.isReplyThread &&
                                                              index < replyOffsets.length)
                                                            Obx(() => SlideToReply(
                                                                width: replyOffsets[index].value.abs(),
                                                                isFromMe: message.isFromMe!)),
                                                        ],
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
    final avatarPad = !isFromMe && (showAvatar || alwaysShowAvatars)
        ? EdgeInsets.only(left: BubbleConnect.incomingAvatarIndent(isIOS: iOS, avatarScale: avatarScale))
        : EdgeInsets.zero;

    final propsShowsReplies = canShowReplyPill &&
        !e.isMediaCollection &&
        service.struct.threads(message.guid!, e.part, returnOriginator: false).isNotEmpty;
    final hasNonReplyProperties = message.expressiveSendStyleId != null;

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
      final cs = context.theme.colorScheme;
      final baseLabelStyle = context.theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600);
      const evenHeight = TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
        leadingDistribution: TextLeadingDistribution.even,
      );
      void openThread() => showReplyThread(context, message, e, service, widget.cvController);
      final hasWallpaper = !iOS && (ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false);

      final Widget pill = iOS
          ? SelectionSafeTap(
              behavior: HitTestBehavior.opaque,
              onTap: openThread,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, textHeightBehavior: evenHeight, style: baseLabelStyle?.copyWith(color: cs.primary, height: 1.2)),
                    const SizedBox(width: 2),
                    Icon(CupertinoIcons.chevron_right, size: 12, color: cs.primary),
                  ],
                ),
              ),
            )
          : SelectionSafeTap.builder(
              onTap: openThread,
              builder: (_, handleTap) {
                final ink = InkWell(
                  borderRadius: BorderRadius.circular(hasWallpaper ? 12 : 16),
                  onTap: handleTap,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: hasWallpaper ? 4 : 10, vertical: hasWallpaper ? 3 : 4),
                    child: hasWallpaper
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                label,
                                style: WallpaperContrast.unbubbledStyle(
                                  baseLabelStyle ?? const TextStyle(),
                                  hasWallpaper: true,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 15,
                                color: WallpaperContrast.unbubbledTextColor,
                                shadows: WallpaperContrast.unbubbledTextShadows,
                              ),
                            ],
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.reply_rounded, size: 13, color: cs.onSecondaryContainer),
                              const SizedBox(width: 4),
                              Text(
                                label,
                                textHeightBehavior: evenHeight,
                                style: baseLabelStyle?.copyWith(color: cs.onSecondaryContainer, height: 1.2),
                              ),
                            ],
                          ),
                  ),
                );
                return hasWallpaper
                    ? ink
                    : Material(
                        color: cs.secondaryContainer.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: ink,
                      );
              },
            );

      widgets.add(
        Padding(
          padding: avatarPad.add(EdgeInsets.only(top: 4, left: iOS ? 15 : 0, right: iOS ? 15 : 0)),
          child: pill,
        ),
      );
    }
    return widgets;
  }
}
