import 'package:bluebubbles/app/layouts/conversation_details/material/chat_detail_theme.dart';
import 'package:bluebubbles/app/layouts/conversation_details/material/material_chat_header.dart';
import 'package:bluebubbles/app/layouts/conversation_details/material/material_chat_options.dart';
import 'package:bluebubbles/app/layouts/conversation_details/material/material_participants_section.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/attachments_loader.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/chat_info.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/chat_options.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/findmy_location_card.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/participants_list.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/documents/documents_section.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/links/links_section.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/media/media_grid_section.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class ChatInspectorPane extends StatefulWidget {
  const ChatInspectorPane({
    super.key,
    required this.chat,
    required this.onClose,
  });

  final Chat chat;
  final VoidCallback onClose;

  @override
  State<ChatInspectorPane> createState() => _ChatInspectorPaneState();
}

class _ChatInspectorPaneState extends State<ChatInspectorPane> {
  List<Attachment> media = <Attachment>[];
  List<Attachment> docs = <Attachment>[];
  final RxList<String> selected = <String>[].obs;
  bool isLoadingAttachments = true;

  void _onAttachmentsLoaded(
    List<Attachment> loadedMedia,
    List<Attachment> loadedDocs,
    List<Attachment> _,
  ) {
    if (!mounted) return;
    setState(() {
      media = loadedMedia;
      docs = loadedDocs;
      isLoadingAttachments = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ChatsSvc.getOrCreateChatState(widget.chat);
    return ChatStateScope(
      chatState: chatState,
      child: Obx(() {
        final dbReady = Database.initComplete.isCompleted;
        final chatDetailTheme = dbReady
            ? ChatDetailTheme.resolve(context, widget.chat)
            : ChatDetailTheme(
                theme: Theme.of(context),
                headerColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                tileColor: Theme.of(context).colorScheme.surface,
              );
        final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;

        return Theme(
          data: chatDetailTheme.theme,
          child: Material(
            color: chatDetailTheme.theme.colorScheme.surface,
            child: Column(
              children: [
                Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: chatDetailTheme.headerColor,
                    border: Border(
                      bottom: BorderSide(
                        color: chatDetailTheme.theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Details',
                        style: chatDetailTheme.theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Hide chat details (Alt+I)',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      if (dbReady)
                        SliverToBoxAdapter(
                          child: isIOS ? ChatInfo(chat: widget.chat) : ExpressiveChatHeader(chat: widget.chat),
                        ),
                      SliverToBoxAdapter(child: FindMyLocationCard(chat: widget.chat)),
                      if (dbReady) ...[
                        isIOS
                            ? ParticipantsList(chat: widget.chat)
                            : ExpressiveParticipantsSection(chat: widget.chat),
                        SliverToBoxAdapter(
                          child: AttachmentsLoader(
                            chat: widget.chat,
                            onAttachmentsLoaded: _onAttachmentsLoaded,
                          ),
                        ),
                        isIOS ? ChatOptions(chat: widget.chat) : ExpressiveChatOptions(chat: widget.chat),
                        MediaGridSection(
                          chat: widget.chat,
                          media: media,
                          selected: selected,
                          isLoading: isLoadingAttachments,
                        ),
                        LinksSection(chat: widget.chat),
                        DocumentsSection(
                          chat: widget.chat,
                          docs: docs,
                          isLoading: isLoadingAttachments,
                        ),
                      ],
                      const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}
