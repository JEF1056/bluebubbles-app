import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_detail_sheet.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_raw_data_dialog.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:maps_launcher/maps_launcher.dart';

class FindMyFriendListTile extends StatelessWidget {
  final FindMyFriend item;
  final FindMyController controller;
  final bool withLocation;

  const FindMyFriendListTile({
    super.key,
    required this.item,
    required this.controller,
    this.withLocation = true,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      controller.freshnessTick.value;
      if (GetIt.I.isRegistered<ContactServiceV2>()) {
        ContactsSvcV2.cacheVersion.value;
      }
      final hideContactInfo = shouldRedactFindMyContactInfo();
      final now = controller.currentTime;
      final isLive = item.isLiveFresh(now);
      final freshness = item.displayFreshness(now);
      final hasLocation = item.latitude != null && item.longitude != null;
      final markerPoint = hasLocation ? controller.markerPointForFriend(item) : null;
      final address = controller.addressForFriend(item, preferLong: !withLocation);
      final proximity = (withLocation && hasLocation && !hideContactInfo)
          ? controller.proximityLabelForFriend(item)
          : '';
      final eta = (withLocation && hasLocation && !hideContactInfo)
          ? controller.etaLabelForFriend(item)
          : null;

      final displayName = item.resolveDisplayName(hideContactInfo: hideContactInfo);
      final contactAddress = item.handleAddress ?? item.title ?? '';
      final avatarHandle = item.handle ??
          Handle(
            address: item.handleAddress ?? item.title ?? "Unknown",
            formattedAddress: item.handleAddress != null ? formatPhoneNumber(item.handleAddress!) : null,
          );
      final isSelected = item.stableId != null && controller.selectedFriendId.value == item.stableId;
      final isLocating = item.locatingInProgress ||
          (item.stableId != null && controller.locatingFriendId.value == item.stableId);
      final cs = context.theme.colorScheme;
      final tt = context.theme.textTheme;

      if (isSelected) {
        final locationLine = hideContactInfo
            ? 'Location'
            : [
                if (proximity.isNotEmpty) proximity,
                address ?? (hasLocation ? 'Coordinates available' : 'No location found'),
              ].join(' • ');

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Material(
            key: ValueKey('findmy-inline-friend-${item.stableId ?? displayName}'),
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
                        FindMyFriendAvatar(
                          handle: avatarHandle,
                          displayName: displayName,
                          size: 44,
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
                              const SizedBox(height: 2),
                              Text(
                                locationLine,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  if (isLive) ...[
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFF22C55E),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                  ],
                                  Text(
                                    isLive
                                        ? 'Live'
                                        : (isLocating
                                            ? 'Locating...'
                                            : (freshness.isNotEmpty ? freshness : 'Offline')),
                                    style: tt.labelMedium?.copyWith(
                                      color: isLive ? const Color(0xFF22C55E) : cs.onSurfaceVariant,
                                      fontWeight: isLive ? FontWeight.w700 : FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (isLocating) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 34,
                            child: Center(
                              child: SizedBox(
                                key: ValueKey('findmy-friend-locating-${item.stableId ?? displayName}'),
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                              ),
                            ),
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
                              label: Text(
                                eta ?? 'Directions',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(shape: const StadiumBorder()),
                              onPressed: contactAddress.isEmpty || hideContactInfo
                                  ? null
                                  : () => FindMyDetailSheet.openContact(
                                        context,
                                        displayName: displayName,
                                        address: contactAddress,
                                        handle: item.handle,
                                      ),
                              icon: const Icon(Icons.person_outline, size: 18),
                              label: const Text('Contact'),
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

      final subtitleParts = <String>[
        if (hideContactInfo)
          'Location'
        else
          address ?? 'No location found',
        if (!isLive && freshness.isNotEmpty) freshness,
      ];

      return ListTile(
        mouseCursor: MouseCursor.defer,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: FindMyFriendAvatar(
          handle: avatarHandle,
          displayName: displayName,
          size: 42,
        ),
        title: Text(
          displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitleParts.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        trailing: isLocating
            ? SizedBox(
                width: 24,
                height: 24,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurfaceVariant),
                  ),
                ),
              )
            : (proximity.isNotEmpty
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLive) ...[
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: Color(0xFF22C55E),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        proximity,
                        style: tt.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  )
                : null),
        onTap: withLocation && markerPoint != null ? () => controller.focusFriend(item) : null,
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
