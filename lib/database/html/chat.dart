import 'dart:async';
import 'dart:typed_data';

import 'package:bluebubbles/database/html/attachment.dart';
import 'package:bluebubbles/database/html/custom_group.dart';
import 'package:bluebubbles/database/html/handle.dart';
import 'package:bluebubbles/database/html/message.dart';
import 'package:bluebubbles/database/html/objectbox.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show HandleLookupKey, MessageSaveResult;
import 'package:bluebubbles/services/backend/interfaces/chat_interface.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:faker/faker.dart';
import 'package:get/get.dart' hide Condition, Response;
import 'package:get_it/get_it.dart';

class Chat {
  int? id;
  String guid;
  String? chatIdentifier;
  bool? isArchived;
  String? muteType;
  String? muteArgs;
  bool? isPinned;
  bool? hasUnreadMessage;

  String? displayName;
  bool? autoSendReadReceipts;
  bool? autoSendTypingIndicators;
  String? textFieldText;
  String? textFieldRuns;
  List<String> textFieldAttachments = [];

  final dbLatestMessage = ToOne<Message>();
  DateTime? dbOnlyLatestMessageDate;

  void setLatestMessage(Message m) {
    dbLatestMessage.target = m;
    dbOnlyLatestMessageDate = m.dateCreated;
  }

  DateTime? dateDeleted;
  int? style;
  bool lockChatName;
  bool lockChatIcon;
  String? lastReadMessageGuid;
  String? customThemeLight;
  String? customThemeDark;

  String? wallpaperType;
  String? dynamicWallpaperId;
  String? dynamicWallpaperConfig;
  String? knownGroupPhotoGuid;
  String? serverGroupPhotoGuid;
  String? serverBackgroundGuid;
  bool hasServerProperties = false;
  String? serviceName;

  final RxnString _customAvatarPath = RxnString();
  String? get customAvatarPath => _customAvatarPath.value;
  set customAvatarPath(String? s) => _customAvatarPath.value = s;

  final RxnString _customBackgroundPath = RxnString();
  String? get customBackgroundPath => _customBackgroundPath.value;
  set customBackgroundPath(String? s) => _customBackgroundPath.value = s;

  final RxnInt _pinIndex = RxnInt();
  int? get pinIndex => _pinIndex.value;
  set pinIndex(int? i) => _pinIndex.value = i;

  RxDouble sendProgress = 0.0.obs;

  final handles = ToMany<Handle>();

  List<Handle> get people => peopleIn(handles);

  static List<Handle> peopleIn(Iterable<Handle> handles) {
    final seen = <String>{};
    return handles.where((h) => seen.add(h.address)).toList();
  }

  List<Handle> participants = [];

  final messages = ToMany<Message>();
  final customGroups = ToMany<CustomGroup>();

  String? _fakeName;

  String get fakeName {
    if (_fakeName != null) return _fakeName!;
    final color = faker.color.color();
    final animal = faker.animal.name();
    _fakeName = "${color.capitalize} ${animal.capitalize}";
    return _fakeName!;
  }

  Chat({
    this.id,
    required this.guid,
    this.chatIdentifier,
    this.isArchived = false,
    this.isPinned = false,
    this.muteType,
    this.muteArgs,
    this.hasUnreadMessage = false,
    this.displayName,
    String? customAvatar,
    String? customBackground,
    int? pinnedIndex,
    Message? latestMessage,
    this.participants = const [],
    this.autoSendReadReceipts,
    this.autoSendTypingIndicators,
    this.textFieldText,
    this.textFieldRuns,
    this.textFieldAttachments = const [],
    this.dateDeleted,
    this.style,
    this.lockChatName = false,
    this.lockChatIcon = false,
    this.lastReadMessageGuid,
    this.customThemeLight,
    this.customThemeDark,
    this.wallpaperType,
    this.dynamicWallpaperId,
    this.dynamicWallpaperConfig,
    this.knownGroupPhotoGuid,
    this.serverGroupPhotoGuid,
    this.serverBackgroundGuid,
    this.hasServerProperties = false,
    this.serviceName,
  }) {
    customAvatarPath = customAvatar;
    customBackgroundPath = customBackground;
    pinIndex = pinnedIndex;
    if (textFieldAttachments.isEmpty) textFieldAttachments = [];
    if (participants.isNotEmpty) {
      handles.addAll(participants);
    }
    if (latestMessage != null) {
      dbLatestMessage.target = latestMessage;
      dbOnlyLatestMessageDate ??= latestMessage.dateCreated;
    }
  }

  static bool isFilteredByServer(Map<String, dynamic> json) {
    return json['isFiltered'] == true || json['isFilteredAsSpam'] == true;
  }

