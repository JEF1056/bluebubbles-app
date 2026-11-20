import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/components/facetime/outgoing_facetime_sheet.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/address_picker.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

/// Attempts to open a FaceTime join URL and returns whether the platform accepted it.
Future<bool> tryLaunchFaceTimeJoinLink(String link) async {
  final uri = Uri.tryParse(link);
  if (uri == null) {
    showSnackbar("FaceTime", "Invalid call link", type: SnackbarType.error);
    return false;
  }

  return launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
    webOnlyWindowName: kIsWeb ? '_blank' : null,
  );
}

/// Opens a FaceTime join URL. On Web, opens a new tab and offers a user-gesture
/// fallback bottom sheet if a browser popup blocker intercepts the post-await launch.
Future<void> openFaceTimeJoinLink(String link, {BuildContext? context}) async {
  final uri = Uri.tryParse(link);
  if (uri == null) {
    showSnackbar("FaceTime", "Invalid call link", type: SnackbarType.error);
    return;
  }

  final opened = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
    webOnlyWindowName: kIsWeb ? '_blank' : null,
  );
  if (opened) return;

  if (kIsWeb && context != null && context.mounted) {
    final reducedMotion = facetimeReducedMotionOf(context);
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      sheetAnimationStyle: reducedMotion ? AnimationStyle.noAnimation : null,
      builder: (sheetCtx) => FaceTimeJoinFallbackSheet(
        onCopyLink: () {
          Clipboard.setData(ClipboardData(text: link));
          Navigator.of(sheetCtx).pop();
          showSnackbar("FaceTime", "Copied call link");
        },
        onJoinCall: () {
          Navigator.of(sheetCtx).pop();
          launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
        },
      ),
    );
    return;
  }

  showSnackbar("FaceTime", "Couldn't open the call link", type: SnackbarType.error);
}

/// Whether [address] can be dialed via FaceTime through the server's Mac.
bool canFaceTimeAddress(String address) =>
    SettingsSvc.getServerDetails().supportsFaceTimeCalls &&
    SettingsSvc.settings.enablePrivateAPI.value &&
    address.trim().isNotEmpty &&
    !address.startsWith("urn:biz");

/// Whether the details page offers to FaceTime this chat through the server's Mac: a 1:1 iMessage chat, on a
/// supported server, with the Private API on. Groups aren't offered: the server dials every address as one 1:1 request.
bool canFaceTime(Chat chat) =>
    !chat.isGroup &&
    chat.isIMessage &&
    chat.handles.isNotEmpty &&
    !(chat.chatIdentifier?.startsWith("urn:biz") ?? false) &&
    canFaceTimeAddress(chat.handles.first.address);

/// Whether an SMS/RCS 1:1 chat can ring via Google Meet/Duo (Android or Web, dialable phone only).
bool canMeetVideoCall(Chat chat, {bool? isDesktop}) =>
    !(isDesktop ?? kIsDesktop) &&
    !chat.isGroup &&
    (chat.isSMS || chat.isRCS) &&
    !(chat.chatIdentifier?.startsWith("urn:biz") ?? false) &&
    chat.handles.isNotEmpty &&
    dialablePhonesForHandle(chat.handles.first).isNotEmpty;

/// Unified single Video button visibility: iMessage -> FaceTime only; SMS/RCS -> Meet/Duo.
bool canVideoCall(Chat chat, {bool? isDesktop}) {
  if (chat.isGroup || chat.handles.isEmpty || (chat.chatIdentifier?.startsWith("urn:biz") ?? false)) {
    return false;
  }
  if (chat.isIMessage) return canFaceTime(chat);
  if (chat.isSMS || chat.isRCS) return canMeetVideoCall(chat, isDesktop: isDesktop);
  return false;
}

/// Whether an audio call option (Phone SIM, FaceTime Audio, or iPhone Continuity) is available for [chat].
bool canAudioCall(Chat chat, {bool? isDesktop}) {
  if (chat.isGroup || chat.handles.isEmpty || (chat.chatIdentifier?.startsWith("urn:biz") ?? false)) {
    return false;
  }
  return canAudioCallHandle(chat, chat.handles.first, isDesktop: isDesktop);
}

/// Whether an audio call option is available for [handle] inside [chat].
bool canAudioCallHandle(Chat chat, Handle handle, {ContactV2? contact, bool? isDesktop}) {
  final desktop = isDesktop ?? kIsDesktop;
  final hasPhone = !desktop && dialablePhonesForHandle(handle, contact: contact).isNotEmpty;
  final hasFaceTime = chat.isIMessage && canFaceTimeAddress(handle.address);
  return hasPhone || hasFaceTime;
}

