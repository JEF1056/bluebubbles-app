import 'package:bluebubbles/app/layouts/chat_creator/chat_creator.dart';
import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_pin_marker.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_raw_data_dialog.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:latlong2/latlong.dart';
import 'package:maps_launcher/maps_launcher.dart';
import 'package:slugify/slugify.dart';

/// Apple Find My iOS-style detail sheet rendered inside the Material 3 bottom sheet / side panel
/// when a friend, device, or item is selected from the map or list.
class FindMyDetailSheet extends StatelessWidget {
  const FindMyDetailSheet({
    super.key,
    required this.controller,
    this.onClose,
  });

  static Future<void> openContact(
    BuildContext context, {
    required String displayName,
    required String address,
    Handle? handle,
  }) async {
    if (!kIsWeb && !kIsDesktop) {
      final contact = handle?.contactsV2.firstOrNull;
      if (contact != null && contact.isNative) {
        await MethodChannelSvc.actions.viewContactForm(nativeContactId: contact.nativeContactId);
      } else {
        await MethodChannelSvc.actions.openContactForm(
          address: address,
          isEmail: address.isEmail,
          name: displayName,
        );
      }
      return;
    }

    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(displayName),
        content: SelectableText(address),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: address));
              Navigator.of(ctx).pop();
              showSnackbar('Copied', 'Copied contact address');
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static void showDetailModal(BuildContext context, FindMyController controller) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetCtx) => SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).padding.bottom + 12),
          child: FindMyDetailSheet(
            controller: controller,
            onClose: () => Navigator.of(sheetCtx).pop(),
          ),
        ),
      ),
    );
  }

  final FindMyController controller;
  final VoidCallback? onClose;

  void _handleClose() {
    if (onClose != null) {
      onClose!();
    } else {
      controller.clearSelection();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final _ = controller.freshnessTick.value;
      if (GetIt.I.isRegistered<ContactServiceV2>()) {
        ContactsSvcV2.cacheVersion.value;
      }
      final friend = controller.selectedFriend;
      final device = controller.selectedDevice;
      if (friend == null && device == null) {
        return const SizedBox.shrink();
      }
      if (friend != null) {
        return _buildFriendDetail(context, friend);
      }
      return _buildDeviceDetail(context, device!);
    });
  }

  Widget _buildFriendDetail(BuildContext context, FindMyFriend friend) {
    final redacted = shouldRedactFindMyContactInfo();
    final title = redacted ? 'Friend' : friend.resolveDisplayName();
    final addressHandle = friend.handle?.address ?? friend.handleAddress;
    final subtitle = (!redacted && addressHandle != null && addressHandle != title) ? addressHandle : null;
    final now = controller.currentTime;
    final isLive = friend.isLiveFresh(now);
    final isLocating = friend.locatingInProgress ||
        (friend.stableId != null && controller.locatingFriendId.value == friend.stableId);
    final statusText = friend.displayFreshness(now);
    final hasCoords = (friend.latitude ?? 0) != 0 && (friend.longitude ?? 0) != 0;
    final displayAddress = redacted
        ? 'Location hidden'
        : (controller.addressForFriend(friend, preferLong: true) ??
            (hasCoords ? 'Resolving address...' : 'Location unavailable'));

    final distanceText = _distanceLabel(
      hasCoords ? LatLng(friend.latitude!, friend.longitude!) : null,
      redacted: redacted,
    );
    final accuracy = friend.horizontalAccuracy;
    final accuracyText = (!redacted && accuracy != null && accuracy > 0) ? '±${accuracy.round()}m' : null;
    final speed = friend.speed;
    final speedText = (!redacted && speed != null && speed.isFinite && speed >= 0.5)
        ? '${(speed * 3.6).round()} km/h'
        : null;
    final altitude = friend.altitude;
    final altitudeText =
        (!redacted && altitude != null && altitude.isFinite) ? '${altitude.round()}m alt' : null;
    final avatarHandle = friend.handle ??
        Handle(
          address: friend.handleAddress ?? friend.title ?? 'Unknown',
          formattedAddress: friend.handleAddress != null ? formatPhoneNumber(friend.handleAddress!) : null,
        );

    return _DetailSheetFrame(
      leading: Stack(
        alignment: Alignment.center,
        children: [
          FindMyPulsingHalo(
            active: isLive || isLocating,
            pulseNonce: controller.livePulseNonce.value,
            size: 64,
            color: isLive ? const Color(0xFF22C55E) : context.theme.colorScheme.primary,
          ),
          FindMyFriendAvatar(
            handle: avatarHandle,
            displayName: title,
            size: 50,
          ),
        ],
      ),
      title: title,
      subtitle: subtitle,
      pills: [
        if (isLive)
          const FindMyLiveBadge()
        else
          _CenteredPill(
            icon: isLocating ? Icons.sync : Icons.access_time,
            label: isLocating ? 'Locating...' : (statusText.isEmpty ? 'Offline' : statusText),
          ),
        if (isLive && isLocating)
          const _CenteredPill(
            icon: Icons.sync,
            label: 'Updating...',
          ),
        if (accuracyText != null) _CenteredPill(icon: Icons.gps_fixed, label: accuracyText),
        if (speedText != null) _CenteredPill(icon: Icons.speed, label: speedText),
        if (altitudeText != null) _CenteredPill(icon: Icons.terrain, label: altitudeText),
      ],
      addressText: displayAddress,
      distanceText: distanceText,
      isOffline: !hasCoords,
      onClose: _handleClose,
      actions: [
        _ActionTile(
          icon: Icons.directions,
          label: 'Directions',
          enabled: hasCoords,
          onTap: () => MapsLauncher.launchCoordinates(friend.latitude!, friend.longitude!),
        ),
        _RefreshActionTile(controller: controller),
        _LiveToggleTile(controller: controller),
        if (!redacted && addressHandle != null && addressHandle.isNotEmpty) ...[
          _ActionTile(
            icon: Icons.chat_bubble_outline,
            label: 'Message',
            onTap: () => _openChat(context, displayName: title, address: addressHandle),
          ),
          _ActionTile(
            icon: Icons.person_outline,
            label: 'Contact',
            onTap: () => _openContact(context, displayName: title, address: addressHandle, handle: friend.handle),
          ),
        ],
        if (!redacted)
          _ActionTile(
            icon: Icons.info_outline,
            label: 'Info',
            onTap: () => showDialog(
              context: context,
              builder: (_) => FindMyRawDataDialog(item: friend),
            ),
          ),
      ],
    );
  }

  Widget _buildDeviceDetail(BuildContext context, FindMyDevice device) {
    final redacted = shouldRedactFindMyContactInfo();
    final title = redacted ? (device.isConsideredAccessory ? 'Item' : 'Device') : (device.name ?? 'Device');
    final modelName = !redacted ? (device.modelDisplayName ?? device.deviceDisplayName) : null;
    final subtitle = (modelName != null && modelName != title) ? modelName : null;
    final now = controller.currentTime;
    final isLive = device.isLiveFresh(now);
    final isLocating = device.isLocatingInProgress;
    final statusText = device.displayFreshness(now);
    final hasCoords = device.location?.latitude != null && device.location?.longitude != null;
    final rawAddress = device.address?.label ?? device.address?.mapItemFullAddress;
    final displayAddress = redacted
        ? 'Location hidden'
        : (rawAddress ?? (hasCoords ? 'Coordinates available' : 'Location unavailable'));

    final distanceText = _distanceLabel(
      hasCoords ? LatLng(device.location!.latitude!, device.location!.longitude!) : null,
      redacted: redacted,
    );
    final batteryLabel = formatFindMyBattery(device.batteryLevel, status: device.batteryStatus);
    final accuracy = device.location?.horizontalAccuracy;
    final accuracyText = (!redacted && accuracy != null && accuracy > 0) ? '±${accuracy.round()}m' : null;
    final cs = context.theme.colorScheme;

    return _DetailSheetFrame(
      leading: Stack(
        alignment: Alignment.center,
        children: [
          FindMyPulsingHalo(
            active: isLive || isLocating,
            pulseNonce: controller.livePulseNonce.value,
            size: 64,
            color: isLive ? const Color(0xFF22C55E) : cs.primary,
          ),
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              shape: BoxShape.circle,
              border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Center(
              child: (device.role?['emoji'] != null && !redacted)
                  ? Text(
                      device.role!['emoji'].toString(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24),
                    )
                  : Icon(
                      iconForFindMyDevice(device),
                      color: cs.onSurface,
                      size: 24,
                    ),
            ),
          ),
        ],
      ),
      title: title,
      subtitle: subtitle,
      pills: [
        if (isLive)
          const FindMyLiveBadge()
        else
          _CenteredPill(
            icon: isLocating ? Icons.sync : Icons.access_time,
            label: isLocating && statusText.isEmpty ? 'Locating...' : (statusText.isEmpty ? 'Offline' : statusText),
          ),
        if (batteryLabel != null)
          _CenteredPill(
            icon: _batteryIcon(device.batteryLevel, device.batteryStatus),
            label: batteryLabel,
            tint: _batteryColor(context, device.batteryLevel, device.batteryStatus),
          ),
        if (accuracyText != null) _CenteredPill(icon: Icons.gps_fixed, label: accuracyText),
        if (device.isInaccurate)
          _CenteredPill(
            icon: Icons.warning_amber_rounded,
            label: 'Low accuracy',
            tint: cs.error,
          ),
      ],
      addressText: displayAddress,
      distanceText: distanceText,
      isOffline: !hasCoords,
      onClose: _handleClose,
      actions: [
        _ActionTile(
          icon: Icons.directions,
          label: 'Directions',
          enabled: hasCoords,
          onTap: () => MapsLauncher.launchCoordinates(device.location!.latitude!, device.location!.longitude!),
        ),
        _RefreshActionTile(controller: controller),
        _LiveToggleTile(controller: controller),
        if (!redacted)
          _ActionTile(
            icon: Icons.info_outline,
            label: 'Info',
            onTap: () => showDialog(
              context: context,
              builder: (_) => FindMyRawDataDialog(item: device),
            ),
          ),
      ],
    );
  }

  String? _distanceLabel(LatLng? target, {required bool redacted}) {
    if (redacted || target == null) return null;
    final userPos = controller.location.value;
    if (userPos == null) return null;
    final meters = distanceMetersBetween(LatLng(userPos.latitude, userPos.longitude), target);
    final formatted = formatFindMyDistance(meters);
    return formatted.isEmpty ? null : formatted;
  }

  IconData _batteryIcon(double? level, String? status) {
    if (status?.toLowerCase() == 'charging') return Icons.battery_charging_full;
    if (level == null) return Icons.battery_unknown;
    final pct = level <= 1.0 ? level * 100 : level;
    if (pct <= 15) return Icons.battery_alert;
    if (pct <= 40) return Icons.battery_3_bar;
    if (pct <= 75) return Icons.battery_5_bar;
    return Icons.battery_full;
  }

  Color _batteryColor(BuildContext context, double? level, String? status) {
    if (status?.toLowerCase() == 'charging') return const Color(0xFF16A34A);
    if (level != null) {
      final pct = level <= 1.0 ? level * 100 : level;
      if (pct <= 20) return context.theme.colorScheme.error;
    }
    return context.theme.colorScheme.onSurfaceVariant;
  }

  Future<void> _openChat(BuildContext context, {required String displayName, required String address}) async {
    Chat? existingChat;
    try {
      if (kIsWeb) {
        existingChat = await Chat.findOneWeb(chatIdentifier: slugify(address, delimiter: ''));
      } else {
        existingChat = Chat.findOne(chatIdentifier: slugify(address, delimiter: ''));
      }
    } catch (_) {}

    if (!context.mounted) return;
    if (existingChat != null) {
      NavigationSvc.pushAndRemoveUntil(
        context,
        ConversationView(chat: existingChat),
        (route) => route.isFirst,
      );
    } else {
      NavigationSvc.pushAndRemoveUntil(
        context,
        NewChatCreator(
          initialSelected: [SelectedContact(displayName: displayName, address: address)],
        ),
        (route) => route.isFirst,
      );
    }
  }

  Future<void> _openContact(
    BuildContext context, {
    required String displayName,
    required String address,
    Handle? handle,
  }) =>
      FindMyDetailSheet.openContact(
        context,
        displayName: displayName,
        address: address,
        handle: handle,
      );
}

