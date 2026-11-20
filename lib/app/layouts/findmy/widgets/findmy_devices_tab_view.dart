import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_device_list_tile.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class FindMyDevicesTabView extends StatelessWidget {
  final FindMyController controller;

  const FindMyDevicesTabView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => FindMyDeviceCategoryTabView(controller: controller, isItem: false);
}

class FindMyDeviceCategoryTabView extends StatelessWidget {
  final FindMyController controller;
  final bool isItem;

  const FindMyDeviceCategoryTabView({super.key, required this.controller, required this.isItem});

  static bool _hasLocation(dynamic item) =>
      (item.address?.label ?? item.address?.mapItemFullAddress) != null ||
      (item.location?.latitude != null && item.location?.longitude != null);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final allEntries = controller.devices.where((d) => d.isConsideredAccessory == isItem).toList();
      final selectedId = controller.selectedDeviceId.value;
      final cs = context.theme.colorScheme;
      final tt = context.theme.textTheme;

      final withLocation = allEntries.where(_hasLocation).toList();
      if (selectedId != null) {
        final idx = withLocation.indexWhere((d) => d.id == selectedId);
        if (idx > 0) {
          final picked = withLocation.removeAt(idx);
          withLocation.insert(0, picked);
        }
      }
      final withoutLocation = allEntries.where((item) => !_hasLocation(item)).toList();

      return SliverList(
        delegate: SliverChildListDelegate([
          if (allEntries.isEmpty) _buildEmptyState(context),
          if (withLocation.isNotEmpty)
            _buildSectionList(withLocation, selectedId: selectedId, dividerColor: cs.outlineVariant.withValues(alpha: 0.35)),
          if (withoutLocation.isNotEmpty) ...[
            if (withLocation.isNotEmpty)
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
            _buildSectionList(withoutLocation, dividerColor: cs.outlineVariant.withValues(alpha: 0.35)),
          ],
          SizedBox(height: 112 + MediaQuery.viewPaddingOf(context).bottom),
        ]),
      );
    });
  }

  Widget _buildSectionList(List items, {String? selectedId, required Color dividerColor}) {
    return Material(
      color: Colors.transparent,
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (context, i) {
          if (selectedId != null && items[i].id == selectedId) {
            return const SizedBox(height: 2);
          }
          return Divider(
            height: 1,
            indent: 70,
            endIndent: 16,
            color: dividerColor,
          );
        },
        itemBuilder: (context, i) => FindMyDeviceListTile(
          item: items[i],
          controller: controller,
          isItem: isItem,
        ),
      ),
    );
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
              child: Icon(isItem ? Icons.adjust_rounded : Icons.devices_outlined, size: 26),
            ),
            const SizedBox(height: 12),
            Text(
              controller.fetching.value == null
                  ? "Something went wrong!"
                  : controller.fetching.value == false
                      ? (isItem ? "No Items Found" : "No Devices Found")
                      : "Getting Find My data...",
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (isItem && controller.fetching.value == false) ...[
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
