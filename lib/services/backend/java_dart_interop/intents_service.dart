import 'dart:async';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/layouts/settings/pages/scheduling/scheduled_messages_panel.dart';
import 'package:bluebubbles/app/layouts/settings/pages/server/server_management_panel.dart';
import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';

import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/chat_creator/chat_creator.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:bluebubbles/models/models.dart' show HandleLookupKey;
import 'package:path/path.dart';
import 'package:receive_intent/receive_intent.dart';
import 'package:universal_io/io.dart';
import 'package:get_it/get_it.dart';

// ignore: non_constant_identifier_names
IntentsService get IntentsSvc => GetIt.I<IntentsService>();

class IntentsService {
  late final StreamSubscription sub;

  @visibleForTesting
  ActiveCallController? callControllerOverride;

  /// When a notification tap triggers navigation to a specific chat, this is
  /// set synchronously (before any async gap) so that [onAppResume] can skip
  /// marking the previously-active chat as read while the redirect is pending.
  String? pendingOpenChatGuid;

  Future<void> init() async {
    if (kIsWeb || kIsDesktop) return;

    // getInitialIntent() reflects Activity.getIntent() at attach time, which fires
    // on every new/recreated Activity — including cases where the OS destroyed the
    // Activity but the Dart isolate (and ChatsSvc.activeChat) survived underneath
    // (e.g. via the foreground-service keep-alive). The widget tree is starting
    // fresh either way, so activeChat can't be trusted for the "already open"
    // shortcut on this path. receivedIntentStream, by contrast, only fires for an
    // Activity that was already attached and running, where activeChat is
    // guaranteed to be in sync with what's on screen.
    final intent = await ReceiveIntent.getInitialIntent();
    handleIntent(intent, isInitialIntent: true);

    sub = ReceiveIntent.receivedIntentStream.listen((Intent? intent) {
      handleIntent(intent, isInitialIntent: false);
    }, onError: (err) {
      Logger.error("Failed to get intent!", error: err);
    });
  }

  void close() async {
    await sub.cancel();
  }

  /// Android keeps the bubble's engine for the next bubble, which must not start on this chat.
  ///
  /// The chat is closed as well as popped: the bubble's header back button leaves it active, and the next
  /// bubble's intent arrives through [ReceiveIntent.receivedIntentStream], where [openChat] skips navigating
  /// to a chat that is still active.
  void leaveBubbleChat() {
    if (GetIt.I.isRegistered<ChatsService>()) {
      final controller = ChatsSvc.activeChat?.controller;
      if (controller != null) {
        controller.close();
      } else {
        ChatsSvc.setAllInactiveSync();
      }
    }
    Get.until((route) => route.isFirst);
  }

