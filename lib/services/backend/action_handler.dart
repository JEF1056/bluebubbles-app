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
  final Set<String> _answeredCallUuids = <String>{};
  final Map<String, ({String? callUuid, DateTime at})> _recentMissedByAddress =
      <String, ({String? callUuid, DateTime at})>{};

  static String? _normalizeCallAddress(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.contains('@')) return trimmed.toLowerCase();
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }

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
    final remoteAddresses = _extractRemoteAddresses(enriched);
    final String? address = remoteAddresses.isNotEmpty ? remoteAddresses.first : null;
    if ((enriched["display_name"] == null ||
            ActiveCallController.isGenericCallLabel(enriched["display_name"]?.toString())) &&
        remoteAddresses.isNotEmpty &&
        GetIt.I.isRegistered<ContactServiceV2>()) {
      final cachedNames = <String>[];
      var resolvedAny = false;
      for (final addr in remoteAddresses) {
        final cachedContact = ContactsSvcV2.findContactForAddressSync(addr);
        if (cachedContact != null && cachedContact.displayName.trim().isNotEmpty) {
          cachedNames.add(cachedContact.displayName.trim());
          resolvedAny = true;
        } else {
          cachedNames.add(addr);
        }
      }
      if (resolvedAny) {
        enriched["display_name"] = cachedNames.join(", ");
      }
    }

    if (statusId == 4) {
      ActiveCallController.instance.applyServerSession(enriched);
      await handleIncomingFaceTimeCall(enriched);
      return;
    }

    ActiveCallController.instance.applyServerSession(enriched);

    final String? callUuid = _nonEmptyString(enriched["uuid"]) ??
        _nonEmptyString(enriched["call_uuid"]) ??
        _nonEmptyString(enriched["session_uuid"]);
    final bool isTelephony = enriched["is_telephony"] == true;
    final bool isAudio = isTelephony ||
        (enriched["is_video"] is bool
            ? !(enriched["is_video"] as bool)
            : (enriched["is_audio"] is bool ? enriched["is_audio"] as bool : false));
    final bool? explicitIsGroup = enriched["is_group"] is bool ? enriched["is_group"] as bool : null;

    if (statusId != 6 &&
        callUuid != null &&
        remoteAddresses.isNotEmpty &&
        GetIt.I.isRegistered<ContactServiceV2>()) {
      await _resolveAndApplyCallerInfo(
        callUuid,
        remoteAddresses,
        existingDisplayName: _nonEmptyString(enriched["display_name"]),
        isVideo: !isAudio,
        isTelephony: isTelephony,
        explicitIsGroup: explicitIsGroup,
      );
    }

    final bool isOutgoing = enriched["is_outgoing"] == true;
    final String? endedReason = _nonEmptyString(enriched["ended_reason"])?.toLowerCase();
    final String? normalizedAddress = _normalizeCallAddress(address);
    final int? disconnectedReason =
        enriched["disconnected_reason"] is num ? (enriched["disconnected_reason"] as num).toInt() : null;

    if (statusId == 1) {
      if (callUuid != null) {
        if (_answeredCallUuids.length >= 100) _answeredCallUuids.clear();
        _answeredCallUuids.add(callUuid);
        if (_notifiedMissedCallUuids.contains(callUuid) && GetIt.I.isRegistered<NotificationsService>()) {
          unawaited(NotificationsSvc.clearMissedFaceTimeNotification(callUuid));
        }
      }
      if (normalizedAddress != null) {
        final recent = _recentMissedByAddress[normalizedAddress];
        if (recent != null && DateTime.now().difference(recent.at).inSeconds <= 15) {
          _recentMissedByAddress.remove(normalizedAddress);
          if (GetIt.I.isRegistered<NotificationsService>()) {
            unawaited(NotificationsSvc.clearMissedFaceTimeNotification(recent.callUuid));
          }
        }
      }
    }

    if (statusId == 6 && !isOutgoing && endedReason == "missed") {
      final bool wasAnswered =
          enriched["answered_at"] != null || (callUuid != null && _answeredCallUuids.contains(callUuid));
      final bool endedElsewhere = disconnectedReason == 17 || disconnectedReason == 18;
      final activeState = ActiveCallController.instance.state;
      final bool activeMatchesCaller =
          (activeState.phase == ActiveCallPhase.ongoing || activeState.phase == ActiveCallPhase.connecting) &&
              normalizedAddress != null &&
              _normalizeCallAddress(activeState.callerAddress) == normalizedAddress;
      final bool alreadyNotified = callUuid != null && _notifiedMissedCallUuids.contains(callUuid);
      if (!wasAnswered &&
          !endedElsewhere &&
          !activeMatchesCaller &&
          !alreadyNotified &&
          GetIt.I.isRegistered<NotificationsService>()) {
        if (callUuid != null) {
          if (_notifiedMissedCallUuids.length >= 100) _notifiedMissedCallUuids.clear();
          _notifiedMissedCallUuids.add(callUuid);
        }
        if (normalizedAddress != null) {
          if (_recentMissedByAddress.length >= 50) _recentMissedByAddress.clear();
          _recentMissedByAddress[normalizedAddress] = (callUuid: callUuid, at: DateTime.now());
        }
        String caller = _nonEmptyString(enriched["display_name"]) ??
            _nonEmptyString(address) ??
            ActiveCallController.callKindLabelFor(
              isVideo: !isAudio,
              isTelephony: isTelephony,
              isGroup: !isTelephony && (explicitIsGroup ?? remoteAddresses.length > 1),
            );
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

  List<String> _extractRemoteAddresses(Map<String, dynamic> data) {
    final candidates = <String>[];
    if (data["addresses"] is List) {
      for (final raw in (data["addresses"] as List)) {
        final s = _nonEmptyString(raw);
        if (s != null) candidates.add(s);
      }
    }
    final handleAddr = data["handle"] is Map ? _nonEmptyString(data["handle"]["address"]) : null;
    if (handleAddr != null) candidates.add(handleAddr);
    final singleAddr = _nonEmptyString(data["address"]);
    if (singleAddr != null) candidates.add(singleAddr);
    return ActiveCallController.filterRemoteAddresses(candidates);
  }

  Future<({List<CallParticipant> details, Uint8List? primaryAvatar, String? resolvedName})>
      _resolveParticipants(
    List<String> remoteAddresses, {
    String? existingDisplayName,
    required bool isVideo,
    required bool isTelephony,
    required bool isGroup,
  }) async {
    final details = <CallParticipant>[];
    Uint8List? primaryAvatar;

    if (GetIt.I.isRegistered<ContactServiceV2>()) {
      for (final addr in remoteAddresses) {
        final ContactV2? contact =
            ContactsSvcV2.findContactForAddressSync(addr) ?? await ContactsSvcV2.getContact(addr);
        Uint8List? avatar;
        if (contact != null && contact.nativeContactId.isNotEmpty) {
          avatar = await ContactsSvcV2.getContactAvatar(contact.nativeContactId);
          if (avatar != null && avatar.isEmpty) avatar = null;
        }
        primaryAvatar ??= avatar;
        final contactName = contact?.displayName.trim();
        details.add(
          CallParticipant(
            address: addr,
            displayName: (contactName != null && contactName.isNotEmpty) ? contactName : null,
            avatarBytes: avatar,
          ),
        );
      }
    } else {
      for (final addr in remoteAddresses) {
        details.add(CallParticipant(address: addr));
      }
    }

    String? resolvedName = existingDisplayName;
    final hasResolvedContact = details.any((p) => p.displayName != null && p.displayName!.isNotEmpty);
    final existingIsRawOrGeneric = existingDisplayName == null ||
        ActiveCallController.isGenericCallLabel(existingDisplayName) ||
        remoteAddresses.contains(existingDisplayName) ||
        existingDisplayName == remoteAddresses.join(", ");
    if (hasResolvedContact && existingIsRawOrGeneric) {
      resolvedName = ActiveCallController.formatParticipantNames(
        details.map((p) => p.label),
        isVideo: isVideo,
        isTelephony: isTelephony,
        isGroup: isGroup,
      );
    }

    return (details: details, primaryAvatar: primaryAvatar, resolvedName: resolvedName);
  }

  Future<void> _resolveAndApplyCallerInfo(
    String callUuid,
    List<String> remoteAddresses, {
    String? existingDisplayName,
    required bool isVideo,
    required bool isTelephony,
    bool? explicitIsGroup,
  }) async {
    final isGroup = !isTelephony && (explicitIsGroup ?? remoteAddresses.length > 1);
    final resolved = await _resolveParticipants(
      remoteAddresses,
      existingDisplayName: existingDisplayName,
      isVideo: isVideo,
      isTelephony: isTelephony,
      isGroup: isGroup,
    );
    final currentAvatar = ActiveCallController.instance.state.avatarBytes;
    final nextAvatar = (currentAvatar == null || currentAvatar.isEmpty) ? resolved.primaryAvatar : null;
    ActiveCallController.instance.updateCallerInfo(
      callUuid,
      callerName: resolved.resolvedName,
      callerAddress: remoteAddresses.first,
      avatarBytes: nextAvatar,
      isGroup: isGroup,
      participants: remoteAddresses,
      participantDetails: resolved.details,
    );
  }

  Future<void> handleIncomingFaceTimeCall(Map<String, dynamic> data) async {
    Logger.info("Handling incoming FaceTime call");
    final String? callUuid = _nonEmptyString(data["uuid"]);
    final bool isTelephony = data["is_telephony"] == true;
    final remoteAddresses = _extractRemoteAddresses(data);
    final String? address = remoteAddresses.isNotEmpty ? remoteAddresses.first : null;
    final bool isAudio = isTelephony ||
        (data["is_video"] is bool
            ? !(data["is_video"] as bool)
            : (data["is_audio"] is bool ? data["is_audio"] as bool : false));
    final bool isGroup = !isTelephony && (data["is_group"] == true || remoteAddresses.length > 1);

    final resolved = await _resolveParticipants(
      remoteAddresses,
      existingDisplayName: _nonEmptyString(data["display_name"]),
      isVideo: !isAudio,
      isTelephony: isTelephony,
      isGroup: isGroup,
    );

    final String caller = resolved.resolvedName ??
        address ??
        ActiveCallController.callKindLabelFor(
          isVideo: !isAudio,
          isTelephony: isTelephony,
          isGroup: isGroup,
        );

    if (callUuid != null) {
      ActiveCallController.instance.updateCallerInfo(
        callUuid,
        callerName: caller,
        callerAddress: address,
        avatarBytes: resolved.primaryAvatar,
        isGroup: isGroup,
        participants: remoteAddresses,
        participantDetails: resolved.details,
      );
    }

    await _dispatchIncomingFaceTimeUI(
      callUuid: callUuid,
      caller: caller,
      chatIcon: resolved.primaryAvatar,
      isAudio: isAudio,
      callerAddress: address,
      isTelephony: isTelephony,
      isGroup: isGroup,
      participants: remoteAddresses,
      participantDetails: resolved.details,
    );
  }

  Future<void> handleIncomingFaceTimeCallLegacy(Map<String, dynamic> data) async {
    Logger.info("Handling incoming FaceTime call (legacy)");
    final String? callUuid = _nonEmptyString(data["uuid"]);
    final bool isTelephony = data["is_telephony"] == true;
    final remoteAddresses = _extractRemoteAddresses(data);
    final String? rawCaller = _nonEmptyString(data["caller"]);
    final String? address = remoteAddresses.isNotEmpty ? remoteAddresses.first : rawCaller;
    final bool isAudio = isTelephony ||
        (data["is_video"] is bool
            ? !(data["is_video"] as bool)
            : (data["is_audio"] is bool ? data["is_audio"] as bool : false));
    final bool isGroup = !isTelephony && (data["is_group"] == true || remoteAddresses.length > 1);

    final resolved = await _resolveParticipants(
      remoteAddresses.isNotEmpty ? remoteAddresses : [if (address != null) address],
      existingDisplayName: rawCaller,
      isVideo: !isAudio,
      isTelephony: isTelephony,
      isGroup: isGroup,
    );

    String? caller = resolved.resolvedName ?? address;
    if (caller == null) {
      if (callUuid == null) return;
      caller = ActiveCallController.callKindLabelFor(
        isVideo: !isAudio,
        isTelephony: isTelephony,
        isGroup: isGroup,
      );
    }

    await _dispatchIncomingFaceTimeUI(
      callUuid: callUuid,
      caller: caller,
      chatIcon: resolved.primaryAvatar,
      isAudio: isAudio,
      callerAddress: address,
      isTelephony: isTelephony,
      isGroup: isGroup,
      participants: remoteAddresses,
      participantDetails: resolved.details,
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
    bool isGroup = false,
    List<String> participants = const [],
    List<CallParticipant> participantDetails = const [],
    bool allowFallbackOverlayUuid = false,
  }) async {
    final String? overlayUuid =
        callUuid ?? (allowFallbackOverlayUuid ? 'ft_${caller.hashCode}' : null);
    final currentCallState = ActiveCallController.instance.state;
    // Skip re-showing the incoming overlay for an already-active call with the same UUID
    // (still allow the initial ft-call-status-changed status_id=4 pass before faceTimeOverlays is populated).
    final bool skipOverlay = overlayUuid != null &&
        currentCallState.callUuid == overlayUuid &&
        currentCallState.phase != ActiveCallPhase.idle &&
        (currentCallState.phase != ActiveCallPhase.incoming ||
            faceTimeOverlays.containsKey(overlayUuid));

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
      if (LifecycleSvc.isForeground && overlayUuid != null && !skipOverlay) {
        await showFaceTimeOverlay(
          overlayUuid,
          caller,
          chatIcon,
          isAudio,
          callerAddress: callerAddress,
          isTelephony: isTelephony,
          isGroup: isGroup,
          participants: participants,
          participantDetails: participantDetails,
        );
      }
      return;
    }

    if (!LifecycleSvc.isForeground) {
      if (kIsDesktop && overlayUuid != null && !skipOverlay) {
        await showFaceTimeOverlay(
          overlayUuid,
          caller,
          chatIcon,
          isAudio,
          callerAddress: callerAddress,
          isTelephony: isTelephony,
          isGroup: isGroup,
          participants: participants,
          participantDetails: participantDetails,
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
    } else if (overlayUuid != null && !skipOverlay) {
      await showFaceTimeOverlay(
        overlayUuid,
        caller,
        chatIcon,
        isAudio,
        callerAddress: callerAddress,
        isTelephony: isTelephony,
        isGroup: isGroup,
        participants: participants,
        participantDetails: participantDetails,
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
        if (chat != null && readBefore != null) {
          chat.lastReadAt = readBefore;
          ChatsSvc.getChatState(chat.guid)?.chat.lastReadAt = readBefore;
        }
        if (chat != null && rawRead == true && await chat.clearNotificationsForPartialRead(readBefore)) return;
        if (chat != null && rawRead is bool) {
          // Route through ChatsService so the ChatState the conversation list
          // renders from is updated too. Writing only to the DB row leaves the
          // unread dot stale until the state is rebuilt (open chat / restart).
          // Forced so a chat already marked read locally (e.g. by a reply from another device) still clears.
          await ChatsSvc.setChatHasUnread(chat, !rawRead,
              force: rawRead, privateMark: false, readBefore: readBefore);
          if (rawRead && Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
            Get.find<ConversationViewController>(tag: chat.guid).clearUnreadDivider();
          }
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
