import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class SendButton extends StatefulWidget {
  const SendButton({
    super.key,
    required this.onLongPress,
    required this.sendMessage,
    this.chat,
    this.isScheduled,
  });

  final Function() onLongPress;
  final Function() sendMessage;
  final Chat? chat;
  final bool? isScheduled;

  /// Resolves the Material transport container fill, foreground color, and compact badge label.
  static ({Color container, Color foreground, String? badge}) resolveMaterialStyle(
    ColorScheme scheme, {
    required bool isIMessage,
    required bool isRCS,
    bool hasChat = true,
  }) {
    if (!hasChat) {
      return (container: scheme.primaryContainer, foreground: scheme.onPrimaryContainer, badge: null);
    }
    if (isRCS) {
      return (container: scheme.tertiaryContainer, foreground: scheme.onTertiaryContainer, badge: 'RCS');
    }
    if (isIMessage) {
      return (container: scheme.primaryContainer, foreground: scheme.onPrimaryContainer, badge: 'iMsg');
    }
    return (container: scheme.secondaryContainer, foreground: scheme.onSecondaryContainer, badge: 'SMS');
  }

  @override
  SendButtonState createState() => SendButtonState();
}

class SendButtonState extends State<SendButton> with SingleTickerProviderStateMixin, ThemeHelpers {
  late final controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: SettingsSvc.settings.sendDelay.value),
      animationBehavior: AnimationBehavior.preserve);

  // Colors cached here and refreshed in didChangeDependencies so they update
  // when an inherited Theme changes (e.g. per-chat adaptive theme loading).
  late Color _iosBaseColor;
  late Color _materialBaseColor;
  late Color _errorColor;
  late Color _iosOnPrimary;
  late Color _materialIconColor;
  late Color _onError;

  Color get baseColor => iOS ? _iosBaseColor : _materialBaseColor;

  @override
  void initState() {
    super.initState();
    controller.addListener(() {
      if (controller.isCompleted) {
        controller.reset();
        widget.sendMessage.call();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _iosBaseColor = context.theme.colorScheme.primary;
    _materialBaseColor = context.theme.colorScheme.primaryContainer;
    _errorColor = context.theme.colorScheme.error;
    _iosOnPrimary = context.theme.colorScheme.onPrimary;
    _materialIconColor = context.theme.colorScheme.onPrimaryContainer;
    _onError = context.theme.colorScheme.onError;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTap: () {
        if (controller.isAnimating) {
          controller.reset();
        } else {
          widget.onLongPress.call();
        }
      },
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: iOS ? _iosBaseColor : null,
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          fixedSize: iOS ? const Size(32, 32) : const Size(48, 48),
          maximumSize: iOS ? const Size(32, 32) : const Size(48, 48),
          minimumSize: iOS ? const Size(32, 32) : const Size(48, 48),
          tapTargetSize: iOS ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
        ),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            return _SendButtonIcon(
              animationValue: controller.value,
              baseColor: baseColor,
              errorColor: _errorColor,
              iosOnPrimary: _iosOnPrimary,
              materialSecondary: _materialIconColor,
              onError: _onError,
              chat: widget.chat,
              isScheduled: widget.isScheduled,
            );
          },
        ),
        onPressed: () {
          if (controller.isAnimating) {
            controller.reset();
          } else if (SettingsSvc.settings.sendDelay.value != 0) {
            controller.forward();
          } else {
            HapticFeedback.lightImpact();
            widget.sendMessage.call();
          }
        },
        onLongPress: () {
          if (controller.isAnimating) {
            controller.reset();
          } else {
            widget.onLongPress.call();
          }
        },
      ),
    );
  }
}

/// Extracted animated icon to reduce rebuild scope
class _SendButtonIcon extends StatelessWidget {
  const _SendButtonIcon({
    required this.animationValue,
    required this.baseColor,
    required this.errorColor,
    required this.iosOnPrimary,
    required this.materialSecondary,
    required this.onError,
    this.chat,
    this.isScheduled,
  });

  final double animationValue;
  final Color baseColor;
  final Color errorColor;
  final Color iosOnPrimary;
  final Color materialSecondary;
  final Color onError;
  final Chat? chat;
  final bool? isScheduled;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final skin = SettingsSvc.settings.skin.value;
      final isIOS = skin == Skins.iOS;
      final isMaterial = skin == Skins.Material;
      final isAnimating = animationValue != 0;

      final effectiveChat = chat ?? ChatStateScope.maybeChatOf(context);
      final cvcController = effectiveChat != null && Get.isRegistered<ConversationViewController>(tag: effectiveChat.guid)
          ? Get.find<ConversationViewController>(tag: effectiveChat.guid)
          : null;
      final scheduled = isScheduled ?? (cvcController?.scheduledDate.value != null);

      final materialStyle = isMaterial
          ? SendButton.resolveMaterialStyle(
              context.theme.colorScheme,
              isIMessage: effectiveChat?.isIMessage ?? false,
              isRCS: effectiveChat?.isRCS ?? false,
              hasChat: effectiveChat != null,
            )
          : null;
      final effectiveBaseColor = materialStyle?.container ?? baseColor;
      final effectiveForeground = materialStyle?.foreground ?? materialSecondary;

      Widget iconContent;
      if (isAnimating) {
        iconContent = Icon(
          isIOS ? CupertinoIcons.xmark : Icons.close,
          color: onError,
          size: isIOS ? 20 : 22,
        );
      } else if (isMaterial && (materialStyle?.badge != null || scheduled)) {
        final badge = materialStyle?.badge ?? 'Later';
        iconContent = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              scheduled ? Icons.schedule_send_rounded : Icons.send_rounded,
              color: effectiveForeground,
              size: 18,
            ),
            Text(
              badge,
              maxLines: 1,
              style: TextStyle(
                color: effectiveForeground,
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                height: 1.0,
                letterSpacing: 0.2,
              ),
            ),
          ],
        );
      } else {
        iconContent = Icon(
          isIOS
              ? CupertinoIcons.arrow_up
              : (scheduled ? Icons.schedule_send_rounded : Icons.send_rounded),
          color: isIOS ? iosOnPrimary : effectiveForeground,
          size: isIOS ? 20 : 22,
        );
      }

      return Container(
        width: isIOS ? null : 48,
        height: isIOS ? null : 48,
        constraints: isIOS ? const BoxConstraints(minHeight: 32, minWidth: 32) : null,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (!isIOS && !isAnimating) ? effectiveBaseColor : null,
          gradient: isIOS || isAnimating
              ? LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [effectiveBaseColor, effectiveBaseColor, errorColor, errorColor],
                  stops: [0.0, 1 - animationValue, 1 - animationValue, 1.0],
                )
              : null,
        ),
        alignment: Alignment.center,
        child: iconContent,
      );
    });
  }
}
