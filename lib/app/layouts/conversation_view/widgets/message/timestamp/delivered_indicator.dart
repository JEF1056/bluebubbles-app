import 'dart:async';

import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class DeliveredIndicator extends StatefulWidget {
  const DeliveredIndicator({
    super.key,
    required this.forceShow,
  });

  final bool forceShow;

  @override
  State<StatefulWidget> createState() => _DeliveredIndicatorState();
}

class _DeliveredIndicatorState extends State<DeliveredIndicator> with ThemeHelpers {
  late MessageState controller;
  late final bool _isGroup;
  Message get message => controller.message;
  bool get showAvatar => _isGroup;

  // Debounced shadow of isSending. Goes true immediately when sending starts,
  // but stays true for at least _sendingMinDisplayMs after sending ends so the
  // "Sending..." label outlives the send animation (~650 ms total).
  bool _isSendingDisplayed = false;
  Timer? _sendingTimer;
  Worker? _isSendingWorker;
  static const int _sendingMinDisplayMs = 700;

  @override
  void initState() {
    super.initState();
    controller = MessageStateScope.readStateOnce(context);
    final fallbackChat = ChatStateScope.maybeReadChatOnce(context);
    _isGroup = controller.cvController?.chat.isGroup ?? fallbackChat?.isGroup ?? false;
    _isSendingDisplayed = controller.isSending.value;
    _isSendingWorker = ever(controller.isSending, _onIsSendingChange);
  }

  void _onIsSendingChange(bool newVal) {
    if (newVal) {
      _sendingTimer?.cancel();
      if (mounted) setState(() => _isSendingDisplayed = true);
    } else if (_isSendingDisplayed) {
      _sendingTimer = Timer(const Duration(milliseconds: _sendingMinDisplayMs), () {
        if (mounted) setState(() => _isSendingDisplayed = false);
      });
    }
  }

  @override
  void dispose() {
    _isSendingWorker?.dispose();
    _sendingTimer?.cancel();
    super.dispose();
  }

  bool get shouldShow {
    if (controller.audioWasKept.value != null) return true;
    if (widget.forceShow || _isSendingDisplayed) return true;
    if ((!message.isFromMe! && iOS) || (controller.parts.lastOrNull?.isUnsent ?? false)) return false;

    // Visibility for "last delivered/read/sent" is computed by
    // MessagesService._recomputeDeliveredIndicators and stored reactively on
    // the MessageState — each tier is independent.
    return controller.showReadIndicator.value || controller.showDeliveredIndicator.value;
  }

  List<InlineSpan> buildTwoPiece(String action, String? date) {
    final material = !iOS && !samsung;
    final hasBackground = ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false;
    final color = hasBackground
        ? Colors.white.withValues(alpha: 0.86)
        : (material ? context.theme.colorScheme.onSurfaceVariant : context.theme.colorScheme.outline);
    final shadows = hasBackground ? const [Shadow(color: Colors.black54, blurRadius: 3)] : null;
    final baseStyle = material ? context.theme.textTheme.bodySmall! : context.theme.textTheme.labelSmall!;
    final hasDate = date != null && date.isNotEmpty;
    return [
      TextSpan(
        text: action,
        style: baseStyle.copyWith(fontWeight: material ? FontWeight.w500 : FontWeight.w600, color: color, shadows: shadows),
      ),
      if (hasDate)
        TextSpan(
          text: material ? " · $date" : " $date",
          style: baseStyle.copyWith(color: color, fontWeight: FontWeight.normal, shadows: shadows),
        ),
    ];
  }

  List<InlineSpan> getText() {
    // Use reactive MessageState fields for Obx subscription
    final material = !iOS && !samsung;
    final dateRead = controller.dateRead.value ?? message.dateRead;
    final dateDelivered = controller.dateDelivered.value ?? message.dateDelivered;
    final wasDeliveredQuietly = controller.wasDeliveredQuietly.value;
    final didNotifyRecipient = controller.didNotifyRecipient.value;

    if (controller.audioWasKept.value != null) {
      return buildTwoPiece("Kept", buildDate(controller.audioWasKept.value!));
    } else if (!(message.isFromMe ?? false)) {
      return buildTwoPiece("Received", buildDate(message.dateCreated));
    } else if (dateRead != null) {
      return buildTwoPiece("Read", buildDate(dateRead));
    } else if (dateDelivered != null) {
      return buildTwoPiece(
          "Delivered${wasDeliveredQuietly && !didNotifyRecipient ? " Quietly" : ""}",
          SettingsSvc.settings.showDeliveryTimestamps.value || !iOS || widget.forceShow
              ? buildDate(dateDelivered)
              : null);
    } else if (message.isDelivered) {
      return buildTwoPiece("Delivered", null);
    } else if (_isSendingDisplayed && (material || !(controller.cvController?.chat.isGroup ?? _isGroup)) && !iOS) {
      return buildTwoPiece("Sending...", null);
    } else if (widget.forceShow) {
      return buildTwoPiece("Sent", buildDate(message.dateCreated));
    }

    return [];
  }

  @override
  Widget build(BuildContext context) {
    final material = !iOS && !samsung;
    final indentLeft =
        (showAvatar || (!material && SettingsSvc.settings.alwaysShowAvatars.value)) && !(message.isFromMe ?? false)
            ? 35.0
            : 0.0;
    return AnimatedSize(
      curve: Curves.easeInOut,
      alignment: Alignment.bottomCenter,
      duration: const Duration(milliseconds: 250),
      child: Obx(() {
        // Observe the fields that affect both shouldShow and getText.
        // isSending is handled via the debounced _isSendingDisplayed + setState,
        // not subscribed here, so the "Sending..." label outlives the animation.
        controller.showReadIndicator.value;
        controller.showDeliveredIndicator.value;
        controller.audioWasKept.value;
        controller.dateDelivered.value;
        controller.dateRead.value;
        return shouldShow && getText().isNotEmpty
            ? Padding(
                padding: EdgeInsets.symmetric(horizontal: material ? 4 : 15)
                    .add(EdgeInsets.only(top: 2, bottom: 2, left: indentLeft)),
                child: Text.rich(TextSpan(
                  children: getText(),
                )),
              )
            : const SizedBox.shrink();
      }),
    );
  }
}
