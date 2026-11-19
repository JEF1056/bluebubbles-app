import 'env_io.dart' if (dart.library.js_interop) 'env_web.dart';
export 'env_io.dart' if (dart.library.js_interop) 'env_web.dart';

bool isIsolateOverride = false;
String? isolateNameOverride;
String? logNamePrefix;

bool get isIsolate {
  final name = getIsolateDebugName();
  return isIsolateOverride || (name != null && name != 'main');
}
