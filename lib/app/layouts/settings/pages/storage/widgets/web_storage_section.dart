import 'package:bluebubbles/app/layouts/settings/pages/storage/storage_analyzer_controller.dart';
import 'package:bluebubbles/app/layouts/settings/pages/storage/storage_analyzer_helpers.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class WebStorageSection extends StatelessWidget with StorageAnalyzerHelpersMixin {
  const WebStorageSection({super.key, required this.controller});

  final StorageAnalyzerController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final mediaBytes = controller.webMediaUsageBytes.value;
      final originUsage = controller.webOriginUsageBytes.value;
      final originQuota = controller.webOriginQuotaBytes.value;
      final loading = controller.webLoading.value;
      final clearing = controller.webClearingCache.value;

      return SettingsSection(
        backgroundColor: context.tileColor,
        children: [
          SettingsTile(
            title: "Media Cache (BlueBubblesMedia.db)",
            subtitle: loading && mediaBytes == null
                ? "Calculating..."
                : formatBytes(mediaBytes ?? 0),
            backgroundColor: context.tileColor,
          ),
          const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
          SettingsTile(
            title: "Browser Origin Storage (BlueBubblesStore.db + Media)",
            subtitle: originUsage != null && originQuota != null
                ? "${formatBytes(originUsage)} used of ${formatBytes(originQuota)}"
                : loading
                    ? "Estimating..."
                    : "Unavailable in this browser",
            backgroundColor: context.tileColor,
          ),
          const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
          SettingsTile(
            title: clearing ? "Clearing Media Cache..." : "Clear Media Cache",
            subtitle: "Removes cached web attachments, thumbnails, and wallpapers from IndexedDB",
            trailing: clearing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.delete_outline, color: context.theme.colorScheme.error),
            onTap: clearing ? null : () => controller.clearWebMediaCache(),
            backgroundColor: context.tileColor,
          ),
        ],
      );
    });
  }
}
