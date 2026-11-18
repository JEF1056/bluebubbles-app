import 'package:bluebubbles/app/components/avatars/contact_avatar_group_widget.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/conversation_list_fab.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/filters/custom_group_filter_chip_row.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/material_header.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/list_item.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/scrollbar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: <T>(bool didPop, T? other) {
        if (didPop) return;
        if (controller.selectedChats.isNotEmpty) {
          controller.clearSelectedChats();
          return;
        } else if (controller.showArchivedChats || controller.showUnknownSenders) {
          // Pop the current page
          Navigator.of(context).pop();
        } else {
          // Pop the app to exit the app
          SystemNavigator.pop();
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
          extendBodyBehindAppBar: false,
          floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
          floatingActionButton: !showArchived && !showUnknown
              ? ConversationListFAB(parentController: controller)
              : const SizedBox.shrink(),
          body: Obx(() {
            // Force reactivity by accessing observable values first
            final loaded = ChatsSvc.loadedFirstChatBatch.value;
            // Observe chat list version to trigger rebuild when order changes
            final _ = ChatsSvc.chatListVersion.value;

            final _chats = ChatsSvc.getFilteredChats(
              showArchived: showArchived,
              showUnknown: showUnknown,
              filters: ChatsSvc.chatListFilters.value,
            );

            final bool showPinnedHeader = !showArchived && !showUnknown;
            final List<Chat> pinnedChats = showPinnedHeader
                ? _chats.where((c) => c.isPinned == true).toList()
                : const [];
            final List<Chat> listChats = showPinnedHeader
                ? _chats.where((c) => c.isPinned != true).toList()
                : _chats;

            if (!loaded || _chats.isEmpty) {
              return Material(
                color: sheetColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    if (!showArchived && !showUnknown)
                      const CustomGroupFilterChipRow(
                        padding: EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 4),
                      ),
                    Expanded(
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
                    ),
                  ],
                ),
              );
            }

            return NotificationListener(
              onNotification: (notif) {
                if (notif is ScrollStartNotification) {
                  controller.materialScrollStartPosition = controller.materialScrollController.offset;
                }
                return true;
              },
              child: ScrollbarWrapper(
                showScrollbar: true,
                controller: controller.materialScrollController,
                child: CustomScrollView(
                  controller: controller.materialScrollController,
                  physics: ThemeSwitcher.getScrollPhysics(),
                  slivers: [
                    if (pinnedChats.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _MaterialPinnedSection(
                          pinnedChats: pinnedChats,
                          controller: controller,
                          onSelectionChanged: () => setState(() {}),
                        ),
                      ),
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
                          SliverPadding(
                            padding: const EdgeInsets.only(top: 8, bottom: 88),
                            sliver: SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final chat = listChats[index];
                                  return Container(
                                    key: ValueKey(chat.guid),
                                    child: ListItem(
                                      chat: chat,
                                      controller: controller,
                                      update: () => setState(() {}),
                                    ),
                                  );
                                },
                                childCount: listChats.length,
                                findChildIndexCallback: (key) =>
                                    findChildIndexByKey(listChats, key, (item) => item.guid),
                              ),
                            ),
                          ),
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _MaterialPinnedSection extends StatelessWidget {
  const _MaterialPinnedSection({
    required this.pinnedChats,
    required this.controller,
    required this.onSelectionChanged,
  });

  final List<Chat> pinnedChats;
  final ConversationListController controller;
  final VoidCallback onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final rows = <List<Chat>>[];
    for (int i = 0; i < pinnedChats.length; i += 3) {
      rows.add(pinnedChats.sublist(i, (i + 3).clamp(0, pinnedChats.length)));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int r = 0; r < rows.length; r++) ...[
            if (r > 0) const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int c = 0; c < rows[r].length; c++) ...[
                  if (c > 0) const SizedBox(width: 20),
                  _MaterialPinnedItem(
                    chat: rows[r][c],
                    controller: controller,
                    onSelectionChanged: onSelectionChanged,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MaterialPinnedItem extends StatelessWidget {
  const _MaterialPinnedItem({
    required this.chat,
    required this.controller,
    required this.onSelectionChanged,
  });

  final Chat chat;
  final ConversationListController controller;
  final VoidCallback onSelectionChanged;

  void _toggleSelect() {
    HapticFeedback.lightImpact();
    final idx = controller.selectedChats.indexWhere((c) => c.guid == chat.guid);
    if (idx >= 0) {
      controller.selectedChats.removeAt(idx);
    } else {
      controller.selectedChats.add(chat);
    }
    controller.updateSelectedChats();
    onSelectionChanged();
  }

  void _openOrSelect(BuildContext context) {
    if (controller.selectedChats.isNotEmpty) {
      _toggleSelect();
      return;
    }
    NavigationSvc.pushAndRemoveUntil(
      context,
      ConversationView(chat: chat),
      (route) => route.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ChatsSvc.getOrCreateChatState(chat);
    return ChatStateScope(
      chatState: chatState,
      child: SizedBox(
        width: 96,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openOrSelect(context),
          onLongPress: _toggleSelect,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Obx(() {
              final _ = controller.selectionVersion.value;
              final isSelected = controller.selectedChats.any((c) => c.guid == chat.guid);
              final rawTitle = chatState.title.value;
              final title = (rawTitle != null && rawTitle.isNotEmpty) ? rawTitle : chat.getTitle();
              final unread = chatState.hasUnreadMessage.value && chatState.muteType.value != "mute";
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ContactAvatarGroupWidget(
                        chat: chat,
                        size: 84,
                        editable: false,
                      ),
                      if (isSelected)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: context.theme.colorScheme.primary.withValues(alpha: 0.72),
                            ),
                            child: Icon(
                              Icons.check,
                              color: context.theme.colorScheme.onPrimary,
                              size: 32,
                            ),
                          ),
                        )
                      else if (unread)
                        Positioned(
                          right: 2,
                          top: 2,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: context.theme.colorScheme.primary,
                              border: Border.all(
                                color: context.theme.colorScheme.surfaceContainer,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: context.theme.textTheme.bodyMedium?.copyWith(
                      color: context.theme.colorScheme.onSurface,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                      fontSize: 13.5,
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }
}