  static bool? readReceiptsOverrideInProperties(dynamic properties) {
    bool? parseScalar(dynamic v) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        if (s == 'true' || s == '1') return true;
        if (s == 'false' || s == '0') return false;
      }
      return null;
    }

    if (properties is List) {
      for (final item in properties) {
        if (item is Map && item.containsKey('EnableReadReceiptForChat')) {
          final parsed = parseScalar(item['EnableReadReceiptForChat']);
          if (parsed != null) return parsed;
        }
      }
    } else if (properties is Map && properties.containsKey('EnableReadReceiptForChat')) {
      return parseScalar(properties['EnableReadReceiptForChat']);
    }
    return null;
  }

  factory Chat.fromMap(Map<String, dynamic> json) {
    final message = json['lastMessage'] != null ? Message.fromMap(json['lastMessage']!.cast<String, dynamic>()) : null;
    final pinned = json["isPinned"] == true;
    final archived = (json['isArchived'] == true) || (isFilteredByServer(json) && !pinned);
    final readReceipts = json["autoSendReadReceipts"] is bool
        ? json["autoSendReadReceipts"] as bool
        : readReceiptsOverrideInProperties(json["properties"]);
    return Chat(
      id: json["ROWID"] ?? json["id"],
      guid: json["guid"],
      chatIdentifier: json["chatIdentifier"],
      participants:
          (json['participants'] as List? ?? []).map((e) => Handle.fromMap(e!.cast<String, dynamic>())).toList(),
      isArchived: archived,
      muteType: json["muteType"],
      muteArgs: json["muteArgs"],
      isPinned: pinned,
      hasUnreadMessage: json["hasUnreadMessage"] ?? false,
      latestMessage: message,
      displayName: json["displayName"],
      customAvatar: json['_customAvatarPath'],
      customBackground: json['_customBackgroundPath'],
      pinnedIndex: json['_pinIndex'] ?? json['pinIndex'],
      autoSendReadReceipts: readReceipts,
      autoSendTypingIndicators: json["autoSendTypingIndicators"],
      dateDeleted: parseDate(json["dateDeleted"]),
      style: json["style"],
      lockChatName: json["lockChatName"] ?? false,
      lockChatIcon: json["lockChatIcon"] ?? false,
      lastReadMessageGuid: json["lastReadMessageGuid"],
      customThemeLight: json["customThemeLight"],
      customThemeDark: json["customThemeDark"],
      wallpaperType: json["wallpaperType"],
      dynamicWallpaperId: json["dynamicWallpaperId"],
      dynamicWallpaperConfig: json["dynamicWallpaperConfig"],
      knownGroupPhotoGuid: json["knownGroupPhotoGuid"],
      serverGroupPhotoGuid: json["serverGroupPhotoGuid"] ?? groupPhotoGuidInProperties(json["properties"]),
      serverBackgroundGuid: json["serverBackgroundGuid"] ?? backgroundGuidInProperties(json["properties"]),
      hasServerProperties: json["hasServerProperties"] == true || json.containsKey("properties"),
      serviceName: json["serviceName"],
      textFieldText: json["textFieldText"],
      textFieldRuns: json["textFieldRuns"],
      textFieldAttachments: (json["textFieldAttachments"] as List?)?.cast<String>() ?? const [],
    );
  }

  Future<Chat> saveAsync({
    bool updateMuteType = false,
    bool updateMuteArgs = false,
    bool updateIsPinned = false,
    bool updatePinIndex = false,
    bool updateIsArchived = false,
    bool updateHasUnreadMessage = false,
    bool updateAutoSendReadReceipts = false,
    bool updateAutoSendTypingIndicators = false,
    bool updateCustomAvatarPath = false,
    bool updateCustomBackgroundPath = false,
    bool updateTextFieldText = false,
    bool updateTextFieldAttachments = false,
    bool updateDisplayName = false,
    bool updateDateDeleted = false,
    bool updateLockChatName = false,
    bool updateLockChatIcon = false,
    bool updateLastReadMessageGuid = false,
    bool updateLatestMessage = false,
    bool updateCustomThemes = false,
    bool updateWallpaperSettings = false,
    bool updateKnownGroupPhotoGuid = false,
    bool updateServiceName = false,
  }) async {
    await ChatInterface.saveChat(
      guid: guid,
      chatData: toMap(),
      updateFlags: {
        'updateMuteType': updateMuteType,
        'updateMuteArgs': updateMuteArgs,
        'updateIsPinned': updateIsPinned,
        'updatePinIndex': updatePinIndex,
        'updateIsArchived': updateIsArchived,
        'updateHasUnreadMessage': updateHasUnreadMessage,
        'updateAutoSendReadReceipts': updateAutoSendReadReceipts,
        'updateAutoSendTypingIndicators': updateAutoSendTypingIndicators,
        'updateCustomAvatarPath': updateCustomAvatarPath,
        'updateCustomBackgroundPath': updateCustomBackgroundPath,
        'updateTextFieldText': updateTextFieldText,
        'updateTextFieldAttachments': updateTextFieldAttachments,
        'updateDisplayName': updateDisplayName,
        'updateDateDeleted': updateDateDeleted,
        'updateLockChatName': updateLockChatName,
        'updateLockChatIcon': updateLockChatIcon,
        'updateLastReadMessageGuid': updateLastReadMessageGuid,
        'updateLatestMessage': updateLatestMessage,
        'updateCustomThemes': updateCustomThemes,
        'updateWallpaperSettings': updateWallpaperSettings,
        'updateKnownGroupPhotoGuid': updateKnownGroupPhotoGuid,
        'updateServiceName': updateServiceName,
      },
    );
    (WebListeners.notifyChat as dynamic)(this);
    return this;
  }

  Future<Chat> changeNameAsync(String? name) async {
    displayName = name;
    await saveAsync(updateDisplayName: true);
    return this;
  }

  String getTitle() => isNullOrEmpty(displayName) ? getChatCreatorSubtitle() : displayName!;

  String getChatCreatorSubtitle() {
    final people = this.people;
    final count = people.length;
    if (count == 0) {
      if (chatIdentifier!.startsWith("urn:biz")) {
        return "Business Chat";
      }
      return chatIdentifier!;
    } else if (count == 1) {
      return people.first.displayName;
    }

    if (count <= 4) {
      final buffer = StringBuffer();
      for (int i = 0; i < count; i++) {
        if (i > 0) buffer.write(i == count - 1 ? ' & ' : ', ');
        buffer.write(people[i].shortName);
      }
      return buffer.toString();
    } else {
      final buffer = StringBuffer();
      for (int i = 0; i < 3; i++) {
        if (i > 0) buffer.write(', ');
        buffer.write(people[i].shortName);
      }
      buffer.write(' & ${count - 3} others');
      return buffer.toString();
    }
  }

  bool shouldMuteNotification(Message? message) {
    if (SettingsSvc.settings.filterUnknownSenders.value && handles.length == 1 && handles.first.contactsV2.isEmpty) {
      return true;
    } else if (SettingsSvc.settings.globalTextDetection.value.isNotEmpty) {
      List<String> text = SettingsSvc.settings.globalTextDetection.value.split(",");
      for (String s in text) {
        if (message?.text?.toLowerCase().contains(s.toLowerCase()) ?? false) {
          return false;
        }
      }
      return true;
    } else if (muteType == "mute") {
      return true;
    } else if (muteType == "mute_individuals") {
      List<String> individuals = muteArgs!.split(",");
      return individuals.contains(message?.handleRelation.target?.address ?? "");
    } else if (muteType == "temporary_mute") {
      DateTime time = DateTime.parse(muteArgs!);
      bool shouldMute = DateTime.now().toLocal().difference(time).inSeconds.isNegative;
      if (!shouldMute) {
        toggleMuteAsync(false);
      }
      return shouldMute;
    } else if (muteType == "text_detection") {
      List<String> text = muteArgs!.split(",");
      for (String s in text) {
        if (message?.text?.toLowerCase().contains(s.toLowerCase()) ?? false) {
          return false;
        }
      }
      return true;
    }

    return !SettingsSvc.settings.notifyReactions.value &&
        message != null &&
        ReactionTypes.isTapbackType(message.associatedMessageType);
  }

  Future<bool> clearNotificationsForPartialRead(int? readBefore) async {
    return false;
  }

  Future<Chat> toggleHasUnreadAsync(bool hasUnread,
      {bool force = false, bool clearLocalNotifications = true, bool privateMark = true, int? readBefore}) async {
    if (hasUnreadMessage == hasUnread && !force) return this;
    hasUnreadMessage = hasUnread;
    await saveAsync(updateHasUnreadMessage: true);

    try {
      if (privateMark &&
          SettingsSvc.settings.enablePrivateAPI.value &&
          (autoSendReadReceipts ?? SettingsSvc.settings.privateMarkChatAsRead.value)) {
        if (!hasUnread) {
          HttpSvc.chat.markRead(guid);
        } else {
          HttpSvc.chat.markUnread(guid);
        }
      }
    } catch (_) {}

    return this;
  }

  Future<MessageSaveResult> addMessage(Message message,
      {bool changeUnreadStatus = true,
      bool checkForMessageText = true,
      bool clearNotificationsIfFromMe = true,
      List<Attachment> attachments = const []}) async {
    Message? latest = dbLatestMessage.target;
    Message? newMessage;
    bool isNewer = false;

    try {
      final result = await ChatInterface.addMessageToChat(
        messageData: message.toMap(),
        attachmentsData: attachments.map((e) => e.toMap()).toList(),
        chatData: toMap(),
        latestMessageData: (latest ?? Message(dateCreated: DateTime.fromMillisecondsSinceEpoch(0), guid: guid)).toMap(),
        checkForMessageText: checkForMessageText,
      );
      newMessage = result.message as Message?;
      isNewer = result.isNewer;
    } catch (ex, stacktrace) {
      newMessage = Message.findOne(guid: message.guid);
      if (newMessage == null) {
        Logger.error("Failed to add message (GUID: ${message.guid}) to chat (GUID: $guid)",
            error: ex, trace: stacktrace);
      }
    }

    if (isNewer) {
      setLatestMessage(newMessage ?? message);
      if (dateDeleted != null) {
        dateDeleted = null;
        await saveAsync(updateDateDeleted: true);
      }
      if ((isArchived ?? false) && !(message.isFromMe ?? false) && SettingsSvc.settings.unarchiveOnNewMessage.value) {
        await toggleArchivedAsync(false);
      }
    }

    await saveAsync();

    if (checkForMessageText && changeUnreadStatus && isNewer) {
      if (message.isFromMe ?? false) {
        await toggleHasUnreadAsync(false, clearLocalNotifications: clearNotificationsIfFromMe, privateMark: false);
      } else if (message.dateRead == null) {
        await toggleHasUnreadAsync(true, privateMark: false);
      }
    }

    if (message.isParticipantEvent && checkForMessageText) {
      unawaited(serverSyncParticipantsAsync());
    }

    final savedMessage = newMessage ?? message;
    (WebListeners.notifyMessage as dynamic)(savedMessage, chat: this);
    return MessageSaveResult(savedMessage as dynamic, isNewer);
  }

  Future<void> serverSyncParticipantsAsync() async {
    try {
      final response = await HttpSvc.chat.fetchOne(guid, withQuery: "participants");
      if (response.statusCode == 200 && response.data["data"] != null) {
        final chatData = response.data["data"];
        final updatedChat = (await ChatInterface.bulkSyncChats(chatsData: [chatData])).chats;
        if (updatedChat.isNotEmpty) {
          await (updatedChat.first as dynamic).saveAsync();
        }
      }
    } catch (ex, stacktrace) {
      Logger.error("Failed to sync participants", error: ex, trace: stacktrace);
    }
  }

  Future<List<Attachment>> getAttachmentsAsync({bool fetchDeleted = false}) async {
    if (id == null) return [];

    final stopwatch = Stopwatch()..start();

    final messageQuery = (HtmlDatabase.messages.query(fetchDeleted
            ? Message_.dateCreated.notNull().and(Message_.dateDeleted.isNull().or(Message_.dateDeleted.notNull()))
            : Message_.dateDeleted.isNull().and(Message_.dateCreated.notNull()))
          ..link(Message_.chat, Chat_.id.equals(id!))
          ..order(Message_.dateCreated, flags: Order.descending))
        .build();

    final messages = await messageQuery.findAsync();
    messageQuery.close();

    if (messages.isEmpty) {
      stopwatch.stop();
      Logger.debug("Fetched 0 messages for chat $guid in ${stopwatch.elapsedMilliseconds} ms");
      return [];
    }

    final messageIds = messages.map((e) => e.id!).toList();
    final attachmentQuery = (HtmlDatabase.attachments.query(Attachment_.mimeType.notNull())
          ..link(Attachment_.message, Message_.id.oneOf(messageIds)))
        .build();

    final attachments = await attachmentQuery.findAsync();
    attachmentQuery.close();

    if (attachments.isNotEmpty) {
      final guids = attachments.map((e) => e.guid).toSet();
      attachments.retainWhere((element) => guids.remove(element.guid));
    }

    stopwatch.stop();
    Logger.debug("Fetched ${attachments.length} attachments for chat $guid in ${stopwatch.elapsedMilliseconds} ms");
    return attachments;
  }

  static List<Message> getMessages(Chat chat,
      {int offset = 0, int limit = 25, bool includeDeleted = false, bool getDetails = false}) {
    if (chat.id == null) return [];
    return HtmlDatabase.runInTransaction(TxMode.read, () {
      final query = (HtmlDatabase.messages.query(includeDeleted
              ? Message_.dateCreated.notNull().and(Message_.dateDeleted.isNull().or(Message_.dateDeleted.notNull()))
              : Message_.dateDeleted.isNull().and(Message_.dateCreated.notNull()))
            ..link(Message_.chat, Chat_.id.equals(chat.id!))
            ..order(Message_.dateCreated, flags: Order.descending))
          .build();
      query
        ..limit = limit
        ..offset = offset;
      final messages = query.find();
      query.close();
      for (int i = 0; i < messages.length; i++) {
        final message = messages[i];
        if (chat.handles.isNotEmpty && !(message.isFromMe ?? false) && message.handleId != null && message.handleId != 0) {
          final handle = chat.handles.firstWhereOrNull((e) => e.originalROWID == message.handleId) ??
              message.handleRelation.target;
          if (handle == null) {
            messages.removeAt(i);
            i--;
          }
        }
      }
      if (getDetails) {
        final messageGuids = messages.map((e) => e.guid!).toList();
        final associatedMessagesQuery = (HtmlDatabase.messages
                .query(Message_.associatedMessageGuid.oneOf(messageGuids) & Message.reactionCondition)
              ..order(Message_.originalROWID))
            .build();
        var associatedMessages = associatedMessagesQuery.find();
        associatedMessagesQuery.close();
        associatedMessages = ((MessageHelper.normalizedAssociatedMessages as dynamic)(associatedMessages) as List).cast<Message>();
        for (final m in messages) {
          m.associatedMessages = associatedMessages.where((e) => e.associatedMessageGuid == m.guid).toList();
        }
      }
      return messages;
    });
  }

  static Future<List<Message>> getMessagesAsync(Chat chat,
      {int offset = 0,
      int limit = 25,
      bool includeDeleted = false,
      int? searchAround,
      Function? onSupplementalDataLoaded}) async {
    if (chat.id == null) return [];

    final totalStopwatch = Stopwatch()..start();

    final messages = (await ChatInterface.getMessagesAsync(
      chatId: chat.id!,
      chatGuid: chat.guid,
      participantsData: chat.handles.map((e) => e.toMap()).toList(),
      offset: offset,
      limit: limit,
      includeDeleted: includeDeleted,
      searchAround: searchAround,
    ) as List)
        .cast<Message>();

    if (messages.isEmpty) {
      return messages;
    }

    final messageGuids = messages.map((e) => e.guid!).toList();
    _loadSupplementalDataAsync(messages, messageGuids, totalStopwatch, onSupplementalDataLoaded);

    totalStopwatch.stop();
    Logger.debug("[getMessagesAsync] RETURNED (Phase 1 complete): ${totalStopwatch.elapsedMilliseconds}ms");
    return messages;
  }

  static Future<void> _loadSupplementalDataAsync(
    List<Message> messages,
    List<String> messageGuids,
    Stopwatch totalStopwatch,
    Function? onComplete,
  ) async {
    final supplementalStopwatch = Stopwatch()..start();

    try {
      var associatedMessages = await ChatInterface.loadSupplementalData(
        messageGuids: messageGuids,
      );

      Logger.debug("[getMessagesAsync] Phase 2 - Supplemental query: ${supplementalStopwatch.elapsedMilliseconds}ms");
      associatedMessages = MessageHelper.normalizedAssociatedMessages(associatedMessages);

      for (final m in messages) {
        final messageReactions = associatedMessages.where((e) => e.associatedMessageGuid == m.guid).toList();
        m.associatedMessages = messageReactions as List<Message>;
      }

      supplementalStopwatch.stop();
      if (onComplete != null) {
        onComplete();
      }
    } catch (ex, stacktrace) {
      Logger.error("Failed to load supplemental data for messages", error: ex, trace: stacktrace);
    }
  }

  void webSyncParticipants() {
    final matched = <Handle>[];
    for (final p in participants) {
      final found = Handle.findOne(addressAndService: HandleLookupKey(p.address, p.service)) ??
          (p.originalROWID != null ? Handle.findOne(originalROWID: p.originalROWID) : null);
      if (found != null) {
        matched.add(found);
      } else {
        matched.add(p);
      }
    }
    if (matched.isNotEmpty) {
      participants = matched;
      handles
        ..clear()
        ..addAll(matched);
    }
  }

  Future<Chat> togglePinAsync(bool isPinned) async {
    if (id == null) return this;
    this.isPinned = isPinned;
    _pinIndex.value = null;
    await saveAsync(updateIsPinned: true, updatePinIndex: true);
    return this;
  }

  Future<Chat> toggleMuteAsync(bool isMuted) async {
    if (id == null) return this;
    muteType = isMuted ? "mute" : null;
    muteArgs = null;
    await saveAsync(updateMuteType: true, updateMuteArgs: true);
    return this;
  }

  Future<Chat> toggleArchivedAsync(bool isArchived) async {
    if (id == null) return this;
    isPinned = false;
    this.isArchived = isArchived;
    await saveAsync(updateIsPinned: true, updateIsArchived: true);
    return this;
  }

  Future<Chat> toggleAutoReadAsync(bool? autoSendReadReceipts) async {
    if (id == null) return this;
    this.autoSendReadReceipts = autoSendReadReceipts;
    await saveAsync(updateAutoSendReadReceipts: true);
    if (SettingsSvc.settings.enablePrivateAPI.value &&
        (autoSendReadReceipts ?? SettingsSvc.settings.privateMarkChatAsRead.value)) {
      HttpSvc.chat.markRead(guid);
    }
    return this;
  }

  Future<Chat> toggleAutoTypeAsync(bool? autoSendTypingIndicators) async {
    if (id == null) return this;
    this.autoSendTypingIndicators = autoSendTypingIndicators;
    await saveAsync(updateAutoSendTypingIndicators: true);
    if (!(autoSendTypingIndicators ?? SettingsSvc.settings.privateSendTypingIndicators.value)) {
      unawaited(HttpSvc.chat.stopTyping(guid));
    }
    return this;
  }

  static Future<Chat?> findOneWeb({String? guid, String? chatIdentifier}) async {
    final local = findOne(guid: guid, chatIdentifier: chatIdentifier);
    if (local != null) return local;
    if (guid != null) {
      return ChatsSvc.findChatByGuid(guid) as dynamic;
    } else if (chatIdentifier != null) {
      return ChatsSvc.findChatByChatIdentifier(chatIdentifier) as dynamic;
    }
    return null;
  }

  static Chat? findOne({String? guid, String? chatIdentifier}) {
    if (guid != null) {
      final query = HtmlDatabase.chats.query(Chat_.guid.equals(guid)).build();
      final result = query.findFirst();
      query.close();
      return result;
    } else if (chatIdentifier != null) {
      final query = HtmlDatabase.chats.query(Chat_.chatIdentifier.equals(chatIdentifier)).build();
      final result = query.findFirst();
      query.close();
      return result;
    }
    return null;
  }

  static Future<List<Chat>> getChatsAsync({int limit = 15, int offset = 0, List<int> ids = const []}) async {
    final chats = await ChatInterface.getChatsAsync(
      limit: limit,
      offset: offset,
      ids: ids,
    );
    return (chats as List).cast<Chat>();
  }

  static Future<List<Chat>> bulkSyncChats(List<Chat> chats) async {
    if (chats.isEmpty) return [];
    final synced = (await ChatInterface.bulkSyncChats(
      chatsData: chats.map((e) => e.toMap()).toList(),
    ))
        .chats;
    return (synced as List).cast<Chat>();
  }

  void clearTranscript() {
    HtmlDatabase.runInTransaction(TxMode.write, () {
      final toDelete = List<Message>.from(messages);
      for (final element in toDelete) {
        element.dateDeleted = DateTime.now().toUtc();
      }
      HtmlDatabase.messages.putMany(toDelete);
    });
  }

  Future<void> clearTranscriptAsync() async {
    if (id == null) return;
    await ChatInterface.clearTranscriptAsync(
      chatId: id!,
      chatGuid: guid,
    );
  }

  // Prefer latest message service over stale chat.service_name on unified `any;-;` chats.
  ChatServiceType get service =>
      ChatServiceType.fromServiceName(dbLatestMessage.target?.service) ??
      ChatServiceType.fromServiceName(serviceName) ??
      ChatServiceType.fromServiceName(handles.firstOrNull?.service) ??
      ChatServiceType.fromServiceName(participants.firstOrNull?.service) ??
      ChatServiceType.fromGuid(guid);

  bool get isTextForwarding => service == ChatServiceType.sms;

  bool get isSMS => service == ChatServiceType.sms;

  bool get isRCS => service == ChatServiceType.rcs;

  bool get isIMessage => service == ChatServiceType.iMessage;

  bool get isGroup => style != null ? style == 43 : people.length > 1;

  Chat merge(Chat other) {
    id ??= other.id;
    _customAvatarPath.value ??= other._customAvatarPath.value;
    _customBackgroundPath.value ??= other._customBackgroundPath.value;
    _pinIndex.value ??= other._pinIndex.value;
    autoSendReadReceipts ??= other.autoSendReadReceipts;
    autoSendTypingIndicators ??= other.autoSendTypingIndicators;
    if (textFieldText == null) {
      textFieldText = other.textFieldText;
      textFieldRuns = other.textFieldRuns;
    }
    if (textFieldAttachments.isEmpty) {
      textFieldAttachments.addAll(other.textFieldAttachments);
    }
    chatIdentifier ??= other.chatIdentifier;
    displayName ??= other.displayName;
    if (handles.isEmpty) {
      handles.addAll(other.handles);
    }
    hasUnreadMessage ??= other.hasUnreadMessage;
    isArchived ??= other.isArchived;
    isPinned ??= other.isPinned;
    if (dbLatestMessage.target == null && other.dbLatestMessage.target != null) {
      setLatestMessage(other.dbLatestMessage.target!);
    } else if (dbLatestMessage.target != null &&
        other.dbLatestMessage.target?.service != null &&
        dbLatestMessage.target!.guid == other.dbLatestMessage.target!.guid) {
      dbLatestMessage.target!.service = other.dbLatestMessage.target!.service;
    }
    muteArgs ??= other.muteArgs;
    dateDeleted ??= other.dateDeleted;
    style ??= other.style;
    wallpaperType ??= other.wallpaperType;
    dynamicWallpaperId ??= other.dynamicWallpaperId;
    dynamicWallpaperConfig ??= other.dynamicWallpaperConfig;
    knownGroupPhotoGuid ??= other.knownGroupPhotoGuid;
    if (other.serviceName != null) serviceName = other.serviceName;
    return this;
  }

  static int sort(Chat? a, Chat? b) {
    if (a!.isPinned! && b!.isPinned! && a.pinIndex != null && b.pinIndex != null) {
      return a.pinIndex!.compareTo(b.pinIndex!);
    }
    if (b!.isPinned! && b.pinIndex != null && (!a.isPinned! || a.pinIndex == null)) {
      return 1;
    }
    if (a.isPinned! && a.pinIndex != null && (!b.isPinned! || b.pinIndex == null)) {
      return -1;
    }
    if (!a.isPinned! && b.isPinned!) {
      return 1;
    }
    if (a.isPinned! && !b.isPinned!) {
      return -1;
    }

    final aDate = a.dbOnlyLatestMessageDate ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bDate = b.dbOnlyLatestMessageDate ?? DateTime.fromMillisecondsSinceEpoch(0);
    return -aDate.compareTo(bDate);
  }

  static Future<void> getIcon(Chat c, {bool force = false}) async {
    if (!force && c.lockChatIcon) return;
    final response = await HttpSvc.chat.getIcon(c.guid).catchError((err, stack) async {
      Logger.debug("Failed to get chat icon for chat ${c.getTitle()}: $err");
      return Response(statusCode: 500, requestOptions: RequestOptions(path: ""));
    });
    final status = response.statusCode ?? 500;
    if (status != 200 || isNullOrEmpty(response.data)) {
      if ((status == 404 || status == 204) && c.customAvatarPath != null) {
        if (GetIt.I.isRegistered<ChatsService>() && !ChatsSvc.headless) {
          await (ChatsSvc as dynamic).setChatCustomAvatarPath(c, null);
        } else {
          await FilesystemSvc.deleteWebAvatar(c.customAvatarPath!);
          c.customAvatarPath = null;
          await c.saveAsync(updateCustomAvatarPath: true);
        }
      }
      return;
    }

    final raw = response.data;
    final bytes = raw is Uint8List ? raw : Uint8List.fromList((raw as List).cast<int>());
    if (bytes.isEmpty) return;
    final path = await FilesystemSvc.saveWebAvatar('chat_${FilesystemService.sanitizeGuid(c.guid)}', bytes);
    if (GetIt.I.isRegistered<ChatsService>() && !ChatsSvc.headless) {
      await (ChatsSvc as dynamic).setChatCustomAvatarPath(c, path);
    } else {
      c.customAvatarPath = path;
      await c.saveAsync(updateCustomAvatarPath: true);
    }
    if (!isNullOrEmpty(c.serverGroupPhotoGuid) && c.knownGroupPhotoGuid != c.serverGroupPhotoGuid) {
      c.knownGroupPhotoGuid = c.serverGroupPhotoGuid;
      await c.saveAsync(updateKnownGroupPhotoGuid: true);
    }
  }

  static final Map<String, String?> _cachedServerBgGuids = {};
  static final Map<String, Future<void>> _inFlightBgSyncs = {};

  static String? cachedServerBackgroundGuid(String guid, {String? fallbackStoredPath}) {
    if (_cachedServerBgGuids.containsKey(guid)) {
      return _cachedServerBgGuids[guid];
    }
    final bgGuid = serverBackgroundGuidFromPath(
      FilesystemSvc.getExistingChatBackgroundPath(guid, fallbackStoredPath: fallbackStoredPath),
    );
    _cachedServerBgGuids[guid] = bgGuid;
    return bgGuid;
  }

  static void invalidateServerBackgroundGuidCache(String guid, [String? bgGuid]) {
    _cachedServerBgGuids[guid] = bgGuid;
  }

  static Future<void> syncBackground(Chat c, {Chat? targetChat}) {
    final existing = _inFlightBgSyncs[c.guid];
    if (existing != null) return existing;
    final future = _syncBackgroundImpl(c, targetChat: targetChat).whenComplete(() {
      _inFlightBgSyncs.remove(c.guid);
    });
    _inFlightBgSyncs[c.guid] = future;
    return future;
  }

  static Future<void> _syncBackgroundImpl(Chat c, {Chat? targetChat}) async {
    final serverGuid = c.serverBackgroundGuid;
    final target = targetChat ?? c;
    final existingPath = FilesystemSvc.getExistingChatBackgroundPath(
      c.guid,
      fallbackStoredPath: target.customBackgroundPath,
    );
    final currentWallpaperType = ChatsSvc.getChatState(target.guid)?.wallpaperType.value.name ?? target.wallpaperType;

    if (!shouldSyncServerBackground(
      serverGuid: serverGuid,
      hasServerProperties: c.hasServerProperties,
      existingPath: existingPath,
      wallpaperType: currentWallpaperType,
    )) {
      _cachedServerBgGuids[c.guid] = serverBackgroundGuidFromPath(existingPath);
      return;
    }

    if (serverGuid == null) {
      await (ChatsSvc as dynamic).clearChatWallpaper(target);
      _cachedServerBgGuids[c.guid] = null;
      return;
    }

    final response = await HttpSvc.chat.getBackground(c.guid).catchError((err, stack) {
      Logger.debug("Failed to fetch chat background for ${c.guid}: $err");
      return Response(statusCode: 500, requestOptions: RequestOptions(path: ""));
    });
    if (response.statusCode != 200 || isNullOrEmpty(response.data)) return;

    final raw = response.data;
    final bytes = raw is Uint8List ? raw : Uint8List.fromList((raw as List).cast<int>());
    if (bytes.isEmpty) return;

    final contentType = response.headers.value('content-type')?.toLowerCase() ?? '';
    final ext = contentType.contains('png') ? 'png' : 'jpg';
    if (existingPath != null) {
      ThemesService.clearAdaptiveThemeCache(existingPath);
    }
    final path = await FilesystemSvc.saveServerChatBackground(c.guid, serverGuid, bytes, ext: ext);
    await (ChatsSvc as dynamic).setChatCustomBackgroundPath(target, path);
    _cachedServerBgGuids[c.guid] = serverGuid;
  }

  Map<String, dynamic> toMap() {
    final participants = handles.isEmpty ? this.participants : handles.toList();
    return {
      "ROWID": id,
      "guid": guid,
      "chatIdentifier": chatIdentifier,
      "isArchived": isArchived!,
      "muteType": muteType,
      "muteArgs": muteArgs,
      "isPinned": isPinned!,
      "displayName": displayName,
      "participants": participants.map((item) => item.toMap()).toList(),
      "hasUnreadMessage": hasUnreadMessage!,
      "_customAvatarPath": _customAvatarPath.value,
      "_customBackgroundPath": _customBackgroundPath.value,
      "_pinIndex": _pinIndex.value,
      "autoSendReadReceipts": autoSendReadReceipts,
      "autoSendTypingIndicators": autoSendTypingIndicators,
      "dateDeleted": dateDeleted?.millisecondsSinceEpoch,
      "style": style,
      "lockChatName": lockChatName,
      "lockChatIcon": lockChatIcon,
      "lastReadMessageGuid": lastReadMessageGuid,
      "customThemeLight": customThemeLight,
      "customThemeDark": customThemeDark,
      "wallpaperType": wallpaperType,
      "dynamicWallpaperId": dynamicWallpaperId,
      "dynamicWallpaperConfig": dynamicWallpaperConfig,
      "knownGroupPhotoGuid": knownGroupPhotoGuid,
      "serverGroupPhotoGuid": serverGroupPhotoGuid,
      "serverBackgroundGuid": serverBackgroundGuid,
      "hasServerProperties": hasServerProperties,
      "serviceName": serviceName,
      "textFieldText": textFieldText,
      "textFieldRuns": textFieldRuns,
      "textFieldAttachments": textFieldAttachments,
      "dbOnlyLatestMessageDate": dbOnlyLatestMessageDate?.millisecondsSinceEpoch,
      "dbLatestMessageId": dbLatestMessage.targetId,
    };
  }
}
