import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/database/global/attributed_body.dart';
import 'package:bluebubbles/database/global/message_summary_info.dart';
import 'package:bluebubbles/database/global/payload_data.dart';
import 'package:bluebubbles/database/html/attachment.dart';
import 'package:bluebubbles/database/html/chat.dart';
import 'package:bluebubbles/database/html/handle.dart';
import 'package:bluebubbles/database/html/objectbox.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/interfaces/message_interface.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide Condition;

class Message {
  int? id;
  int? originalROWID;
  String? guid;
  int? handleId;
  int? otherHandle;
  String? text;
  String? subject;
  String? country;
  DateTime? dateCreated;
  bool? isFromMe;
  // Data detector results
  bool? hasDdResults;
  DateTime? datePlayed;
  bool hasEffectPlayed;
  int? itemType;
  String? groupTitle;
  int? groupActionType;
  String? balloonBundleId;
  String? associatedMessageGuid;
  int? associatedMessagePart;
  String? associatedMessageType;
  String? associatedMessageEmoji;
  String? expressiveSendStyleId;
  String? service;
  Handle? handle;
  bool hasAttachments;
  bool hasReactions;

  final handleRelation = ToOne<Handle>();
  DateTime? dateDeleted;
  Map<String, dynamic>? metadata;
  String? threadOriginatorGuid;
  String? threadOriginatorPart;

  List<Message> associatedMessages = [];
  bool? bigEmoji;
  List<AttributedBody> attributedBody;
  List<MessageSummaryInfo> messageSummaryInfo;
  PayloadData? payloadData;
  bool hasApplePayloadData;
  bool wasDeliveredQuietly;
  bool didNotifyRecipient;
  bool isBookmarked;

  final RxInt _error = RxInt(0);
  int get error => _error.value;
  set error(int i) => _error.value = i;

  String? errorMessage;

  final Rxn<DateTime> _dateRead = Rxn<DateTime>();
  DateTime? get dateRead => _dateRead.value;
  set dateRead(DateTime? d) => _dateRead.value = d;

  final Rxn<DateTime> _dateDelivered = Rxn<DateTime>();
  DateTime? get dateDelivered => _dateDelivered.value;
  set dateDelivered(DateTime? d) => _dateDelivered.value = d;

  final RxBool _isDelivered = RxBool(false);
  bool get isDelivered => (dateDelivered != null) ? true : _isDelivered.value;
  set isDelivered(bool b) => _isDelivered.value = b;

  final Rxn<DateTime> _dateEdited = Rxn<DateTime>();
  DateTime? get dateEdited => _dateEdited.value;
  set dateEdited(DateTime? d) => _dateEdited.value = d;

  List<int> get retractedParts => messageSummaryInfo.firstOrNull?.retractedParts ?? [];

  bool get hasUnsentParts => dateEdited != null && retractedParts.isNotEmpty;

  final dbAttachments = ToMany<Attachment>();
  final chat = ToOne<Chat>();

  String? get dbAttributedBody => jsonEncode(attributedBody.map((e) => e.toMap()).toList());
  set dbAttributedBody(String? json) => attributedBody =
      json == null ? <AttributedBody>[] : (jsonDecode(json) as List).map((e) => AttributedBody.fromMap(e)).toList();

  String? get dbMessageSummaryInfo => jsonEncode(messageSummaryInfo.map((e) => e.toJson()).toList());
  set dbMessageSummaryInfo(String? json) => messageSummaryInfo = json == null
      ? <MessageSummaryInfo>[]
      : (jsonDecode(json) as List).map((e) => MessageSummaryInfo.fromJson(e)).toList();

  String? get dbPayloadData => payloadData == null ? null : jsonEncode(payloadData!.toJson());
  set dbPayloadData(String? json) => payloadData = json == null ? null : PayloadData.fromJson(jsonDecode(json));

  String? get dbMetadata => metadata == null ? null : jsonEncode(metadata);
  set dbMetadata(String? json) => metadata = json == null ? null : jsonDecode(json) as Map<String, dynamic>;

  bool get isKeptAudio => itemType == 5 && subject != null;

  bool get isSending => isFromMe == true && guid != null && guid!.startsWith("temp");

  bool get isSticker => associatedMessageType == "sticker" && associatedMessageGuid != null;

  /// A tapback or sticker on another message; see the io [Message.isReaction].
  bool get isReaction => associatedMessageGuid != null && ReactionTypes.isReactionType(associatedMessageType);

  static Condition<Message> get reactionCondition =>
      Message_.associatedMessageGuid.notNull() & Message_.associatedMessageType.oneOf(ReactionTypes.associatedTypes);

  static Condition<Message> get notReactionCondition =>
      Message_.associatedMessageGuid.isNull() |
      Message_.associatedMessageType.isNull() |
      ReactionTypes.associatedTypes
          .map((type) => Message_.associatedMessageType.notEquals(type))
          .reduce((a, b) => a & b);

  bool get isNameChange => itemType == 2;

  bool get isGroupPhotoEvent => itemType == 3 && (groupActionType ?? 0) > 0;

  bool get isGroupPhotoChanged => itemType == 3 && groupActionType == 1;

  bool get isGroupPhotoRemoved => itemType == 3 && groupActionType == 2;

