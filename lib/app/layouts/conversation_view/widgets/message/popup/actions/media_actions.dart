import 'dart:async';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_action_context.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:flutter/foundation.dart';
import 'package:bluebubbles/platform/shims/native_misc.dart' show OpenFilex, ResultType;
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' hide context;
import 'package:url_launcher/url_launcher.dart';

Future<void> downloadAttachment(MessagePopupActionContext ctx) async {
  try {
    dynamic content;
    if (ctx.isEmbeddedMedia) {
      content = PlatformFile(
        name: basename(ctx.message.interactiveMediaPath!),
        path: ctx.message.interactiveMediaPath,
        size: 0,
      );
    } else {
      content = AttachmentsSvc.getContent(ctx.part.attachments.first);
    }

    if (content is PlatformFile) {
      ctx.popDetails();
      await AttachmentsSvc.saveToDisk(
        content,
        isDocument: ctx.part.attachments.first.mimeStart != "image" && ctx.part.attachments.first.mimeStart != "video",
      );
    }
  } catch (ex, trace) {
    Logger.error("Error downloading attachment: ${ex.toString()}", error: ex, trace: trace);
    ctx.showSnack("Save Error", "Failed to save: $ex", type: SnackbarType.error);
  }
}

@visibleForTesting
Uri? buildAttachmentWebUri(String? rawUrl, String guidAuthKey) {
  if (rawUrl == null || rawUrl.isEmpty) return null;
  final parsed = Uri.tryParse(rawUrl);
  if (parsed == null) return null;
  return parsed.replace(
    queryParameters: {
      ...parsed.queryParameters,
      'guid': guidAuthKey,
    },
  );
}

Future<void> openAttachmentWeb(MessagePopupActionContext ctx) async {
  final uri = buildAttachmentWebUri(
    ctx.part.attachments.firstOrNull?.webUrl,
    SettingsSvc.settings.guidAuthKey.value,
  );
  if (uri == null) return;
  await launchUrl(uri);
  ctx.popDetails();
}

Future<void> openInImageViewer(MessagePopupActionContext ctx) async {
  try {
    final content = AttachmentsSvc.getContent(ctx.part.attachments.first);
    if (content is! PlatformFile || isNullOrEmptyString(content.path)) {
      ctx.showSnack("Open Error", "Failed to find image file path!", type: SnackbarType.error);
      return;
    }

    final response = await OpenFilex.open(content.path!, type: ctx.part.attachments.first.mimeType);
    if (response.type == ResultType.done) {
      ctx.popDetails();
      return;
    }

    if (response.type == ResultType.noAppToOpen) {
      ctx.showSnack("Open Error", "No app found to open this image!", type: SnackbarType.error);
      return;
    }

    Logger.warn(
      "Failed to open image in viewer (${response.type}): ${response.message}",
      tag: "MessagePopup",
    );
    ctx.showSnack("Open Error", "Failed to open image: ${response.message}", type: SnackbarType.error);
  } catch (ex, trace) {
    Logger.error("Failed to open image in viewer!", error: ex, trace: trace);
    ctx.showSnack("Open Error", "Failed to open image!", type: SnackbarType.error);
  }
}

Future<void> copyAttachment(MessagePopupActionContext ctx) async {
  if (kIsWeb) {
    final att = ctx.part.attachments.firstOrNull;
    final content = att != null ? AttachmentsSvc.getContent(att, autoDownload: false) : null;
    if (att?.mimeStart == 'image' && content is PlatformFile && content.bytes != null) {
      try {
        await Pasteboard.writeImage(content.bytes);
        ctx.popDetails();
        showCopiedToast("Attachment copied to clipboard");
        return;
      } catch (e) {
        Logger.warn("Web clipboard image write failed: $e");
      }
    }
    ctx.showSnack("Copy Unavailable", "Use Save or Open In New Tab on web.", type: SnackbarType.error);
    return;
  }
  final paths = ctx.part.attachments.map((element) => element.path).whereType<String>().toList();
  if (paths.isEmpty) {
    ctx.showSnack("Copy Error", "Attachment file not downloaded yet!", type: SnackbarType.error);
    return;
  }
  Pasteboard.writeFiles(paths).then((_) {
    ctx.popDetails();
    showCopiedToast(
        ctx.part.attachments.length > 1 ? "Attachments copied to clipboard" : "Attachment copied to clipboard");
  }).catchError((e) {
    Logger.error("Failed to copy attachment(s)!", error: e);
    ctx.showSnack("Copy Error", "Failed to copy attachment(s)!", type: SnackbarType.error);
  });
}

