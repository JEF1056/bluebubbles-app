import 'package:universal_io/io.dart' as io;
import 'package:bluebubbles/helpers/backend/settings_helpers.dart';
import 'package:bluebubbles/platform/shims/firebase_rtdb.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart' hide Response;
import 'package:bluebubbles/database/models.dart';

FirebaseDatabaseService fdb = Get.isRegistered<FirebaseDatabaseService>()
    ? Get.find<FirebaseDatabaseService>()
    : Get.put(FirebaseDatabaseService());

const String _kConfiguredGoogleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

@visibleForTesting
String? resolveGoogleWebClientId({
  String configuredClientId = _kConfiguredGoogleWebClientId,
  bool debug = kDebugMode,
  String? webOrigin,
}) {
  final trimmed = configuredClientId.trim();
  if (trimmed.isNotEmpty) return trimmed;
  if (debug) {
    return '500464701389-5u2eogcqls1eljhu3hq825oed6iue1f0.apps.googleusercontent.com';
  }
  final origin = webOrigin ?? Uri.base.toString();
  if (origin.contains('tneotia.github.io')) {
    return '500464701389-5u2eogcqls1eljhu3hq825oed6iue1f0.apps.googleusercontent.com';
  }
  if (origin.contains('app.bluebubbles.app')) {
    return '500464701389-8trcdkcj7ni5l4dn6n7l795rhb1asnh3.apps.googleusercontent.com';
  }
  return null;
}

class FirebaseDatabaseService extends GetxService {
  @override
  void onInit() {
    super.onInit();
    if (kIsDesktop || kIsWeb) {
      setupFirebaseRtdb();
    }
  }

  String? getClientId() {
    if (kIsWeb) return resolveGoogleWebClientId();
    if (kIsDesktop) return '500464701389-18rfq995s6dqo3e5d3n2e7i3ljr0uc9i.apps.googleusercontent.com';
    return null;
  }

  String? getServerClientId() {
    if (!kIsWeb && io.Platform.isAndroid) {
      return '500464701389-8trcdkcj7ni5l4dn6n7l795rhb1asnh3.apps.googleusercontent.com';
    }
    return null;
  }

  /// Installed-app OAuth client used by Desktop and by self-signed Android forks
  /// when Play Services rejects the custom signing SHA-1.
  String getLoopbackOAuthClientId() {
    return '500464701389-18rfq995s6dqo3e5d3n2e7i3ljr0uc9i.apps.googleusercontent.com';
  }

  Future<bool> fetchFirebaseConfig() async {
    try {
      final response = await HttpSvc.fcm.getServiceAccount();
      Map<String, dynamic>? data = response.data["data"];
      if (!isNullOrEmpty(data)) {
        FCMData newData = FCMData.fromMap(data!);
        await SettingsSvc.saveFCMData(newData);
      }
    } catch (e, s) {
      Logger.error("Failed to fetch Firebase Config!", error: e, trace: s);
      final statusCode = e is DioException ? e.response?.statusCode : (e is Response ? e.statusCode : null);
      if (statusCode == 404) {
        await FCMData.deleteFcmData();
      }

      return false;
    }

    return true;
  }

  /// Fetch the new server URL from the Firebase Database
  ///
  /// The fetched URL is always saved with `force: true`, which restarts the socket
  /// as a side effect. Callers that restart the socket themselves should pass
  /// [restartSocket] as false so the connection isn't torn down twice in a row.
  Future<String?> fetchNewUrl({bool restartSocket = true}) async {
    // Make sure setup is complete and we have valid data
    if (!SettingsSvc.settings.finishedSetup.value) return null;
    if (SettingsSvc.fcmData.isNull) {
      Logger.error("Firebase Data was null when fetching new URL!");
      return null;
    }

    try {
      String? url;
      Logger.info("Fetching new server URL from Firebase");
      // Use firebase_dart on desktop and REST fallback on web
      if (kIsWeb || kIsDesktop) {
        final rawUrl = await fetchFirebaseServerUrl(
          apiKey: SettingsSvc.fcmData.apiKey ?? '',
          appId: SettingsSvc.fcmData.applicationID ?? '',
          projectId: SettingsSvc.fcmData.projectID ?? '',
          databaseUrl: SettingsSvc.fcmData.firebaseURL,
        );
        if (rawUrl != null) {
          url = sanitizeServerAddress(address: rawUrl);
        }
      } else {
        // First, try to auth with FCM with the current data
        Logger.info('Authenticating with FCM', tag: 'FCM-Auth');
        await MethodChannelSvc.actions.firebaseAuth(fcmData: SettingsSvc.fcmData.toMap());
        url = sanitizeServerAddress(address: await MethodChannelSvc.actions.getServerUrl());
      }

      await saveNewServerUrl(url ?? SettingsSvc.settings.serverAddress.value,
          force: true, restartSocket: restartSocket);
      return url;
    } catch (e, s) {
      Logger.error("Failed to fetch URL!", error: e, trace: s);
      return null;
    }
  }
}
