import 'package:notebook_core/notebook_core.dart';

class HttpResponseData {
  const HttpResponseData({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

class OperationOutcome {
  const OperationOutcome({
    required this.ok,
    this.error,
    this.manualRequired = false,
  });

  final bool ok;
  final String? error;
  final bool manualRequired;
}

class HotspotStartOutcome {
  const HotspotStartOutcome({
    required this.ok,
    this.credentials,
    this.error,
  });

  final bool ok;
  final HotspotCredentials? credentials;
  final String? error;
}

abstract class PlatformAdapter {
  bool get isWeb;
  bool get canPickImage;
  bool get canScanQrCode;
  bool get canHostServer;
  bool get canDiscoverNearby;
  bool get canManageHotspot;

  Stream<NearbyBoardBeacon> get nearbyBeacons;

  String defaultWsUrl();
  String? initialRoomFromUrl();
  String defaultDeviceName();
  DeviceFormFactor defaultFormFactor(double shortestSideLogicalPixels);

  Future<String?> readLocalValue(String key);
  Future<void> writeLocalValue(String key, String value);

  Future<HttpResponseData?> httpGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 4),
  });
  Future<HttpResponseData?> httpPostJson(Uri uri, String jsonBody);

  Future<String?> pickImageAsDataUrl();
  Future<String?> scanQrCode();
  Future<String?> loadImagePathAsDataUrl(String filePath);
  Future<String?> saveExportFile(String filename, String content);

  Future<int?> startEmbeddedServer({int preferredPort = 8787});
  Future<void> stopEmbeddedServer();
  Future<List<String>> discoverLocalIps();

  Future<OperationOutcome> startNearbyDiscovery({bool enableBle = true});
  Future<void> stopNearbyDiscovery();
  Future<OperationOutcome> updateHostBroadcastBeacon(
    NearbyBoardBeacon? beacon, {
    bool enableBle = true,
  });

  Future<HotspotStartOutcome> startLocalHotspot();
  Future<void> stopLocalHotspot();
  Future<OperationOutcome> connectToHotspot(String ssid, String password);
  Future<void> unbindHotspot();
  Future<void> openSystemHotspotSettings();

  Future<void> dispose();
}

PlatformAdapter createPlatformAdapter() => throw UnsupportedError(
      'No PlatformAdapter implementation available for this target.',
    );
