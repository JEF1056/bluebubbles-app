import 'package:bluebubbles/helpers/helpers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

class ChatCreatorDialogs {
  static Future<void> showGroupChatCreationDialog(BuildContext context) {
    return showBBDialog(
      barrierDismissible: false,
      context: context,
      title: "Group Chat Creation",
      body:
          "Creating group chats from BlueBubbles is not possible on macOS 11 (Big Sur) and later due to limitations from Apple. You must setup the Private API to gain this feature.",
      actions: [
        BBDialogAction(
          text: "Close",
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  static Future<void> showCannotForwardAttachmentDialog(BuildContext context) {
    return showBBDialog(
      context: context,
      title: "Cannot Forward Attachment",
      body: "Attachments cannot be forwarded to a new conversation. Please select an existing contact.",
      actions: [
        BBDialogAction(
          text: "OK",
          isDefault: true,
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  static Widget buildCreatingChatDialog(BuildContext context, String method) {
    return BBProgressDialog(title: "Creating a new $method chat...");
  }

  static Future<void> showCreateChatErrorDialog(BuildContext context, Object error) {
    return showBBDialog(
      context: context,
      title: "Failed to create chat!",
      body: error is Response
          ? "Reason: (${error.data["error"]["type"]}) -> ${error.data["error"]["message"]}"
          : error.toString(),
      actions: [
        BBDialogAction(
          text: "OK",
          isDefault: true,
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }
}
