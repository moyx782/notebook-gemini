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

enum VoiceSpeechEventType {
  partial,
  finalized,
  level,
  status,
  error;

  static VoiceSpeechEventType fromName(String? raw) {
    for (final v in VoiceSpeechEventType.values) {
      if (v.name == raw) return v;
    }
    return VoiceSpeechEventType.status;
  }
}

class VoiceSpeechEvent {
  const VoiceSpeechEvent({
    required this.type,
    this.text = '',
    this.level = 0.0,
    this.status = '',
    this.error,
  });

  final VoiceSpeechEventType type;
  final String text;
  final double level;
  final String status;
  final String? error;

  factory VoiceSpeechEvent.fromJson(Map<String, dynamic> json) {
    return VoiceSpeechEvent(
      type: VoiceSpeechEventType.fromName(json['type'] as String?),
      text: json['text'] as String? ?? '',
      level: (json['level'] as num? ?? 0.0).toDouble().clamp(0.0, 1.0),
      status: json['status'] as String? ?? '',
      error: json['error'] as String?,
    );
  }
}

enum LocalAsrEngineKind {
  sherpaTransducer('Sherpa-ONNX Transducer'),
  sherpaParaformer('Sherpa-ONNX Paraformer'),
  sherpaZipformerCtc('Sherpa-ONNX Zipformer CTC'),
  whisperCli('whisper.cpp CLI'),
  unknown('未知模型');

  const LocalAsrEngineKind(this.label);
  final String label;
}

class LocalAsrModelPreset {
  const LocalAsrModelPreset({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.archiveUrl,
    required this.extractedDirName,
    required this.sizeLabel,
    required this.engineKind,
    this.recommended = false,
  });

  final String id;
  final String name;
  final String subtitle;
  final String archiveUrl;
  final String extractedDirName;
  final String sizeLabel;
  final LocalAsrEngineKind engineKind;
  final bool recommended;
}

const List<LocalAsrModelPreset> kLinuxAsrModelPresets = [
  LocalAsrModelPreset(
    id: 'zipformer-zh-14m',
    name: 'Zipformer 中文轻量流式 (14M)',
    subtitle: '中文字词流式识别，体积小速度快（推荐）',
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23.tar.bz2',
    extractedDirName: 'sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23',
    sizeLabel: '74 MB',
    engineKind: LocalAsrEngineKind.sherpaTransducer,
    recommended: true,
  ),
  LocalAsrModelPreset(
    id: 'zipformer-ctc-multi-zh-int8',
    name: 'Zipformer CTC 多方言量化 (Int8)',
    subtitle: '普通话与多方言实时流式量化模型，CPU 占用低',
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-ctc-multi-zh-hans-int8-2023-12-13.tar.bz2',
    extractedDirName:
        'sherpa-onnx-streaming-zipformer-ctc-multi-zh-hans-int8-2023-12-13',
    sizeLabel: '57 MB',
    engineKind: LocalAsrEngineKind.sherpaZipformerCtc,
  ),
  LocalAsrModelPreset(
    id: 'zipformer-bilingual-zh-en',
    name: 'Zipformer 中英双语流式',
    subtitle: '中英混合技术术语高准确率识别',
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20-mobile.tar.bz2',
    extractedDirName:
        'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20-mobile',
    sizeLabel: '347 MB',
    engineKind: LocalAsrEngineKind.sherpaTransducer,
  ),
];

class LocalAsrStatus {
  const LocalAsrStatus({
    required this.supported,
    required this.ready,
    required this.hasRuntime,
    required this.hasModel,
    this.engineKind = LocalAsrEngineKind.unknown,
    this.engineSummary = '',
    this.activeModelPath = '',
    this.activeRuntimePath = '',
    this.modelsRootDir = '',
    this.audioTool = '',
    this.installedPresetIds = const <String>[],
    this.issueMessage,
  });

  const LocalAsrStatus.unsupported()
      : supported = false,
        ready = false,
        hasRuntime = false,
        hasModel = false,
        engineKind = LocalAsrEngineKind.unknown,
        engineSummary = '',
        activeModelPath = '',
        activeRuntimePath = '',
        modelsRootDir = '',
        audioTool = '',
        installedPresetIds = const <String>[],
        issueMessage = null;

  final bool supported;
  final bool ready;
  final bool hasRuntime;
  final bool hasModel;
  final LocalAsrEngineKind engineKind;
  final String engineSummary;
  final String activeModelPath;
  final String activeRuntimePath;
  final String modelsRootDir;
  final String audioTool;
  final List<String> installedPresetIds;
  final String? issueMessage;
}

class LocalAsrDownloadProgress {
  const LocalAsrDownloadProgress({
    required this.stage,
    required this.fraction,
    this.done = false,
    this.error,
    this.installedModelPath,
    this.installedRuntimePath,
  });

  final String stage;
  final double? fraction;
  final bool done;
  final String? error;
  final String? installedModelPath;
  final String? installedRuntimePath;
}

abstract class PlatformAdapter {
  bool get isWeb;
  bool get canPickImage;
  bool get canImportPdf;
  bool get canScanQrCode;
  bool get canHostServer;
  bool get canDiscoverNearby;
  bool get canManageHotspot;
  bool get canTranscribeSpeech;
  bool get supportsLocalAsrModels;

  Stream<NearbyBoardBeacon> get nearbyBeacons;
  Stream<VoiceSpeechEvent> get speechEvents;

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
  Future<HttpResponseData?> httpPostJson(
    Uri uri,
    String jsonBody, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
  });

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

  Future<OperationOutcome> startSpeechRecognition({
    String localeId = 'zh-CN',
    String? localModelPath,
    String? localRuntimePath,
  });
  Future<void> stopSpeechRecognition();

  Future<LocalAsrStatus> queryLocalAsrStatus({
    String? customModelPath,
    String? customRuntimePath,
  });
  Stream<LocalAsrDownloadProgress> installLinuxAsrPreset(
    LocalAsrModelPreset preset, {
    bool useMirror = false,
  });
  Future<String?> pickLocalAsrPath({required bool directory});

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
