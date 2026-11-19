import 'dart:async';

import 'package:bluebubbles/app/components/facetime/active_call_controller.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:bluebubbles/app/components/facetime/incoming_facetime_screen.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/intents_service.dart';
import 'package:bluebubbles/services/backend/notifications/notifications_service.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:faker/faker.dart' hide Image;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

Map<String, Route> faceTimeOverlays = {}; // Map from call uuid to overlay route

/// Hides the FaceTime overlay with the given [callUuid].
/// Also calls [NotificationsService.clearFaceTimeNotification] to clear the notification.
void hideFaceTimeOverlay(String callUuid, {bool keepCallState = false}) {
  if (GetIt.I.isRegistered<NotificationsService>()) {
    NotificationsSvc.clearFaceTimeNotification(callUuid);
  }
  if (!keepCallState && ActiveCallController.instance.state.callUuid == callUuid) {
    ActiveCallController.instance.clear();
  }
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
  final route = RawDialogRoute<void>(
    barrierDismissible: false,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: transitionDuration,
    pageBuilder: pageBuilder,
    transitionBuilder: transitionBuilder,
  );
  // Record synchronously so immediate calls to showFaceTimeConnectingOverlay/hideFaceTimeOverlay see it before frame 1.
  faceTimeOverlays[callUuid] = route;
  unawaited(
    navigator.push(route).then((_) {
      if (faceTimeOverlays[callUuid] == route) {
        faceTimeOverlays.remove(callUuid);
      }
    }),
  );
}

/// Shows a full-bleed frosted FaceTime overlay for an incoming call.
/// Saves the overlay route in [faceTimeOverlays].
Future<void> showFaceTimeOverlay(
  String callUuid,
  String caller,
  Uint8List? chatIcon,
  bool isAudio, {
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

  final targetContext = context ?? Get.context;
  if (targetContext == null) return;

  // If we are somehow already showing an overlay for this call, close it first.
  hideFaceTimeOverlay(callUuid);

  final callController = controller ?? ActiveCallController.instance;
  callController.startIncoming(
    callUuid: callUuid,
    callerName: displayCaller,
    avatarBytes: avatarBytes,
    isVideo: !isAudio,
  );

  final reducedMotion = facetimeReducedMotionOf(targetContext);
  _pushFaceTimeRoute(
    targetContext: targetContext,
    callUuid: callUuid,
    barrierLabel: 'Incoming FaceTime Call',
    transitionDuration: reducedMotion ? Duration.zero : const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, animation, secondaryAnimation) => IncomingFaceTimeScreen(
      callUuid: callUuid,
      callerName: displayCaller,
      avatarBytes: avatarBytes,
      isAudio: isAudio,
      controller: callController,
      onAnswerVideo: () => IntentsSvc.answerFaceTime(callUuid),
      onAnswerAudio: () => IntentsSvc.answerFaceTime(callUuid, audioOnly: true),
      onDecline: () => hideFaceTimeOverlay(callUuid),
      onCancelConnecting: () => hideFaceTimeOverlay(callUuid),
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

/// Transitions an existing FaceTime overlay into the connecting state, or shows
/// a sleek frosted connecting overlay when answered from a notification/intent.
Future<void> showFaceTimeConnectingOverlay(
  String callUuid, {
  String? caller,
  Uint8List? chatIcon,
  bool isAudio = false,
  BuildContext? context,
  ActiveCallController? controller,
}) async {
  final callController = controller ?? ActiveCallController.instance;
  callController.setConnecting(
    callUuid: callUuid,
    callerName: caller,
    avatarBytes: chatIcon,
    isVideo: !isAudio,
  );

  // If the incoming screen is already visible for this call, it updates in-place.
  if (faceTimeOverlays.containsKey(callUuid)) return;

  final targetContext = context ?? Get.context;
  if (targetContext == null) return;

  final state = callController.state;
  final reducedMotion = facetimeReducedMotionOf(targetContext);
  _pushFaceTimeRoute(
    targetContext: targetContext,
    callUuid: callUuid,
    barrierLabel: 'Connecting FaceTime Call',
    transitionDuration: reducedMotion ? Duration.zero : const Duration(milliseconds: 200),
    pageBuilder: (dialogContext, animation, secondaryAnimation) => IncomingFaceTimeScreen(
      callUuid: callUuid,
      callerName: state.callerName.isNotEmpty ? state.callerName : (caller ?? 'FaceTime Call'),
      avatarBytes: state.avatarBytes ?? chatIcon,
      isAudio: isAudio,
      isConnecting: true,
      controller: callController,
      onCancelConnecting: () => hideFaceTimeOverlay(callUuid),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      if (reducedMotion) return child;
      return FadeTransition(opacity: animation, child: child);
    },
  );
}