  bool get isGroupPhotoState => itemType == 3 && groupActionType == 3;

  bool get isReply => threadOriginatorGuid != null;

  Message({
    this.id,
    this.originalROWID,
    this.guid,
    this.handleId,
    this.otherHandle,
    this.text,
    this.subject,
    this.country,
    int? error,
    this.errorMessage,
    this.dateCreated,
    DateTime? dateRead,
    DateTime? dateDelivered,
    bool? isDelievered,
    this.isFromMe = true,
    this.hasDdResults = false,
    this.datePlayed,
    this.hasEffectPlayed = false,
    this.itemType = 0,
    this.groupTitle,
    this.groupActionType = 0,
    this.balloonBundleId,
    this.associatedMessageGuid,
    this.associatedMessagePart,
    this.associatedMessageType,
    this.associatedMessageEmoji,
    this.expressiveSendStyleId,
    this.service,
    this.handle,
    this.hasAttachments = false,
    this.hasReactions = false,
    this.associatedMessages = const [],
    this.dateDeleted,
    this.metadata,
    this.threadOriginatorGuid,
    this.threadOriginatorPart,
    this.attributedBody = const [],
    this.messageSummaryInfo = const [],
    this.payloadData,
    this.hasApplePayloadData = false,
    DateTime? dateEdited,
    this.wasDeliveredQuietly = false,
    this.didNotifyRecipient = false,
    this.isBookmarked = false,
  }) {
    if (error != null) _error.value = error;
    if (dateRead != null) _dateRead.value = dateRead;
    if (dateDelivered != null) _dateDelivered.value = dateDelivered;
    if (dateEdited != null) _dateEdited.value = dateEdited;
    if (isDelievered != null) _isDelivered.value = isDelievered;
    if (associatedMessages.isEmpty) associatedMessages = [];
    if (attributedBody.isEmpty) attributedBody = [];
    if (messageSummaryInfo.isEmpty) messageSummaryInfo = [];
  }

  factory Message.fromMap(Map<String, dynamic> json) {
    final attachments = (json['attachments'] as List? ?? [])
        .map((a) => Attachment.fromMap((a as Map).cast<String, dynamic>()))
        .toList();

    List<AttributedBody> attributedBody = [];
    if (json["attributedBody"] != null) {
      if (json['attributedBody'] is Map) {
        json['attributedBody'] = [json['attributedBody']!.cast<String, dynamic>()];
      }
      try {
        attributedBody =
            (json['attributedBody'] as List).map((a) => AttributedBody.fromMap(a!.cast<String, dynamic>())).toList();
      } catch (e, stack) {
        Logger.error('Failed to parse attributed body!', error: e, trace: stack);
      }
    }

    Map<String, dynamic> metadata = {};
    if (!isNullOrEmpty(json["metadata"])) {
      if (json["metadata"] is String) {
        try {
          metadata = jsonDecode(json["metadata"]);
        } catch (_) {}
      } else {
        metadata = json["metadata"]?.cast<String, dynamic>();
      }
    }

    List<MessageSummaryInfo> msi = [];
    try {
      msi = (json['messageSummaryInfo'] as List? ?? [])
          .map((e) => MessageSummaryInfo.fromJson(e!.cast<String, dynamic>()))
          .toList();
    } catch (e, stack) {
      Logger.error('Failed to parse summary info!', error: e, trace: stack);
    }

    PayloadData? payloadData;
    try {
      payloadData = json['payloadData'] == null ? null : PayloadData.fromJson(json['payloadData']);
    } catch (e, stack) {
      Logger.error('Failed to parse payload data!', error: e, trace: stack);
    }
    final appPayload = json['appPayload'];
    final app = payloadData?.appData?.firstOrNull;
    if (appPayload is Map && app != null) {
      app.sessionId = appPayload['session_id'] as String? ?? app.sessionId;
      app.ldText = appPayload['summary'] as String? ?? app.ldText;
      app.url = appPayload['url'] as String? ?? app.url;
    } else if (appPayload is Map) {
      final caption = appPayload['caption'] as String?;
      payloadData = PayloadData(type: PayloadType.app, appData: [
        iMessageAppData(
          appName: appPayload['app_name'] as String?,
          ldText: appPayload['summary'] as String?,
          url: appPayload['url'] as String?,
          sessionId: appPayload['session_id'] as String?,
          userInfo: caption == null ? null : UserInfo(caption: caption),
        ),
      ]);
    }

    final message = Message(
      id: json["ROWID"] ?? json['id'],
      originalROWID: json["originalROWID"],
      guid: json["guid"],
      handleId: json["handleId"] ?? 0,
      otherHandle: json["otherHandle"],
      text: sanitizeString(attributedBody.firstOrNull?.string ?? json["text"]),
      subject: json["subject"],
      country: json["country"],
      error: json["error"] ?? json["_error"] ?? 0,
      errorMessage: json['errorMessage'] as String?,
      dateCreated: parseDate(json["dateCreated"]),
      dateRead: parseDate(json["dateRead"]),
      dateDelivered: parseDate(json["dateDelivered"]),
      isDelievered: json["isDelivered"] ?? false,
      isFromMe: json['isFromMe'] == true,
      hasDdResults: json['hasDdResults'] == true,
      datePlayed: parseDate(json["datePlayed"]),
      itemType: json["itemType"],
      groupTitle: json["groupTitle"],
      groupActionType: json["groupActionType"] ?? 0,
      balloonBundleId: json["balloonBundleId"],
      associatedMessageGuid: json["associatedMessageGuid"]?.toString().replaceAll("bp:", "").split("/").last,
      associatedMessagePart: json["associatedMessagePart"] ??
          int.tryParse(json["associatedMessageGuid"].toString().replaceAll("p:", "").split("/").first),
      associatedMessageType: json["associatedMessageType"],
      associatedMessageEmoji: json["associatedMessageEmoji"],
      expressiveSendStyleId: json["expressiveSendStyleId"],
      service: json["service"],
      handle: json['handle'] != null ? Handle.fromMap((json['handle'] as Map).cast<String, dynamic>()) : null,
      hasAttachments: attachments.isNotEmpty || json['hasAttachments'] == true,
      hasReactions: json['hasReactions'] == true,
      dateDeleted: parseDate(json["dateDeleted"]),
      metadata: metadata is String ? null : metadata,
      threadOriginatorGuid: json['threadOriginatorGuid'],
      threadOriginatorPart: json['threadOriginatorPart'],
      attributedBody: attributedBody,
      messageSummaryInfo: msi,
      payloadData: payloadData,
      hasApplePayloadData: json['hasApplePayloadData'] == true || payloadData != null,
      dateEdited: parseDate(json["dateEdited"]),
      wasDeliveredQuietly: json['wasDeliveredQuietly'] ?? false,
      didNotifyRecipient: json['didNotifyRecipient'] ?? false,
      isBookmarked: json['isBookmarked'] ?? false,
    );
    if (attachments.isNotEmpty) {
      message.dbAttachments.addAll(attachments);
    }
    return message;
  }

