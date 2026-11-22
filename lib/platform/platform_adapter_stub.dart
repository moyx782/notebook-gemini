import 'dart:convert';
import 'dart:typed_data';

import 'package:notebook_core/notebook_core.dart';

class PdfRenderedPage {
  const PdfRenderedPage({
    required this.pageNumber,
    required this.width,
    required this.height,
    required this.dataUrl,
  });

  final int pageNumber;
  final double width;
  final double height;
  final String dataUrl;
}

class PdfImportedDocument {
  const PdfImportedDocument({
    required this.fileName,
    required this.totalPages,
    required this.pages,
    this.error,
  });

  final String fileName;
  final int totalPages;
  final List<PdfRenderedPage> pages;
  final String? error;
}

PdfImportedDocument? parsePdfImportJson(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty) return null;
  try {
    final map = jsonDecode(rawJson) as Map<String, dynamic>;
    final err = map['error'] as String?;
    if (err != null && err.isNotEmpty) {
      return PdfImportedDocument(
        fileName: map['fileName'] as String? ?? 'document.pdf',
        totalPages: 0,
        pages: const <PdfRenderedPage>[],
        error: err,
      );
    }
    final rawPages = map['pages'] as List<dynamic>? ?? const <dynamic>[];
    final pages = <PdfRenderedPage>[];
    for (var i = 0; i < rawPages.length; i++) {
      final item = Map<String, dynamic>.from(rawPages[i] as Map);
      final dataUrl = item['dataUrl'] as String? ?? '';
      if (dataUrl.isEmpty) continue;
      pages.add(
        PdfRenderedPage(
          pageNumber: (item['pageNumber'] as num? ?? (i + 1)).toInt(),
          width: (item['width'] as num? ?? 595).toDouble(),
          height: (item['height'] as num? ?? 842).toDouble(),
          dataUrl: dataUrl,
        ),
      );
    }
    return PdfImportedDocument(
      fileName: map['fileName'] as String? ?? 'document.pdf',
      totalPages: (map['totalPages'] as num? ?? pages.length).toInt(),
      pages: pages,
    );
  } catch (e) {
    return PdfImportedDocument(
      fileName: 'document.pdf',
      totalPages: 0,
      pages: const <PdfRenderedPage>[],
      error: e.toString(),
    );
  }
}

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
  bool get canImportPdf;
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
  Future<PdfImportedDocument?> pickAndRenderPdf({int maxPages = 30});
  Future<String?> scanQrCode();
  Future<String?> loadImagePathAsDataUrl(String filePath);
  Future<String?> saveExportFile(String filename, String content);
  Future<String?> saveExportBytes(
    String filename,
    Uint8List bytes, {
    String mimeType = 'image/png',
  });

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