Future<void> downloadOriginalAttachments(MessagePopupActionContext ctx) async {
  final toDownload = ctx.part.attachments
      .where((element) =>
          (element.uti?.contains("heic") ?? false) ||
          (element.uti?.contains("heif") ?? false) ||
          (element.uti?.contains("quicktime") ?? false) ||
          (element.uti?.contains("coreaudio") ?? false) ||
          (element.uti?.contains("tiff") ?? false))
      .toList();
  final length = toDownload.length;
  ctx.popDetails();
  if (length == 0) return;

  ctx.showSnack(
    "Downloading",
    length > 1 ? "Downloading $length original attachments…" : "Downloading original attachment…",
    type: SnackbarType.info,
  );

  try {
    for (final Attachment element in toDownload) {
      final response = await HttpSvc.attachment.download(
        element.guid!,
        original: true,
      );
      final file = PlatformFile(
        name: element.transferName!,
        size: response.data.length,
        bytes: response.data,
      );

      await AttachmentsSvc.saveToDisk(file, isDocument: element.mimeStart != "image" && element.mimeStart != "video");
    }
    ctx.showSnack(
      "Download Complete",
      length > 1 ? "Saved $length original attachments." : "Saved original attachment.",
    );
  } catch (ex, trace) {
    Logger.error("Failed to download original attachment!", error: ex, trace: trace);
    ctx.showSnack("Download Error", "Failed to download: $ex", type: SnackbarType.error);
  }
}

Future<void> downloadLivePhoto(MessagePopupActionContext ctx) async {
  final toDownload = ctx.part.attachments.where((element) => element.hasLivePhoto).toList();
  final length = toDownload.length;
  ctx.popDetails();
  if (length == 0) return;

  ctx.showSnack(
    "Downloading",
    length > 1 ? "Downloading $length live photos…" : "Downloading live photo…",
    type: SnackbarType.info,
  );

  try {
    for (final Attachment element in toDownload) {
      final response = await HttpSvc.attachment.downloadLivePhoto(element.guid!);
      final nameSplit = element.transferName!.split(".");
      final file = PlatformFile(
        name: "${nameSplit.take(nameSplit.length - 1).join(".")}.mov",
        size: response.data.length,
        bytes: response.data,
      );
      await AttachmentsSvc.saveToDisk(file, isDocument: true);
    }
    ctx.showSnack(
      "Download Complete",
      length > 1 ? "Saved $length live photos." : "Saved live photo.",
    );
  } catch (ex, trace) {
    Logger.error("Failed to download live photo!", error: ex, trace: trace);
    ctx.showSnack("Download Error", "Failed to download: $ex", type: SnackbarType.error);
  }
}

void redownload(MessagePopupActionContext ctx) {
  if (ctx.isEmbeddedMedia) {
    ctx.popDetails();
    ctx.service.getMessageStateIfExists(ctx.message.guid!)?.embeddedMediaRefreshKey.value++;
    return;
  }

  final msgGuid = ctx.message.guid;
  if (msgGuid != null) {
    for (final Attachment? element in ctx.part.attachments) {
      if (element != null) {
        unawaited(ctx.service.redownloadAttachment(msgGuid, element));
      }
    }
  }
  ctx.popDetails();
}

/// Clears any cached web-loaded preview state (URL previews, Photos app
/// previews, etc) for this message and signals its interactive widget to
/// re-fetch. Generic across preview types - the widget itself (via
/// [MessageState.previewRefreshKey]) owns how it re-fetches its own content.
void refreshPreview(MessagePopupActionContext ctx) {
  // Per slot, rather than `message.metadata = null`. Blanking the whole map
  // also threw away the other slot's cached image hash and anything the server
  // put there — keys this action has no business touching. `clear` removes only
  // the slot's own keys and its attempt bookkeeping.
  for (final slot in MetadataCacheSlot.values) {
    MessageMetadataStore.clear(ctx.message, slot: slot);
  }
  // The persisted copy is only half the cache — drop the in-memory entry too,
  // or the refetch is served from it and nothing appears to change.
  MetadataHelper.invalidateForMessage(ctx.message);
  Logger.debug('Refresh Preview: cleared metadata and memo cache for ${ctx.message.guid}', tag: 'RefreshPreview');
  ctx.messageState.previewRefreshKey.value++;
  ctx.popDetails();
}

void sharePart(MessagePopupActionContext ctx) {
  if (ctx.part.attachments.isNotEmpty && !ctx.part.hasInlineAttachments && !ctx.message.isLegacyUrlPreview) {
    Share.files(ctx.part.attachments.map((a) => a.path).nonNulls.toList());
  } else if (!isNullOrEmpty(ctx.part.text)) {
    Share.text(ctx.part.hasInlineAttachments ? withoutInlineAttachments(ctx.part.text!) : ctx.part.text!);
  }
  ctx.popDetails();
}