  Message save({Chat? chat, bool updateIsBookmarked = false}) {
    HtmlDatabase.runInTransaction(TxMode.write, () {
      Message? existing = Message.findOne(guid: guid);
      if (existing != null) {
        id = existing.id;
        text ??= existing.text;

        if (existing.handleRelation.hasValue) {
          handleRelation.target = existing.handleRelation.target;
        }

        if (chat == null && !this.chat.hasValue && existing.chat.hasValue) {
          this.chat.target = existing.chat.target;
        }
      }

      if (handle != null && !handleRelation.hasValue) {
        if (handle!.id != null) {
          handleRelation.targetId = handle!.id!;
        } else if (handleId != null) {
          final foundHandle = Handle.findOne(originalROWID: handleId);
          if (foundHandle != null) {
            handleRelation.target = foundHandle;
          }
        }
      }
      if (associatedMessageType != null && isReaction) {
        Message? associatedMessage = Message.findOne(guid: associatedMessageGuid);
        if (associatedMessage != null) {
          associatedMessage.hasReactions = true;
          associatedMessage.save();
        }
      } else if (!hasReactions) {
        Message? reaction = Message.findOne(associatedMessageGuid: guid);
        if (reaction != null) {
          hasReactions = true;
        }
      }
      if (!updateIsBookmarked) {
        isBookmarked = existing?.isBookmarked ?? isBookmarked;
      }

      try {
        if (chat != null) this.chat.target = chat;
        final attachmentsToPreserve = List<Attachment>.from(dbAttachments);
        id = HtmlDatabase.messages.put(this);
        if (attachmentsToPreserve.isNotEmpty) {
          dbAttachments.clear();
          dbAttachments.addAll(attachmentsToPreserve);
          dbAttachments.applyToDb();
        }
      } on UniqueViolationException catch (_) {}
    });
    (WebListeners.notifyMessage as dynamic)(this, chat: chat);
    return this;
  }

  Future<Message> saveAsync({Chat? chat, bool updateIsBookmarked = false}) async {
    final result = await MessageInterface.saveMessageAsync(
      messageData: toMap(),
      chatData: chat?.toMap(),
      updateIsBookmarked: updateIsBookmarked,
    );

    if (result != null) {
      id = result.id;
    }
    (WebListeners.notifyMessage as dynamic)(this, chat: chat);
    return this;
  }

  static Future<Message> replaceMessage(String? oldGuid, Message newMessage) async {
    final replaced = await MessageInterface.replaceMessage(
      oldGuid: oldGuid,
      newMessageData: newMessage.toMap(),
    );
    (WebListeners.notifyMessage as dynamic)(replaced, tempGuid: oldGuid);
    return replaced as dynamic;
  }

  Message setPlayedDate({DateTime? timestamp}) {
    datePlayed = timestamp ?? DateTime.now().toUtc();
    save();
    return this;
  }

  Message setEffectPlayed() {
    hasEffectPlayed = true;
    save();
    return this;
  }

