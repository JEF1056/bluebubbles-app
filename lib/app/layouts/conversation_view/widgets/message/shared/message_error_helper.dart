import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Helper class for getting error display information
class ErrorHelper {
  /// Returns the body text to display for an error dialog.
  /// Uses the message's [errorMessage] field when available; falls back to a
  /// generic string for older/legacy entries that may not have it set.
  static String getErrorText(Message message) {
    return message.errorMessage ?? "An unknown error occurred.";
  }

  /// Returns the dialog title for the given numeric error code.
  /// Client-side errors show their [ClientMessageError.friendlyTitle].
  /// Server-side errors (including the well-known code 22) fall back to
  /// "iMessage Error (Code X)", and zero / unrecognized codes use a generic title.
  static String getErrorTitle(int errorCode) {
    final clientError = ClientMessageErrorExtension.fromCode(errorCode);
    if (clientError != null) return clientError.friendlyTitle;
    if (errorCode > 0) return "iMessage Error (Code $errorCode)";
    return "Message Failed to Send";
  }
}

/// Displays a skin-aware message/reaction error dialog via [showBBDialog].
Future<void> showMessageErrorDialog(
  BuildContext context, {
  required int errorCode,
  required String errorText,
  required VoidCallback onRetry,
  required VoidCallback onRemove,
  required int chatId,
}) {
  return showBBDialog<void>(
    context: context,
    title: ErrorHelper.getErrorTitle(errorCode),
    body: errorText,
    icon: Icons.error_outline,
    iconColor: context.theme.colorScheme.error,
    actions: [
      BBDialogAction(
        text: "Retry",
        isDefault: true,
        onPressed: () {
          Navigator.of(context, rootNavigator: true).pop();
          onRetry();
        },
      ),
      BBDialogAction(
        text: "Remove",
        isDestructive: true,
        onPressed: () async {
          Navigator.of(context, rootNavigator: true).pop();
          onRemove();
          await NotificationsSvc.clearFailedToSend(chatId);
        },
      ),
      BBDialogAction(
        text: "Cancel",
        onPressed: () async {
          Navigator.of(context, rootNavigator: true).pop();
          await NotificationsSvc.clearFailedToSend(chatId);
        },
      ),
    ],
  );
}

/// Shared retry logic for reactions
Future<void> retryReaction({
  required Message reaction,
  required Chat chat,
  required Message selected,
}) async {
  // Remove the original message and notification
  await MessagesSvc(chat.guid).deleteMessage(reaction);
  await NotificationsSvc.clearFailedToSend(chat.id!);

  // Remove from parent MessageState
  final parentState = MessagesSvc(chat.guid).getMessageStateIfExists(reaction.associatedMessageGuid!);
  if (parentState != null) {
    parentState.removeAssociatedMessageInternal(reaction);
  }

  // Re-send
  OutgoingMsgHandler.queue(
    OutgoingReaction(
      chat: chat,
      message: Message(
        associatedMessageGuid: selected.guid,
        associatedMessageType: reaction.associatedMessageType,
        associatedMessageEmoji: reaction.associatedMessageEmoji,
        associatedMessagePart: reaction.associatedMessagePart,
        dateCreated: DateTime.now(),
        hasAttachments: false,
        isFromMe: true,
        handleId: 0,
      ),
      selectedMessage: selected,
      reaction: reaction.associatedMessageType!,
    ),
  );
}

/// Shared remove logic for reactions
Future<void> removeReaction({
  required Message reaction,
  required Chat chat,
}) async {
  // Delete the message from DB and service
  await MessagesSvc(chat.guid).deleteMessage(reaction);

  // Remove from parent MessageState
  final parentState = MessagesSvc(chat.guid).getMessageStateIfExists(reaction.associatedMessageGuid!);
  if (parentState != null) {
    parentState.removeAssociatedMessageInternal(reaction);
  }

  await NotificationsSvc.clearFailedToSend(chat.id!);
  // Get the "new" latest info
  List<Message> latest = await Chat.getMessagesAsync(chat, limit: 1);
  ChatsSvc.setChatLatestMessage(chat, latest.first);
  await chat.saveAsync();
}

/// Shared retry logic for regular messages
Future<void> retryMessage({
  required Message message,
  required Chat chat,
  required MessagesService service,
  required MessageState controller,
}) async {
  // Retry message through service (updates DB and MessageState)
  await service.retryFailedMessage(message, oldGuid: message.guid);

  // Force UI rebuild to show unsent color
  controller.update();
}