/// Unified Audio call launcher:
/// - Phone SIM only -> existing native `tel:` address picker (with `Permission.phone`).
/// - FaceTime Audio only (email/no phone) -> FaceTime Audio sheet directly.
/// - Multiple choices (Phone SIM + FaceTime Audio and/or iPhone Cellular Continuity) -> chooser sheet.
Future<void> startAudioCall(BuildContext context, Chat chat) async {
  if (chat.handles.isEmpty) return;
  await startAudioCallForHandle(
    context,
    chat,
    chat.handles.first,
    callerNameOverride: chat.getTitle(),
  );
}

Future<void> startAudioCallForHandle(
  BuildContext context,
  Chat chat,
  Handle handle, {
  ContactV2? contact,
  String? callerNameOverride,
}) async {
  final resolvedContact = contact ?? handle.contactsV2.firstOrNull;
  final hasPhone = !kIsDesktop && dialablePhonesForHandle(handle, contact: resolvedContact).isNotEmpty;
  final hasFaceTimeAudio = chat.isIMessage && canFaceTimeAddress(handle.address);
  final hasContinuity = !kIsDesktop &&
      !kIsWeb &&
      Platform.isAndroid &&
      hasPhone &&
      SettingsSvc.getServerDetails().supportsFaceTimeCalls &&
      SettingsSvc.settings.enablePrivateAPI.value;
  final callerName = callerNameOverride ?? (handle.displayName.isNotEmpty ? handle.displayName : handle.address);

  if (!hasFaceTimeAudio && !hasContinuity) {
    if (hasPhone) {
      showAddressPicker(resolvedContact, handle, context);
    }
    return;
  }

  if (!hasPhone && !hasContinuity && hasFaceTimeAudio) {
    await _startFaceTimeForHandle(context, handle: handle, callerName: callerName, video: false, chatGuid: chat.guid);
    return;
  }

  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasPhone)
            ListTile(
              leading: const Icon(Icons.phone_outlined),
              title: const Text('Phone (SIM)'),
              subtitle: const Text('Call using this device'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                showAddressPicker(resolvedContact, handle, context);
              },
            ),
          if (hasFaceTimeAudio)
            ListTile(
              leading: const Icon(Icons.record_voice_over_outlined),
              title: const Text('FaceTime Audio'),
              subtitle: const Text('Call via Mac FaceTime'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _startFaceTimeForHandle(context, handle: handle, callerName: callerName, video: false, chatGuid: chat.guid);
              },
            ),
          if (hasContinuity)
            ListTile(
              leading: const Icon(Icons.phone_iphone_outlined),
              title: const Text('iPhone Cellular (via Mac)'),
              subtitle: const Text('Relay cellular call through paired iPhone'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _startFaceTimeForHandle(
                  context,
                  handle: handle,
                  callerName: callerName,
                  video: false,
                  isTelephony: true,
                  chatGuid: chat.guid,
                );
              },
            ),
        ],
      ),
    ),
  );
}

/// Unified Video action visibility for an individual participant row.
bool canVideoCallHandle(Chat chat, Handle handle, {ContactV2? contact, bool? isDesktop}) {
  if (chat.isIMessage) return canFaceTimeAddress(handle.address);
  if (chat.isSMS || chat.isRCS) {
    return !(isDesktop ?? kIsDesktop) && dialablePhonesForHandle(handle, contact: contact).isNotEmpty;
  }
  return false;
}

/// Starts a unified Video call: iMessage -> FaceTime Video (long-press opens Video/Audio sheet);
/// SMS/RCS -> Google Meet/Duo.
Future<void> startVideoCall(
  BuildContext context,
  Chat chat, {
  bool isLongPressed = false,
}) async {
  if (chat.handles.isEmpty) return;
  if (chat.isIMessage) {
    if (!canFaceTime(chat)) return;
    await startFaceTimeCall(context, chat, video: isLongPressed ? null : true);
    return;
  }
  if (chat.isSMS || chat.isRCS) {
    if (!canMeetVideoCall(chat)) return;
    final handle = chat.handles.first;
    showAddressPicker(
      handle.contactsV2.firstOrNull,
      handle,
      context,
      video: true,
      isLongPressed: isLongPressed,
    );
  }
}

