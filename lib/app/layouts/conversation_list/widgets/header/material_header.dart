import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/header_widgets.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
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
        Obx(() => Container(
              height: controller.selectedChats.isEmpty ? 100 : null,
              width: NavigationSvc.width(context),
              color: SettingsSvc.settings.windowEffect.value == WindowEffect.disabled
                  ? context.theme.colorScheme.surfaceContainer
                  : Colors.transparent,
            )),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          child: controller.selectedChats.isEmpty
              ? SafeArea(
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
                        padding: const EdgeInsets.only(left: 20.0, right: 12.0, top: 6.0, bottom: 6.0),
                        child: Row(
                          children: [
                            Text(
                              "BlueBubbles",
                              style: context.theme.textTheme.titleLarge?.copyWith(
                                color: context.theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w500,
                                fontSize: 22,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const SyncIndicator(size: 12),
                            const Spacer(),
                            const ChatListFilterButton(),
                            OverflowMenu(controller: controller),
                          ],
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
                            Text(
                              controller.selectedChats.length.toString(),
                              style: context.theme.textTheme.titleLarge!.copyWith(
                                color: context.theme.colorScheme.primary,
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
