import 'dart:async';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/components/facetime/in_app_call_screen.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/app/components/facetime/web_ringtone.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/intents_service.dart';
import 'package:bluebubbles/services/backend/notifications/notifications_service.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:faker/faker.dart' hide Image;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class FaceTimeIncomingActions {
  const FaceTimeIncomingActions({
    required this.callerName,
    this.avatarBytes,
    required this.isAudio,
    required this.isTelephony,
    this.onAnswerVideo,
    required this.onAnswerAudio,
    required this.onDecline,
    required this.onCancelConnecting,
  });

  final String callerName;
  final Uint8List? avatarBytes;
  final bool isAudio;
  final bool isTelephony;
  final VoidCallback? onAnswerVideo;
  final VoidCallback onAnswerAudio;
  final VoidCallback onDecline;
  final VoidCallback onCancelConnecting;
}

/// Active FaceTime incoming overlays keyed by `callUuid`.
/// A `null` route means the non-modal Continuity banner is active in the app shell;
/// a non-null [Route] means the full-screen [IncomingFaceTimeScreen] is open.
Map<String, Route?> faceTimeOverlays = {};
final Map<String, FaceTimeIncomingActions> faceTimeIncomingActions = {};

/// Active full-screen [InAppCallScreen] route when expanded from [OngoingCallPillOverlay].
Route<void>? activeInAppCallRoute;

/// Dismisses the expanded [InAppCallScreen] route if currently active.
void hideInAppCallScreen() {
  final route = activeInAppCallRoute;
  activeInAppCallRoute = null;
  if (route != null && route.isActive) {
    route.navigator?.removeRoute(route);
  }
}

