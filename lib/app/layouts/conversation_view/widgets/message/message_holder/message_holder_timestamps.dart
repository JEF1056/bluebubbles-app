import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/text/text_bubble.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/message_timestamp.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Isolated widget for Samsung timestamp with reaction-aware padding
class SamsungTimestampObserver extends StatelessWidget {
  const SamsungTimestampObserver({
    super.key,
    required this.part,
    required this.cvController,
  });

  final MessagePart part;
  final ConversationViewController cvController;

  @override
  Widget build(BuildContext context) {
    final ms = MessageStateScope.of(context);
    return Obx(() {
      final isFromMe = ms.isFromMe.value;
      return Padding(
        padding: ms.hasVisibleTapbacks(part)
            ? EdgeInsets.only(left: isFromMe ? 0 : 10, right: isFromMe ? 20 : 0)
            : const EdgeInsets.only(right: 10),
        child: MessageTimestamp(controller: ms, cvController: cvController),
      );
    });
  }
}

/// Isolated widget for edit history display
/// Only rebuilds when showEdits flag changes
class EditHistoryObserver extends StatelessWidget {
  const EditHistoryObserver({
    super.key,
    required this.part,
    required this.newerMessage,
    required this.showAvatar,
    required this.alwaysShowAvatars,
    required this.avatarScale,
  });

  final MessagePart part;
  final Message? newerMessage;
  final bool showAvatar;
  final bool alwaysShowAvatars;
  final double avatarScale;

  @override
  Widget build(BuildContext context) {
    final ms = MessageStateScope.of(context);
    final message = MessageStateScope.messageOf(context);
    final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;
    return Padding(
      padding: !message.isFromMe! && (showAvatar || alwaysShowAvatars)
          ? EdgeInsets.only(left: BubbleConnect.incomingAvatarIndent(isIOS: isIOS, avatarScale: avatarScale))
          : EdgeInsets.zero,
      child: Obx(() => AnimatedSize(
            duration: const Duration(milliseconds: 250),
            alignment: Alignment.bottomCenter,
            curve: ms.showEdits.value ? Curves.easeOutBack : Curves.easeOut,
            child: ms.showEdits.value
                ? Opacity(
                    opacity: 0.75,
                    child: Column(
                      crossAxisAlignment: message.isFromMe! ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: part.edits
                          .indexed
                          .map((entry) => Padding(
                                padding: const EdgeInsets.only(bottom: 2.0),
                                child: ClipPath(
                                  clipper: TailClipper(
                                    isFromMe: message.isFromMe!,
                                    showTail: false,
                                    connectLower: true,
                                    connectUpper: entry.$1 > 0 || BubbleConnect.upper(ms, part),
                                  ),
                                  child: TextBubble(
                                    message: entry.$2,
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                  )
                : Container(
                    height: 0,
                    constraints: BoxConstraints(maxWidth: MessageState.maxBubbleWidth(context, inset: 30))),
          )),
    );
  }
}
