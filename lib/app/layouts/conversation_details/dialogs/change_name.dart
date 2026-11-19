import 'dart:async';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';

void showChangeName(Chat chat, String method, BuildContext context) {
  final controller = TextEditingController(text: chat.displayName);
  final node = FocusNode();
  showBBDialog(
    context: context,
    title: "Change Name",
    content: TextField(
      controller: controller,
      focusNode: node,
      decoration: const InputDecoration(
        labelText: "Chat Name",
        border: OutlineInputBorder(),
      ),
    ),
    actions: [
      BBDialogAction(
        text: "Cancel",
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
      BBDialogAction(
        text: "OK",
        isDefault: true,
        onPressed: () async {
          node.unfocus();
          if (method == "private-api") {
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (BuildContext dialogContext) {
                return BBProgressDialog(
                  title: controller.text.isEmpty ? "Removing name..." : "Changing name to ${controller.text}...",
                );
              },
            );
            final response = await HttpSvc.chat.setDisplayName(chat.guid, controller.text);
            if (response.statusCode == 200) {
              if (context.mounted) {
                Navigator.of(context, rootNavigator: true).pop();
                Navigator.of(context, rootNavigator: true).pop();
              }
              unawaited(ChatsSvc.setChatDisplayName(chat, controller.text));
            } else {
              if (context.mounted) {
                Navigator.of(context, rootNavigator: true).pop();
              }
              showSnackbar("Error", "Failed to update name!", type: SnackbarType.error);
            }
          } else {
            Navigator.of(context, rootNavigator: true).pop();
            unawaited(ChatsSvc.setChatDisplayName(chat, controller.text));
          }
        },
      ),
    ],
  ).whenComplete(() {
    controller.dispose();
    node.dispose();
  });
}
