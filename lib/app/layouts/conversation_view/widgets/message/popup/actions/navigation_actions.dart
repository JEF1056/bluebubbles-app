import 'package:universal_io/io.dart';
import 'dart:typed_data';

import 'package:bluebubbles/app/layouts/chat_creator/chat_creator.dart';
import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_action_context.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/models/models.dart' show MessageReplyContext;
import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

void reply(MessagePopupActionContext ctx) {
  ctx.popDetails();
  final part = ctx.part;
  ctx.cvController.replyToMessage = MessageReplyContext(
    ctx.message,
    part.part,
    attachmentGuid: part.attachments.length == 1 ? part.attachments.first.guid : null,
  );
}

void openDm(MessagePopupActionContext ctx) {
  if (ctx.dmChat == null) return;
  ctx.popDetails();
  Navigator.pushReplacement(
    ctx.context,
    cupertino.CupertinoPageRoute(
      builder: (BuildContext context) {
        return ConversationView(chat: ctx.dmChat!);
      },
    ),
  );
}

void showThread(MessagePopupActionContext ctx) {
  ctx.popDetails();
  if (ctx.message.threadOriginatorGuid != null) {
    final root = resolveRootReplyTarget(ctx.message, ctx.message.normalizedThreadPart, service: ctx.service);
    final mwc = root.message != null
        ? (ctx.service.getMessageStateIfExists(root.message!.guid!) ?? ctx.service.getOrCreateState(root.message!))
        : null;
    if (mwc == null) return ctx.showSnack("Error", "Failed to find thread!", type: SnackbarType.error);
    final originatorPart = mwc.partById(root.part);
    if (originatorPart == null) return ctx.showSnack("Error", "Failed to find thread!", type: SnackbarType.error);
    showReplyThread(ctx.context, mwc.message, originatorPart, ctx.service, ctx.cvController);
  } else {
    showReplyThread(ctx.context, ctx.message, ctx.part, ctx.service, ctx.cvController);
  }
}

void newConvo(MessagePopupActionContext ctx) {
  final Handle? handle = ctx.message.handleRelation.target;
  if (handle == null) return;
  ctx.popDetails();
  // This route replacement bypasses ConversationView's back-handler, so
  // explicitly close the active controller first.
  ctx.cvController.close();
  NavigationSvc.pushAndRemoveUntil(
    ctx.context,
    NewChatCreator(initialSelected: [SelectedContact(displayName: handle.displayName, address: handle.address)]),
    (route) => route.isFirst,
  );
}

Future<void> forward(MessagePopupActionContext ctx) async {
  ctx.popDetails();
  final List<PlatformFile> attachments = [];
  final _attachments = ctx.message.dbAttachments
      .where((e) => AttachmentsSvc.getContent(e, autoDownload: false) is PlatformFile)
      .map((e) => AttachmentsSvc.getContent(e, autoDownload: false) as PlatformFile);
  for (final PlatformFile a in _attachments) {
    Uint8List? bytes = a.bytes;
    if (bytes == null && !kIsWeb && a.path != null) {
      bytes = await File(a.path!).readAsBytes();
    }
    if (bytes == null) continue;
    attachments.add(PlatformFile(
      name: a.name,
      path: a.path,
      size: bytes.length,
      bytes: bytes,
    ));
  }

  if (attachments.isNotEmpty || !isNullOrEmpty(ctx.message.text)) {
    // This route replacement bypasses ConversationView's back-handler, so
    // explicitly close the active controller first.
    ctx.cvController.close();
    NavigationSvc.pushAndRemoveUntil(
      ctx.context,
      NewChatCreator(
        initialText: ctx.message.text,
        initialAttachments: attachments,
      ),
      (route) => route.isFirst,
    );
  }
}