  Future<Message> fetchAssociatedMessages({MessagesService? service, bool shouldRefresh = false}) async {
    final result = await MessageInterface.fetchAssociatedMessagesAsync(
      messageGuid: guid!,
      messageId: id,
      threadOriginatorGuid: threadOriginatorGuid,
    );

    final associatedMessagesData = (result['associatedMessages'] as List).cast<Map<String, dynamic>>();
    associatedMessages = associatedMessagesData.map((e) => Message.fromMap(e)).toList();

    if (threadOriginatorGuid != null) {
      final existing = service?.struct.getMessage(threadOriginatorGuid!);
      if (existing != null && !associatedMessages.any((m) => m.guid == threadOriginatorGuid)) {
        associatedMessages.add(existing as dynamic);
      } else if (existing == null && associatedMessages.any((m) => m.guid == threadOriginatorGuid)) {
        final threadOriginator = associatedMessages.firstWhere((m) => m.guid == threadOriginatorGuid);
        (service?.struct.addThreadOriginator as dynamic)?.call(threadOriginator);
      }
    }

    return this;
  }

  Handle? getHandle() {
    if (handleRelation.target != null) return handleRelation.target;
    if (handleId == 0 || handleId == null) return null;
    return Handle.findOne(originalROWID: handleId!);
  }

  static Message? findOne({String? guid, String? associatedMessageGuid}) {
    if (guid != null) {
      final query = HtmlDatabase.messages.query(Message_.guid.equals(guid)).build();
      query.limit = 1;
      final result = query.findFirst();
      query.close();
      return result;
    } else if (associatedMessageGuid != null) {
      final query = HtmlDatabase.messages
          .query(Message_.associatedMessageGuid.equals(associatedMessageGuid) & Message.reactionCondition)
          .build();
      query.limit = 1;
      final result = query.findFirst();
      query.close();
      return result;
    }
    return null;
  }

  static Future<Message?> findOneAsync({String? guid, String? associatedMessageGuid}) async {
    final result = await MessageInterface.findOneAsync(
      guid: guid,
      associatedMessageGuid: associatedMessageGuid,
    );
    return result as dynamic;
  }

  static Message? findRemovedStickerTapback(Message removal) => null;

  static List<Message> find({Condition<Message>? cond}) {
    final query = HtmlDatabase.messages.query(cond).build();
    final results = query.find();
    query.close();
    return results;
  }

  static Future<List<Message>> findAsync({Condition<Message>? cond}) async {
    final results = await MessageInterface.findAsync(conditionJson: null);
    return (results as List).cast<Message>();
  }

  static Future<void> delete(String guid) async {
    await MessageInterface.deleteMessage(guid: guid);
  }

  static Future<void> softDelete(String guid) async {
    await MessageInterface.softDeleteMessage(guid: guid);
  }

  static Future<int> relinkMessagesToHandle({required int handleId, required int localHandleId}) async {
    return await MessageInterface.relinkMessagesToHandle(handleId: handleId, localHandleId: localHandleId);
  }

  static int sort(Message a, Message b, {bool descending = true}) {
    late DateTime aDateToUse;

    if (a.dateDelivered == null) {
      aDateToUse = a.dateCreated!;
    } else {
      aDateToUse = a.dateCreated!.isBefore(a.dateDelivered!) ? a.dateCreated! : a.dateDelivered!;
    }

    late DateTime bDateToUse;
    if (b.dateDelivered == null) {
      bDateToUse = b.dateCreated!;
    } else {
      bDateToUse = b.dateCreated!.isBefore(b.dateDelivered!) ? b.dateCreated! : b.dateDelivered!;
    }

    return descending ? bDateToUse.compareTo(aDateToUse) : aDateToUse.compareTo(bDateToUse);
  }

  String get fullText => sanitizeString([subject, text].where((e) => !isNullOrEmpty(e)).join("\n"));

  // first condition is for macOS < 11 and second condition is for macOS >= 11
  bool get isLegacyUrlPreview =>
      (balloonBundleId == "com.apple.messages.URLBalloonProvider" && hasDdResults!) ||
      ((hasDdResults! || isFromMe!) && (text ?? "").trim().isURL);

  String? get url => text?.replaceAll("\n", " ").split(" ").firstWhereOrNull((String e) => e.hasUrl);

  bool get isInteractive => balloonBundleId != null && !isLegacyUrlPreview;

  bool get isPhotoSlideshow => balloonBundleId?.split(":").last == 'com.apple.mobileslideshow.PhotosMessagesApp';

  String get interactiveText {
    String text = "";

    if (payloadData?.urlData != null && payloadData!.urlData!.isNotEmpty && payloadData?.urlData?.first.url != null) {
      final uri = Uri.parse(payloadData!.urlData!.first.url!);
      return "Website: ${payloadData!.urlData!.first.title} (${uri.host.replaceFirst('www.', '')})";
    }

    final temp =
        balloonBundleIdMap[balloonBundleId?.split(":").first] ?? (balloonBundleId?.split(":").first ?? "Unknown");
    if (temp is Map) {
      text = temp[balloonBundleId?.split(":").last] ?? ((balloonBundleId?.split(":").last ?? "Unknown"));
    } else {
      text = temp.toString();
    }
    return text;
  }

  String? get interactiveMediaPath {
    return null;
  }

  bool get isGroupEvent => groupTitle != null || (itemType ?? 0) > 0 || (groupActionType ?? 0) > 0;

  String get groupEventText {
    final h = handle ?? handleRelation.target ?? getHandle();
    final name = h?.displayName ?? (isFromMe! || h == null ? SettingsSvc.effectiveUserName : 'Unknown');
    return buildGroupEventText(name);
  }

