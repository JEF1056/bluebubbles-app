import 'package:bluebubbles/database/html/objectbox.dart';
import 'package:bluebubbles/services/services.dart';

class FCMData {
  int? id;
  String? projectID;
  String? storageBucket;
  String? apiKey;
  String? firebaseURL;
  String? clientID;
  String? applicationID;

  FCMData({
    this.id,
    this.projectID,
    this.storageBucket,
    this.apiKey,
    this.firebaseURL,
    this.clientID,
    this.applicationID,
  });

  factory FCMData.fromMap(Map<String, dynamic> json) {
    Map<String, dynamic> projectInfo = json["project_info"];
    Map<String, dynamic> client = json["client"][0];
    String clientID = client["oauth_client"][0]["client_id"];
    return FCMData(
      projectID: projectInfo["project_id"],
      storageBucket: projectInfo["storage_bucket"],
      apiKey: client["api_key"][0]["current_key"],
      firebaseURL: projectInfo["firebase_url"],
      clientID: clientID.contains("-") ? clientID.substring(0, clientID.indexOf("-")) : clientID,
      applicationID: client["client_info"]["mobilesdk_app_id"],
    );
  }

  Future<FCMData> save({bool wait = false}) async {
    if (isNull) return this;
    final List<FCMData> data = HtmlDatabase.fcmData.getAll();
    if (data.length > 1) data.removeRange(1, data.length);
    id = !HtmlDatabase.fcmData.isEmpty() ? data.first.id : null;
    HtmlDatabase.fcmData.put(this);
    final future = PrefsSvc.firebase.saveConfig(
      projectID: projectID,
      storageBucket: storageBucket,
      apiKey: apiKey,
      firebaseURL: firebaseURL,
      clientID: clientID,
      applicationID: applicationID,
    );
    if (wait) {
      await future;
    } else {
      Future.delayed(Duration.zero, () async => await future);
    }
    // On Dart VM tests, SettingsSvc.fcmData resolves to io/FCMData while on Web it resolves to html/FCMData.
    (SettingsSvc as dynamic).fcmData = this;
    return this;
  }

  static Future<void> deleteFcmData() async {
    HtmlDatabase.fcmData.removeAll();
    await PrefsSvc.firebase.clearConfig();
    (SettingsSvc as dynamic).fcmData = FCMData();
  }

  static FCMData getFCM() {
    final result = HtmlDatabase.fcmData.getAll();
    if (result.isEmpty) {
      return FCMData(
        projectID: PrefsSvc.firebase.getProjectID(),
        storageBucket: PrefsSvc.firebase.getStorageBucket(),
        apiKey: PrefsSvc.firebase.getApiKey(),
        firebaseURL: PrefsSvc.firebase.getFirebaseURL(),
        clientID: PrefsSvc.firebase.getClientID(),
        applicationID: PrefsSvc.firebase.getApplicationID(),
      );
    }
    return result.first;
  }

  Map<String, dynamic> toMap() => {
        "project_id": projectID,
        "storage_bucket": storageBucket,
        "api_key": apiKey,
        "firebase_url": firebaseURL,
        "client_id": clientID,
        "application_id": applicationID,
      };

  bool get isNull =>
      projectID == null || storageBucket == null || apiKey == null || clientID == null || applicationID == null;
}
