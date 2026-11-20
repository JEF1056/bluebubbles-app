import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_detail_sheet.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_raw_data_dialog.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_shared_tile.dart';
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
      final isLocating = item.locatingInProgress ||
          (item.stableId != null && controller.locatingFriendId.value == item.stableId);
      final freshness = formatFindMyFreshness(
        isLiveFresh: isLive,
        locatingInProgress: isLocating,
        isOld: item.isOld,
        lastUpdated: item.lastUpdated,
        now: now,
      );
      final hasLocation = item.latitude != null && item.longitude != null;
      final markerPoint = hasLocation ? controller.markerPointForFriend(item) : null;
      final address = controller.addressForFriend(item, preferLong: true);
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

      final locationLine = hideContactInfo
          ? 'Location'
          : [
              if (proximity.isNotEmpty) proximity,
              address ?? (hasLocation ? 'Coordinates available' : 'No location found'),
            ].join(' • ');
      final rowSubtitle = [
        if (hideContactInfo) 'Location' else address ?? 'No location found',
        if (!isLive && freshness.isNotEmpty) freshness,
      ].join(' · ');

      final isPinned = controller.isFriendPinned(item);

      return FindMySharedTile(
        isSelected: isSelected,
        isPinned: isPinned,
        onTogglePin: () => controller.toggleFriendPin(item),
        cardKey: ValueKey('findmy-inline-friend-${item.stableId ?? displayName}'),
        leadingExpanded: FindMyFriendAvatar(handle: avatarHandle, displayName: displayName, size: 44),
        leadingCollapsed: FindMyFriendAvatar(handle: avatarHandle, displayName: displayName, size: 42),
        displayName: displayName,
        locationLine: locationLine,
        showStatusDot: isLive,
        statusText: isLive ? 'Live' : (freshness.isNotEmpty ? freshness : 'Offline'),
        statusActive: isLive,
        isBusyExpanded: isLocating,
        busyIndicatorKey: ValueKey('findmy-friend-locating-${item.stableId ?? displayName}'),
        onClearSelection: () => controller.clearSelection(),
        onShowDetails: () => FindMyDetailSheet.showDetailModal(context, controller),
        onLaunchDirections: markerPoint == null
            ? null
            : () => MapsLauncher.launchCoordinates(markerPoint.latitude, markerPoint.longitude),
        directionsLabel: eta ?? 'Directions',
        secondaryButton: FilledButton.tonalIcon(
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
        extraActions: [
          OutlinedButton.icon(
            key: const ValueKey('findmy-inline-refresh'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              shape: const StadiumBorder(),
            ),
            onPressed: isLocating ? null : () => controller.refreshSelected(),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(isLocating ? 'Locating...' : 'Refresh'),
          ),
          if (!hideContactInfo && contactAddress.isNotEmpty)
            OutlinedButton.icon(
              key: const ValueKey('findmy-inline-chat'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                shape: const StadiumBorder(),
              ),
              onPressed: () => FindMyDetailSheet.openChat(
                context,
                displayName: displayName,
                address: contactAddress,
              ),
              icon: const Icon(Icons.chat_bubble_outline, size: 16),
              label: const Text('Chat'),
            ),
        ],
        rowSubtitle: rowSubtitle,
        isLocatingRow: isLocating,
        proximity: proximity,
        showLiveDotInRow: isLive,
        onTapRow: () => controller.focusFriend(item),
        onLongPress: hideContactInfo
            ? null
            : () => FindMyRawDataDialog.show(context, item),
      );
    });
  }
}
