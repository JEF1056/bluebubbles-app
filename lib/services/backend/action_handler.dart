import 'dart:async';

import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';
import 'package:universal_io/io.dart';

// ignore: non_constant_identifier_names
ActionHandler MessageHandlerSvc =
    Get.isRegistered<ActionHandler>() ? Get.find<ActionHandler>() : Get.put(ActionHandler());

class ActionHandler extends GetxService {
  /// Tracks in-flight real GUIDs (from our own `new-message` events) that
  /// arrived without a `tempGuid`.  When a subsequent `updated-message` event
  /// comes in with the same real GUID, it is removed here so the delayed
  /// `new-message` processing is skipped (the updated-message will handle it).
  final List<String> outOfOrderTempGuids = [];

  /// Extracts `readAt` (epoch ms) or legacy `lastReadMessageTimestamp` from a
  /// `chat-read-status-changed` payload, treating non-positive values as unset.
  static int? extractReadBefore(Map<String, dynamic> data) {
    return _parsePositiveEpochMs(data["readAt"]) ??
        _parsePositiveEpochMs(data["lastReadMessageTimestamp"]);
  }

  static int? _parsePositiveEpochMs(dynamic raw) {
    final int? value = raw is num
        ? raw.toInt()
        : (raw is String ? num.tryParse(raw.trim())?.toInt() : null);
    return (value != null && value > 0) ? value : null;
  }

  Future<Chat> handleNewOrUpdatedChat(Chat partialData) async {
    final chat = await ChatsSvc.fetchChat(partialData.guid) ?? partialData;

    // Push the updated chat into reactive state so the UI refreshes without
    // requiring an app restart.
    ChatsSvc.updateChat(chat);
    return chat;
  }

  Future<void> handleFaceTimeStatusChange(Map<String, dynamic> data) async {
    if (data["status_id"] == null) return;
    final int statusId = data["status_id"] as int;
    if (statusId == 4) {
      await handleIncomingFaceTimeCall(data);
    } else if (statusId == 6 && data["uuid"] != null) {
      hideFaceTimeOverlay(data["uuid"]!);
    }
  }

  Future<void> handleIncomingFaceTimeCall(Map<String, dynamic> data) async {
    Logger.info("Handling incoming FaceTime call");
    final callUuid = data["uuid"];
    String? address = data["handle"]?["address"];
    String caller = data["address"] ?? "Unknown Number";
    final bool isAudio = data["is_video"] != null
        ? !(data["is_video"] as bool)
        : (data["is_audio"] as bool? ?? false);
    Uint8List? chatIcon;

    if (address != null) {
      ContactV2? contact = await ContactsSvcV2.getContact(address);
      if (contact?.avatarPath != null) {
        chatIcon = await ContactsSvcV2.getContactAvatar(contact!.nativeContactId);
      }
      caller = contact?.displayName ?? caller;
    }

    if (!kIsWeb && Platform.isAndroid && isAudio) {
      final handledByTelecom = await NotificationsSvc.createIncomingFaceTimeNotification(
        callUuid,
        caller,
        chatIcon,
        isAudio,
        callerAddress: address,
      );
      if (handledByTelecom) return;
      if (LifecycleSvc.isAlive) {
        await showFaceTimeOverlay(callUuid, caller, chatIcon, isAudio);
      }
      return;
    }

    if (!LifecycleSvc.isAlive) {
      if (kIsDesktop) {
        await showFaceTimeOverlay(callUuid, caller, chatIcon, isAudio);
      }
      await NotificationsSvc.createIncomingFaceTimeNotification(
        callUuid,
        caller,
        chatIcon,
        isAudio,
        callerAddress: address,
      );
    } else {
      await showFaceTimeOverlay(callUuid, caller, chatIcon, isAudio);
    }
  }

  Future<void> handleIncomingFaceTimeCallLegacy(Map<String, dynamic> data) async {
    Logger.info("Handling incoming FaceTime call (legacy)");
    String? address = data["caller"];
    String? caller = address;
    Uint8List? chatIcon;

    if (address != null) {
      ContactV2? contact = await ContactsSvcV2.getContact(address);
      if (contact?.avatarPath != null) {
        chatIcon = await ContactsSvcV2.getContactAvatar(contact!.nativeContactId);
      }
      caller = contact?.displayName ?? caller;
      await NotificationsSvc.createIncomingFaceTimeNotification(null, caller!, chatIcon, false);
    }
  }

