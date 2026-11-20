import 'package:bluebubbles/app/layouts/findmy/findmy_controller.dart';
import 'package:bluebubbles/app/layouts/findmy/widgets/findmy_friend_list_tile.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class FindMyFriendsTabView extends StatelessWidget {
  final FindMyController controller;

  const FindMyFriendsTabView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      controller.pinVersion.value;
      final selectedId = controller.selectedFriendId.value;
      final allWithLocation = [...controller.friendsWithLocation];
      final pinnedWithLocation = <dynamic>[];
      final unpinnedWithLocation = <dynamic>[];
      for (final f in allWithLocation) {
        if (controller.isFriendPinned(f)) {
          pinnedWithLocation.add(f);
        } else {
          unpinnedWithLocation.add(f);
        }
      }
      void bubbleSelected(List<dynamic> list) {
        if (selectedId == null) return;
        final idx = list.indexWhere((f) => f.stableId == selectedId);
        if (idx > 0) {
          final picked = list.removeAt(idx);
          list.insert(0, picked);
        }
      }
      bubbleSelected(pinnedWithLocation);
      bubbleSelected(unpinnedWithLocation);
      final hasPinnedSection = pinnedWithLocation.isNotEmpty;

      return SliverList(
        delegate: SliverChildListDelegate([
          if (controller.friends.isEmpty &&
              (controller.fetching2.value == null ||
                  controller.fetching2.value == true ||
                  controller.fetching2.value == false))
            _buildEmptyState(context),
          if (hasPinnedSection) ...[
            _buildSectionHeader(context, 'Pinned', topPadding: 8),
            _buildFriendsSection(context, pinnedWithLocation.cast(), selectedId),
          ],
          if (unpinnedWithLocation.isNotEmpty) ...[
            if (hasPinnedSection) _buildSectionHeader(context, 'People', topPadding: 14),
            _buildFriendsSection(context, unpinnedWithLocation.cast(), selectedId),
          ],
          if (controller.friendsWithoutLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: context.tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: const RoundedRectangleBorder(side: BorderSide(color: Colors.transparent)),
                    title: const Text("Friends without locations"),
                    initiallyExpanded: true,
                    children: controller.friendsWithoutLocation
                        .map((item) => FindMyFriendListTile(
                              item: item,
                              controller: controller,
                              withLocation: false,
                            ))
                        .toList(),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 92),
        ]),
      );
    });
  }

  Widget _buildSectionHeader(BuildContext context, String label, {double topPadding = 12}) {
    final cs = context.theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, 4),
      child: Text(
        label,
        style: context.theme.textTheme.labelMedium?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildFriendsSection(BuildContext context, List<dynamic> items, String? selectedId) {
    return Material(
      color: Colors.transparent,
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (context, i) {
          final current = items[i];
          if (selectedId != null && current.stableId == selectedId) {
            return const SizedBox(height: 2);
          }
          return Divider(
            height: 1,
            indent: 74,
            endIndent: 16,
            color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
          );
        },
        itemBuilder: (context, i) => FindMyFriendListTile(
          item: items[i],
          controller: controller,
          withLocation: true,
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final cs = context.theme.colorScheme;
    final tt = context.theme.textTheme;
    final state = controller.fetching2.value;
    final isLoading = state == true && controller.friends.isEmpty;
    final isError = state == null;
    final title = isError
        ? 'Unable to load Find My'
        : isLoading
            ? 'Getting Find My data...'
            : 'No People Found';
    final subtitle = isError
        ? 'Check your server connection and pull down to refresh.'
        : isLoading
            ? 'Fetching shared locations from your account.'
            : 'People who share their location with you will appear here.';

    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: cs.surfaceContainerHigh,
              child: isLoading
                  ? (GetIt.I.isRegistered<SettingsService>()
                      ? buildProgressIndicator(context, size: 20)
                      : SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                        ))
                  : Icon(
                      isError ? Icons.cloud_off_rounded : Icons.people_outline_rounded,
                      size: 26,
                      color: isError ? cs.error : cs.onSurfaceVariant,
                    ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
