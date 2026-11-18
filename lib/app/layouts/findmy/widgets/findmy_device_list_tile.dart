import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_detail_sheet.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_raw_data_dialog.dart';
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
      final isLive = item.isLiveFresh(now);
      final isNow = isLive || (item.thisDevice ?? false);
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
      final tt = context.theme.textTheme;

      if (isSelected) {
        final modelSubtitle = (item.thisDevice ?? false)
            ? 'This ${item.modelDisplayName ?? 'Device'}'
            : null;
        final locationLine = hideContactInfo
            ? 'Location'
            : (proximity.isNotEmpty && proximity != 'With You' && proximity != 'Nearby')
                ? '$proximity • $addressText'
                : addressText;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Material(
            key: ValueKey('findmy-inline-device-${item.id ?? displayName}'),
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => controller.clearSelection(),
              onLongPress: hideContactInfo
                  ? null
                  : () => showDialog(
                        context: context,
                        builder: (context) => FindMyRawDataDialog(item: item),
                      ),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 22,
                          backgroundColor: cs.surfaceContainerHighest,
                          foregroundColor: cs.onSurface,
                          child: Icon(deviceIcon, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              if (modelSubtitle != null) ...[
                                const SizedBox(height: 1),
                                Text(
                                  modelSubtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                ),
                              ],
                              const SizedBox(height: 1),
                              Text(
                                locationLine,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  Text(
                                    isNow
                                        ? 'Now'
                                        : (item.isLocatingInProgress
                                            ? 'Locating...'
                                            : (freshness.isNotEmpty ? freshness : 'Offline')),
                                    style: tt.labelMedium?.copyWith(
                                      color: isNow ? const Color(0xFF22C55E) : cs.onSurfaceVariant,
                                      fontWeight: isNow ? FontWeight.w700 : FontWeight.w500,
                                    ),
                                  ),
                                  if (batteryLabel != null) ...[
                                    Text(
                                      ' · $batteryLabel',
                                      style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (isBusy) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                          ),
                        ],
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 34,
                          height: 34,
                          child: IconButton.filledTonal(
                            key: const ValueKey('findmy-inline-more'),
                            padding: EdgeInsets.zero,
                            tooltip: 'Details',
                            onPressed: () => FindMyDetailSheet.showDetailModal(context, controller),
                            icon: const Icon(Icons.more_horiz, size: 18),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(shape: const StadiumBorder()),
                              onPressed: markerPoint == null
                                  ? null
                                  : () async {
                                      await MapsLauncher.launchCoordinates(
                                        markerPoint.latitude,
                                        markerPoint.longitude,
                                      );
                                    },
                              icon: const Icon(Icons.directions_outlined, size: 18),
                              label: const Text('Directions'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(shape: const StadiumBorder()),
                              onPressed: controller.canRefresh.value && !isBusy
                                  ? () => controller.refreshSelected()
                                  : null,
                              icon: isBusy
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: cs.onSecondaryContainer,
                                      ),
                                    )
                                  : const Icon(Icons.refresh_rounded, size: 18),
                              label: Text(isBusy ? 'Updating' : 'Refresh'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      final rowSubtitle = (item.thisDevice ?? false)
          ? 'This ${item.modelDisplayName ?? 'Device'}'
          : addressText;

      return ListTile(
        mouseCursor: MouseCursor.defer,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: CircleAvatar(
          radius: 21,
          backgroundColor: cs.surfaceContainerHighest,
          foregroundColor: cs.onSurface,
          child: Icon(deviceIcon, size: 20),
        ),
        title: Text(
          displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          rowSubtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        onTap: markerPoint != null ? () => controller.focusDevice(item) : null,
        trailing: item.isLocatingInProgress
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurfaceVariant),
              )
            : (proximity.isNotEmpty
                ? Text(
                    proximity,
                    style: tt.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                : null),
        onLongPress: hideContactInfo
            ? null
            : () async {
                showDialog(
                  context: context,
                  builder: (context) => FindMyRawDataDialog(item: item),
                );
              },
      );
    });
  }
}
