import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_detail_sheet.dart';
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
      final deviceIcon = iconForFindMyDevice(item);
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
        leadingExpanded: CircleAvatar(
          radius: 22,
          backgroundColor: cs.surfaceContainerHighest,
          foregroundColor: cs.onSurface,
          child: Icon(deviceIcon, size: 22),
        ),
        leadingCollapsed: CircleAvatar(
          radius: 21,
          backgroundColor: cs.surfaceContainerHighest,
          foregroundColor: cs.onSurface,
          child: Icon(deviceIcon, size: 20),
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
        rowSubtitle: modelSubtitle ?? addressText,
        isLocatingRow: item.isLocatingInProgress,
        proximity: proximity,
        showLiveDotInRow: false,
        onTapRow: markerPoint != null ? () => controller.focusDevice(item) : null,
        onLongPress: hideContactInfo
            ? null
            : () => FindMyRawDataDialog.show(context, item),
      );
    });
  }
}