  /// Build the group-event description string with a pre-resolved [senderName].
  String buildGroupEventText(String senderName) {
    if (isGroupPhotoState) return "The group photo was updated.";

    String text = "Unknown group event";
    final name = senderName;

    String? other = "someone";
    if (otherHandle != null && isParticipantEvent) {
      other = Handle.findOne(originalROWID: otherHandle)?.displayName ?? other;
    }

    if (itemType == 1) {
      if (groupActionType == 0) {
        text = "$name added $other to the conversation.";
      } else if (groupActionType == 1) {
        text = "$name removed $other from the conversation.";
      }
    } else if (itemType == 2) {
      if (groupTitle != null) {
        text = "$name named the conversation \"$groupTitle\".";
      } else {
        text = "$name removed the name from the conversation.";
      }
    } else if (itemType == 3) {
      if (groupActionType == null || groupActionType == 0) {
        text = "$name left the conversation.";
      } else if (groupActionType == 1) {
        text = "$name changed the group photo.";
      } else if (groupActionType == 2) {
        text = "$name removed the group photo.";
      }
    } else if (itemType == 4 && groupActionType == 0) {
      text = "$name shared ${name == "You" ? "your" : "their"} location.";
    } else if (itemType == 5) {
      text = "$name kept an audio message.";
    } else if (itemType == 6) {
      text = "$name started a FaceTime call.";
    }

    return text;
  }

  bool get isParticipantEvent =>
      isGroupEvent && ((itemType == 1 && [0, 1].contains(groupActionType)) || [2, 3].contains(itemType));

  bool get isBigEmoji => bigEmoji ?? MessageHelper.shouldShowBigEmoji(fullText);

  List<Attachment> get realAttachments => dbAttachments.where((e) => e.mimeType != null).toList();

  List<Attachment> get previewAttachments => dbAttachments.where((e) => e.mimeType == null).toList();

  List<Message> get reactions => associatedMessages.where((m) => (ReactionTypes.isTapback as dynamic)(m) as bool).toList();

  MessageStatusIndicator get indicatorToShow {
    if (!isFromMe!) return MessageStatusIndicator.NONE;
    if (dateRead != null) return MessageStatusIndicator.READ;
    if (isDelivered) return MessageStatusIndicator.DELIVERED;
    if (dateDelivered != null) return MessageStatusIndicator.DELIVERED;
    if (dateCreated != null) return MessageStatusIndicator.SENT;
    return MessageStatusIndicator.NONE;
  }

  bool get hasAudioTranscript => attributedBody.any((i) => i.runs.any((e) => e.attributes?.audioTranscript != null));

  bool showTail(Message? newer) {
    // if there is no newer, or if the newer is a different sender or reply boundary
    if (newer == null || !sameSender(newer) || newer.isGroupEvent || isReply != newer.isReply) {
      return true;
    }
    if (isReply &&
        (threadOriginatorGuid != newer.threadOriginatorGuid ||
            normalizedThreadPart != newer.normalizedThreadPart)) {
      return true;
    }
    // if newer is over a minute newer
    return newer.dateCreated!.difference(dateCreated!).inMinutes.abs() > 1;
  }

  bool sameSender(Message? other) {
    return (isFromMe! && isFromMe == other?.isFromMe) ||
        (!isFromMe! && !(other?.isFromMe ?? true) && handleId == other?.handleId);
  }

  void generateTempGuid() {
    guid = "temp-${randomString(8)}";
  }

  static int? countForChat(Chat? chat) {
    if (chat == null || chat.id == null) return 0;
    return chat.messages.length;
  }

  Message mergeWith(Message otherMessage) {
    return Message.merge(this, otherMessage);
  }

  /// Get what shape the reply line should be
  LineType getLineType(Message? olderMessage, Message threadOriginator) {
    if (olderMessage?.threadOriginatorGuid != threadOriginatorGuid) olderMessage = threadOriginator;
    if (isFromMe! && (olderMessage?.isFromMe ?? false)) {
      return LineType.meToMe;
    } else if (!isFromMe! && (olderMessage?.isFromMe ?? false)) {
      return LineType.meToOther;
    } else if (isFromMe! && !(olderMessage?.isFromMe ?? false)) {
      return LineType.otherToMe;
    } else {
      return LineType.otherToOther;
    }
  }

  /// Get whether the reply line from the message should connect to the message below
  bool shouldConnectLower(Message? olderMessage, Message? newerMessage, Message threadOriginator) {
    if (newerMessage == null || newerMessage.threadOriginatorGuid != threadOriginatorGuid) return false;
    if (getLineType(olderMessage, threadOriginator) == LineType.meToOther ||
        getLineType(olderMessage, threadOriginator) == LineType.otherToOther) {
      return false;
    }
    return isFromMe != newerMessage.isFromMe;
  }

  int get normalizedThreadPart {
    if (threadOriginatorPart == null || threadOriginatorPart!.isEmpty) return 0;
    return int.tryParse(threadOriginatorPart!.split(':').first) ?? 0;
  }

  bool connectToUpper() => threadOriginatorGuid != null;