  Future<void> handleEvent(String event, Map<String, dynamic> data, String source, {bool useQueue = true}) async {
    Logger.info("Received $event from $source");
    switch (event) {
      case "pinned-chats-updated":
        final guids = ChatsService.extractPinnedChatGuids(data);
        if (guids != null && GetIt.I.isRegistered<ChatsService>() && !ChatsSvc.headless) {
          await ChatsSvc.applyPinnedChatGuids(guids);
        }
        return;
      case "new-message":
        if (!isNullOrEmpty(data)) {
          final payload = ServerPayload.fromJson(data);
          final message = Message.fromMap(payload.data);
          if (message.error > 0) message.errorMessage = serverErrorMessage(message.error);
          if (message.isFromMe!) {
            if (payload.data['tempGuid'] == null) {
              // No tempGuid — we don't know which local temp message this echo
              // belongs to.  Wait briefly for the paired updated-message event
              // to arrive (which will carry the tempGuid and remove this entry).
              // If nothing arrives, process the new-message normally.
              MessageHandlerSvc.outOfOrderTempGuids.add(message.guid!);
              await Future.delayed(const Duration(milliseconds: 500));
              if (!MessageHandlerSvc.outOfOrderTempGuids.remove(message.guid!)) return;
            } else {
              MessageHandlerSvc.outOfOrderTempGuids.remove(message.guid!);
            }
          }

          await IncomingMsgHandler.handle(
              IncomingPayload(
                type: MessageEventType.newMessage,
                source: MessageSource.socket,
                chat: Chat.fromMap(payload.data['chats'].first.cast<String, dynamic>()),
                message: message,
                attachments: ((payload.data['attachments'] as List?) ?? const [])
                    .whereType<Map>()
                    .map((e) => Attachment.fromMap(e.cast<String, dynamic>()))
                    .toList(),
                tempGuid: payload.data['tempGuid'],
              ),
              front: !useQueue);
        }
        return;
      case "updated-message":
        if (!isNullOrEmpty(data)) {
          final payload = ServerPayload.fromJson(data);
          final updatedMessage = Message.fromMap(payload.data);
          if (updatedMessage.error > 0) updatedMessage.errorMessage = serverErrorMessage(updatedMessage.error);
          await IncomingMsgHandler.handle(
              IncomingPayload(
                type: MessageEventType.updatedMessage,
                source: MessageSource.socket,
                chat: Chat.fromMap(payload.data['chats'].first.cast<String, dynamic>()),
                message: updatedMessage,
                attachments: ((payload.data['attachments'] as List?) ?? const [])
                    .whereType<Map>()
                    .map((e) => Attachment.fromMap(e.cast<String, dynamic>()))
                    .toList(),
                tempGuid: payload.data['tempGuid'],
              ),
              front: !useQueue);
        }
        return;
      case "group-name-change":
      case "participant-removed":
      case "participant-added":
      case "participant-left":
        try {
          await MessageHandlerSvc.handleNewOrUpdatedChat(Chat.fromMap(data['chats'].first.cast<String, dynamic>()));
        } catch (e, s) {
          Logger.warn("Failed to handle chat participant change event", error: e, trace: s, tag: 'ActionHandler');
        }
        return;
      case "chat-read-status-changed":
        Chat? chat = Chat.findOne(guid: data["chatGuid"]);
        final dynamic rawRead = data["read"] ?? data["status"];
        final int? readBefore = extractReadBefore(data);
        if (chat != null && rawRead == true && await chat.clearNotificationsForPartialRead(readBefore)) return;
        if (chat != null && rawRead is bool) {
          // Route through ChatsService so the ChatState the conversation list
          // renders from is updated too. Writing only to the DB row leaves the
          // unread dot stale until the state is rebuilt (open chat / restart).
          // Forced so a chat already marked read locally (e.g. by a reply from another device) still clears.
          await ChatsSvc.setChatHasUnread(chat, !rawRead,
              force: rawRead, privateMark: false, readBefore: readBefore);
        }
        return;
      case "typing-indicator":
        final chat = ChatsSvc.findChatByGuid(data["guid"]);
        if (chat != null) {
          final controller = cvc(chat);
          // Gated: the typing indicator row sits between the message list and
          // the text field, so toggling it mid-send moves the target
          // SendAnimation is flying toward. Runs inline when no send is in
          // flight, which is the overwhelmingly common case.
          controller.messageListGate.run(() => controller.showTypingIndicator.value = data["display"]);
        }
        return;
      case "incoming-facetime":
        Logger.info("Received legacy incoming FaceTime call");
        await handleIncomingFaceTimeCallLegacy(data);
        return;
      case "ft-call-status-changed":
        Logger.info("Received FaceTime call status change");
        await handleFaceTimeStatusChange(data);
        return;
      case "imessage-aliases-removed":
        Logger.info("Alias(es) removed ${data["aliases"]}");
        await NotificationsSvc.createAliasesRemovedNotification((data["aliases"] as List).cast<String>());
        return;
      default:
        return;
    }
  }
}
