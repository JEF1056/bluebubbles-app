import 'package:bluebubbles/helpers/helpers.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Optimized reactive widget for contact upload progress
/// Only rebuilds when progress, totalSize, or uploadingContacts changes
class ContactUploadProgress extends StatelessWidget {
  final RxnDouble progress;
  final RxnInt totalSize;
  final RxBool uploadingContacts;
  final VoidCallback onClose;

  const ContactUploadProgress({
    super.key,
    required this.progress,
    required this.totalSize,
    required this.uploadingContacts,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(() => BBProgressDialog(
          title: progress.value == 1 ? "Upload Complete" : "Uploading contacts...",
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Without a size there is nothing to count: the bar alone shows the upload is running.
              if (totalSize.value != null)
                Text(
                  '${progress.value != null ? (progress.value! * totalSize.value! / 1000).getFriendlySize(withSuffix: false) : ""} / ${(totalSize.value!.toDouble() / 1000).getFriendlySize()} (${((progress.value ?? 0) * 100).floor()}%)',
                  style: context.theme.textTheme.bodyMedium,
                ),
              const SizedBox(height: 12.0),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                  value: progress.value,
                  minHeight: 6,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    context.theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 12.0),
              Text(
                progress.value == 1
                    ? "Upload Complete!"
                    : "You can close this dialog. Contacts will continue to upload in the background.",
                textAlign: TextAlign.center,
                style: context.theme.textTheme.bodyMedium,
              ),
            ],
          ),
          actions: [
            if (!uploadingContacts.value)
              BBDialogAction(
                text: "Close",
                isDefault: true,
                onPressed: onClose,
              ),
          ],
        ));
  }
}
