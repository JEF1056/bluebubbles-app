import 'package:bluebubbles/app/components/custom/custom_cupertino_alert_dialog.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart' hide CupertinoAlertDialog, CupertinoDialogAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class FailedToScanDialog extends StatelessWidget {
  const FailedToScanDialog({super.key, required this.exception, required this.title});
  final dynamic exception;
  final String title;

  static String _formatError(dynamic exception) {
    String error = exception.toString();
    if (error.contains("ROWID")) {
      error = "iMessage is not configured on the macOS server, please sign in with an Apple ID and try again.";
    }
    return error;
  }

  static Future<void> show(
    BuildContext context, {
    required dynamic exception,
    required String title,
  }) {
    final error = _formatError(exception);
    return showBBDialog<void>(
      context: context,
      icon: Icons.error_outline_rounded,
      iconColor: context.theme.colorScheme.error,
      title: title,
      content: SingleChildScrollView(
        physics: ThemeSwitcher.getScrollPhysics(),
        child: Text(error, style: context.theme.textTheme.bodyMedium),
      ),
      actions: [
        BBDialogAction(
          text: "Copy Error",
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
            Clipboard.setData(ClipboardData(text: error));
            showCopiedToast("Error copied to clipboard");
          },
        ),
        BBDialogAction(
          text: "Dismiss",
          isDefault: true,
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _formatError(exception);
    final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isIOS) {
      return CupertinoTheme(
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
                  Icons.error_outline_rounded,
                  size: 28,
                  color: context.theme.colorScheme.error,
                ),
              ),
              Text(title),
            ],
          ),
          content: Material(
            type: MaterialType.transparency,
            child: SingleChildScrollView(
              physics: ThemeSwitcher.getScrollPhysics(),
              child: Text(error),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              child: const Text("Copy Error"),
              onPressed: () {
                Navigator.of(context).pop();
                Clipboard.setData(ClipboardData(text: error));
                showCopiedToast("Error copied to clipboard");
              },
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              child: const Text("Dismiss"),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
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
          Icons.error_outline_rounded,
          color: context.theme.colorScheme.error,
          size: 24,
        ),
      ),
      title: Text(
        title,
        style: context.theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        textAlign: TextAlign.center,
      ),
      content: SingleChildScrollView(
        physics: ThemeSwitcher.getScrollPhysics(),
        child: Text(error, style: context.theme.textTheme.bodyMedium),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: const StadiumBorder(),
          ),
          child: const Text("Copy Error"),
          onPressed: () {
            Navigator.of(context).pop();
            Clipboard.setData(ClipboardData(text: error));
            showCopiedToast("Error copied to clipboard");
          },
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: const StadiumBorder(),
          ),
          child: const Text("Dismiss"),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
