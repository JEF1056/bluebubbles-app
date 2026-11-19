import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/components/facetime/outgoing_facetime_sheet.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

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

/// Whether the details page offers to FaceTime this chat through the server's Mac: a 1:1 iMessage chat, on a
/// supported server, with the Private API on. Groups aren't offered: the server dials every address as one 1:1 request.
bool canFaceTime(Chat chat) =>
    SettingsSvc.getServerDetails().supportsFaceTimeCalls &&
    SettingsSvc.settings.enablePrivateAPI.value &&
    !chat.isGroup &&
    chat.isIMessage &&
    chat.handles.isNotEmpty &&
    !(chat.chatIdentifier?.startsWith("urn:biz") ?? false);

/// Starts a FaceTime call using a sleek bottom sheet for Video/Audio selection,
/// inline Android Telecom setup, connecting state, and error recovery.
Future<void> startFaceTimeCall(
  BuildContext context,
  Chat chat, {
  bool? video,
  bool isTelephony = false,
}) async {
  if (chat.handles.isEmpty) return;
  final handle = chat.handles.first;
  final address = handle.address;
  final callerName = chat.getTitle();

  Uint8List? avatarBytes;
  if (GetIt.I.isRegistered<ContactServiceV2>()) {
    try {
      final contact = ContactsSvcV2.findContactForAddressSync(address) ?? await ContactsSvcV2.getContact(address);
      if (contact?.avatarPath != null) {
        avatarBytes = await ContactsSvcV2.getContactAvatar(contact!.nativeContactId);
      }
    } catch (_) {}
  }

  if (!context.mounted) return;
  final rootNav = Navigator.of(context, rootNavigator: true);
  final reducedMotion = facetimeReducedMotionOf(context);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
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
      ),
      onOpenJoinLink: (link) => openFaceTimeJoinLink(
        link,
        context: rootNav.mounted ? rootNav.context : null,
      ),
      onHangUpRingingCall: (callUuid) async {
        try {
          await HttpSvc.faceTime.leave(callUuid);
        } catch (e, s) {
          Logger.warn("Failed to hang up FaceTime call", error: e, trace: s, tag: 'FaceTime');
          showSnackbar("FaceTime", "Couldn't hang up the call", type: SnackbarType.error);
        }
      },
    ),
  );
}