  bool showUpperMessage(Message olderMessage) {
    final olderPartCount = chat.target?.guid != null
        ? maybeFindMessagesSvc(chat.target!.guid)?.getMessageStateIfExists(olderMessage.guid!)?.parts.length ?? 1
        : 1;
    if (olderMessage.threadOriginatorGuid == null) {
      if (olderMessage.guid != threadOriginatorGuid) return true;
      return normalizedThreadPart != olderPartCount - 1;
    }
    return olderMessage.threadOriginatorGuid != threadOriginatorGuid ||
        olderMessage.normalizedThreadPart != normalizedThreadPart;
  }

  bool connectToLower(Message newerMessage) {
    final thisPartCount = chat.target?.guid != null
        ? maybeFindMessagesSvc(chat.target!.guid)?.getMessageStateIfExists(guid!)?.parts.length ?? 1
        : 1;
    if (newerMessage.isFromMe != isFromMe) return false;
    if (threadOriginatorGuid != null) {
      return newerMessage.threadOriginatorGuid == threadOriginatorGuid &&
          newerMessage.normalizedThreadPart == normalizedThreadPart;
    } else {
      if (newerMessage.normalizedThreadPart != thisPartCount - 1) return false;
      return newerMessage.threadOriginatorGuid == guid;
    }
  }

  /// Get whether the reply line from the message should connect to the message above
  bool shouldConnectUpper(Message? olderMessage, Message threadOriginator) {
    if (olderMessage == null ||
        (olderMessage.threadOriginatorGuid != threadOriginatorGuid && !upperIsThreadOriginatorBubble(olderMessage))) {
      return false;
    }
    if (upperIsThreadOriginatorBubble(olderMessage) ||
        (!threadOriginator.isFromMe! && isFromMe!) ||
        getLineType(olderMessage, threadOriginator) == LineType.meToMe ||
        getLineType(olderMessage, threadOriginator) == LineType.otherToMe) {
      return true;
    }
    return isFromMe == olderMessage.isFromMe;
  }

  /// Get whether the upper bubble is actually the thread originator as the outlined bubble
  bool upperIsThreadOriginatorBubble(Message? olderMessage) {
    return olderMessage?.threadOriginatorGuid != threadOriginatorGuid;
  }

  Size getBubbleSize(BuildContext context,
      {double? maxWidthOverride, double? minHeightOverride, String? textOverride}) {
    if (MessagesService.cachedBubbleSizes[guid!] != null) return MessagesService.cachedBubbleSizes[guid!]!;
    if (fullText.isEmpty && dbAttachments.isNotEmpty) {
      return Size(
          dbAttachments
              .map((e) => e.width)
              .fold(0, (p, e) => max(p, (e ?? NavigationSvc.width(context) / 2).toDouble()) + 28),
          dbAttachments
              .map((e) => e.height)
              .fold(0, (p, e) => max(p, (e ?? NavigationSvc.width(context) / 2).toDouble())));
    }
    final fontSizeFactor = isBigEmoji ? bigEmojiScaleFactor : 1.0;
    final constraints = BoxConstraints(
      maxWidth: maxWidthOverride ?? NavigationSvc.width(context) * MessageState.maxBubbleSizeFactor - 30,
      minHeight: minHeightOverride ?? Theme.of(context).textTheme.bodySmall!.fontSize! * fontSizeFactor,
    );
    final renderParagraph = RichText(
      text: TextSpan(
        text: textOverride ?? fullText,
        style: context.theme.textTheme.bodySmall!.apply(color: Colors.white, fontSizeFactor: fontSizeFactor),
      ),
    ).createRenderObject(context);
    Size size = renderParagraph.getDryLayout(constraints);
    if (size.height < context.theme.textTheme.bodySmall!.fontSize! * 2 * fontSizeFactor ||
        (subject != null && size.height < context.theme.textTheme.bodySmall!.fontSize! * 3 * fontSizeFactor)) {
      size = Size(size.width + 28, size.height);
    }
    if (isLegacyUrlPreview) {
      size = Size(NavigationSvc.width(context) * 2 / 3 - 30, size.height);
    }
    if (hasReactions) {
      size = Size(size.width, size.height + 25);
    }
    size = Size(size.width, size.height + 16);
    MessagesService.cachedBubbleSizes[guid!] = size;
    return size;
  }