class _DetailSheetFrame extends StatelessWidget {
  const _DetailSheetFrame({
    required this.leading,
    required this.title,
    this.subtitle,
    required this.pills,
    required this.addressText,
    this.distanceText,
    required this.isOffline,
    required this.onClose,
    required this.actions,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final List<Widget> pills;
  final String addressText;
  final String? distanceText;
  final bool isOffline;
  final VoidCallback onClose;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    final tt = context.theme.textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: pills,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                key: const ValueKey('findmy-detail-close'),
                onPressed: onClose,
                tooltip: 'Back to list',
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      isOffline ? Icons.location_off_outlined : Icons.location_on_outlined,
                      size: 18,
                      color: isOffline ? cs.onSurfaceVariant : cs.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        addressText,
                        style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
                if (distanceText != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.near_me_outlined, size: 16, color: cs.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Text(
                        distanceText!,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final count = actions.length.clamp(2, 4);
              final tileWidth = ((constraints.maxWidth - spacing * (count - 1)) / count).clamp(72.0, 150.0);
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: actions
                    .map((a) => SizedBox(width: tileWidth, child: a))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CenteredPill extends StatelessWidget {
  const _CenteredPill({
    required this.icon,
    required this.label,
    this.tint,
  });

  final IconData icon;
  final String label;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    final fg = tint ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.65)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: context.theme.textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.selected = false,
    this.customIcon,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool selected;
  final Widget? customIcon;

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    final bg = !enabled
        ? cs.surfaceContainerHighest.withValues(alpha: 0.5)
        : selected
            ? cs.primaryContainer
            : cs.secondaryContainer;
    final fg = !enabled
        ? cs.onSurface.withValues(alpha: 0.38)
        : selected
            ? cs.onPrimaryContainer
            : cs.onSecondaryContainer;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              customIcon ?? Icon(icon, size: 20, color: fg),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.theme.textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RefreshActionTile extends StatelessWidget {
  const _RefreshActionTile({required this.controller});

  final FindMyController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final isBusy = controller.refreshing.value || controller.refreshing2.value;
      final canTap = controller.canRefresh.value && !isBusy;
      return _ActionTile(
        icon: Icons.refresh,
        label: isBusy ? 'Updating' : 'Refresh',
        enabled: canTap,
        onTap: controller.refreshSelected,
        customIcon: isBusy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.theme.colorScheme.onSecondaryContainer,
                ),
              )
            : null,
      );
    });
  }
}

class _LiveToggleTile extends StatelessWidget {
  const _LiveToggleTile({required this.controller});

  final FindMyController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final liveOn = controller.liveTrackingEnabled.value;
      return _ActionTile(
        icon: liveOn ? Icons.sensors : Icons.sensors_off,
        label: liveOn ? 'Live On' : 'Live Off',
        selected: liveOn,
        onTap: controller.toggleLiveTracking,
      );
    });
  }
}
