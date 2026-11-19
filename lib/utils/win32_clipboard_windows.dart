import 'package:ffi/ffi.dart';
import 'dart:ffi';
import 'package:universal_io/io.dart';
import 'package:win32/win32.dart' show GetClipboardOwner, GetCurrentProcessId, GetWindowThreadProcessId;

bool clipboardFromElsewhere() {
  if (!Platform.isWindows) return false;
  final owner = GetClipboardOwner().value;
  if (owner.address == 0) return false;
  return using((arena) {
    final pid = arena<Uint32>();
    GetWindowThreadProcessId(owner, pid);
    return pid.value != GetCurrentProcessId();
  });
}