/// Starts a unified Video call for an individual participant in a chat.
Future<void> startVideoCallForHandle(
  BuildContext context,
  Chat chat,
  Handle handle, {
  ContactV2? contact,
  bool isLongPressed = false,
}) async {
  if (chat.isIMessage) {
    if (!canFaceTimeAddress(handle.address)) return;
    final callerName = handle.displayName.isNotEmpty ? handle.displayName : handle.address;
    await _startFaceTimeForHandle(
      context,
      handle: handle,
      callerName: callerName,
      video: isLongPressed ? null : true,
      chatGuid: chat.guid,
    );
    return;
  }
  if (chat.isSMS || chat.isRCS) {
    if (!canVideoCallHandle(chat, handle, contact: contact)) return;
    showAddressPicker(
      contact ?? handle.contactsV2.firstOrNull,
      handle,
      context,
      video: true,
      isLongPressed: isLongPressed,
    );
  }
}

/// Starts a FaceTime call using a sleek bottom sheet for Video/Audio selection,
/// inline Android Telecom setup, connecting state, and error recovery.
Future<void> startFaceTimeCall(
  BuildContext context,
  Chat chat, {
  bool? video,
  bool isTelephony = false,
}) async {
  if (chat.handles.isEmpty) return;
  await _startFaceTimeForHandle(
    context,
    handle: chat.handles.first,
    callerName: chat.getTitle(),
    video: video,
    isTelephony: isTelephony,
    chatGuid: chat.guid,
  );
}

Future<void> _startFaceTimeForHandle(
  BuildContext context, {
  required Handle handle,
  required String callerName,
  bool? video,
  bool isTelephony = false,
  String? chatGuid,
}) async {
  final address = handle.address;

  // Pre-open a blank tab synchronously on user tap before any await so Web
  // browsers preserve transient user activation when the server returns the join link.
  final PendingCallTab? pendingTab = (kIsWeb && video != null) ? openPendingCallTab() : null;

  Uint8List? avatarBytes;
  if (GetIt.I.isRegistered<ContactServiceV2>()) {
    try {
      final contact = ContactsSvcV2.findContactForAddressSync(address) ?? await ContactsSvcV2.getContact(address);
      if (contact?.avatarPath != null) {
        avatarBytes = await ContactsSvcV2.getContactAvatar(contact!.nativeContactId);
      }
    } catch (_) {}
  }

  if (!context.mounted) {
    pendingTab?.close();
    return;
  }
  final rootNav = Navigator.of(context, rootNavigator: true);
  final reducedMotion = facetimeReducedMotionOf(context);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: reducedMotion ? AnimationStyle.noAnimation : null,
    builder: (sheetContext) => OutgoingFaceTimeSheet(
      callerName: callerName,
      callerAddress: address,
      chatHandle: handle,
      avatarBytes: avatarBytes,
      initialVideo: video,
      isAndroid: !kIsWeb && Platform.isAndroid,
      isIOS: facetimeIsIOSSkin(),
      isTelephony: isTelephony,
      initialPendingTab: pendingTab,
      onPreOpenTab: kIsWeb ? openPendingCallTab : null,
      onTryOpenJoinLink: tryLaunchFaceTimeJoinLink,
      checkTelecomEnabled: () => MethodChannelSvc.actions.isTelecomEnabled(),
      onOpenCallingAccounts: () => MethodChannelSvc.actions.openCallingAccounts(),
      requestCallPermissions: () async {
        final permissions = await [
          Permission.microphone,
          Permission.phone,
          Permission.bluetoothConnect,
        ].request();
        return permissions[Permission.microphone] == PermissionStatus.granted &&
            permissions[Permission.phone] == PermissionStatus.granted;
      },
      onPlaceNativeAudioCall: () => MethodChannelSvc.actions.placeFaceTimeCall(
        address: address,
        callerName: callerName,
        isTelephony: isTelephony,
      ),
      onStartServerCall: (isVideo) => HttpSvc.faceTime.call(
        address,
        video: isVideo,
        isTelephony: isTelephony,
        displayName: callerName,
        chatGuid: chatGuid,
      ),
      onOpenJoinLink: (link) => openFaceTimeJoinLink(
        link,
        context: rootNav.mounted ? rootNav.context : null,
      ),
      onHangUpRingingCall: (callUuid) async {
        try {
          await HttpSvc.faceTime.leaveFaceTime(callUuid, displayName: callerName, chatGuid: chatGuid);
        } catch (e, s) {
          Logger.warn("Failed to hang up FaceTime call", error: e, trace: s, tag: 'FaceTime');
          showSnackbar("FaceTime", "Couldn't hang up the call", type: SnackbarType.error);
        }
      },
    ),
  );
}
