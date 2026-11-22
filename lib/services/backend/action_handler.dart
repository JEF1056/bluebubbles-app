import 'dart:async';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';

// ignore: non_constant_identifier_names
ActionHandler MessageHandlerSvc =
    Get.isRegistered<ActionHandler>() ? Get.find<ActionHandler>() : Get.put(ActionHandler());

class ActionHandler extends GetxService {
  /// Tracks in-flight real GUIDs (from our own `new-message` events) that
  /// arrived without a `tempGuid`.  When a subsequent `updated-message` event
  /// comes in with the same real GUID, it is removed here so the delayed
  /// `new-message` processing is skipped (the updated-message will handle it).
  final List<String> outOfOrderTempGuids = [];
  final Set<String> _notifiedMissedCallUuids = <String>{};

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

    // Push the updated chat into reactive state (override: true so Web's shared
    // in-memory Chat reference still propagates displayName/participant updates).
    ChatsSvc.updateChat(chat, override: true);
    return chat;
  }

  Future<void> handleFaceTimeStatusChange(Map<String, dynamic> data) async {
    final rawStatusId = data["status_id"];
    final int? statusId = rawStatusId is num
        ? rawStatusId.toInt()
        : (rawStatusId is String
            ? int.tryParse(rawStatusId)
            : switch (data["status"]?.toString().toLowerCase()) {
                "incoming" => 4,
                "outgoing" => 3,
                "connecting" => 2,
                "answered" => 1,
                "disconnected" => 6,
                _ => null,
              });
    if (statusId == null) return;

    final enriched = Map<String, dynamic>.from(data);
    final String? address = (enriched["handle"] is Map ? enriched["handle"]["address"] : null)?.toString() ??
        enriched["address"]?.toString();
    if ((enriched["display_name"] == null || enriched["display_name"].toString().trim().isEmpty) &&
        address != null &&
        address.isNotEmpty &&
        GetIt.I.isRegistered<ContactServiceV2>()) {
      final cachedContact = ContactsSvcV2.findContactForAddressSync(address);
      if (cachedContact != null && cachedContact.displayName.isNotEmpty) {
        enriched["display_name"] = cachedContact.displayName;
      }
    }

    if (statusId == 4) {
      ActiveCallController.instance.applyServerSession(enriched);
      await handleIncomingFaceTimeCall(enriched);
      return;
    }

    ActiveCallController.instance.applyServerSession(enriched);

    final bool isOutgoing = enriched["is_outgoing"] == true;
    final String? endedReason = _nonEmptyString(enriched["ended_reason"])?.toLowerCase();
    if (statusId == 6 && !isOutgoing && endedReason == "missed") {
      final String? callUuid = _nonEmptyString(enriched["uuid"]) ??
          _nonEmptyString(enriched["call_uuid"]) ??
          _nonEmptyString(enriched["session_uuid"]);
      final bool alreadyNotified = callUuid != null && _notifiedMissedCallUuids.contains(callUuid);
      if (!alreadyNotified && GetIt.I.isRegistered<NotificationsService>()) {
        if (callUuid != null) {
          if (_notifiedMissedCallUuids.length >= 100) _notifiedMissedCallUuids.clear();
          _notifiedMissedCallUuids.add(callUuid);
        }
        final bool isTelephony = enriched["is_telephony"] == true;
        final bool isAudio = isTelephony ||
            (enriched["is_video"] is bool
                ? !(enriched["is_video"] as bool)
                : (enriched["is_audio"] is bool ? enriched["is_audio"] as bool : false));
        String caller = _nonEmptyString(enriched["display_name"]) ??
            _nonEmptyString(address) ??
            (isTelephony ? "iPhone Call" : "Unknown Number");
        if (_nonEmptyString(enriched["display_name"]) == null &&
            address != null &&
            address.isNotEmpty &&
            GetIt.I.isRegistered<ContactServiceV2>()) {
          final contact = await ContactsSvcV2.getContact(address);
          caller = contact?.displayName ?? caller;
        }
        await NotificationsSvc.createMissedFaceTimeNotification(
          callUuid,
          caller,
          isAudio: isAudio,
          isTelephony: isTelephony,
          callerAddress: address,
        );
      }
    }
  }

  static String? _nonEmptyString(dynamic raw) {
    final trimmed = raw?.toString().trim();
    return (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
  }

  Future<void> handleIncomingFaceTimeCall(Map<String, dynamic> data) async {
    Logger.info("Handling incoming FaceTime call");
    final String? callUuid = _nonEmptyString(data["uuid"]);
    final bool isTelephony = data["is_telephony"] == true;
    final String? address = (data["handle"] is Map ? _nonEmptyString(data["handle"]["address"]) : null) ??
        _nonEmptyString(data["address"]);
    String caller = _nonEmptyString(data["address"]) ?? (isTelephony ? "iPhone call" : "Unknown Number");
    final bool isAudio = isTelephony ||
        (data["is_video"] is bool
            ? !(data["is_video"] as bool)
            : (data["is_audio"] is bool ? data["is_audio"] as bool : false));
    Uint8List? chatIcon;

    if (address != null && GetIt.I.isRegistered<ContactServiceV2>()) {
      ContactV2? contact = await ContactsSvcV2.getContact(address);
      if (contact?.avatarPath != null) {
        chatIcon = await ContactsSvcV2.getContactAvatar(contact!.nativeContactId);
      }
      caller = contact?.displayName ?? caller;
    }

    await _dispatchIncomingFaceTimeUI(
      callUuid: callUuid,
      caller: caller,
      chatIcon: chatIcon,
      isAudio: isAudio,
      callerAddress: address,
      isTelephony: isTelephony,
    );
  }

  Future<void> handleIncomingFaceTimeCallLegacy(Map<String, dynamic> data) async {
    Logger.info("Handling incoming FaceTime call (legacy)");
    final String? callUuid = _nonEmptyString(data["uuid"]);
    final bool isTelephony = data["is_telephony"] == true;
    final String? rawAddress = _nonEmptyString(data["address"]) ??
        (data["handle"] is Map ? _nonEmptyString(data["handle"]["address"]) : null);
    final String? rawCaller = _nonEmptyString(data["caller"]);
    final String? address = rawAddress ?? rawCaller;
    String? caller = rawCaller ?? address;
    final bool isAudio = isTelephony ||
        (data["is_video"] is bool
            ? !(data["is_video"] as bool)
            : (data["is_audio"] is bool ? data["is_audio"] as bool : false));
    Uint8List? chatIcon;

    if (address != null && GetIt.I.isRegistered<ContactServiceV2>()) {
      ContactV2? contact = await ContactsSvcV2.getContact(address);
      if (contact?.avatarPath != null) {
        chatIcon = await ContactsSvcV2.getContactAvatar(contact!.nativeContactId);
      }
      caller = contact?.displayName ?? caller;
    }

    if (caller == null) {
      if (callUuid == null) return;
      caller = isTelephony ? "iPhone call" : "Unknown Number";
    }

    await _dispatchIncomingFaceTimeUI(
      callUuid: callUuid,
      caller: caller,
      chatIcon: chatIcon,
      isAudio: isAudio,
      callerAddress: address,
      isTelephony: isTelephony,
      allowFallbackOverlayUuid: true,
    );
  }

  Future<void> _dispatchIncomingFaceTimeUI({
    required String? callUuid,
    required String caller,
    required Uint8List? chatIcon,
    required bool isAudio,
    required String? callerAddress,
    required bool isTelephony,
    bool allowFallbackOverlayUuid = false,
  }) async {
    final String? overlayUuid =
        callUuid ?? (allowFallbackOverlayUuid ? 'ft_${caller.hashCode}' : null);

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final handledByTelecom = await NotificationsSvc.createIncomingFaceTimeNotification(
        callUuid,
        caller,
        chatIcon,
        isAudio,
        callerAddress: callerAddress,
        isTelephony: isTelephony,
      );
      if (handledByTelecom) return;
      if (LifecycleSvc.isForeground && overlayUuid != null) {
        await showFaceTimeOverlay(
          overlayUuid,
          caller,
          chatIcon,
          isAudio,
          callerAddress: callerAddress,
          isTelephony: isTelephony,
        );
      }
      return;
    }

    if (!LifecycleSvc.isForeground) {
      if (kIsDesktop && overlayUuid != null) {
        await showFaceTimeOverlay(
          overlayUuid,
          caller,
          chatIcon,
          isAudio,
          callerAddress: callerAddress,
          isTelephony: isTelephony,
        );
      }
      await NotificationsSvc.createIncomingFaceTimeNotification(
        callUuid,
        caller,
        chatIcon,
        isAudio,
        callerAddress: callerAddress,
        isTelephony: isTelephony,
      );
    } else if (overlayUuid != null) {
      await showFaceTimeOverlay(
        overlayUuid,
        caller,
        chatIcon,
        isAudio,
        callerAddress: callerAddress,
        isTelephony: isTelephony,
      );
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
          final msgGuid = message.guid;
          if (message.isFromMe == true && msgGuid != null) {
            if (payload.data['tempGuid'] == null) {
              // No tempGuid — we don't know which local temp message this echo
              // belongs to.  Wait briefly for the paired updated-message event
              // to arrive (which will carry the tempGuid and remove this entry).
              // If nothing arrives, process the new-message normally.
              MessageHandlerSvc.outOfOrderTempGuids.add(msgGuid);
              await Future.delayed(const Duration(milliseconds: 500));
              if (!MessageHandlerSvc.outOfOrderTempGuids.remove(msgGuid)) return;
            } else {
              MessageHandlerSvc.outOfOrderTempGuids.remove(msgGuid);
            }
          }

          final rawChats = payload.data['chats'] as List?;
          final firstChat = rawChats?.whereType<Map>().firstOrNull;
          final chat = firstChat != null
              ? Chat.fromMap(firstChat.cast<String, dynamic>())
              : Message.findOne(guid: payload.data['tempGuid'] ?? msgGuid)?.chat.target;
          if (chat == null) {
            Logger.warn("Dropping new-message without chat metadata (guid=$msgGuid)");
            return;
          }

          await IncomingMsgHandler.handle(
              IncomingPayload(
                type: MessageEventType.newMessage,
                source: MessageSource.socket,
                chat: chat,
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
      case "message-send-error":
        if (!isNullOrEmpty(data)) {
          final payload = ServerPayload.fromJson(data);
          final updatedMessage = Message.fromMap(payload.data);
          if (event == "message-send-error" && updatedMessage.error == 0) {
            updatedMessage.error = 4;
          }
          if (updatedMessage.error > 0) updatedMessage.errorMessage = serverErrorMessage(updatedMessage.error);
          final rawChats = payload.data['chats'] as List?;
          final Chat? chat = (rawChats != null && rawChats.isNotEmpty)
              ? Chat.fromMap((rawChats.first as Map).cast<String, dynamic>())
              : Message.findOne(guid: payload.data['tempGuid'] ?? updatedMessage.guid)?.chat.target;
          if (chat == null) return;
          await IncomingMsgHandler.handle(
              IncomingPayload(
                type: MessageEventType.updatedMessage,
                source: MessageSource.socket,
                chat: chat,
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
          final display = data["display"] == true;
          controller.messageListGate.run(() => controller.setTypingIndicator(display));
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
        final aliases = (data["aliases"] as List?)?.whereType<String>().toList() ?? const <String>[];
        if (aliases.isNotEmpty) {
          await NotificationsSvc.createAliasesRemovedNotification(aliases);
        }
        return;
      case "new-findmy-location":
      case "new-findmy-device":
        EventDispatcherSvc.emit(event, data);
        return;
      default:
        return;
    }
  }
}
