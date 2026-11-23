import 'package:bluebubbles/app/layouts/fullscreen_media/conversation_fullscreen_holder.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/platform/shims/native_misc.dart' show OpenFilex, ResultType;
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:mime_type/mime_type.dart';
import 'package:path/path.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

/// The visual content of a generic (non-media) file attachment: an icon tile on
/// the left and the filename + size•type label on the right. Contains no tap or
/// interactive behavior so it can be reused inside both [OtherFile] (which
/// wraps it in an [InkWell]) and the upload-progress overlay (which sits on
/// top of it).
class OtherFileRow extends StatelessWidget {
  const OtherFileRow({
    super.key,
    required this.attachment,
    this.file,
    this.trailing,
  });

  final Attachment attachment;

  /// The resolved local file. May be `null` during upload before the file has
  /// been cached; falls back to [Attachment.transferName] and
  /// [Attachment.getFriendlySize] in that case.
  final PlatformFile? file;

  /// Optional trailing action widget (e.g. web hover/focus download button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = context.theme.colorScheme;
    final name = file?.name ?? attachment.transferName ?? "";
    final typeLabel = (mime(name)?.split("/").lastOrNull ?? mime(name) ?? "file").toUpperCase();
    final sizeLabel = file != null ? file!.size.toDouble().getFriendlySize() : attachment.getFriendlySize();
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                getAttachmentIcon(attachment.mimeType ?? ""),
                color: scheme.onSecondaryContainer,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.theme.textTheme.bodyMedium!.apply(fontWeightDelta: 2),
                  ),
                  const SizedBox(height: 2.5),
                  Text(
                    "$sizeLabel \u2022 $typeLabel",
                    style: context.theme.textTheme.labelMedium!
                        .copyWith(fontWeight: FontWeight.normal, color: scheme.outline),
                    overflow: TextOverflow.clip,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 4),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class OtherFile extends StatefulWidget {
  const OtherFile({
    super.key,
    required this.attachment,
    required this.file,
    @visibleForTesting this.isWebOverride = kIsWeb,
  });

  final Attachment attachment;
  final PlatformFile file;
  final bool isWebOverride;

  @override
  State<OtherFile> createState() => _OtherFileState();
}

class _OtherFileState extends State<OtherFile> {
  bool _hovered = false;
  bool _focused = false;

  Future<void> _activate(BuildContext context) async {
    final attachment = widget.attachment;
    final file = widget.file;
    final currentChat = ChatStateScope.maybeChatOf(context);

    if (attachment.mimeStart == "image" || (attachment.mimeStart == "video")) {
      NavigationSvc.push(
        context,
        ConversationFullscreenHolder(
          currentChat: currentChat,
          attachment: attachment,
          showInteractions: true,
        ),
      );
      return;
    }
    if (kIsWeb || file.path == null) {
      final bytes = file.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        downloadBytes(bytes, file.name);
      } else if (attachment.guid != null) {
        AttachmentsSvc.redownloadAttachment(
          attachment,
          onComplete: (downloaded) {
            final data = downloaded.bytes;
            if (data != null && data.isNotEmpty) {
              downloadBytes(data, downloaded.name);
            } else {
              showSnackbar('Error', 'Failed to download file!', type: SnackbarType.error);
            }
          },
          onError: () => showSnackbar('Error', 'Failed to download file!', type: SnackbarType.error),
        );
      } else {
        showSnackbar('Error', 'That attachment has no data to save!', type: SnackbarType.error);
      }
    } else if (kIsDesktop) {
      final localFile = File(join(
          FilesystemSvc.sysTempPath, "BlueBubbles", "attachments", FilesystemService.sanitizeGuid(attachment.guid), basename(file.path!)));
      if (!await localFile.exists()) {
        await localFile.create(recursive: true);
        await File(file.path!).copy(localFile.path);
      }
      launchUrl(Uri.file(localFile.path));
    } else {
      try {
        final res = await OpenFilex.open(
            join(FilesystemSvc.attachmentsPath, FilesystemService.sanitizeGuid(attachment.guid), basename(file.path!)));
        if (res.type == ResultType.noAppToOpen) {
          showSnackbar('Error', "No handler for this file type! Using share menu instead.",
              type: SnackbarType.error);
          await Future.delayed(const Duration(seconds: 1));
          Share.files([file.path!]);
        } else if (res.type == ResultType.error) {
          showSnackbar('Error', "Failed to open file: ${res.message}", type: SnackbarType.error);
        } else if (res.type == ResultType.fileNotFound) {
          showSnackbar('Not Found', "File not found at path: ${file.path}", type: SnackbarType.error);
        } else if (res.type == ResultType.permissionDenied) {
          showSnackbar(
              'Permission Denied', "BlueBubbles does not have access to this file! Using share menu instead.",
              type: SnackbarType.error);
          await Future.delayed(const Duration(seconds: 1));
          Share.files([file.path!]);
        }
      } catch (ex) {
        Logger.error("Error opening file: ${file.path}", error: ex);
        showSnackbar('Error', "No handler for this file type!", type: SnackbarType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final showWebDownload = widget.isWebOverride && (_hovered || _focused);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter): () => _activate(context),
            const SingleActivator(LogicalKeyboardKey.space): () => _activate(context),
          },
          child: Semantics(
            button: true,
            label: 'Open file ${widget.file.name}',
            child: Tooltip(
              message: 'Open ${widget.file.name}',
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _activate(context),
                child: OtherFileRow(
                  attachment: widget.attachment,
                  file: widget.file,
                  trailing: widget.isWebOverride
                      ? AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          switchInCurve: Curves.easeOutCubic,
                          child: showWebDownload
                              ? IconButton(
                                  key: const ValueKey('web-file-download'),
                                  tooltip: 'Download file',
                                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                  icon: const Icon(Icons.download_outlined),
                                  onPressed: () => _activate(context),
                                )
                              : const SizedBox.shrink(key: ValueKey('web-file-download-empty')),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