/// Opens the full-screen [InAppCallScreen] without duplicating route stacks.
void openInAppCallScreen({
  BuildContext? context,
  ActiveCallController? controller,
  Widget? videoView,
  Future<bool> Function(bool enabled)? onToggleSpeaker,
  bool initialSpeakerOn = false,
}) {
  final existingRoute = activeInAppCallRoute;
  if (existingRoute != null &&
      existingRoute.isActive &&
      (existingRoute.navigator?.mounted ?? false)) {
    return;
  }

  final targetContext = context ?? Get.context;
  if (targetContext == null) return;

  final callController = controller ?? ActiveCallController.instance;
  if (callController.state.phase == ActiveCallPhase.idle) return;

  final reducedMotion = facetimeReducedMotionOf(targetContext);
  final navigator = Navigator.of(targetContext, rootNavigator: true);
  final themes = InheritedTheme.capture(
    from: targetContext,
    to: navigator.context,
  );
  final route = RawDialogRoute<void>(
    barrierDismissible: false,
    barrierLabel: 'In-app call screen',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: reducedMotion ? Duration.zero : const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, animation, secondaryAnimation) => themes.wrap(
      Builder(
        builder: (themedContext) => InAppCallScreen(
          controller: callController,
          videoView: videoView,
          onToggleSpeaker: onToggleSpeaker,
          initialSpeakerOn: initialSpeakerOn,
          onMinimize: () => Navigator.of(themedContext).maybePop(),
        ),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      if (reducedMotion) return child;
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
  activeInAppCallRoute = route;
  unawaited(
    navigator.push(route).then((_) {
      if (identical(activeInAppCallRoute, route)) {
        activeInAppCallRoute = null;
      }
    }),
  );
}

/// Hides the FaceTime overlay with the given [callUuid].
/// Also calls [NotificationsService.clearFaceTimeNotification] to clear the notification.
void hideFaceTimeOverlay(String callUuid, {bool keepCallState = false}) {
  if (kIsWeb) {
    stopWebFaceTimeRingtone(callUuid: callUuid);
  }
  if (GetIt.I.isRegistered<NotificationsService>()) {
    NotificationsSvc.clearFaceTimeNotification(callUuid, onlyIfRinging: keepCallState);
  }
  if (!keepCallState && ActiveCallController.instance.state.callUuid == callUuid) {
    ActiveCallController.instance.clear();
  }
  faceTimeIncomingActions.remove(callUuid);
  final route = faceTimeOverlays.remove(callUuid);
  if (route != null && route.isActive) {
    route.navigator?.removeRoute(route);
  }
}

void _pushFaceTimeRoute({
  required BuildContext targetContext,
  required String callUuid,
  required String barrierLabel,
  required Duration transitionDuration,
  required RoutePageBuilder pageBuilder,
  required RouteTransitionsBuilder transitionBuilder,
}) {
  final navigator = Navigator.of(targetContext, rootNavigator: true);
  final themes = InheritedTheme.capture(
    from: targetContext,
    to: navigator.context,
  );
  final route = RawDialogRoute<void>(
    barrierDismissible: false,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: transitionDuration,
    pageBuilder: (dialogContext, animation, secondaryAnimation) => themes.wrap(
      Builder(
        builder: (themedContext) => pageBuilder(themedContext, animation, secondaryAnimation),
      ),
    ),
    transitionBuilder: transitionBuilder,
  );
  faceTimeOverlays[callUuid] = route;
  unawaited(
    navigator.push(route).then((_) {
      if (faceTimeOverlays[callUuid] == route) {
        faceTimeOverlays[callUuid] = null;
      }
    }),
  );
}

/// Opens the full-screen [IncomingFaceTimeScreen] for an active incoming call
/// when the user taps the non-modal Continuity banner.
void openIncomingFaceTimeScreen(
  String callUuid, {
  BuildContext? context,
  ActiveCallController? controller,
}) {
  final existingRoute = faceTimeOverlays[callUuid];
  if (existingRoute != null && existingRoute.isActive) return;

  final targetContext = context ?? Get.context;
  if (targetContext == null) return;

  final callController = controller ?? ActiveCallController.instance;
  final state = callController.state;
  final actions = faceTimeIncomingActions[callUuid];
  final displayCaller = actions?.callerName ??
      (state.callerName.isNotEmpty ? state.callerName : (state.isTelephony ? 'iPhone Call' : 'FaceTime Call'));
  final avatarBytes = actions?.avatarBytes ?? state.avatarBytes;
  final isTelephony = actions?.isTelephony ?? state.isTelephony;
  final isAudio = actions?.isAudio ?? (!state.isVideo || isTelephony);
  final reducedMotion = facetimeReducedMotionOf(targetContext);

  _pushFaceTimeRoute(
    targetContext: targetContext,
    callUuid: callUuid,
    barrierLabel: isTelephony ? 'Incoming iPhone Call' : 'Incoming FaceTime Call',
    transitionDuration: reducedMotion ? Duration.zero : const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, animation, secondaryAnimation) => IncomingFaceTimeScreen(
      callUuid: callUuid,
      callerName: displayCaller,
      avatarBytes: avatarBytes,
      isAudio: isAudio,
      isTelephony: isTelephony,
      controller: callController,
      onAnswerVideo: actions?.onAnswerVideo ??
          (isTelephony ? null : () => unawaited(callController.answerCall(audioOnly: false, context: dialogContext))),
      onAnswerAudio: actions?.onAnswerAudio ??
          () => unawaited(callController.answerCall(audioOnly: true, context: dialogContext)),
      onDecline: actions?.onDecline ??
          () {
            unawaited(callController.declineCall());
            hideFaceTimeOverlay(callUuid);
          },
      onCancelConnecting: actions?.onCancelConnecting ??
          () {
            unawaited(callController.endCall());
            hideFaceTimeOverlay(callUuid);
          },
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      if (reducedMotion) return child;
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Shows a non-modal iOS/macOS Continuity incoming call banner in the app shell
/// (keeping chat usable underneath) and registers [callUuid] in [faceTimeOverlays].
Future<void> showFaceTimeOverlay(
  String callUuid,
  String caller,
  Uint8List? chatIcon,
  bool isAudio, {
  String? callerAddress,
  bool isTelephony = false,
  BuildContext? context,
  ActiveCallController? controller,
}) async {
  Uint8List? avatarBytes = chatIcon;
  var displayCaller = caller;
  if (GetIt.I.isRegistered<SettingsService>() &&
      SettingsSvc.settings.redactedMode.value &&
      SettingsSvc.settings.hideContactInfo.value) {
    avatarBytes = null;
    displayCaller = faker.person.name();
  }

  // If we are somehow already showing an overlay for this call, close it first.
  if (faceTimeOverlays.containsKey(callUuid)) {
    hideFaceTimeOverlay(callUuid);
  }

  final callController = controller ?? ActiveCallController.instance;
  callController.startIncoming(
    callUuid: callUuid,
    callerName: displayCaller,
    callerAddress: callerAddress,
    avatarBytes: avatarBytes,
    isVideo: !isAudio && !isTelephony,
    isTelephony: isTelephony,
  );

  faceTimeIncomingActions[callUuid] = FaceTimeIncomingActions(
    callerName: displayCaller,
    avatarBytes: avatarBytes,
    isAudio: isAudio || isTelephony,
    isTelephony: isTelephony,
    onAnswerVideo: isTelephony
        ? null
        : () {
            if (GetIt.I.isRegistered<IntentsService>()) {
              IntentsSvc.answerFaceTime(callUuid);
            } else {
              unawaited(callController.answerCall(audioOnly: false, context: context ?? Get.context));
            }
          },
    onAnswerAudio: () {
      if (GetIt.I.isRegistered<IntentsService>()) {
        IntentsSvc.answerFaceTime(callUuid, audioOnly: true, isTelephony: isTelephony);
      } else {
        unawaited(callController.answerCall(audioOnly: true, context: context ?? Get.context));
      }
    },
    onDecline: () {
      unawaited(callController.declineCall());
      hideFaceTimeOverlay(callUuid);
    },
    onCancelConnecting: () {
      unawaited(callController.endCall());
      hideFaceTimeOverlay(callUuid);
    },
  );
  // Register synchronously without blocking the UI with a modal dialog.
  faceTimeOverlays[callUuid] = null;
}

/// Transitions an existing FaceTime call into the connecting state.
/// Updates [IncomingFaceTimeScreen] in-place if open, or keeps the integrated top bar non-blocking.
Future<void> showFaceTimeConnectingOverlay(
  String callUuid, {
  String? caller,
  Uint8List? chatIcon,
  bool isAudio = false,
  bool isTelephony = false,
  BuildContext? context,
  ActiveCallController? controller,
}) async {
  final callController = controller ?? ActiveCallController.instance;
  callController.setConnecting(
    callUuid: callUuid,
    callerName: caller,
    avatarBytes: chatIcon,
    isVideo: !isAudio && !isTelephony,
    isTelephony: isTelephony,
  );
  faceTimeOverlays.putIfAbsent(callUuid, () => null);
}