  void handleIntent(Intent? intent, {required bool isInitialIntent}) async {
    if (intent == null) return;

    // Every activity launch tells us whether we're running as a bubble. Set it
    // for ALL intents, not just chat-opens — otherwise isBubble stays true after
    // a bubble session when the app is next opened from the launcher or a share
    // sheet, misrouting lifecycle teardown to closeBubble() indefinitely.
    LifecycleSvc.isBubble = intent.extra?["bubble"] == true;

    switch (intent.action) {
      case "android.intent.action.SEND":
      case "android.intent.action.SEND_MULTIPLE":
        final id = intent.extra?["android.intent.extra.shortcut.ID"];
        final text = intent.extra?["android.intent.extra.TEXT"];
        final files = <PlatformFile>[];
        if (intent.extra?["android.intent.extra.STREAM"] != null) {
          final data = intent.extra!["android.intent.extra.STREAM"];
          if (data is List) {
            for (String? s in data) {
              if (s == null) continue;
              final path = await MethodChannelSvc.actions.getContentUriPath(uri: s);
              final bytes = await File(path).readAsBytes();
              files.add(PlatformFile(
                path: path,
                name: basename(path),
                bytes: bytes,
                size: bytes.length,
              ));
            }
          } else if (data != null) {
            final path = await MethodChannelSvc.actions.getContentUriPath(uri: data.toString());
            final bytes = await File(path).readAsBytes();
            files.add(PlatformFile(
              path: path,
              name: basename(path),
              bytes: bytes,
              size: bytes.length,
            ));
          }
        }
        await openChat(id, text: text, attachments: files, isInitialIntent: isInitialIntent);
        return;
      default:
        if (intent.data?.startsWith("imessage://") ?? false) {
          final uri =
              Uri.tryParse(intent.data!.replaceFirst("imessage://", "imessage:").replaceFirst("&body=", "?body="));
          if (uri != null) {
            await StartupTasks.waitForUI();
            final ctx = Get.context;
            if (ctx != null) {
              final address = uri.path;
              final handle = Handle.findOne(addressAndService: HandleLookupKey(address, "iMessage"));
              NavigationSvc.pushAndRemoveUntil(
                ctx,
                NewChatCreator(
                  initialSelected: [SelectedContact(displayName: handle?.displayName ?? address, address: address)],
                  initialText: uri.queryParameters['body'],
                ),
                (route) => route.isFirst,
              );
            }
          }
        } else if (intent.extra?["chatGuid"] != null) {
          final guid = intent.extra!["chatGuid"]!;
          await openChat(guid, isInitialIntent: isInitialIntent);
        } else if (intent.extra?["callUuid"] != null) {
          await StartupTasks.waitForUI();
          final isTelephony = intent.extra?["isTelephony"] == true;
          final isAudio = isTelephony ||
              intent.extra?["audioOnly"] == true ||
              intent.extra?["isAudio"] == true ||
              intent.extra?["isVideo"] == false;
          if (intent.extra?["answer"] == true) {
            await answerFaceTime(
              intent.extra?["callUuid"]!,
              audioOnly: isAudio,
              isTelephony: isTelephony,
            );
          } else {
            await showFaceTimeOverlay(
              intent.extra?["callUuid"],
              intent.extra?["caller"] ?? (isTelephony ? "iPhone call" : "FaceTime Call"),
              null,
              isAudio,
              isTelephony: isTelephony,
            );
          }
        }
    }
  }

  Future<void> answerFaceTime(
    String callUuid, {
    bool audioOnly = false,
    bool isTelephony = false,
  }) async {
    final controller = callControllerOverride ?? ActiveCallController.instance;
    final prevState = controller.state;
    final matchesPrev = prevState.callUuid == callUuid;
    final effectiveTelephony = isTelephony || (matchesPrev && prevState.isTelephony);
    final callerName = matchesPrev && prevState.callerName.isNotEmpty
        ? prevState.callerName
        : (effectiveTelephony ? "iPhone Call" : "FaceTime Call");
    final callerAddress = matchesPrev ? prevState.callerAddress : null;
    final avatarBytes = matchesPrev ? prevState.avatarBytes : null;
    final chatGuid = matchesPrev ? prevState.chatGuid : null;
    final wasVideo = matchesPrev ? prevState.isVideo : !(audioOnly || effectiveTelephony);
    final isAudioAnswer = effectiveTelephony || audioOnly || !wasVideo;
    final isAndroid = !kIsWeb && (Platform.isAndroid || defaultTargetPlatform == TargetPlatform.android);

    if (effectiveTelephony && !isAndroid) {
      hideFaceTimeOverlay(callUuid);
      return showSnackbar(
        "Unsupported",
        "iPhone cellular calls require Android Calling Accounts.",
        type: SnackbarType.error,
      );
    }

    if (isAndroid && isAudioAnswer) {
      final telecomEnabled = !GetIt.I.isRegistered<MethodChannelService>() ||
          await MethodChannelSvc.actions.isTelecomEnabled();
      if (!telecomEnabled) {
        hideFaceTimeOverlay(callUuid);
        if (GetIt.I.isRegistered<MethodChannelService>()) {
          await MethodChannelSvc.actions.openCallingAccounts();
        }
        showSnackbar(
          "Enable Calling Accounts",
          effectiveTelephony
              ? "Turn on BlueBubbles in Calling Accounts to answer iPhone calls."
              : "Turn on BlueBubbles in Calling Accounts to answer FaceTime Audio calls.",
          type: SnackbarType.info,
        );
        return;
      }
      if (!matchesPrev) {
        controller.setConnecting(
          callUuid: callUuid,
          callerName: callerName,
          callerAddress: callerAddress,
          avatarBytes: avatarBytes,
          isVideo: false,
          isTelephony: effectiveTelephony,
          chatGuid: chatGuid,
        );
      }
      await controller.answerCall(audioOnly: true, context: Get.context);
      return;
    }

    if (!matchesPrev) {
      controller.setConnecting(
        callUuid: callUuid,
        callerName: callerName,
        callerAddress: callerAddress,
        avatarBytes: avatarBytes,
        isVideo: !audioOnly && wasVideo,
        isTelephony: effectiveTelephony,
        chatGuid: chatGuid,
      );
    }
    await controller.answerCall(
      audioOnly: audioOnly || !wasVideo,
      context: Get.context,
    );
  }

