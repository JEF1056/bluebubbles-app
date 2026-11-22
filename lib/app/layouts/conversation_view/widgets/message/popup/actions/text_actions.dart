import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_action_context.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

void openLink(MessagePopupActionContext ctx) {
  final String? url = ctx.part.url;
  MethodChannelSvc.actions.openBrowser(link: (url ?? ctx.part.text) ?? '');
  ctx.popDetails();
}

void copyText(MessagePopupActionContext ctx) {
  final part = ctx.part;
  Clipboard.setData(ClipboardData(text: part.fullText));
  // Runs are relative to the text; an inline attachment's U+FFFC, dropped from fullText, would shift them
  final text = part.text ?? '';
  if (!text.contains(objectReplacementChar)) {
    final offset = isNullOrEmpty(part.subject) || text.isEmpty ? 0 : part.subject!.length + 1;
    MentionTextEditingController.rememberCopy(part.fullText, [
      for (final run in part.runs)
        Run(range: [run.range[0] + offset, run.range[1]], attributes: run.attributes),
    ]);
  }
  ctx.popDetails();
  showCopiedToast("Copied to clipboard");
}

void copySelection(MessagePopupActionContext ctx) {
  showBBDialog(
    context: ctx.context,
    title: "Copy Selection",
    content: SelectableText(ctx.part.fullText, style: Theme.of(ctx.context).extension<BubbleText>()!.bubbleText),
  );
}

Future<void> translateMessage(MessagePopupActionContext ctx) async {
  final ms = ctx.messageState;
  final guid = ms.message.guid;
  ctx.popDetails();
  if (ms.translation.value != null) {
    ms.showOriginalTranslation.value = !ms.showOriginalTranslation.value;
    return;
  }
  if (guid == null || ms.isTranslating.value) return;
  ms.isTranslating.value = true;
  try {
    final resp = await HttpSvc.translateMessage(guid);
    final payload = resp.data?['data'];
    final rawTr = payload is Map ? payload['translation'] : null;
    if (rawTr is Map) {
      final tr = MessageTranslation.fromJson(Map<String, dynamic>.from(rawTr));
      ms.message.metadata = Map<String, dynamic>.from(ms.message.metadata ?? {})..['translation'] = tr.toJson();
      ms.translation.value = tr;
      ms.showOriginalTranslation.value = false;
      await Message.replaceMessage(guid, ms.message);
    } else {
      showSnackbar("Notice", "No translation needed");
    }
  } catch (e) {
    showSnackbar("Error", "Failed to translate message", type: SnackbarType.error);
  } finally {
    ms.isTranslating.value = false;
  }
}
