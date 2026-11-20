import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';

import 'message_holder_reactions.dart';

/// Consolidated widget for displaying reactions on a message part
/// Handles both isFromMe and !isFromMe cases
class MessageReactions extends StatelessWidget {
  const MessageReactions({
    super.key,
    required this.part,
    required this.chatGuid,
    this.showInMaterial = true,
  });

  final MessagePart part;
  final String chatGuid;

  /// When false, Material reactions are rendered by [MaterialReactionBubble] overlapping
  /// the bubble's bottom edge rather than inside the inner bubble Stack.
  final bool showInMaterial;

  @override
  Widget build(BuildContext context) {
    return ReactionObserver(
      part: part,
      chatGuid: chatGuid,
      showInMaterial: showInMaterial,
    );
  }
}