  Future<void> openChat(String? guid,
      {String? text, List<PlatformFile> attachments = const [], required bool isInitialIntent}) async {
    Logger.info("Handling open chat intent with guid: $guid", tag: "IntentsService");

    if (guid == null) {
      Logger.debug("Opening new chat creator..", tag: "IntentsService");
      await StartupTasks.waitForUI();
      final ctx = Get.context;
      if (ctx == null) return;
      NavigationSvc.pushAndRemoveUntil(
        ctx,
        NewChatCreator(
          initialAttachments: attachments,
          initialText: text,
        ),
        (route) => route.isFirst,
      );
    } else if (guid == "-1") {
      Logger.debug("Popping all routes...", tag: "IntentsService");
      await StartupTasks.waitForUI();
      if (ChatsSvc.activeChat != null) {
        NavigationSvc.closeSections();
        final ctx = Get.context;
        if (ctx != null) {
          NavigationSvc.closeAllConversationView(ctx);
        }
        await ChatsSvc.setAllInactive();
      }
    } else if (guid == "-2") {
      Logger.debug("Opening server management panel...", tag: "IntentsService");
      await StartupTasks.waitForUI();
      NavigationSvc.openSettings(initialPage: ServerManagementPanel());
    } else if (guid.contains("scheduled")) {
      Logger.debug("Opening scheduled messages panel...", tag: "IntentsService");
      await StartupTasks.waitForUI();
      NavigationSvc.openSettings(initialPage: const ScheduledMessagesPanel());
    } else {
      Logger.debug("Opening existing chat (Attachments: ${attachments.length}; Text: ${text?.shorten(10) ?? 'N/A'})",
          tag: "IntentsService");
      final chat = Chat.findOne(guid: guid);
      if (chat == null) {
        Logger.debug("Chat not found with guid: $guid", tag: "IntentsService");
        return;
      }

      // Mark the navigation as pending BEFORE waitForUI() so onAppResume can see
      // we are about to switch chats and must not mark the old chat read prematurely.
      pendingOpenChatGuid = guid;
      try {
        await StartupTasks.waitForUI();

        // On the initial-intent path the widget tree is starting fresh (see the
        // comment in init()), so activeChat may be a stale leftover from before the
        // Activity was torn down — always navigate explicitly in that case rather
        // than trusting it to already reflect what's on screen.
        bool chatIsOpen = !isInitialIntent && ChatsSvc.activeChat?.chat.guid == guid;
        Logger.debug("Chat is active: $chatIsOpen", tag: "IntentsService");

        setPickedAttachments() {
          if (attachments.isNotEmpty) {
            cvc(chat).pickedAttachments.value = attachments;
          }

          if (text != null && text.isNotEmpty) {
            cvc(chat).textController.text = text;
          }
        }

        if (!chatIsOpen) {
          Logger.debug("Navigating to conversation view...", tag: "IntentsService");

          // Rather than waiting for paging to eventually reach this chat,
          // proactively seed its ChatState now. getOrCreateChatState() inserts
          // a fully valid ChatState immediately and is a no-op if the batch
          // loader already added it.
          ChatsSvc.getOrCreateChatState(chat);

          // Pre-populate text/attachments on the controller before navigating so
          // the ConversationView text field is pre-filled on first build.
          setPickedAttachments();

          final ctx = Get.context;
          if (ctx != null) {
            await NavigationSvc.pushAndRemoveUntil(
              ctx,
              ConversationView(chat: chat),
              (route) => route.isFirst,
            );
          }
        } else {
          Logger.debug("Chat is already open, not navigating", tag: "IntentsService");
          // It may still be open under Settings or Find My: bring it back into view
          NavigationSvc.closeSections();
          setPickedAttachments();
        }
      } finally {
        if (pendingOpenChatGuid == guid) {
          pendingOpenChatGuid = null;
        }
      }
    }
  }
}