  static Message merge(Message existing, Message newMessage) {
    existing.id ??= newMessage.id;
    existing.guid ??= newMessage.guid;

    if ((existing.dateCreated == null && newMessage.dateCreated != null) ||
        (existing.dateCreated != null &&
            newMessage.dateCreated != null &&
            existing.dateCreated!.millisecondsSinceEpoch < newMessage.dateCreated!.millisecondsSinceEpoch)) {
      existing.dateCreated = newMessage.dateCreated;
    }

    if ((existing._dateDelivered.value == null && newMessage._dateDelivered.value != null) ||
        (existing._dateDelivered.value != null &&
            newMessage.dateDelivered != null &&
            existing._dateDelivered.value!.millisecondsSinceEpoch <
                newMessage._dateDelivered.value!.millisecondsSinceEpoch)) {
      existing._dateDelivered.value = newMessage.dateDelivered;
    }

    if (existing._isDelivered.value != newMessage._isDelivered.value) {
      existing._isDelivered.value = newMessage._isDelivered.value;
    }

    if ((existing._dateRead.value == null && newMessage._dateRead.value != null) ||
        (existing._dateRead.value != null &&
            newMessage.dateRead != null &&
            existing._dateRead.value!.millisecondsSinceEpoch < newMessage._dateRead.value!.millisecondsSinceEpoch)) {
      existing._dateRead.value = newMessage.dateRead;
    }

    if ((existing.datePlayed == null && newMessage.datePlayed != null) ||
        (existing.datePlayed != null &&
            newMessage.datePlayed != null &&
            existing.datePlayed!.millisecondsSinceEpoch < newMessage.datePlayed!.millisecondsSinceEpoch)) {
      existing.datePlayed = newMessage.datePlayed;
    }

    if ((existing.dateDeleted == null && newMessage.dateDeleted != null) ||
        (existing.dateDeleted != null &&
            newMessage.dateDeleted != null &&
            existing.dateDeleted!.millisecondsSinceEpoch < newMessage.dateDeleted!.millisecondsSinceEpoch)) {
      existing.dateDeleted = newMessage.dateDeleted;
    }

    if (newMessage.dateEdited != null &&
        (existing.dateEdited == null || !newMessage.dateEdited!.isBefore(existing.dateEdited!))) {
      existing.dateEdited = newMessage.dateEdited;
      existing.text = newMessage.text;
      existing.subject = newMessage.subject;
      existing.attributedBody = newMessage.attributedBody;
      existing.messageSummaryInfo = newMessage.messageSummaryInfo;
    }

    if (existing.dateEdited == null && !isNullOrEmpty(newMessage.attributedBody)) {
      existing.attributedBody = newMessage.attributedBody;
    }
    if (existing.dateEdited == null && !isNullOrEmpty(newMessage.messageSummaryInfo)) {
      existing.messageSummaryInfo = newMessage.messageSummaryInfo;
    }

    if (existing._error.value != newMessage._error.value) {
      existing._error.value = newMessage._error.value;
    }

    if ((existing.hasDdResults == null && newMessage.hasDdResults != null) ||
        (!existing.hasDdResults! && newMessage.hasDdResults!)) {
      existing.hasDdResults = newMessage.hasDdResults;
    }

    existing.metadata = mergeTopLevelDicts(existing.metadata, newMessage.metadata);

    if (existing.originalROWID == null && newMessage.originalROWID != null) {
      existing.originalROWID = newMessage.originalROWID;
    }

    if (!existing.hasAttachments && newMessage.hasAttachments) {
      existing.hasAttachments = newMessage.hasAttachments;
    }

    if (!existing.hasReactions && newMessage.hasReactions) {
      existing.hasReactions = newMessage.hasReactions;
    }

    if (!existing.chat.hasValue && newMessage.chat.hasValue) {
      existing.chat.target = newMessage.chat.target;
    }

    if (!existing.handleRelation.hasValue && newMessage.handleRelation.hasValue) {
      existing.handleRelation.target = newMessage.handleRelation.target;
    }

    if (existing.dbAttachments.isEmpty && newMessage.dbAttachments.isNotEmpty) {
      existing.dbAttachments.addAll(newMessage.dbAttachments);
    }

    if ((existing.payloadData == null && newMessage.payloadData != null) ||
        (!existing.payloadData.hasAppSession && newMessage.payloadData.hasAppSession)) {
      existing.payloadData = newMessage.payloadData;
    }
    existing.threadOriginatorGuid ??= newMessage.threadOriginatorGuid;
    existing.threadOriginatorPart ??= newMessage.threadOriginatorPart;
    existing.country ??= newMessage.country;
    existing.associatedMessageEmoji ??= newMessage.associatedMessageEmoji;
    existing.service ??= newMessage.service;

    if (!existing.wasDeliveredQuietly && newMessage.wasDeliveredQuietly) {
      existing.wasDeliveredQuietly = newMessage.wasDeliveredQuietly;
    }

    if (!existing.didNotifyRecipient && newMessage.didNotifyRecipient) {
      existing.didNotifyRecipient = newMessage.didNotifyRecipient;
    }

    existing.isBookmarked = newMessage.isBookmarked;

    return existing;
  }

  String getLastUpdate() {
    if (dateEdited != null) {
      return "Edited at $dateEdited";
    } else if (datePlayed != null) {
      return "Played at $datePlayed";
    } else if (dateRead != null) {
      return "Read at $dateRead";
    } else if (dateDelivered != null) {
      return "Delivered at $dateDelivered";
    } else if (isDelivered) {
      return "Delivered";
    } else {
      return "Sent at $dateCreated";
    }
  }

