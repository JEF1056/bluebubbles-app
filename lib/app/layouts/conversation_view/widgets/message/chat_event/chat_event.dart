import 'dart:convert';

import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/facetime_call.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

class ChatEvent extends StatelessWidget {
  const ChatEvent({
    super.key,
    required this.part,
  });

  final MessagePart part;

  @override
  Widget build(BuildContext context) {
    final message = MessageStateScope.messageOf(context);
    final state = MessageStateScope.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
        child: GestureDetector(
          onLongPress: () {
            const encoder = JsonEncoder.withIndent("     ");
            Map map = message.toMap();
            if (map["dateCreated"] is int) {
              map["dateCreated"] =
                  DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateCreated"]));
            }
            if (map["dateDelivered"] is int) {
              map["dateDelivered"] = DateFormat("MMMM d, yyyy h:mm:ss a")
                  .format(DateTime.fromMillisecondsSinceEpoch(map["dateDelivered"]));
            }
            if (map["dateRead"] is int) {
              map["dateRead"] =
                  DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateRead"]));
            }
            if (map["dateEdited"] is int) {
              map["dateEdited"] =
                  DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateEdited"]));
            }
            String str = encoder.convert(map);
            showBBDialog(
              context: context,
              title: "Message Info",
              content: SizedBox(
                width: NavigationSvc.width(context) * 3 / 5,
                height: context.height * 1 / 4,
                child: Container(
                  padding: const EdgeInsets.all(10.0),
                  decoration: BoxDecoration(
                      color: context.theme.colorScheme.surface,
                      borderRadius: const BorderRadius.all(Radius.circular(10))),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      str,
                      style: context.theme.textTheme.bodyLarge,
                    ),
                  ),
                ),
              ),
              actions: [
                BBDialogAction(
                  text: "Close",
                  onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                ),
              ],
            );
          },
          child: Obx(() {
            final chatState = ChatStateScope.maybeOf(context);
            final chat = chatState?.chat;
            if (message.itemType == 6 && !part.isUnsent) {
              return _FaceTimeHistoryCard(
                senderName: state.senderDisplayName,
                dateCreated: message.dateCreated,
                onCallBack: chat != null && canVideoCall(chat) ? () => startVideoCall(context, chat) : null,
              );
            }
            final hasBackground = chatState?.hasCustomWallpaper ?? false;
            final senderName = state.senderDisplayName;
            final text = part.isUnsent
                ? (message.isFromMe!
                    ? "You unsent a message. Others may still see the message on devices where the software hasn't been updated"
                    : "$senderName unsent a message")
                : message.buildGroupEventText(senderName);
            final textColor =
                hasBackground ? context.theme.colorScheme.onSurface : context.theme.colorScheme.outline;
            final textWidget = Text(
              text,
              style: context.theme.textTheme.bodySmall!.copyWith(color: textColor),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              textAlign: TextAlign.center,
            );
            if (!hasBackground) return textWidget;
            return Center(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
                decoration: BoxDecoration(
                  color: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.86),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: textWidget,
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _FaceTimeHistoryCard extends StatelessWidget {
  const _FaceTimeHistoryCard({
    required this.senderName,
    required this.dateCreated,
    this.onCallBack,
  });

  final String senderName;
  final DateTime? dateCreated;
  final VoidCallback? onCallBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = '$senderName started a FaceTime call';
    final timeStr = dateCreated != null ? DateFormat.jm().format(dateCreated!) : null;
    final semanticsLabel = timeStr != null ? '$title, $timeStr' : title;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(FaceTimeDims.tileRadius),
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  label: semanticsLabel,
                  excludeSemantics: true,
                  child: Row(
                    children: [
                      Icon(Icons.videocam_rounded, size: 20, color: colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 14,
                                color: colors.onSurface,
                              ),
                            ),
                            if (timeStr != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                timeStr,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (onCallBack != null) ...[
                const SizedBox(width: 12),
                FilledButton.tonal(
                  onPressed: onCallBack,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: const Text('Call back'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
