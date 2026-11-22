import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:universal_io/io.dart';
import 'package:flutter_user_certificates_android/flutter_user_certificates_android.dart';

class UserCertificates {
  // Cached so that SecurityContext.defaultContext is only mutated once.
  // Calling setTrustedCertificatesBytes() twice with the same cert throws a
  // TlsException, which would abort every socket reconnect attempt.
  static SecurityContext? _cache;
  static Future<SecurityContext?>? _pending;

  Future<SecurityContext?> getContext() {
    if (_cache != null) return Future.value(_cache);
    return _pending ??= _loadContext();
  }

  Future<SecurityContext?> _loadContext() async {
    // Non-Android platforms (and Web, where universal_io checks userAgent) use the system cert store as-is.
    if (kIsWeb || !Platform.isAndroid) {
      return null;
    }

    try {
      final certs = await FlutterUserCertificatesAndroid().getUserCertificates();

      // No user-installed certs — nothing to add.
      if (certs == null || certs.isEmpty) {
        return null;
      }

      // Mutate defaultContext once and cache it.
      final ctx = SecurityContext.defaultContext;
      for (final c in certs.entries) {
        try {
          ctx.setTrustedCertificatesBytes(utf8.encode(c.value.toPEM()));
        } catch (_) {
          // Skip invalid or already-trusted certificates rather than aborting all certs.
        }
      }

      _cache = ctx;
      return _cache;
    } catch (_) {
      // Clear memoized future on plugin failure so a transient error can be retried.
      _pending = null;
      return null;
    }
  }
}
