import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_device_list_tile.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class FindMyItemsTabView extends StatelessWidget {
  final FindMyController controller;

  const FindMyItemsTabView({super.key, required this.controller});

  static bool _hasLocation(dynamic item) =>
      (item.address?.label ?? item.address?.mapItemFullAddress) != null ||
      (item.location?.latitude != null && item.location?.longitude != null);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final allItems = controller.devices.where((item) => item.isConsideredAccessory).toList();
      final selectedId = controller.selectedDeviceId.value;
      final cs = context.theme.colorScheme;
      final tt = context.theme.textTheme;

      final itemsWithLocation = allItems.where(_hasLocation).toList();
      if (selectedId != null) {
        final idx = itemsWithLocation.indexWhere((d) => d.id == selectedId);
        if (idx > 0) {
          final picked = itemsWithLocation.removeAt(idx);
          itemsWithLocation.insert(0, picked);
        }
      }
      final itemsWithoutLocation = allItems.where((item) => !_hasLocation(item)).toList();

      return SliverList(
        delegate: SliverChildListDelegate([
          if (allItems.isEmpty &&
              (controller.fetching.value == null ||
                  controller.fetching.value == true ||
                  controller.fetching.value == false))
            _buildEmptyState(context),
          if (itemsWithLocation.isNotEmpty)
            Material(
              color: Colors.transparent,
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: itemsWithLocation.length,
                separatorBuilder: (context, i) {
                  final current = itemsWithLocation[i];
                  if (selectedId != null && current.id == selectedId) {
                    return const SizedBox(height: 2);
                  }
                  return Divider(
                    height: 1,
                    indent: 70,
                    endIndent: 16,
                    color: cs.outlineVariant.withValues(alpha: 0.35),
                  );
                },
                itemBuilder: (context, i) => FindMyDeviceListTile(
                  item: itemsWithLocation[i],
                  controller: controller,
                  isItem: true,
                ),
              ),
            ),
          if (itemsWithoutLocation.isNotEmpty) ...[
            if (itemsWithLocation.isNotEmpty)
              Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
                color: cs.outlineVariant.withValues(alpha: 0.35),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Text(
                'No Location Found',
                style: tt.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: itemsWithoutLocation.length,
                separatorBuilder: (context, i) => Divider(
                  height: 1,
                  indent: 70,
                  endIndent: 16,
                  color: cs.outlineVariant.withValues(alpha: 0.35),
                ),
                itemBuilder: (context, i) => FindMyDeviceListTile(
                  item: itemsWithoutLocation[i],
                  controller: controller,
                  isItem: true,
                ),
              ),
            ),
          ],
          const SizedBox(height: 92),
        ]),
      );
    });
  }

  Widget _buildEmptyState(BuildContext context) {
    final cs = context.theme.colorScheme;
    final tt = context.theme.textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: cs.surfaceContainerHigh,
              foregroundColor: cs.onSurfaceVariant,
              child: const Icon(Icons.adjust_rounded, size: 26),
            ),
            const SizedBox(height: 12),
            Text(
              controller.fetching.value == null
                  ? "Something went wrong!"
                  : controller.fetching.value == false
                      ? "No Items Found"
                      : "Getting Find My data...",
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (controller.fetching.value == false) ...[
              const SizedBox(height: 4),
              Text(
                "AirTags and Find My accessories will appear here.",
                textAlign: TextAlign.center,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
            if (controller.fetching.value == true) ...[
              const SizedBox(height: 12),
              GetIt.I.isRegistered<SettingsService>()
                  ? buildProgressIndicator(context, size: 15)
                  : const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ],
        ),
      ),
    );
  }
}
