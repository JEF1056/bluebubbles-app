import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/facetime.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

/// Whether the details page offers to FaceTime this chat through the server's Mac: a 1:1 iMessage chat, on a
/// supported server, with the Private API on. Groups aren't offered: the server dials every address as one 1:1 request.
bool canFaceTime(Chat chat) =>
    SettingsSvc.getServerDetails().supportsFaceTimeCalls &&
    SettingsSvc.settings.enablePrivateAPI.value &&
    !chat.isGroup &&
    chat.isIMessage &&
    chat.handles.isNotEmpty &&
    !(chat.chatIdentifier?.startsWith("urn:biz") ?? false);

/// Starts a FaceTime call: Video opens the server's web link; Audio on Android places a native Telecom call
/// through [FaceTimeConnectionService] when enabled.
Future<void> startFaceTimeCall(
  BuildContext context,
  Chat chat, {
  bool? video,
  bool isTelephony = false,
}) async {
  video ??= await showBBListSelector<bool>(
    context: context,
    title: "FaceTime",
    options: const [
      BBListSelectorOption(label: "Video", value: true),
      BBListSelectorOption(label: "Audio", value: false),
    ],
  );
  if (video == null || !context.mounted) return;

  final address = chat.handles.first.address;

  if (!video && Platform.isAndroid) {
    final permissions = await [
      Permission.microphone,
      Permission.phone,
      Permission.bluetoothConnect,
    ].request();
    if (permissions[Permission.microphone] != PermissionStatus.granted ||
        permissions[Permission.phone] != PermissionStatus.granted) {
      showSnackbar("FaceTime Audio", "Microphone and Phone permissions are required for calls", type: SnackbarType.error);
      return;
    }

    if (!await MethodChannelSvc.actions.isTelecomEnabled()) {
      if (!context.mounted) return;
      showBBDialog(
        context: context,
        title: "Enable Calling Account",
        body: "Turn on BlueBubbles FaceTime in Android Calling Accounts to place native FaceTime Audio calls.",
        actions: [
          BBDialogAction(text: "Cancel", onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
          BBDialogAction(
            text: "Open Settings",
            isDefault: true,
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              MethodChannelSvc.actions.openCallingAccounts();
            },
          ),
        ],
      );
      return;
    }

    final placedNative = await MethodChannelSvc.actions.placeFaceTimeCall(
      address: address,
      callerName: chat.getTitle(),
      isTelephony: isTelephony,
    );
    if (!placedNative) {
      showSnackbar("FaceTime Audio", "Couldn't start native call", type: SnackbarType.error);
    }
    return;
  }

  // The root navigator, not this page's context: the page may close while the Mac dials, and the progress dialog
  // and whatever follows it still need somewhere to go.
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => const PopScope(canPop: false, child: BBProgressDialog(title: "Calling…")),
  );

  PlacedFaceTimeCall? placed;
  FaceTimeException? refusal;
  try {
    placed = await HttpSvc.faceTime.call(address, video: video, isTelephony: isTelephony);
  } on FaceTimeException catch (e) {
    refusal = e;
  } catch (e, s) {
    Logger.warn("Failed to start FaceTime call", error: e, trace: s, tag: 'FaceTime');
    refusal = const FaceTimeException("Couldn't reach the server.");
  } finally {
    navigator.pop();
  }

  if (placed != null) {
    final link = placed.link;
    if (link == null || link.isEmpty) {
      showSnackbar("FaceTime", "Couldn't get a call link", type: SnackbarType.error);
      return;
    }
    final opened = await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    if (!opened) showSnackbar("FaceTime", "Couldn't open the call link", type: SnackbarType.error);
    return;
  }

  final ringing = refusal!.call;
  if (ringing == null) {
    if (!navigator.mounted) return;
    showBBDialog(
      context: navigator.context,
      title: "Couldn't Start FaceTime",
      body: refusal.message,
      actions: [BBDialogAction(text: "OK", onPressed: () => navigator.pop())],
    );
    return;
  }

  // Ringing with no way in: the only useful thing left is to stop it.
  if (!navigator.mounted) return;
  showBBDialog(
    context: navigator.context,
    title: "No Link to Join",
    body: "The call is ringing, but the server couldn't make a link to join it.",
    actions: [
      BBDialogAction(text: "Leave Ringing", onPressed: () => navigator.pop()),
      BBDialogAction(
        text: "Hang Up",
        isDestructive: true,
        isDefault: true,
        onPressed: () async {
          navigator.pop();
          try {
            await HttpSvc.faceTime.leave(ringing.callUuid);
          } catch (e, s) {
            Logger.warn("Failed to hang up FaceTime call", error: e, trace: s, tag: 'FaceTime');
            showSnackbar("FaceTime", "Couldn't hang up the call", type: SnackbarType.error);
          }
        },
      ),
    ],
  );
}
