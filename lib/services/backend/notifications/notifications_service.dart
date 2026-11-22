import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/web_ringtone.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/settings/pages/scheduling/scheduled_messages_panel.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'package:get/get.dart';
import 'package:bluebubbles/services/backend/notifications/desktop_notification.dart';
import 'package:bluebubbles/services/backend/notifications/web_notifications_interop.dart';
import 'package:bluebubbles/services/backend/notifications/toast_button_images.dart';
import 'package:path/path.dart';
import 'package:synchronized/synchronized.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:timezone/timezone.dart';
import 'package:universal_io/io.dart';
import 'package:get_it/get_it.dart';

part 'notifications_service_fork.dart';

// ignore: non_constant_identifier_names
NotificationsService get NotificationsSvc => GetIt.I<NotificationsService>();

class PendingToastItem {
  final String? sender;
  final String text;
  final bool isReaction;
  final bool isGroupEvent;
  final DateTime? date;

  String get senderText => sender == null ? text : "$sender: $text";

  PendingToastItem(
      {required this.sender, required this.text, required this.isReaction, required this.isGroupEvent, this.date});
}

class NotificationsService {
  static const String NEW_MESSAGE_CHANNEL = "com.bluebubbles.new_messages";
  static const String ERROR_CHANNEL = "com.bluebubbles.errors";
  static const String REMINDER_CHANNEL = "com.bluebubbles.reminders";
  static const String FACETIME_CHANNEL = "com.bluebubbles.incoming_facetimes";
  static const String MISSED_FACETIME_CHANNEL = "com.bluebubbles.missed_facetimes";
  static const String FOREGROUND_SERVICE_CHANNEL = "com.bluebubbles.foreground_service";

  static const String NEW_MESSAGE_TAG = "com.bluebubbles.messaging.NEW_MESSAGE_NOTIFICATION";
  static const String NEW_FACETIME_TAG = "com.bluebubbles.messaging.NEW_FACETIME_NOTIFICATION";

  final FlutterLocalNotificationsPlugin flnp = FlutterLocalNotificationsPlugin();
  StreamSubscription? countSub;
  Worker? _webUnreadWorker;
  int currentCount = 0;

  bool headless = false;

  /// For desktop use only
  static int? failedToast;
  static int? aliasesToast;
  static String? aliasesToastText;
  static Map<String, int> facetimeNotifications = {};
  static Map<String, Timer> facetimeTimeouts = {};
  static Map<String, int> activeToasts = {};
  static Map<String, Timer> debounceTimers = {};
  static Map<String, List<PendingToastItem>> pendingMessages = {};
  static final Lock _lock = Lock();
  static Player? _desktopNotificationPlayer;

  static const int maxLines = 4;
  static const int charsPerLineEst = 40;

  /// How long a desktop FaceTime toast can ring before it clears itself. Calls with a UUID are normally cleared by
  /// the server's `disconnected` status, so this only covers a status event that never arrives.
  static const Duration faceTimeToastTimeout = Duration(minutes: 2);

  /// Calls without a UUID come from servers with FaceTime calling off, which never report the call being answered
  /// or ended, so this timeout is the only way the toast closes. Kept short so it stops soon after the call is
  /// answered elsewhere.
  static const Duration legacyFaceTimeToastTimeout = Duration(seconds: 30);

  /// Windows toast identity. The toast icon is registered under the AUMID but only
  /// resolves when it matches the guid (flutter_local_notifications#2738), so one
  /// value serves as both.
  ///
  /// One value per distributable: the guid doubles as the toast activator CLSID, and a
  /// packaged manifest registration outranks the unpackaged HKCU one, so a shared value
  /// sends actions to the wrong app
  ///
  /// Store value must equal msix_config.toast_activator.clsid (pubspec.yaml), sideload
  /// value --toast-activator-clsid (windows/build.ps1), exe value kExeToastActivatorClsid
  /// (windows/runner/toast_forwarder.cpp).
  ///
  /// DO NOT CHANGE THESE
  static const String _storeMsixNotificationGuid = '1c09a4af-0327-4a79-a0f3-a1404df74ed1';
  static const String _sideloadMsixNotificationGuid = '68c6675d-9acf-4098-b539-20b5792427b5';
  static const String _exeNotificationGuid = '5963a68d-695e-4b6e-9596-421c0053a055';

  static String get windowsNotificationGuid => isStoreMsix
      ? _storeMsixNotificationGuid
      : isSideloadMsix
          ? _sideloadMsixNotificationGuid
          : _exeNotificationGuid;

  bool get hideContent => SettingsSvc.settings.hideTextPreviews.value;

