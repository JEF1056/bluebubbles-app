import 'package:bluebubbles/app/components/custom/custom_cupertino_alert_dialog.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart' hide CupertinoAlertDialog, CupertinoDialogAction;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class FailedToConnectDialog extends StatelessWidget {
  const FailedToConnectDialog({super.key, required this.onDismiss});
  final Function() onDismiss;

  static Future<void> show(BuildContext context, {required VoidCallback onDismiss}) {
    final authFailed = SocketSvc.authFailed.value;
    final body = authFailed
        ? "The server rejected the password. Check it and try again."
        : "Please make sure you are connected to the internet and your server is online.";
    return showBBDialog<void>(
      context: context,
      barrierDismissible: false,
      icon: authFailed ? Icons.lock_outline_rounded : Icons.wifi_off_rounded,
      iconColor: context.theme.colorScheme.error,
      title: authFailed ? "Incorrect Password" : "Failed To Connect",
      content: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) onDismiss();
        },
        child: Text(body),
      ),
      actions: [
        BBDialogAction(
          text: "Dismiss",
          isDefault: true,
          onPressed: onDismiss,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final authFailed = SocketSvc.authFailed.value;
    final title = authFailed ? "Incorrect Password" : "Failed To Connect";
    final body = authFailed
        ? "The server rejected the password. Check it and try again."
        : "Please make sure you are connected to the internet and your server is online.";
    final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: <T>(bool didPop, T? result) async {
        if (didPop) return;
        onDismiss();
      },
      child: isIOS
          ? CupertinoTheme(
              data: CupertinoThemeData(
                brightness: Theme.of(context).brightness,
                primaryColor: context.theme.colorScheme.primary,
              ),
              child: CupertinoAlertDialog(
                backgroundColor: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.76 : 0.82),
                title: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Icon(
                        authFailed ? Icons.lock_outline_rounded : Icons.wifi_off_rounded,
                        size: 28,
                        color: context.theme.colorScheme.error,
                      ),
                    ),
                    Text(title),
                  ],
                ),
                content: Material(type: MaterialType.transparency, child: Text(body)),
                actions: [
                  CupertinoDialogAction(
                    isDefaultAction: true,
                    onPressed: onDismiss,
                    child: const Text("Dismiss"),
                  ),
                ],
              ),
            )
          : AlertDialog(
              backgroundColor: context.theme.colorScheme.surfaceContainerHigh,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              icon: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: context.theme.colorScheme.error.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  authFailed ? Icons.lock_outline_rounded : Icons.wifi_off_rounded,
                  color: context.theme.colorScheme.error,
                  size: 24,
                ),
              ),
              title: Text(
                title,
                style: context.theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              content: Text(body, style: context.theme.textTheme.bodyMedium),
              actions: [
                FilledButton(
                  onPressed: onDismiss,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text("Dismiss"),
                ),
              ],
            ),
    );
  }
}
