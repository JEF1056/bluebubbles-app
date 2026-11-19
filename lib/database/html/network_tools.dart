import 'dart:async';

Future<void> configureNetworkTools(String dbDirectory, {bool enableDebugging = false}) async {}

class HostScannerService {
  static final instance = HostScannerService();

  Stream<ActiveHost> scanDevicesForSinglePort(
    String subnet,
    int port, {
    int firstHostId = 1,
    int lastHostId = 254,
    Duration timeout = const Duration(milliseconds: 2000),
    dynamic progressCallback,
    bool resultsInAddressAscendingOrder = true,
  }) =>
      const Stream<ActiveHost>.empty();
}

class NetworkInfoPlusWindowsPlugin {
  Future<String?> getWifiIP() async => null;
  void closeHandle() {}
}

class ActiveHost {
  String address = "";
}
