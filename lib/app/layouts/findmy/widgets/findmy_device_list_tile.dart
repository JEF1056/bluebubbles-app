import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_detail_sheet.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_device_avatar.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_raw_data_dialog.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_shared_tile.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:maps_launcher/maps_launcher.dart';

class FindMyDeviceListTile extends StatelessWidget {
  final FindMyDevice item;
  final FindMyController controller;
  final bool isItem;

  const FindMyDeviceListTile({
    super.key,
    required this.item,
    required this.controller,
    this.isItem = false,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      controller.freshnessTick.value;
      final hideContactInfo = shouldRedactFindMyContactInfo();

      final displayName =
          hideContactInfo ? (isItem ? "Item" : "Device") : (item.name ?? (isItem ? "Unknown Item" : "Unknown Device"));

      final now = controller.currentTime;
      final isNow = item.isLiveFresh(now) || (item.thisDevice ?? false);
      final freshness = item.displayFreshness(now);
      final hasLocation = item.location?.latitude != null && item.location?.longitude != null;
      final markerPoint = hasLocation ? controller.markerPointForDevice(item) : null;
      final proximity = (hasLocation && !hideContactInfo)
          ? controller.proximityLabelForDevice(item)
          : '';
      final batteryLabel = formatFindMyBattery(item.batteryLevel, status: item.batteryStatus);
      final addressText = hideContactInfo
          ? 'Location'
          : (item.address?.label ?? item.address?.mapItemFullAddress ?? 'No location found');
      final isSelected = item.id != null && controller.selectedDeviceId.value == item.id;
      final isBusy = controller.refreshing.value || item.isLocatingInProgress;
      final cs = context.theme.colorScheme;

      final modelSubtitle = (item.thisDevice ?? false) ? 'This ${item.modelDisplayName ?? 'Device'}' : null;
      final locationLine = hideContactInfo
          ? 'Location'
          : (proximity.isNotEmpty && proximity != 'With You' && proximity != 'Nearby')
              ? '$proximity • $addressText'
              : addressText;

      return FindMySharedTile(
        isSelected: isSelected,
        cardKey: ValueKey('findmy-inline-device-${item.id ?? displayName}'),
        leadingExpanded: FindMyDeviceAvatar(
          device: item,
          size: 44,
          redacted: hideContactInfo,
        ),
        leadingCollapsed: FindMyDeviceAvatar(
          device: item,
          size: 42,
          redacted: hideContactInfo,
        ),
        displayName: displayName,
        modelSubtitle: modelSubtitle,
        locationLine: locationLine,
        showStatusDot: false,
        statusText: isNow
            ? 'Now'
            : (item.isLocatingInProgress ? 'Locating...' : (freshness.isNotEmpty ? freshness : 'Offline')),
        statusActive: isNow,
        statusSuffix: batteryLabel != null ? ' · $batteryLabel' : null,
        isBusyExpanded: isBusy,
        onClearSelection: () => controller.clearSelection(),
        onShowDetails: () => FindMyDetailSheet.showDetailModal(context, controller),
        onLaunchDirections: markerPoint == null
            ? null
            : () => MapsLauncher.launchCoordinates(markerPoint.latitude, markerPoint.longitude),
        directionsLabel: 'Directions',
        secondaryButton: FilledButton.tonalIcon(
          style: FilledButton.styleFrom(shape: const StadiumBorder()),
          onPressed: controller.canRefresh.value && !isBusy ? () => controller.refreshSelected() : null,
          icon: isBusy
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSecondaryContainer),
                )
              : const Icon(Icons.refresh_rounded, size: 18),
          label: Text(isBusy ? 'Updating' : 'Refresh'),
        ),
        extraActions: [
          if (item.canRing || controller.ringingDeviceId.value == item.id)
            Obx(() {
              final isRinging = controller.ringingDeviceId.value == item.id;
              final busy = controller.ringBusy.value;
              return OutlinedButton.icon(
                key: ValueKey('findmy-inline-ring-${item.id ?? displayName}'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  shape: const StadiumBorder(),
                ),
                onPressed: busy ? null : () => controller.toggleRingDevice(item),
                icon: Icon(isRinging ? Icons.stop_rounded : Icons.volume_up_rounded, size: 16),
                label: Text(isRinging ? 'Stop Sound' : 'Play Sound'),
              );
            }),
        ],
        rowSubtitle: modelSubtitle ?? addressText,
        isLocatingRow: item.isLocatingInProgress,
        proximity: proximity,
        showLiveDotInRow: false,
        onTapRow: () => controller.focusDevice(item),
        onLongPress: hideContactInfo
            ? null
            : () => FindMyRawDataDialog.show(context, item),
      );
    });
  }
}
