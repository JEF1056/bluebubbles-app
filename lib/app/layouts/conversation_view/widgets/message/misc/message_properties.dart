import 'package:bluebubbles/app/components/wallpaper/wallpaper_contrast.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_line_painter.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class MessageProperties extends StatefulWidget {
  const MessageProperties({
    super.key,
    required this.part,
    this.globalKey,
  });

  final MessagePart part;
  final GlobalKey? globalKey;

  @override
  State<StatefulWidget> createState() => _MessagePropertiesState();
}

class _MessagePropertiesState extends State<MessageProperties> with ThemeHelpers {
  late MessageState _ms;
  MessageState get controller => _ms;
  late final String _chatGuid;
  Message get message => controller.message;
  MessagesService get service => MessagesSvc(_chatGuid);

  @override
  void initState() {
    super.initState();
    _ms = MessageStateScope.readStateOnce(context);
    _chatGuid = controller.cvController?.chat.guid ?? ChatStateScope.readChatOnce(context).guid;
  }

  List<({String label, VoidCallback onTap})> _getPropertyActions() {
    final properties = <({String label, VoidCallback onTap})>[];
    // Collections are per-attachment for replies (native iMessage). Skip the
    // aggregate bubble-level count; open threads via per-card popup instead.
    final replyList = widget.part.isMediaCollection
        ? const <Message>[]
        : service.struct.threads(message.guid!, widget.part.part, returnOriginator: false);
    if (message.expressiveSendStyleId != null) {
      final effect =
          effectMap.entries.firstWhereOrNull((element) => element.value == message.expressiveSendStyleId)?.key ??
              "unknown";
      properties.add((
        label: "↺ sent with $effect",
        onTap: () {
          if (stringToMessageEffect[effect] == MessageEffect.echo) {
            showSnackbar("Notice", "Echo animation is not supported at this time.", type: SnackbarType.error);
            return;
          }
          HapticFeedback.mediumImpact();
          if ((stringToMessageEffect[effect] ?? MessageEffect.none).isBubble) {
            MessageStateScope.of(context).triggerBubbleEffect(widget.part.part);
          } else if (widget.globalKey != null) {
            EventDispatcherSvc.emit('play-effect', {
              'type': effect,
              'size': widget.globalKey!.globalPaintBounds(context),
            });
          }
        },
      ));
    }
    if (replyList.isNotEmpty) {
      properties.add((
        label: "${replyList.length} repl${replyList.length > 1 ? "ies" : "y"}",
        onTap: () {
          if (controller.cvController == null) return;
          showReplyThread(context, message, widget.part, service, controller.cvController!);
        },
      ));
    }

    return properties;
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Observe granular MessageState fields for thread replies
      controller.associatedMessages.length;

      final hasBackground = ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false;
      final props = _getPropertyActions();
      final textStyle = WallpaperContrast.unbubbledStyle(
        context.theme.textTheme.labelSmall!.copyWith(fontWeight: FontWeight.bold),
        hasWallpaper: hasBackground,
        fallbackColor: context.theme.colorScheme.primary,
      );
      return AnimatedSize(
        curve: Curves.easeInOut,
        alignment: Alignment.bottomCenter,
        duration: const Duration(milliseconds: 250),
        child: props.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15).add(const EdgeInsets.only(top: 3)),
                child: SelectionContainer.disabled(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (var i = 0; i < props.length; i++) ...[
                        if (i > 0) Text(" • ", style: textStyle),
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: SelectionSafeTap(
                            onTap: props[i].onTap,
                            child: Text(props[i].label, style: textStyle),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            : const SizedBox.shrink(),
      );
    });
  }
}