  bool isNewerThan(Message other) {
    if (error == 0 && other.error != 0) return false;

    if (dateCreated == null && other.dateCreated != null) return false;
    if (dateCreated != null && other.dateCreated == null) return true;
    if (!isDelivered && other.isDelivered) return false;
    if (isDelivered && !other.isDelivered) return true;
    if (dateDelivered == null && other.dateDelivered != null) return false;
    if (dateDelivered != null && other.dateDelivered == null) return true;
    if (dateRead == null && other.dateRead != null) return false;
    if (dateRead != null && other.dateRead == null) return true;
    if (datePlayed == null && other.datePlayed != null) return false;
    if (datePlayed != null && other.datePlayed == null) return true;
    if (dateEdited == null && other.dateEdited != null) return false;
    if (dateEdited != null && other.dateEdited == null) return true;

    if (dateEdited != null && other.dateEdited != null) {
      return dateEdited!.millisecondsSinceEpoch > other.dateEdited!.millisecondsSinceEpoch;
    } else if (datePlayed != null && other.datePlayed != null) {
      return datePlayed!.millisecondsSinceEpoch > other.datePlayed!.millisecondsSinceEpoch;
    } else if (dateRead != null && other.dateRead != null) {
      return dateRead!.millisecondsSinceEpoch > other.dateRead!.millisecondsSinceEpoch;
    } else if (dateDelivered != null && other.dateDelivered != null) {
      return dateDelivered!.millisecondsSinceEpoch > other.dateDelivered!.millisecondsSinceEpoch;
    } else if (dateCreated != null && other.dateCreated != null) {
      return dateCreated!.millisecondsSinceEpoch > other.dateCreated!.millisecondsSinceEpoch;
    }

    return false;
  }

  void takeOmittableFieldsFrom(Message incoming) {
    final sameContent = (incoming.text ?? text) == text &&
        (incoming.dateEdited ?? dateEdited)?.millisecondsSinceEpoch == dateEdited?.millisecondsSinceEpoch;
    if (incoming.attributedBody.isNotEmpty || !sameContent) attributedBody = incoming.attributedBody;
    if (incoming.messageSummaryInfo.isNotEmpty || !sameContent) messageSummaryInfo = incoming.messageSummaryInfo;
    if (incoming.payloadData.hasAppSession || !payloadData.hasAppSession) {
      payloadData = incoming.payloadData ?? payloadData;
    }
    threadOriginatorGuid = incoming.threadOriginatorGuid ?? threadOriginatorGuid;
    threadOriginatorPart = incoming.threadOriginatorPart ?? threadOriginatorPart;
    associatedMessageEmoji = incoming.associatedMessageEmoji ?? associatedMessageEmoji;
    associatedMessagePart = incoming.associatedMessagePart ?? associatedMessagePart;
    service = incoming.service ?? service;
    datePlayed = incoming.datePlayed ?? datePlayed;
    country = incoming.country ?? country;
  }

  bool fillsGapsIn(Message stored) =>
      (attributedBody.isNotEmpty && stored.attributedBody.isEmpty) ||
      (messageSummaryInfo.isNotEmpty && stored.messageSummaryInfo.isEmpty) ||
      (payloadData != null && stored.payloadData == null) ||
      (payloadData.hasAppSession && !stored.payloadData.hasAppSession) ||
      (threadOriginatorGuid != null && stored.threadOriginatorGuid == null) ||
      (threadOriginatorPart != null && stored.threadOriginatorPart == null) ||
      (associatedMessageEmoji != null && stored.associatedMessageEmoji == null) ||
      (service != null && stored.service == null) ||
      (datePlayed != null && stored.datePlayed == null) ||
      (country != null && stored.country == null);

  Map<String, dynamic> toMap() {
    return {
      "ROWID": id,
      "originalROWID": originalROWID,
      "guid": guid,
      "handleId": handleId,
      "otherHandle": otherHandle,
      "text": sanitizeString(text),
      "subject": subject,
      "country": country,
      "_error": _error.value,
      "errorMessage": errorMessage,
      "dateCreated": dateCreated?.millisecondsSinceEpoch,
      "dateRead": _dateRead.value?.millisecondsSinceEpoch,
      "dateDelivered": _dateDelivered.value?.millisecondsSinceEpoch,
      "isDelivered": _isDelivered.value,
      "isFromMe": isFromMe!,
      "hasDdResults": hasDdResults!,
      "datePlayed": datePlayed?.millisecondsSinceEpoch,
      "itemType": itemType,
      "groupTitle": groupTitle,
      "groupActionType": groupActionType,
      "balloonBundleId": balloonBundleId,
      "associatedMessageGuid": associatedMessageGuid,
      "associatedMessagePart": associatedMessagePart,
      "associatedMessageType": associatedMessageType,
      "associatedMessageEmoji": associatedMessageEmoji,
      "expressiveSendStyleId": expressiveSendStyleId,
      "service": service,
      "handle": getHandle()?.toMap(),
      "hasAttachments": hasAttachments,
      "attachments": dbAttachments.map((a) => a.toMap()).toList(),
      "hasReactions": hasReactions,
      "dateDeleted": dateDeleted?.millisecondsSinceEpoch,
      "metadata": jsonEncode(metadata),
      "threadOriginatorGuid": threadOriginatorGuid,
      "threadOriginatorPart": threadOriginatorPart,
      "hasApplePayloadData": hasApplePayloadData,
      "dateEdited": dateEdited?.millisecondsSinceEpoch,
      "wasDeliveredQuietly": wasDeliveredQuietly,
      "didNotifyRecipient": didNotifyRecipient,
      "isBookmarked": isBookmarked,
      "attributedBody": attributedBody.map((e) => e.toMap()).toList(),
      "messageSummaryInfo": messageSummaryInfo.map((e) => e.toJson()).toList(),
      "payloadData": payloadData?.toJson(),
    };
  }
}
