import 'dart:io' as dart_io show HttpClient;

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/network/user_certificates.dart';
import 'package:universal_io/io.dart';

/// Returns true only when [host] is an IP literal matching [serverHost].
/// Hostnames must present a platform-trusted certificate.
bool acceptsBadCertFor(String serverHost, String host) {
  final normalizedServer = serverHost.trim().toLowerCase();
  final normalizedHost = host.trim().toLowerCase();
  if (normalizedServer.isEmpty || normalizedServer != normalizedHost) return false;
  return InternetAddress.tryParse(normalizedHost) != null;
}

/// Shared certificate validation logic for both HTTP and WebSocket connections.
/// Returns true if the certificate should be accepted (override bad cert), false otherwise.
bool shouldAcceptCertificate(X509Certificate cert, String host, int port) {
  final serverHost = Uri.tryParse(sanitizeServerAddress() ?? "")?.host ?? "";
  return acceptsBadCertFor(serverHost, host);
}

class CustomHttpContext extends HttpOverrides {
  SecurityContext? _cachedContext;

  CustomHttpContext() {
    _initContext();
  }

  Future<void> _initContext() async {
    _cachedContext = await UserCertificates().getContext();
  }

  @override
  dart_io.HttpClient createHttpClient(SecurityContext? context) {
    // Use the cached context with system + user certs
    final client = super.createHttpClient(_cachedContext ?? context);

    // Add custom certificate validation for self-signed certs and hostname mismatches
    client.badCertificateCallback = shouldAcceptCertificate;

    return client;
  }
}
