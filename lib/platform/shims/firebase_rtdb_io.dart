import 'package:firebase_dart/firebase_dart.dart';
import 'package:firebase_dart/implementation/pure_dart.dart';
import 'package:firebase_dart/src/firestore.dart' show FirebaseFirestore;

void setupFirebaseRtdb() {
  FirebaseDart.setup(
    platform: Platform.web(
      currentUrl: Uri.base.toString(),
      isMobile: false,
      isOnline: true,
    ),
  );
}

const Duration _rtdbTimeout = Duration(seconds: 15);

Future<String?> fetchFirebaseServerUrl({
  required String apiKey,
  required String appId,
  required String projectId,
  String? databaseUrl,
}) async {
  final options = FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: '',
    projectId: projectId,
    databaseURL: databaseUrl,
  );
  final app = Firebase.apps.isEmpty
      ? await Firebase.initializeApp(options: options)
      : Firebase.apps.first;

  if (databaseUrl != null && databaseUrl.isNotEmpty) {
    final db = FirebaseDatabase(app: app);
    try {
      // Cached Repo stays interrupted after goOffline(); resume before reading.
      await db.goOnline();
      final event = await db.reference().child('config').child('serverUrl').onValue.first.timeout(_rtdbTimeout);
      return event.snapshot.value?.toString();
    } finally {
      await db.goOffline();
    }
  }
  final db = FirebaseFirestore.instanceFor(app: app);
  final doc = await db.collection('server').doc('config').get().timeout(_rtdbTimeout);
  return doc.data()?['serverUrl']?.toString();
}

Future<void> setFirebaseNextRestart({
  required String databaseUrl,
  required int timestampMs,
}) async {
  final db = FirebaseDatabase(databaseURL: databaseUrl);
  try {
    await db.goOnline();
    await db.reference().child('config').child('nextRestart').set(timestampMs).timeout(_rtdbTimeout);
  } finally {
    await db.goOffline();
  }
}