  Future<void> init({bool headless = false}) async {
    this.headless = headless;
    if (!kIsWeb && !headless) {
      if (kIsDesktop) {
        DesktopNotifications.registerMessageInteractionHandler(_handleDesktopMessageInteraction);
      }
      await flnp.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('ic_stat_icon'),
          linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(
            appName: 'BlueBubbles',
            appUserModelId: windowsNotificationGuid,
            guid: windowsNotificationGuid,
            iconPath: join(
              dirname(Platform.resolvedExecutable),
              'data',
              'flutter_assets',
              'assets',
              'icon',
              'icon.ico',
            ),
          ),
        ),
        onDidReceiveNotificationResponse: (NotificationResponse? response) {
          if (response == null) return;
          if (kIsDesktop) {
            DesktopNotifications.handleResponse(response);
          } else if (response.payload != null) {
            if (GetIt.I.isRegistered<IntentsService>()) {
              // Fired for a notification tapped while the app was already attached
              // and running, so activeChat is guaranteed to be in sync.
              IntentsSvc.openChat(response.payload, isInitialIntent: false);
            } else {
              Logger.warn('IntentsService not registered, cannot open chat from notification tap');
            }
          }
        },
      );
      if (kIsDesktop) {
        DesktopNotifications.registerPlugin(flnp);
        return;
      }
      final details = await flnp.getNotificationAppLaunchDetails();
      if (details != null && details.didNotificationLaunchApp && details.notificationResponse?.payload != null) {
        if (GetIt.I.isRegistered<IntentsService>()) {
          // didNotificationLaunchApp means this tap is what launched the app — the
          // widget tree is starting fresh, so activeChat can't be trusted here.
          IntentsSvc.openChat(details.notificationResponse!.payload!, isInitialIntent: true);
        } else {
          Logger.warn('IntentsService not registered, cannot process notification launch payload');
        }
      }
    } else if (kIsWeb && !headless) {
      bindWebUnreadBadge();
    }
  }

  void close() {
    countSub?.cancel();
    _webUnreadWorker?.dispose();
  }

  static const int _reminderIdBase = 50000;
  static const int _reminderIdRange = 9998;

  /// Reminders are payload-backed and usually fire after the run that scheduled them has
  /// exited, so desktop's stale-toast sweep keeps them.
  static bool isReminderId(int id) => id >= _reminderIdBase && id < _reminderIdBase + _reminderIdRange;

  /// Returns false when the reminder couldn't be scheduled.
  Future<bool> createReminder(Chat? chat, Message? message, DateTime time,
      {String? chatTitle, String? messageText}) async {
    if (kIsWeb) return false;
    final int id = Random().nextInt(_reminderIdRange) + _reminderIdBase;
    final String title = chatTitle ?? 'Reminder: ${chat!.getTitle()}';
    final String body = messageText ?? (hideContent ? "iMessage" : message!.getNotificationText());
    final TZDateTime scheduledDate = TZDateTime.from(time, local);
    if (kIsDesktop) {
      return DesktopNotifications.scheduleReminder(
        id: id,
        title: title,
        body: body,
        scheduledDate: scheduledDate,
        // Reminders fire later, often after a restart; one overwritten file per chat.
        avatarPath: chat == null
            ? null
            : (await _chatAvatarPath(
                chat,
                persistPath: join(
                  FilesystemSvc.appDocDir.path,
                  'reminder_avatars',
                  '${DesktopNotifications.groupBase(chat.guid)}.png',
                ),
              )).$1,
        messageData: chat == null ? null : DesktopMessageData(chatGuid: chat.guid, messageGuid: message?.guid),
      );
    }
    var scheduleMode = AndroidScheduleMode.exactAllowWhileIdle;
    if (!kIsWeb && Platform.isAndroid) {
      final androidPlugin = flnp.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final canScheduleExact = await androidPlugin?.canScheduleExactNotifications() ?? false;
      if (!canScheduleExact) {
        scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;
      }
    }
    await flnp.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          REMINDER_CHANNEL,
          'Reminders',
          channelDescription: 'Message reminder notifications',
          priority: Priority.max,
          importance: Importance.max,
          color: HexColor("4990de"),
        ),
      ),
      payload: "${time.millisecondsSinceEpoch}",
      androidScheduleMode: scheduleMode,
    );
    return true;
  }

  Future<void> createNotification(Chat chat, Message message) async {
    if (GetIt.I.isRegistered<LifecycleService>()) {
      await GetIt.I.isReady<LifecycleService>();
    }

    if (chat.shouldMuteNotification(message) || message.isFromMe!) return;
    final isGroup = chat.isGroup;
    final guid = chat.guid;
    final contactName = message.handleRelation.target?.displayName ?? "Unknown";
    final title = isGroup ? (ChatsSvc.getChatState(chat.guid)?.title.value ?? chat.getTitle()) : contactName;
    final text = hideContent ? "iMessage" : message.getNotificationText();
    final isReaction = message.isReaction;

    if (kIsWeb) {
      if (webNotificationPermission != "granted") return;
      final chatIcon = await avatarAsBytes(chat: chat, quality: 256);
      await showWebNotificationEx(
        title: title,
        body: text,
        icon: chatIcon.isNotEmpty ? "data:image/png;base64,${base64Encode(chatIcon)}" : null,
        tag: message.guid,
        onClick: () async {
          await IntentsSvc.openChat(guid, isInitialIntent: false);
        },
      );
      return;
    } else if (kIsDesktop) {
      // Avatar loading is deferred to _buildAndShowToast — don't load it here.
      _lock.synchronized(
          () => showDesktopNotif(text, chat, title, contactName, message, isReaction, message.isGroupEvent));
    } else {
      if (message.guid != null && message.dateCreated != null) {
        if (!GetIt.I.isRegistered<MethodChannelService>()) {
          Logger.warn('MethodChannelService not registered; skipping incoming message notification');
          return;
        }

        final personIcon = (await rootBundle.load("assets/images/person64.png")).buffer.asUint8List();
        Uint8List chatIcon = await avatarAsBytes(chat: chat, quality: 256);
        final isFromMe = message.isFromMe ?? false;
        // Reuse chatIcon on 1:1 chats instead of decoding and encoding the same avatar twice.
        Uint8List contactIcon = isFromMe
            ? personIcon
            : !chat.isGroup
                ? chatIcon
                : await avatarAsBytes(
                    participantsOverride:
                        chat.people.where((e) => e.address == message.handleRelation.target?.address).toList(),
                    chat: chat,
                    quality: 256);
        if (chatIcon.isEmpty) chatIcon = personIcon;
        if (contactIcon.isEmpty) contactIcon = personIcon;

        // Determine if reaction action should be shown (only if Private API is enabled & not a reaction message)
        final bool showReactionAction = SettingsSvc.settings.enablePrivateAPI.value &&
            SettingsSvc.settings.notificationReactionAction.value &&
            !message.isReaction;
        final String reactionType = SettingsSvc.settings.notificationReactionActionType.value;

        final Handle? senderHandle = message.handleRelation.target;
        final ContactV2? senderContact = senderHandle?.contactsV2.where((c) => c.isNative).firstOrNull ??
            senderHandle?.contactsV2.firstOrNull;
        final String? contactKey = senderHandle?.address;
        final String? contactUri = ContactV2.personUriForAddress(contactKey);
        final String? nativeContactId = (senderContact != null &&
                senderContact.isNative &&
                senderContact.nativeContactId.isNotEmpty)
            ? senderContact.nativeContactId
            : null;

        final List<Map<String, dynamic>> participants = isGroup
            ? chat.people.map((h) {
                final ContactV2? c = h.contactsV2.where((e) => e.isNative).firstOrNull ?? h.contactsV2.firstOrNull;
                return <String, dynamic>{
                  'name': h.displayName,
                  'key': h.address,
                  'uri': ContactV2.personUriForAddress(h.address),
                  'native_contact_id': (c != null && c.isNative && c.nativeContactId.isNotEmpty) ? c.nativeContactId : null,
                };
              }).toList()
            : const <Map<String, dynamic>>[];

        String? attachmentPath;
        String? attachmentMime;
        if (!hideContent && message.dbAttachments.isNotEmpty) {
          for (final att in message.dbAttachments) {
            final mime = att.mimeType;
            if (mime != null && mime.startsWith('image/')) {
              final path = att.path;
              if (File(path).existsSync()) {
                attachmentPath = path;
                attachmentMime = mime;
                break;
              }
            }
          }
        }

        final bool isEdit = message.dateEdited != null;
        final List<Map<String, dynamic>> historicMessages = hideContent
            ? const <Map<String, dynamic>>[]
            : Chat.getMessages(chat, limit: 10)
                .where((m) =>
                    m.guid != message.guid &&
                    m.dateCreated != null &&
                    !m.dateCreated!.isAfter(message.dateCreated!))
                .map((m) {
                  final hHandle = m.handleRelation.target;
                  return <String, dynamic>{
                    'text': m.getNotificationText(),
                    'date': m.dateCreated!.millisecondsSinceEpoch,
                    'is_from_me': m.isFromMe ?? false,
                    'sender_name': hHandle?.displayName,
                    'sender_key': hHandle?.address,
                    'sender_uri': ContactV2.personUriForAddress(hHandle?.address),
                  };
                })
                .where((h) => (h['text'] as String).trim().isNotEmpty)
                .take(5)
                .toList()
                .reversed
                .toList();

        await GetIt.I.isReady<MethodChannelService>();
        await MethodChannelSvc.invokeMethod('create-incoming-message-notification', {
          'channel_id': NEW_MESSAGE_CHANNEL,
          'chat_id': chat.id,
          'chat_guid': guid,
          'chat_is_group': isGroup,
          'chat_title': title,
          'chat_icon': isGroup ? chatIcon : null,
          'contact_name': contactName,
          'contact_avatar': contactIcon,
          'contact_key': contactKey,
          'contact_uri': contactUri,
          'native_contact_id': nativeContactId,
          'you_name': SettingsSvc.settings.userName.value,
          'you_key': 'me',
          'participants': participants,
          'historic_messages': historicMessages,
          'attachment_path': attachmentPath,
          'attachment_mime': attachmentMime,
          'message_guid': message.guid!,
          'message_text': text,
          'message_date': message.dateCreated!.millisecondsSinceEpoch,
          'message_is_from_me': false,
          'is_reaction': isReaction,
          'is_edit': isEdit,
          'only_alert_once': isReaction || isEdit,
          'show_reaction_action': showReactionAction,
          'reaction_type': reactionType,
        });
      }
    }
  }

  Future<void> tryCreateNewMessageNotification(Message message, Chat chat) async {
    if ((message.isFromMe ?? false) || !message.handleRelation.hasValue) {
      if (!(message.isFromMe ?? false) && !message.handleRelation.hasValue) {
        Logger.error(
          'Skipping notification for ${message.guid} in chat ${chat.guid} — '
          'handle relation not resolved (handleId=${message.handleId})',
          tag: 'NotificationsService',
        );
      }
      return;
    }
    if (message.isKeptAudio) return;
    // Already read on another device, e.g. a message the socket missed that arrived late.
    if (message.dateRead != null) return;
    if (chat.shouldMuteNotification(message)) return;
    if (!headless && LifecycleSvc.isForeground) {
      if (ChatsSvc.isChatActive(chat.guid)) return;
      // Desktop always notifies for inactive chats; this chat-list suppression is mobile-only.
      if (!kIsDesktop &&
          ChatsSvc.activeChat == null &&
          NavigationSvc.onChatList &&
          !SettingsSvc.settings.notifyOnChatList.value) {
        return;
      }
    }

    await createNotification(chat, message);
  }

  Future<bool> createIncomingFaceTimeNotification(
      String? callUuid, String caller, Uint8List? chatIcon, bool isAudio,
      {String? callerAddress, bool isTelephony = false}) async {
    // Set some notification defaults
    String title = caller;
    String text = isTelephony
        ? "Incoming iPhone Call"
        : "${callUuid == null ? "Incoming" : "Answer"} FaceTime ${isAudio ? 'Audio' : 'Video'} Call";

    if (kIsWeb) {
      startWebFaceTimeRingtone(
        callUuid: callUuid,
        volume: _effectiveFaceTimeRingtoneVolume(),
      );
      if (webNotificationPermission != "granted") return false;
      await showWebNotificationEx(
        title: title,
        body: text,
        icon: chatIcon != null && chatIcon.isNotEmpty ? "data:image/png;base64,${base64Encode(chatIcon)}" : null,
        tag: callUuid,
        requireInteraction: true,
        renotify: callUuid != null && callUuid.isNotEmpty,
        onClick: callUuid != null
            ? () async {
                stopWebFaceTimeRingtone(callUuid: callUuid);
                await IntentsSvc.answerFaceTime(
                  callUuid,
                  audioOnly: isAudio,
                  isTelephony: isTelephony,
                );
              }
            : () => stopWebFaceTimeRingtone(),
      );
      return false;
    }

    chatIcon ??= (await rootBundle.load("assets/images/person64.png")).buffer.asUint8List();

    if (kIsDesktop) {
      _lock.synchronized(() async => await showPersistentDesktopFaceTimeNotif(callUuid, caller, chatIcon, isAudio));
      return false;
    } else {
      return await MethodChannelSvc.actions.createIncomingFaceTimeNotification(
        channelId: FACETIME_CHANNEL,
        notificationId: faceTimeNotificationId(callUuid),
        title: title,
        body: text,
        callerAvatar: chatIcon,
        caller: caller,
        callUuid: callUuid,
        isVideo: !isAudio,
        callerAddress: callerAddress,
        isTelephony: isTelephony,
      );
    }
  }

  @visibleForTesting
  static int faceTimeNotificationId(String? callUuid) => _faceTimeNotificationId(callUuid);

  @visibleForTesting
  static int missedFaceTimeNotificationId(String? callUuid) =>
      callUuid != null && callUuid.isNotEmpty
          ? ((_faceTimeNotificationId(callUuid) ^ 0x4D495353) & 0x7fffffff)
          : _faceTimeNotificationId(null);

  Future<void> createMissedFaceTimeNotification(
    String? callUuid,
    String caller, {
    bool isAudio = false,
    bool isTelephony = false,
    String? callerAddress,
  }) async {
    final String title = caller;
    final String body = isTelephony
        ? "Missed iPhone Call"
        : "Missed FaceTime ${isAudio ? 'Audio' : 'Video'} Call";

    if (kIsWeb) {
      if (webNotificationPermission != "granted") return;
      await showWebNotificationEx(
        title: title,
        body: body,
        tag: callUuid != null && callUuid.isNotEmpty ? 'missed-$callUuid' : null,
        renotify: false,
      );
      return;
    }

    if (kIsDesktop) {
      await DesktopNotifications.showText(
        title: title,
        body: body,
        onOpen: () async {
          await showAndFocusWindow();
        },
      );
      return;
    }

    await flnp.show(
      id: missedFaceTimeNotificationId(callUuid),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          MISSED_FACETIME_CHANNEL,
          'Missed FaceTime Calls',
          channelDescription: 'Displays missed FaceTime call notifications',
          icon: 'ic_stat_icon',
          priority: Priority.defaultPriority,
          importance: Importance.defaultImportance,
          color: HexColor("4990de"),
        ),
      ),
    );
  }

  double _effectiveFaceTimeRingtoneVolume() {
    if (GetIt.I.isRegistered<SettingsService>()) {
      return (SettingsSvc.settings.soundVolume.value / 100.0).clamp(0.0, 1.0);
    }
    return 1.0;
  }

  Future<void> clearFaceTimeNotification(String callUuid, {bool onlyIfRinging = false}) async {
    if (kIsWeb) {
      stopWebFaceTimeRingtone(callUuid: callUuid);
      await closeWebNotificationsByTag(callUuid);
    } else if (kIsDesktop) {
      await clearDesktopFaceTimeNotif(callUuid);
    } else {
      if (Platform.isAndroid) {
        await MethodChannelSvc.actions.endFaceTimeCall(
          callUuid: callUuid,
          onlyIfRinging: onlyIfRinging,
        );
      }
      await MethodChannelSvc.actions.deleteNotification(
        notificationId: faceTimeNotificationId(callUuid),
        tag: NEW_FACETIME_TAG,
        callUuid: callUuid,
      );
    }
  }

  Future<void> showPersistentDesktopFaceTimeNotif(
    String? callUuid,
    String caller,
    Uint8List? avatar,
    bool isAudio,
  ) async {
    final String key = callUuid ?? caller;
    String? path;

    if (avatar != null) {
      Uint8List? _avatar = await clip(avatar, size: 256, circle: true);
      if (_avatar != null) {
        // Create a temp file with the avatar
        path = join(FilesystemSvc.appTempPath, "${randomString(8)}.png");
        await File(path).create(recursive: true);
        await File(path).writeAsBytes(_avatar);
      }
    }

    facetimeTimeouts.remove(key)?.cancel();
    final int? existing = facetimeNotifications.remove(key);
    if (existing != null) {
      await DesktopNotifications.cancel(existing);
    }

    final int? id = await DesktopNotifications.showFaceTime(
      caller: caller,
      avatarPath: path,
      body: "Incoming FaceTime ${isAudio ? 'Audio' : 'Video'} Call",
      onOpen: () async {
        await showAndFocusWindow();
      },
      onAnswer: callUuid == null
          ? null
          : () async {
              await showAndFocusWindow();
              await IntentsSvc.answerFaceTime(callUuid, audioOnly: isAudio);
            },
      onDecline: callUuid == null
          ? null
          : () async {
              await ActiveCallController.instance.declineCall();
              hideFaceTimeOverlay(callUuid);
              await clearDesktopFaceTimeNotif(key);
            },
    );

    if (id != null) {
      facetimeNotifications[key] = id;
      facetimeTimeouts[key] = Timer(
        callUuid == null ? legacyFaceTimeToastTimeout : faceTimeToastTimeout,
        () => clearDesktopFaceTimeNotif(key),
      );
    }
  }

  Future<void> clearDesktopFaceTimeNotif(String callerUuid) async {
    facetimeTimeouts.remove(callerUuid)?.cancel();
    final int? id = facetimeNotifications.remove(callerUuid);
    if (id != null) await DesktopNotifications.cancel(id);
  }

  void showDesktopNotif(
      String text, Chat chat, String title, String contactName, Message message, bool isReaction, bool isGroupEvent) {
    if (kIsDesktop && !SettingsSvc.settings.desktopNotifications.value) return;

    final String guid = chat.guid;

    pendingMessages[guid] ??= [];

    pendingMessages[guid]!.add(PendingToastItem(
        sender: chat.isGroup && !isReaction ? contactName.split(" ").first : null,
        text: text,
        isReaction: isReaction,
        isGroupEvent: isGroupEvent,
        date: message.dateCreated,
    ));

    // Cancel and clean up old timer
    final oldTimer = debounceTimers[guid];
    oldTimer?.cancel();
    debounceTimers[guid] = Timer(
      const Duration(milliseconds: 300),
      // Serialize against clearDesktopNotificationsForChat across the await points inside _buildAndShowToast.
      () async => await _lock.synchronized(() => _buildAndShowToast(chat, title, message)),
    );
  }

  Future<void> _buildAndShowToast(Chat chat, String title, Message message) async {
    final String guid = chat.guid;
    if (pendingMessages[guid]?.isEmpty ?? true) return;

    int usedLines = 0;
    int numToShow = 0;
    int numMessages = pendingMessages[guid]!.length;

    final int numSenders = pendingMessages[guid]!.map((p) => p.sender).nonNulls.toSet().length;
    for (int i = numMessages - 1; i >= 0; i--) {
      final PendingToastItem item = pendingMessages[guid]![i];
      final String displayText = numSenders > 1 ? item.senderText : item.text;
      final int newLines = _estimateLines(displayText);
      if (usedLines + newLines > maxLines) {
        break;
      }

      usedLines += newLines;
      numToShow += 1;
    }
    if (numToShow == 0) {
      numToShow = 1;
    }

    final int overflowCount = numMessages - numToShow;
    final String body = pendingMessages[guid]!
        .slice(overflowCount)
        .map((PendingToastItem e) => numSenders > 1 ? e.senderText : e.text)
        .join("\n");

    final PendingToastItem lastItem = pendingMessages[guid]!.last;
    final bool multipleMessages = numMessages > 1;

    String displayTitle;
    if (numSenders == 1 && !lastItem.isReaction && !lastItem.isGroupEvent) {
      displayTitle = "$title: ${lastItem.sender}";
    } else {
      displayTitle = title;
    }

    final (String path, bool isTemporaryFile) = await _chatAvatarPath(chat);

    final papi = SettingsSvc.settings.enablePrivateAPI.value;
    final List<String> actionValues = SettingsSvc.settings.actionList
        .map(
          (action) => action == "Mark Read"
              ? 'mark-read'
              : lastItem.isReaction || lastItem.isGroupEvent || !papi
              ? null
              : ReactionTypes.toList().contains(action) || SettingsSvc.serverDetails.supportsEmojiTapbacks
              ? action
              : null,
        )
        .nonNulls
        .toList();

    final bool showMarkRead = actionValues.contains('mark-read');
    final List<String> actionLabels = multipleMessages
        ? showMarkRead
              ? ["Mark $numMessages Messages Read"]
              : const []
        : actionValues
              .map((action) => action == 'mark-read' ? 'Mark Read' : ReactionTypes.reactionToEmoji[action] ?? action)
              .toList();
    final List<String> toastActions = multipleMessages && showMarkRead ? const ['mark-read'] : actionValues;
    // Tapbacks as images, so they look as they do in the app; Mark Read stays text
    List<String?> actionImages = const [];
    if (Platform.isWindows) {
      actionImages = await Future.wait(
          toastActions.map((action) async => action == 'mark-read' ? null : await ToastButtonImages.forAction(action)));
      // All of the tapbacks or none, so a failed image doesn't leave one button looking different
      if (actionImages.whereIndexed((i, image) => image == null && toastActions[i] != 'mark-read').isNotEmpty) {
        actionImages = const [];
      }
    }
    final DesktopMessageData messageData = DesktopMessageData(
      chatGuid: guid,
      messageGuid: message.guid,
      actions: toastActions,
    );

    final String? attribution = overflowCount > 0
        ? "+$overflowCount earlier message${overflowCount > 1 ? "s" : ""}"
        : null;

    try {
      await playDesktopNotificationSound();
    } catch (e, s) {
      Logger.warn("Failed to play desktop notification sound", error: e, trace: s);
    }

    // Always a fresh toast: replacing one in place while its banner is still up only updates Action Center —
    // Windows plays the sound but leaves the old text on screen.
    // The explicit cancel matters on Linux, where cancelGroup can't see live notifications.
    final int? existingToast = activeToasts.remove(guid);
    if (existingToast != null) await DesktopNotifications.cancel(existingToast);
    await DesktopNotifications.cancelGroup(guid);

    final int? id = await DesktopNotifications.showMessage(
      group: guid,
      avatarPath: path,
      title: displayTitle,
      body: body,
      attributionText: attribution,
      actionLabels: actionLabels,
      actionImagePaths: actionImages,
      replyInput: SettingsSvc.settings.showReplyField.value,
      silent: SettingsSvc.settings.desktopNotificationSoundPath.value != null,
      messageData: messageData,
    );

    if (id != null) {
      activeToasts[guid] = id;
    }

    // No dismissal callback exists to clean up the temp avatar, so fall back to a delayed delete.
    if (isTemporaryFile) {
      Future.delayed(const Duration(minutes: 1), () => _deleteTempFile(path));
    }
  }

  /// Avatar file for [chat] and whether it's a temp file the caller should delete.
  /// Single-participant chats reuse the ContactV2 avatar file directly; group chats
  /// and custom avatars get a generated composite written to a temp file, or to
  /// [persistPath] when the file must outlive this run (appTemp is wiped on startup).
  Future<(String, bool)> _chatAvatarPath(Chat chat, {String? persistPath}) async {
    if (chat.people.length == 1 && chat.customAvatarPath == null) {
      final avatarPath = chat.handles.first.contactsV2.map((c) => c.avatarPath).nonNulls.firstOrNull;
      // A reserved character in the file name means a row written before avatar
      // names were sanitized (macOS contact IDs end in `:ABPerson`). Windows can
      // neither build a file URI for it nor read it back reliably, so regenerate
      // a composite instead of handing the toast a path it will choke on.
      if (avatarPath != null &&
          !hasReservedFileNameChars(basename(avatarPath)) &&
          await File(avatarPath).exists()) {
        return (avatarPath, false);
      }
    }
    final Uint8List avatar = await avatarAsBytes(chat: chat, quality: 256);
    final String path = persistPath ?? join(FilesystemSvc.appTempPath, "${randomString(8)}.png");
    final File avatarFile = File(path);
    await avatarFile.create(recursive: true);
    await avatarFile.writeAsBytes(avatar);
    return (path, persistPath == null);
  }

  int _estimateLines(String text) {
    return (text.length / charsPerLineEst).ceil() + "\n".allMatches(text).length;
  }

  void _cleanNotificationState(String guid) {
    activeToasts.remove(guid);
  }

  Future<void> _openChat(Chat chat) async {
    if (!ChatsSvc.isChatActive(chat.guid) && Get.context != null) {
      NavigationSvc.pushAndRemoveUntil(Get.context!, ConversationView(chat: chat), (route) => route.isFirst);
    }
  }

  Future<void> _handleDesktopMessageInteraction(DesktopMessageInteraction interaction) async {
    final DesktopMessageData data = interaction.data;
    final Chat? chat = ChatsSvc.findChatByGuid(data.chatGuid) ?? Chat.findOne(guid: data.chatGuid);
    if (chat == null) {
      Logger.warn(
        'Cannot handle desktop notification: chat ${data.chatGuid} no longer exists',
        tag: 'NotificationsService',
      );
      return;
    }

    _cleanNotificationState(data.chatGuid);
    if (interaction.reply != null) {
      if (chat.hasUnreadMessage == true) {
        unawaited(ChatsSvc.setChatHasUnread(chat, false, privateMark: true));
      }
      final Message reply = Message(
        dateCreated: DateTime.now(),
        handleId: 0,
        text: interaction.reply,
        hasDdResults: true,
      );
      reply.generateTempGuid();
      OutgoingMsgHandler.queue(OutgoingMessage(chat: chat, message: reply));
      return;
    }

    if (interaction.action == 'mark-read') {
      chat.toggleHasUnreadAsync(false);
      EventDispatcher().emit('refresh', null);
      return;
    }

    if (interaction.action != null) {
      final Message? selectedMessage = data.messageGuid == null ? null : Message.findOne(guid: data.messageGuid);
      if (selectedMessage == null) {
        Logger.warn(
          'Cannot react from desktop notification: message ${data.messageGuid} no longer exists',
          tag: 'NotificationsService',
        );
        return;
      }
      final String action = interaction.action!;
      // Anything but a classic tapback is the emoji of an emoji tapback
      final bool emoji = !ReactionTypes.toList().contains(action);
      final String reaction = emoji ? ReactionTypes.EMOJI : action;
      final Message reactionMessage = Message(
        associatedMessageGuid: selectedMessage.guid!,
        associatedMessageType: reaction,
        associatedMessageEmoji: emoji ? action : null,
        associatedMessagePart: 0,
        dateCreated: DateTime.now(),
        handleId: 0,
      );
      OutgoingMsgHandler.queue(
        OutgoingReaction(chat: chat, message: reactionMessage, selectedMessage: selectedMessage, reaction: reaction),
      );
      return;
    }

    await _openChat(chat);
    if (interaction.focusWindow) await showAndFocusWindow();
  }

  Future<void> _deleteTempFile(String path) async {
    try {
      final File file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // Ignore file deletion errors
    }
  }

  Future<void> playDesktopNotificationSound() async {
    if (SettingsSvc.settings.desktopNotificationSoundPath.value != null) {
      _desktopNotificationPlayer?.dispose();
      final player = Player();
      _desktopNotificationPlayer = player;
      await player.setVolume(SettingsSvc.settings.desktopNotificationSoundVolume.value.toDouble());
      await player.open(Media(SettingsSvc.settings.desktopNotificationSoundPath.value!));
      player.stream.completed.firstWhere((completed) => completed, orElse: () => false).then((_) async {
        await Future.delayed(const Duration(milliseconds: 450));
        if (_desktopNotificationPlayer == player) {
          await player.dispose();
          _desktopNotificationPlayer = null;
        }
      });
    }
  }

  Future<void> createAliasesRemovedNotification(List<String> aliases) async {
    if (kIsWeb) return;
    const title = "iMessage alias deregistered!";
    const notifId = -3;
    final text = aliases.length == 1
        ? "${aliases[0]} has been deregistered!"
        : "The following aliases have been deregistered:\n${aliases.join("\n")}";

    if (kIsDesktop) {
      if (aliasesToastText == text) {
        return;
      }
      final int? existing = aliasesToast;
      if (existing != null) {
        await DesktopNotifications.cancel(existing);
      }

      aliasesToastText = text;
      aliasesToast = await DesktopNotifications.showText(
        title: title,
        body: text,
        onOpen: () async {
          aliasesToast = null;
          aliasesToastText = null;
          await showAndFocusWindow();
        },
      );
    } else {
      final notifs = await flnp.getActiveNotifications();

      //Already have this notification
      if (notifs.firstWhereOrNull((n) => n.id == notifId && n.body == text) != null) {
        return;
      }

      await flnp.show(
        id: notifId,
        title: title,
        body: text,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(ERROR_CHANNEL, 'Errors',
            channelDescription: 'Displays message send failures, connection failures, and more',
            priority: Priority.max,
            importance: Importance.max,
            color: HexColor("4990de"),
            ongoing: false,
            onlyAlertOnce: false,
              styleInformation: const BigTextStyleInformation('')),
        ),
      );
    }
  }

  Future<void> createFailedToSend(Chat chat, {bool scheduled = false}) async {
    if (kIsWeb) return;
    final title = 'Failed to send${scheduled ? " scheduled" : ""} message';
    final subtitle = scheduled ? 'Tap to open scheduled messages list' : 'Tap to see more details or retry';
    if (kIsDesktop) {
      failedToast = await DesktopNotifications.showText(
        title: title,
        body: subtitle,
        onOpen: () async {
          failedToast = null;
          await showAndFocusWindow();
          if (scheduled) {
            NavigationSvc.openSettings(initialPage: const ScheduledMessagesPanel());
          } else {
            if (ChatsSvc.activeChat?.chat.guid == chat.guid) {
              // Still open under Settings or Find My: bring it back into view
              NavigationSvc.closeSections();
            } else {
              NavigationSvc.pushAndRemoveUntil(
                Get.context!,
                ConversationView(
                  chat: chat,
                ),
                (route) => route.isFirst,
              );
            }
          }
        },
      );
      return;
    }
    await flnp.show(
      id: (chat.id! + 75000) * (scheduled ? -1 : 1),
      title: title,
      body: subtitle,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          ERROR_CHANNEL,
          'Errors',
          channelDescription: 'Displays message send failures, connection failures, and more',
          priority: Priority.max,
          importance: Importance.max,
          color: HexColor("4990de"),
        ),
      ),
      payload: chat.guid + (scheduled ? "-scheduled" : ""),
    );
  }

  Future<void> clearFailedToSend(int id) async {
    if (kIsWeb) return;
    if (kIsDesktop) {
      final int? toastId = failedToast;
      failedToast = null;
      if (toastId != null) await DesktopNotifications.cancel(toastId);
      return;
    }
    await flnp.cancel(id: id);
  }

  Future<void> clearDesktopNotificationsForChat(String chatGuid, {int? readBefore}) async {
    await _lock.synchronized(() async {
      if (readBefore != null) {
        // Messages newer than the read keep the toast up; the read ones drop out on its next rebuild.
        final pending = pendingMessages[chatGuid];
        pending?.removeWhere((p) => p.date == null || p.date!.millisecondsSinceEpoch <= readBefore);
        if (pending?.isNotEmpty ?? false) return;
      }
      final int? toastId = activeToasts[chatGuid];
      if (toastId != null) await DesktopNotifications.cancel(toastId);
      await DesktopNotifications.cancelGroup(chatGuid);
      _cleanNotificationState(chatGuid);
      debounceTimers[chatGuid]?.cancel();
      debounceTimers.remove(chatGuid);
      pendingMessages.remove(chatGuid);
    });
  }
}
