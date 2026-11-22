import 'dart:ui';

import 'package:bluebubbles/app/components/blur_fade_switcher.dart';
import 'package:bluebubbles/app/components/m3e/m3e.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_view.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/header_widgets.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:bluebubbles/platform/shims/window_effect.dart';
import 'package:get/get.dart';

class MaterialHeader extends CustomStateful<ConversationListController> {
  const MaterialHeader({super.key, required super.parentController});

  @override
  State<StatefulWidget> createState() => _MaterialHeaderState();
}

class _MaterialHeaderState extends CustomState<MaterialHeader, void, ConversationListController> {
  bool get showArchived => controller.showArchivedChats;

  bool get showUnknown => controller.showUnknownSenders;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Obx(() {
            final hasWindowEffect = SettingsSvc.settings.windowEffect.value != WindowEffect.disabled;
            final backgroundColor = hasWindowEffect
                ? Colors.transparent
                : context.theme.colorScheme.surfaceContainer.withValues(alpha: 0.86);
            Widget background = ColoredBox(color: backgroundColor);
            if (!hasWindowEffect && !SettingsSvc.settings.highPerfMode.value) {
              background = ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: background,
                ),
              );
            }
            return background;
          }),
        ),
        AnimatedSwitcher(
          duration: M3EMotion.spatialDefault.duration,
          switchInCurve: M3EMotion.spatialDefault.curve,
          switchOutCurve: M3EMotion.effectsFast.curve,
          child: controller.selectedChats.isEmpty
              ? SafeArea(
                  key: const ValueKey('header_normal'),
                  child: Obx(() {
                    NavigationSvc.listener.value;
                    if (NavigationSvc.isAvatarOnly(context)) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                        child: Center(
                          child: Material(
                            color: Colors.transparent,
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: OverflowMenu(extraItems: true, controller: controller),
                          ),
                        ),
                      );
                    }
                    if (!showArchived && !showUnknown) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
                        child: Material(
                          color: context.theme.colorScheme.surfaceContainerHigh,
                          borderRadius: M3EShapes.radiusXl,
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => NavigationSvc.pushLeft(context, const SearchView()),
                            borderRadius: M3EShapes.radiusXl,
                            mouseCursor: SystemMouseCursors.click,
                            child: SizedBox(
                              height: 48,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Tooltip(
                                      message: 'Search',
                                      child: SizedBox.expand(
                                        child: Padding(
                                          padding: const EdgeInsets.only(left: 16, right: 8),
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.search_rounded,
                                                size: 20,
                                                color: context.theme.colorScheme.onSurfaceVariant,
                                              ),
                                              const SizedBox(width: 10),
                                              Flexible(
                                                child: Text(
                                                  "Search BlueBubbles",
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: context.theme.textTheme.bodyLarge?.copyWith(
                                                    color: context.theme.colorScheme.onSurfaceVariant,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const ChatListFilterButton(),
                                  OverflowMenu(controller: controller),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          IconButton(
                            onPressed: () async {
                              Navigator.of(context).pop();
                            },
                            icon: Icon(
                              Icons.arrow_back,
                              color: context.theme.colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(width: 4),
                          HeaderText(controller: controller, fontSize: 20),
                        ],
                      ),
                    );
                  }),
                )
              : SafeArea(
                  key: const ValueKey('header_selection'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () {
                                controller.clearSelectedChats();
                              },
                              icon: Icon(
                                Icons.close,
                                color: context.theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 10),
                            BlurFadeSwitcher(
                              alignment: AlignmentDirectional.centerStart,
                              animateSize: true,
                              child: Text(
                                controller.selectedChats.length.toString(),
                                key: ValueKey(controller.selectedChats.length),
                                style: context.theme.textTheme.titleLarge!.copyWith(
                                  color: context.theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (([
                              0,
                              controller.selectedChats.length
                            ]).contains(controller.selectedChats.where((element) => element.hasUnreadMessage!).length))
                              IconButton(
                                onPressed: () {
                                  for (Chat element in controller.selectedChats) {
                                    final chatState = ChatsSvc.getChatState(element.guid);
                                    if (chatState != null) {
                                      ChatsSvc.setChatHasUnread(chatState.chat, !element.hasUnreadMessage!);
                                    } else {
                                      element.toggleHasUnreadAsync(!element.hasUnreadMessage!);
                                    }
                                  }
                                  controller.clearSelectedChats();
                                },
                                icon: Icon(
                                  controller.selectedChats[0].hasUnreadMessage!
                                      ? Icons.mark_chat_read_outlined
                                      : Icons.mark_chat_unread_outlined,
                                  color: context.theme.colorScheme.primary,
                                ),
                              ),
                            if (([
                              0,
                              controller.selectedChats.length
                            ]).contains(controller.selectedChats.where((element) => element.muteType == "mute").length))
                              IconButton(
                                onPressed: () {
                                  for (Chat element in controller.selectedChats) {
                                    final chatState = ChatsSvc.getChatState(element.guid);
                                    if (chatState != null) {
                                      ChatsSvc.setChatMuted(chatState.chat, element.muteType != "mute");
                                    } else {
                                      element.toggleMuteAsync(element.muteType != "mute");
                                    }
                                  }
                                  controller.clearSelectedChats();
                                },
                                icon: Icon(
                                  controller.selectedChats[0].muteType == "mute"
                                      ? Icons.notifications_active_outlined
                                      : Icons.notifications_off_outlined,
                                  color: context.theme.colorScheme.primary,
                                ),
                              ),
                            if (([0, controller.selectedChats.length])
                                .contains(controller.selectedChats.where((element) => element.isPinned!).length))
                              IconButton(
                                onPressed: () {
                                  for (Chat element in controller.selectedChats) {
                                    final chatState = ChatsSvc.getChatState(element.guid);
                                    ChatsSvc.setChatPinned(chatState?.chat ?? element, !element.isPinned!);
                                  }
                                  controller.clearSelectedChats();
                                },
                                icon: Icon(
                                  controller.selectedChats[0].isPinned! ? Icons.push_pin_outlined : Icons.push_pin,
                                  color: context.theme.colorScheme.primary,
                                ),
                              ),
                            IconButton(
                              onPressed: () {
                                for (Chat element in controller.selectedChats) {
                                  final chatState = ChatsSvc.getChatState(element.guid);
                                  ChatsSvc.setChatArchived(chatState?.chat ?? element, !element.isArchived!);
                                }
                                controller.clearSelectedChats();
                              },
                              icon: Icon(
                                showArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
                                color: context.theme.colorScheme.primary,
                              ),
                            ),
                            IconButton(
                              onPressed: () {
                                for (Chat element in controller.selectedChats) {
                                  ChatsSvc.removeChat(element);
                                  ChatsSvc.softDeleteChat(element);
                                }
                                controller.clearSelectedChats();
                              },
                              icon: Icon(
                                Icons.delete_outlined,
                                color: context.theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        )
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
