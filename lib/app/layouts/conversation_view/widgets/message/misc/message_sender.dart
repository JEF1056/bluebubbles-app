import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class MessageSender extends StatelessWidget {
  const MessageSender({super.key, required this.olderMessage});

  final Message? olderMessage;

  @override
  Widget build(BuildContext context) {
    final state = MessageStateScope.maybeOf(context);
    if (state == null) return const SizedBox.shrink();
    final chatState = ChatStateScope.maybeOf(context);
    return Padding(
      padding: EdgeInsets.only(
        left: CurrentSkin.material ? 12.0 : 22.0,
        right: 16.0,
        bottom: 2.0,
      ),
      // Obx makes the sender name reactive: updates when contact data syncs.
      child: Obx(() {
        final hasCustomBackground = chatState?.hasCustomWallpaper ?? false;
        return Text(
          state.senderDisplayName,
          style: context.theme.textTheme.labelMedium!.copyWith(
            color: hasCustomBackground
                ? Colors.white.withValues(alpha: 0.88)
                : context.theme.colorScheme.outline,
            fontWeight: FontWeight.normal,
            shadows: hasCustomBackground ? const [Shadow(color: Colors.black54, blurRadius: 3)] : null,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      }),
    );
  }
}
