import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/conversation_list_fab.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/filters/custom_group_filter_chip_row.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/material_header.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/pinned_chats_grid.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/pin_drag/pin_drag_source.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/pin_drag/unpin_drop_target.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/list_item.dart';
import 'package:bluebubbles/app/wrappers/scrollbar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bluebubbles/platform/shims/window_effect.dart';
import 'package:get/get.dart';

class MaterialConversationList extends StatefulWidget {
  const MaterialConversationList({super.key, required this.parentController});

  final ConversationListController parentController;

  @override
  State<MaterialConversationList> createState() => _MaterialConversationListState();
}

class _MaterialConversationListState extends State<MaterialConversationList> {
  bool get showArchived => widget.parentController.showArchivedChats;
  bool get showUnknown => widget.parentController.showUnknownSenders;
  Color get backdropColor => SettingsSvc.settings.windowEffect.value == WindowEffect.disabled
      ? context.theme.colorScheme.surfaceContainer
      : Colors.transparent;
  Color get sheetColor => SettingsSvc.settings.windowEffect.value == WindowEffect.disabled
      ? context.theme.colorScheme.surface
      : Colors.transparent;
  ConversationListController get controller => widget.parentController;

  @override
  void initState() {
    super.initState();
    // update widget when background color changes
    if (kIsDesktop) {
      SettingsSvc.settings.windowEffect.listen((WindowEffect effect) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => PopScope(
        canPop: controller.selectedChats.isEmpty,
        onPopInvokedWithResult: <T>(bool didPop, T? other) {
          if (didPop) return;
          if (controller.selectedChats.isNotEmpty) {
            controller.clearSelectedChats();
          }
        },
        child: Container(
        color: backdropColor,
        padding: EdgeInsets.only(top: kIsDesktop ? 30 : 0),
        child: Scaffold(
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: MaterialHeader(parentController: controller),
          ),
          backgroundColor: backdropColor,
          extendBodyBehindAppBar: true,
          floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
          floatingActionButton: !showArchived && !showUnknown
              ? ConversationListFAB(parentController: controller)
              : const SizedBox.shrink(),
          body: RepaintBoundary(
            child: Builder(
              builder: (bodyContext) => Obx(() {
            // Force reactivity by accessing observable values first
            final loaded = ChatsSvc.loadedFirstChatBatch.value;
            // Observe chat list version to trigger rebuild when order changes
            final _ = ChatsSvc.chatListVersion.value;

            final _chats = ChatsSvc.getFilteredChats(
              showArchived: showArchived,
              showUnknown: showUnknown,
              excludePinned: true,
              filters: ChatsSvc.chatListFilters.value,
            );
            // With every chat pinned, the pins are the list.
            final noChats = _chats.isEmpty &&
                ChatsSvc.getFilteredChats(
                  showArchived: showArchived,
                  showUnknown: showUnknown,
                  pinnedOnly: true,
                  filters: ChatsSvc.chatListFilters.value,
                ).isEmpty;

            return NotificationListener(
              onNotification: (notif) {
                if (notif is ScrollStartNotification) {
                  controller.materialScrollStartPosition = controller.materialScrollController.offset;
                }
                return true;
              },
              child: UnpinDropTarget(
                drag: controller.pinDrag,
                child: ScrollbarWrapper(
                  showScrollbar: true,
                  controller: controller.materialScrollController,
                  child: CustomScrollView(
                    controller: controller.materialScrollController,
                    physics: ThemeSwitcher.getScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: SizedBox(height: MediaQuery.paddingOf(bodyContext).top),
                      ),
                      PinnedChatsGrid(controller: controller),
                      DecoratedSliver(
                        decoration: BoxDecoration(
                          color: sheetColor,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                        ),
                        sliver: SliverMainAxisGroup(
                          slivers: [
                            if (!showArchived && !showUnknown)
                              const SliverToBoxAdapter(
                                child: CustomGroupFilterChipRow(
                                  padding: EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 4),
                                ),
                              ),
                            if (!loaded || noChats)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 100),
                                    child: loaded
                                        ? buildEmptyChatListState(context,
                                            showArchived: showArchived,
                                            showUnknown: showUnknown,
                                            filters: ChatsSvc.chatListFilters.value)
                                        : Column(
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.all(8.0),
                                                child: Text(
                                                  "Loading chats...",
                                                  style: context.theme.textTheme.labelLarge,
                                                  textAlign: TextAlign.center,
                                                ),
                                              ),
                                              buildProgressIndicator(context, size: 15),
                                            ],
                                          ),
                                  ),
                                ),
                              )
                            else ...[
                              SliverPadding(
                                padding: EdgeInsets.only(top: 8, bottom: 88 + MediaQuery.paddingOf(bodyContext).bottom),
                                // Only the rows watch the drag, for the room a pin dragged over them makes, so a drag
                                // doesn't refilter the chats.
                                sliver: Obx(() {
                                  final rows = controller.pinDrag.withUnpinPreview(_chats);
                                  return SliverList(
                                    delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                        final chat = rows[index];
                                        return Container(
                                          key: ValueKey(chat.guid),
                                          child: PinDragSource(
                                            drag: controller.pinDrag,
                                            chat: chat,
                                            child: ListItem(
                                              chat: chat,
                                              controller: controller,
                                              update: () => setState(() {}),
                                            ),
                                          ),
                                        );
                                      },
                                      findChildIndexCallback: (key) =>
                                          findChildIndexByKey(rows, key, (item) => item.guid),
                                      childCount: rows.length,
                                    ),
                                  );
                                }),
                              ),
                              const SliverFillRemaining(
                                hasScrollBody: false,
                                child: SizedBox.shrink(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
            }),
            ),
          ),
        ),
      ),
    ),
    );
  }
}
