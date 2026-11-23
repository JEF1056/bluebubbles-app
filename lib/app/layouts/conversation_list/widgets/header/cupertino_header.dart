import 'dart:ui';

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/ui/route_transition_helpers.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/header_widgets.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_view.dart';
import 'package:bluebubbles/app/wrappers/fade_on_scroll.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class CupertinoHeader extends StatelessWidget {
  const CupertinoHeader({super.key, required this.controller});

  final ConversationListController controller;

  @override
  Widget build(BuildContext context) {
    final double topMargin = context.orientation == Orientation.landscape && context.isPhone
        ? 20
        : kIsDesktop || kIsWeb
            ? 40
            : kToolbarHeight + 30;

    return SliverToBoxAdapter(
      child: FadeOnScroll(
        scrollController: controller.iosScrollController,
        zeroOpacityOffset: topMargin + 15,
        child: Container(
          margin: EdgeInsets.only(
            top: topMargin,
            left: 20,
            right: 20,
            bottom: 5,
          ),
          child: Obx(() {
            NavigationSvc.listener.value;
            return Row(
              mainAxisAlignment:
                  NavigationSvc.isAvatarOnly(context) ? MainAxisAlignment.center : MainAxisAlignment.spaceBetween,
              children: <Widget>[
                if (!NavigationSvc.isAvatarOnly(context))
                  Expanded(
                    child: HeaderText(controller: controller),
                  ),
                if (NavigationSvc.isAvatarOnly(context))
                  Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: OverflowMenu(extraItems: true, controller: controller),
                  ),
                if (!NavigationSvc.isAvatarOnly(context))
                  Row(
                    mainAxisSize: MainAxisSize.max,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () {
                            NavigationSvc.pushLeft(context, const SearchView());
                          },
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: Center(
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: context.theme.colorScheme.surfaceContainerHighest,
                                ),
                                child: Icon(CupertinoIcons.search,
                                    color: context.theme.colorScheme.onSurfaceVariant, size: 18),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const CupertinoChatListFilterButton(),
                      const SizedBox(width: 10.0),
                      if (SettingsSvc.settings.moveChatCreatorToHeader.value)
                        Material(
                          type: MaterialType.transparency,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => controller.openNewChatCreator(context),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Center(
                                child: Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: context.theme.colorScheme.surfaceContainerHighest,
                                  ),
                                  child: Icon(
                                    CupertinoIcons.pencil,
                                    color: context.theme.colorScheme.onSurfaceVariant,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (SettingsSvc.settings.moveChatCreatorToHeader.value &&
                          SettingsSvc.settings.cameraFAB.value &&
                          !kIsWeb &&
                          !kIsDesktop)
                        const SizedBox(width: 10.0),
                      if (SettingsSvc.settings.moveChatCreatorToHeader.value &&
                          SettingsSvc.settings.cameraFAB.value &&
                          !kIsWeb &&
                          !kIsDesktop)
                        Material(
                          type: MaterialType.transparency,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => controller.openCamera(context),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Center(
                                child: Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: context.theme.colorScheme.surfaceContainerHighest,
                                  ),
                                  child: Icon(CupertinoIcons.camera,
                                      color: context.theme.colorScheme.onSurfaceVariant, size: 20),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (SettingsSvc.settings.moveChatCreatorToHeader.value) const SizedBox(width: 10.0),
                      const Material(
                        color: Colors.transparent,
                        shape: CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: OverflowMenu(),
                      ),
                    ],
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

class CupertinoMiniHeader extends StatelessWidget {
  const CupertinoMiniHeader({super.key, required this.controller});

  final ConversationListController controller;

  @override
  Widget build(BuildContext context) {
    final double topMargin = context.orientation == Orientation.landscape && context.isPhone
        ? 20
        : kIsDesktop || kIsWeb
            ? 60
            : kToolbarHeight + 30;

    return IgnorePointer(
      child: ListenableBuilder(
        listenable: controller.iosScrollController,
        builder: (context, _) {
          final fadeDistance = topMargin + 15;
          final offset = controller.iosScrollController.positions.length == 1
              ? controller.iosScrollController.offset
              : 0.0;
          final opacity = fadeDistance <= 0 ? 1.0 : (offset / fadeDistance).clamp(0.0, 1.0);
          if (opacity <= 0.0) return const SizedBox.shrink();

          return ClipRect(
            child: Obx(() {
              NavigationSvc.listener.value;
              final useBlur = !SettingsSvc.settings.highPerfMode.value;
              return RouteSettledBackdropFilter(
                enabled: useBlur,
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  width: NavigationSvc.width(context),
                  height: (topMargin - 20).clamp(kIsDesktop ? 65 : 40, double.infinity),
                  color: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5 * opacity),
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: kIsDesktop ? 10 : 5),
                    child: Text(
                      controller.showArchivedChats
                          ? "Archive"
                          : controller.showUnknownSenders
                              ? "Unknown Senders"
                              : "Messages",
                      style: context.textTheme.titleMedium!.copyWith(
                        color: context.theme.colorScheme.onSurfaceVariant.withValues(alpha: opacity),
                      ),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
