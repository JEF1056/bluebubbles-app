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
      final selectedId = controller.selectedFriendId.value;
      final orderedWithLocation = [...controller.friendsWithLocation];
      if (selectedId != null) {
        final idx = orderedWithLocation.indexWhere((f) => f.stableId == selectedId);
        if (idx > 0) {
          final picked = orderedWithLocation.removeAt(idx);
          orderedWithLocation.insert(0, picked);
        }
      }

      return SliverList(
        delegate: SliverChildListDelegate([
          if (controller.friends.isEmpty &&
              (controller.fetching2.value == null ||
                  controller.fetching2.value == true ||
                  controller.fetching2.value == false))
            _buildEmptyState(context),
          if (orderedWithLocation.isNotEmpty)
            Material(
              color: Colors.transparent,
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: orderedWithLocation.length,
                separatorBuilder: (context, i) {
                  final current = orderedWithLocation[i];
                  if (selectedId != null && current.stableId == selectedId) {
                    return const SizedBox(height: 2);
                  }
                  return Divider(
                    height: 1,
                    indent: 70,
                    endIndent: 16,
                    color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
                  );
                },
                itemBuilder: (context, i) => FindMyFriendListTile(
                  item: orderedWithLocation[i],
                  controller: controller,
                  withLocation: true,
                ),
              ),
            ),
          if (controller.friendsWithoutLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: context.tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ExpansionTile(
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

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 100),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                controller.fetching2.value == null
                    ? "Something went wrong!"
                    : controller.fetching2.value == false
                        ? "You have no friends."
                        : "Getting FindMy data...",
                style: context.theme.textTheme.labelLarge,
              ),
            ),
            if (controller.fetching2.value == true)
              GetIt.I.isRegistered<SettingsService>()
                  ? buildProgressIndicator(context, size: 15)
                  : const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
      ),
    );
  }
}
