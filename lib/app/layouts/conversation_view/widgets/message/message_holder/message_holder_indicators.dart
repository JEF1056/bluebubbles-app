import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/shared/message_error_helper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/delivered_indicator.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Isolated widget for delivered indicator
/// Only rebuilds when tapped state changes
class DeliveredIndicatorObserver extends StatelessWidget {
  const DeliveredIndicatorObserver({
    super.key,
    required this.tapped,
  });

  final RxBool tapped;

  @override
  Widget build(BuildContext context) {
    return Obx(() => DeliveredIndicator(
          forceShow: tapped.value,
        ));
  }
}

/// Isolated widget for error indicator
/// Only rebuilds when error state changes
class ErrorIndicatorObserver extends StatelessWidget {
  const ErrorIndicatorObserver({
    super.key,
    required this.chat,
    required this.service,
  });

  final Chat chat;
  final MessagesService service;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final ms = MessageStateScope.of(context);
      final message = ms.message;
      // Observe MessageState error field directly instead of boolean toggle
      final hasError = ms.hasError.value;

      if (hasError) {
        final errorCode = message.error;
        final errorText = ErrorHelper.getErrorText(message);
        final isMaterial = SettingsSvc.settings.skin.value == Skins.Material;

        void openErrorDialog() {
          showMessageErrorDialog(
            context,
            errorCode: errorCode,
            errorText: errorText,
            chatId: chat.id ?? 0,
            onRetry: () => retryMessage(
              message: message,
              chat: chat,
              service: service,
              controller: ms,
            ),
            onRemove: () async {
              await service.deleteMessage(message);
              if (chat.id != null) {
                final latest = await Chat.getMessagesAsync(chat, limit: 1);
                if (latest.isNotEmpty) {
                  ChatsSvc.setChatLatestMessage(chat, latest.first);
                }
                await chat.saveAsync();
              }
            },
          );
        }

        if (isMaterial || kIsWeb || kIsDesktop) {
          return Padding(
            padding: const EdgeInsets.only(left: 4, top: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: errorText,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: openErrorDialog,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        SettingsSvc.settings.skin.value == Skins.iOS
                            ? CupertinoIcons.exclamationmark_circle
                            : Icons.error_outline,
                        size: 16,
                        color: context.theme.colorScheme.error,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => retryMessage(
                    message: message,
                    chat: chat,
                    service: service,
                    controller: ms,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      "Not sent · Retry",
                      style: context.theme.textTheme.labelSmall?.copyWith(
                        color: context.theme.colorScheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return IconButton(
          icon: Icon(
            SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.exclamationmark_circle : Icons.error_outline,
            color: context.theme.colorScheme.error,
          ),
          onPressed: openErrorDialog,
        );
      }
      return const SizedBox.shrink();
    });
  }
}
