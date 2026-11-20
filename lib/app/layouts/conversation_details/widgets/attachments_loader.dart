import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Widget that handles loading attachments asynchronously with loading state
class AttachmentsLoader extends StatefulWidget {
  final Chat chat;
  final Function(List<Attachment>, List<Attachment>, List<Attachment>) onAttachmentsLoaded;

  const AttachmentsLoader({
    super.key,
    required this.chat,
    required this.onAttachmentsLoaded,
  });

  @override
  State<AttachmentsLoader> createState() => _AttachmentsLoaderState();
}

class _AttachmentsLoaderState extends State<AttachmentsLoader> {
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchAttachments();
  }

  Future<void> _fetchAttachments() async {
    try {
      final attachments = await widget.chat.getAttachmentsAsync();
      final byGuid = <String, Attachment>{
        for (final a in attachments)
          if (a.guid != null) a.guid!: a,
      };
      final messageByAttachmentGuid = <String, Message>{};

      if (kIsWeb) {
        final messages = maybeFindMessagesSvc(widget.chat.guid)?.struct.messages ?? const <Message>[];
        for (final msg in messages) {
          if (msg.dateDeleted != null) continue;
          for (final a in msg.dbAttachments) {
            final guid = a.guid;
            if (guid != null) {
              byGuid.putIfAbsent(guid, () => a);
              messageByAttachmentGuid.putIfAbsent(guid, () => msg);
            }
          }
        }
      }

      if (!mounted) return;

      final allAttachments = byGuid.isNotEmpty ? byGuid.values.toList() : attachments;
      Message? messageFor(Attachment a) => a.message.target ?? messageByAttachmentGuid[a.guid];
      DateTime dateFor(Attachment a) => messageFor(a)?.dateCreated ?? DateTime(0);

      final media = allAttachments
          .where((e) {
            final msg = messageFor(e);
            return !(msg?.isGroupEvent ?? false) &&
                !(msg?.isInteractive ?? false) &&
                (e.mimeStart == "image" || e.mimeStart == "video");
          })
          .toList()
        ..sort((a, b) => dateFor(b).compareTo(dateFor(a)));

      final docs = allAttachments
          .where((e) {
            final msg = messageFor(e);
            return !(msg?.isGroupEvent ?? false) &&
                !(msg?.isInteractive ?? false) &&
                e.mimeStart != "image" &&
                e.mimeStart != "video" &&
                !(e.mimeType ?? "").contains("location");
          })
          .toList()
        ..sort((a, b) => dateFor(b).compareTo(dateFor(a)));

      final locations = allAttachments.where((e) => (e.mimeType ?? "").contains("location")).toList()
        ..sort((a, b) => dateFor(b).compareTo(dateFor(a)));

      setState(() {
        isLoading = false;
      });

      widget.onAttachmentsLoaded(media, docs, locations);
    } catch (e) {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
        widget.onAttachmentsLoaded(const [], const [], const []);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // This widget doesn't render anything visible itself
    // It just triggers the loading and callbacks
    return const SizedBox.shrink();
  }
}
