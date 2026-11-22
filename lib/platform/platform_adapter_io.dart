import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:notebook_core/notebook_core.dart';
import 'package:sync_canvas_server/lan_info.dart';
import 'package:sync_canvas_server/sync_hub.dart';
import 'package:sync_canvas_server/udp_discovery.dart';

import 'platform_adapter_stub.dart';
export 'platform_adapter_stub.dart'
    show
        HotspotStartOutcome,
        HttpResponseData,
        OperationOutcome,
        PdfImportedDocument,
        PdfRenderedPage,
        PlatformAdapter;

/// Resolves the offline Flutter Web bundle directory for the embedded host
/// server by checking explicit overrides, bundled app paths, and repository
/// `build/web` ancestors.
Future<String?> resolveEmbeddedWebDir({
  String? executablePath,
  String? currentDirPath,
  String? envOverride,
}) async {
  final sep = Platform.pathSeparator;
  final candidates = <String>[];

  final explicit = envOverride?.trim();
  final fromEnv = Platform.environment['SYNCCANVAS_WEB_DIR']?.trim();
  final overridePath =
      (explicit != null && explicit.isNotEmpty) ? explicit : fromEnv;
  if (overridePath != null && overridePath.isNotEmpty) {
    candidates.add(overridePath);
  }

  var resolvedExe = executablePath?.trim() ?? '';
  if (resolvedExe.isEmpty) {
    try {
      resolvedExe = Platform.resolvedExecutable;
    } catch (_) {
      resolvedExe = '';
    }
  }

  Directory? exeDir;
  if (resolvedExe.isNotEmpty) {
    exeDir = File(resolvedExe).parent;
    candidates.add('${exeDir.path}${sep}web');
    candidates.add('${exeDir.path}${sep}data${sep}web');
    candidates.add('${exeDir.parent.path}${sep}Resources${sep}web');
  }

  final cwd = (currentDirPath != null && currentDirPath.trim().isNotEmpty)
      ? currentDirPath.trim()
      : Directory.current.path;
  if (cwd.isNotEmpty) {
    candidates.add('$cwd${sep}build${sep}web');
  }

  if (exeDir != null) {
    var probe = exeDir.parent;
    for (var depth = 0; depth < 6; depth++) {
      candidates.add('${probe.path}${sep}web');
      candidates.add('${probe.path}${sep}build${sep}web');
      final parent = probe.parent;
      if (parent.path == probe.path) break;
      probe = parent;
    }
  }

  final seen = <String>{};
  for (final dirPath in candidates) {
    final normalized = Directory(dirPath).absolute.path;
    if (!seen.add(normalized)) continue;
    final indexFile = File('$normalized${sep}index.html');
    if (await indexFile.exists()) {
      return normalized;
    }
  }
  return null;
}

class IoPlatformAdapter implements PlatformAdapter {
  IoPlatformAdapter({this.webDirOverride});

  final String? webDirOverride;

  static const MethodChannel _channel =
      MethodChannel('com.synccanvas/native_bridge');

  final StreamController<NearbyBoardBeacon> _nearbyController =
      StreamController<NearbyBoardBeacon>.broadcast();

  Directory? _cacheDir;
  SyncServer? _embeddedServer;
  final UdpDiscoveryService _listenDiscovery = UdpDiscoveryService();
  final UdpDiscoveryService _hostDiscovery = UdpDiscoveryService();
  NearbyBoardBeacon? _latestHostBeacon;
  bool _hostUdpActive = false;
  bool _handlerBound = false;

  void _ensureMethodCallHandler() {
    if (_handlerBound) return;
    _handlerBound = true;
    try {
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'onBleBeaconDiscovered') {
          final args = call.arguments;
          if (args is Map) {
            final rawJson = args['json'] as String?;
            final rssi = (args['rssi'] as num?)?.toInt();
            if (rawJson != null && rawJson.isNotEmpty) {
              try {
                final map = jsonDecode(rawJson);
                if (map is Map) {
                  final beacon = NearbyBoardBeacon.fromCompactJson(
                    Map<String, dynamic>.from(map),
                    transportOverride: DiscoveryTransport.ble,
                    rssiOverride: rssi,
                    nowMs: DateTime.now().millisecondsSinceEpoch,
                  );
                  if (!_nearbyController.isClosed &&
                      beacon.hostPeerId.isNotEmpty) {
                    _nearbyController.add(beacon);
                  }
                }
              } catch (_) {}
            }
          }
        }
      });
    } catch (_) {}
  }

  Future<Directory> _ensureCacheDir() async {
    final cached = _cacheDir;
    if (cached != null) return cached;

    if (Platform.isAndroid) {
      try {
        final appFilesDir =
            await _channel.invokeMethod<String>('getAppFilesDir');
        if (appFilesDir != null && appFilesDir.isNotEmpty) {
          final dir = Directory('$appFilesDir/sync_canvas_notebook');
          await dir.create(recursive: true);
          _cacheDir = dir;
          return dir;
        }
      } catch (_) {}
    }

    if (Platform.isLinux) {
      final xdgDataHome = Platform.environment['XDG_DATA_HOME']?.trim();
      final home = Platform.environment['HOME']?.trim();
      final linuxBase = (xdgDataHome != null && xdgDataHome.isNotEmpty)
          ? Directory('$xdgDataHome/sync_canvas_notebook')
          : (home != null && home.isNotEmpty)
              ? Directory('$home/.local/share/sync_canvas_notebook')
              : Directory('${Directory.systemTemp.path}/sync_canvas_notebook');
      try {
        await linuxBase.create(recursive: true);
        _cacheDir = linuxBase;
        return linuxBase;
      } catch (_) {}
    }

    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
      final appData = Platform.environment['APPDATA']?.trim();
      final userProfile = Platform.environment['USERPROFILE']?.trim();
      final sep = Platform.pathSeparator;
      final winBase = (localAppData != null && localAppData.isNotEmpty)
          ? Directory('$localAppData${sep}SyncCanvasNotebook')
          : (appData != null && appData.isNotEmpty)
              ? Directory('$appData${sep}SyncCanvasNotebook')
              : (userProfile != null && userProfile.isNotEmpty)
                  ? Directory('$userProfile$sep.sync_canvas_notebook')
                  : Directory(
                      '${Directory.systemTemp.path}${sep}sync_canvas_notebook',
                    );
      try {
        await winBase.create(recursive: true);
        _cacheDir = winBase;
        return winBase;
      } catch (_) {}
    }

    final home = Platform.environment['HOME'];
    final base = home != null && home.isNotEmpty
        ? Directory('$home/.sync_canvas_notebook')
        : Directory('${Directory.systemTemp.path}/sync_canvas_notebook');
    try {
      await base.create(recursive: true);
      _cacheDir = base;
      return base;
    } catch (_) {
      final fallback = Directory(
        '${Directory.systemTemp.path}/sync_canvas_notebook',
      );
      await fallback.create(recursive: true);
      _cacheDir = fallback;
      return fallback;
    }
  }

  String _safeKey(String key) => key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  @override
  bool get isWeb => false;

  @override
  bool get canPickImage =>
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isWindows;

  @override
  bool get canImportPdf =>
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isWindows;

  @override
  bool get canScanQrCode => Platform.isAndroid;

  @override
  bool get canHostServer => true;

  @override
  bool get canDiscoverNearby =>
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isIOS ||
      Platform.isLinux ||
      Platform.isWindows;

  @override
  bool get canManageHotspot => Platform.isAndroid;

  @override
  Stream<NearbyBoardBeacon> get nearbyBeacons => _nearbyController.stream;

  @override
  String defaultWsUrl() => 'ws://127.0.0.1:8787/ws';

  @override
  String? initialRoomFromUrl() => null;

  @override
  String defaultDeviceName() {
    final host = Platform.localHostname.trim();
    if (Platform.isMacOS) {
      return host.isEmpty ? 'Mac 桌面端' : '$host · Mac';
    }
    if (Platform.isIOS) {
      return host.isEmpty ? 'iPad / iOS' : host;
    }
    if (Platform.isAndroid) {
      return host.isEmpty ? 'Android 设备' : host;
    }
    if (Platform.isLinux) {
      return host.isEmpty ? 'Linux 桌面端' : '$host · Linux';
    }
    if (Platform.isWindows) {
      return host.isEmpty ? 'Windows 桌面端' : '$host · Windows';
    }
    return host.isEmpty ? '桌面端' : host;
  }

  @override
  DeviceFormFactor defaultFormFactor(double shortestSideLogicalPixels) {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return DeviceFormFactor.desktop;
    }
    return shortestSideLogicalPixels >= 600
        ? DeviceFormFactor.tablet
        : DeviceFormFactor.phone;
  }

  @override
  Future<String?> readLocalValue(String key) async {
    try {
      final dir = await _ensureCacheDir();
      final file = File('${dir.path}/${_safeKey(key)}.json');
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeLocalValue(String key, String value) async {
    try {
      final dir = await _ensureCacheDir();
      final file = File('${dir.path}/${_safeKey(key)}.json');
      await file.writeAsString(value, flush: true);
    } catch (_) {}
  }

  @override
  Future<HttpResponseData?> httpGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      final resp = await req.close().timeout(timeout);
      final body = await utf8.decoder.bind(resp).join().timeout(timeout);
      return HttpResponseData(statusCode: resp.statusCode, body: body);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<HttpResponseData?> httpPostJson(Uri uri, String jsonBody) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonBody);
      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();
      return HttpResponseData(statusCode: resp.statusCode, body: body);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String?> pickImageAsDataUrl() async {
    if (Platform.isAndroid || Platform.isMacOS) {
      try {
        return await _channel.invokeMethod<String>('pickImage');
      } catch (_) {
        return null;
      }
    }
    if (Platform.isLinux) {
      final path = await _pickLinuxImageFilePath();
      if (path == null || path.isEmpty) return null;
      return loadImagePathAsDataUrl(path);
    }
    if (Platform.isWindows) {
      final path = await _pickWindowsImageFilePath();
      if (path == null || path.isEmpty) return null;
      return loadImagePathAsDataUrl(path);
    }
    return null;
  }

  @override
  Future<PdfImportedDocument?> pickAndRenderPdf({int maxPages = 30}) async {
    final safeLimit = maxPages.clamp(1, 60);
    if (Platform.isAndroid || Platform.isMacOS) {
      try {
        final rawJson = await _channel.invokeMethod<String>(
          'pickPdf',
          <String, Object?>{'maxPages': safeLimit},
        );
        return parsePdfImportJson(rawJson);
      } catch (e) {
        return PdfImportedDocument(
          fileName: 'document.pdf',
          totalPages: 0,
          pages: const <PdfRenderedPage>[],
          error: e.toString(),
        );
      }
    }
    if (Platform.isWindows) {
      return _pickAndRenderWindowsPdf(maxPages: safeLimit);
    }
    if (Platform.isLinux) {
      return _pickAndRenderLinuxPdf(maxPages: safeLimit);
    }
    return null;
  }

  Future<PdfImportedDocument?> _pickAndRenderWindowsPdf({
    required int maxPages,
  }) async {
    final script = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
$dlg = New-Object System.Windows.Forms.OpenFileDialog
$dlg.Title = 'Select PDF for SyncCanvas'
$dlg.Filter = 'PDF Documents (*.pdf)|*.pdf|All Files (*.*)|*.*'
$chosen = $null
try {
  if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
    $chosen = $dlg.FileName
  }
} finally {
  $dlg.Dispose()
  $owner.Dispose()
}
if ([string]::IsNullOrWhiteSpace($chosen)) { exit 0 }

$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFolder, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf, ContentType = WindowsRuntime]

$methods = [System.WindowsRuntimeSystemExtensions].GetMethods()
$asTaskGeneric = ($methods | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.IsGenericMethod })[0]
$asTaskAction = ($methods | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and -not $_.IsGenericMethod -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]

function Await-Op($op, [type]$type) {
  $m = $asTaskGeneric.MakeGenericMethod($type)
  return $m.Invoke($null, @($op)).GetAwaiter().GetResult()
}
function Await-Action($act) {
  [void]$asTaskAction.Invoke($null, @($act)).GetAwaiter().GetResult()
}

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("synccanvas_pdf_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
  $storageFile = Await-Op ([Windows.Storage.StorageFile]::GetFileFromPathAsync($chosen)) ([Windows.Storage.StorageFile])
  $pdfDoc = Await-Op ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($storageFile)) ([Windows.Data.Pdf.PdfDocument])
  $folder = Await-Op ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($tmpDir)) ([Windows.Storage.StorageFolder])
  $total = [int]$pdfDoc.PageCount
  $limit = [Math]::Min($total, __MAX_PAGES__)
  $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
  $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, 85L)
  $pagesOut = @()
  for ($i = 0; $i -lt $limit; $i++) {
    $page = $pdfDoc.GetPage([uint32]$i)
    try {
      $w = [double]$page.Size.Width
      $h = [double]$page.Size.Height
      $maxDim = [Math]::Max($w, $h)
      $scale = [Math]::Min(2.2, [Math]::Max(1.0, 1440.0 / [Math]::Max(1.0, $maxDim)))
      $opts = New-Object Windows.Data.Pdf.PdfPageRenderOptions
      $opts.DestinationWidth = [uint32][Math]::Round($w * $scale)
      $opts.DestinationHeight = [uint32][Math]::Round($h * $scale)
      $pngName = "p_$i.png"
      $outFile = Await-Op ($folder.CreateFileAsync($pngName, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
      $stream = Await-Op ($outFile.OpenAsync([Windows.Storage.FileAccessMode]::ReadWrite)) ([Windows.Storage.Streams.IRandomAccessStream])
      try {
        Await-Action ($page.RenderToStreamAsync($stream, $opts))
      } finally {
        $stream.Dispose()
      }
      $pngPath = Join-Path $tmpDir $pngName
      $srcBmp = [System.Drawing.Image]::FromFile($pngPath)
      try {
        $whiteBmp = New-Object System.Drawing.Bitmap($srcBmp.Width, $srcBmp.Height)
        try {
          $g = [System.Drawing.Graphics]::FromImage($whiteBmp)
          try {
            $g.Clear([System.Drawing.Color]::White)
            $g.DrawImage($srcBmp, 0, 0, $srcBmp.Width, $srcBmp.Height)
          } finally {
            $g.Dispose()
          }
          $ms = New-Object System.IO.MemoryStream
          $whiteBmp.Save($ms, $jpegCodec, $encParams)
          $b64 = [Convert]::ToBase64String($ms.ToArray())
          $ms.Dispose()
        } finally {
          $whiteBmp.Dispose()
        }
      } finally {
        $srcBmp.Dispose()
      }
      $pagesOut += @{
        pageNumber = ($i + 1)
        width = [Math]::Round($w, 2)
        height = [Math]::Round($h, 2)
        dataUrl = ("data:image/jpeg;base64," + $b64)
      }
    } finally {
      $page.Dispose()
    }
  }
  $payload = @{
    fileName = [System.IO.Path]::GetFileName($chosen)
    totalPages = $total
    pages = @(,$pagesOut | ForEach-Object { $_ })
  } | ConvertTo-Json -Compress -Depth 6
  [Console]::Out.Write($payload)
} catch {
  $errPayload = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
  [Console]::Out.Write($errPayload)
} finally {
  Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}
'''
        .replaceAll('__MAX_PAGES__', '$maxPages');

    try {
      final res = await Process.run(
        'powershell.exe',
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Sta',
          '-Command',
          script,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final out = (res.stdout as String).trim();
      if (out.isEmpty) return null;
      return parsePdfImportJson(out);
    } catch (e) {
      return PdfImportedDocument(
        fileName: 'document.pdf',
        totalPages: 0,
        pages: const <PdfRenderedPage>[],
        error: e.toString(),
      );
    }
  }

  Future<PdfImportedDocument?> _pickAndRenderLinuxPdf({
    required int maxPages,
  }) async {
    String? chosen;
    try {
      final res = await Process.run('zenity', <String>[
        '--file-selection',
        '--title=选择 PDF 导入笔记本',
        '--file-filter=PDF 文档 (*.pdf) | *.pdf *.PDF',
      ]);
      if (res.exitCode == 0) {
        final s = (res.stdout as String).trim();
        if (s.isNotEmpty) chosen = s;
      } else {
        return null;
      }
    } catch (_) {
      try {
        final home = Platform.environment['HOME'] ?? '.';
        final res = await Process.run('kdialog', <String>[
          '--getopenfilename',
          home,
          '*.pdf *.PDF',
        ]);
        if (res.exitCode == 0) {
          final s = (res.stdout as String).trim();
          if (s.isNotEmpty) chosen = s;
        }
      } catch (_) {}
    }

    if (chosen == null || chosen.isEmpty) return null;
    final tmpDir = await Directory.systemTemp.createTemp('synccanvas_pdf_');
    try {
      var rendered = false;
      try {
        final ppm = await Process.run('pdftoppm', <String>[
          '-jpeg',
          '-jpegopt',
          'quality=85',
          '-scale-to',
          '1440',
          '-f',
          '1',
          '-l',
          '$maxPages',
          chosen,
          '${tmpDir.path}/page',
        ]);
        rendered = ppm.exitCode == 0;
      } catch (_) {}

      if (!rendered) {
        try {
          final gs = await Process.run('gs', <String>[
            '-dNOPAUSE',
            '-dBATCH',
            '-dSAFER',
            '-sDEVICE=jpeg',
            '-dJPEGQ=85',
            '-r144',
            '-dFirstPage=1',
            '-dLastPage=$maxPages',
            '-sOutputFile=${tmpDir.path}/page-%03d.jpg',
            chosen,
          ]);
          rendered = gs.exitCode == 0;
        } catch (_) {}
      }

      if (!rendered) {
        return const PdfImportedDocument(
          fileName: 'document.pdf',
          totalPages: 0,
          pages: <PdfRenderedPage>[],
          error: '未找到 pdftoppm (poppler-utils) 或 gs (ghostscript) 渲染工具',
        );
      }

      final jpgFiles = tmpDir
          .listSync()
          .whereType<File>()
          .where((f) {
            final lower = f.path.toLowerCase();
            return lower.endsWith('.jpg') || lower.endsWith('.jpeg');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      final pages = <PdfRenderedPage>[];
      for (var i = 0; i < jpgFiles.length; i++) {
        final bytes = await jpgFiles[i].readAsBytes();
        final dims = _readJpegDimensions(bytes);
        pages.add(
          PdfRenderedPage(
            pageNumber: i + 1,
            width: dims.$1,
            height: dims.$2,
            dataUrl: 'data:image/jpeg;base64,${base64Encode(bytes)}',
          ),
        );
      }
      final fileName = chosen.split(Platform.pathSeparator).last;
      return PdfImportedDocument(
        fileName: fileName,
        totalPages: pages.length,
        pages: pages,
      );
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  (double, double) _readJpegDimensions(Uint8List bytes) {
    var i = 2;
    while (i + 9 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = bytes[i + 1];
      if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
        final h = (bytes[i + 5] << 8) | bytes[i + 6];
        final w = (bytes[i + 7] << 8) | bytes[i + 8];
        if (w > 0 && h > 0) return (w.toDouble(), h.toDouble());
      }
      if (marker == 0xD8 || marker == 0xD9 || marker == 0x00) {
        i += 2;
        continue;
      }
      final segLen = (bytes[i + 2] << 8) | bytes[i + 3];
      if (segLen < 2) break;
      i += 2 + segLen;
    }
    return (794.0, 1123.0);
  }

  Future<String?> _pickWindowsImageFilePath() async {
    const script = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
$owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
$dlg = New-Object System.Windows.Forms.OpenFileDialog
$dlg.Title = 'Select Image for SyncCanvas'
$dlg.Filter = 'Image Files (*.png;*.jpg;*.jpeg;*.webp;*.gif)|*.png;*.jpg;*.jpeg;*.webp;*.gif|All Files (*.*)|*.*'
try {
  if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::Out.Write($dlg.FileName)
  }
} finally {
  $dlg.Dispose()
  $owner.Dispose()
}
''';
    try {
      final res = await Process.run(
        'powershell.exe',
        const <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Sta',
          '-Command',
          script,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (res.exitCode == 0) {
        final chosen = (res.stdout as String).trim();
        if (chosen.isNotEmpty) return chosen;
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _pickLinuxImageFilePath() async {
    try {
      final res = await Process.run('zenity', <String>[
        '--file-selection',
        '--title=选择图片插入画板',
        '--file-filter=图片文件 (png/jpg/webp/gif) | *.png *.jpg *.jpeg *.webp *.gif',
      ]);
      if (res.exitCode == 0) {
        final chosen = (res.stdout as String).trim();
        if (chosen.isNotEmpty) return chosen;
      }
      return null;
    } catch (_) {}

    try {
      final home = Platform.environment['HOME'] ?? '.';
      final res = await Process.run('kdialog', <String>[
        '--getopenfilename',
        home,
        '*.png *.jpg *.jpeg *.webp *.gif',
      ]);
      if (res.exitCode == 0) {
        final chosen = (res.stdout as String).trim();
        if (chosen.isNotEmpty) return chosen;
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<String?> scanQrCode() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('scanQrCode');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> loadImagePathAsDataUrl(String filePath) async {
    try {
      final cleaned = filePath.trim();
      if (cleaned.isEmpty) return null;
      final file = File(cleaned);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final lower = cleaned.toLowerCase();
      final mime = lower.endsWith('.png')
          ? 'image/png'
          : lower.endsWith('.webp')
              ? 'image/webp'
              : lower.endsWith('.gif')
                  ? 'image/gif'
                  : 'image/jpeg';
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _resolveExportDir() async {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      final sep = Platform.pathSeparator;
      final home = Platform.isWindows
          ? Platform.environment['USERPROFILE']?.trim()
          : Platform.environment['HOME']?.trim();
      if (home != null && home.isNotEmpty) {
        final downloads = Directory('$home${sep}Downloads');
        try {
          if (await downloads.exists()) {
            return downloads;
          }
        } catch (_) {}
      }
    }
    return _ensureCacheDir();
  }

  @override
  Future<String?> saveExportFile(String filename, String content) async {
    try {
      final dir = await _resolveExportDir();
      final out = File('${dir.path}${Platform.pathSeparator}$filename');
      await out.writeAsString(content, flush: true);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> saveExportBytes(
    String filename,
    Uint8List bytes, {
    String mimeType = 'image/png',
  }) async {
    try {
      final dir = await _resolveExportDir();
      final out = File('${dir.path}${Platform.pathSeparator}$filename');
      await out.writeAsBytes(bytes, flush: true);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> startEmbeddedServer({int preferredPort = 8787}) async {
    if (_embeddedServer != null) {
      return _embeddedServer!.boundPort;
    }
    final cacheDir = await _ensureCacheDir();
    final hostedDir = Directory('${cacheDir.path}/hosted_rooms');
    await hostedDir.create(recursive: true);
    final webDir = await resolveEmbeddedWebDir(envOverride: webDirOverride);

    final server = SyncServer();
    try {
      await server.start(
        host: '0.0.0.0',
        port: preferredPort,
        dataDir: hostedDir.path,
        webDir: webDir,
        apkPath: null,
      );
    } on SocketException {
      await server.start(
        host: '0.0.0.0',
        port: 0,
        dataDir: hostedDir.path,
        webDir: webDir,
        apkPath: null,
      );
    }
    _embeddedServer = server;
    return server.boundPort;
  }

  @override
  Future<void> stopEmbeddedServer() async {
    final server = _embeddedServer;
    _embeddedServer = null;
    if (server != null) {
      await server.close();
    }
  }

  @override
  Future<List<String>> discoverLocalIps() => discoverLanIpv4Addresses();

  @override
  Future<OperationOutcome> startNearbyDiscovery({bool enableBle = true}) async {
    _ensureMethodCallHandler();
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('setMulticastLock', <String, Object?>{
          'enabled': true,
        });
      } catch (_) {}
    }

    await _listenDiscovery.startListening(
      onBeacon: (beacon) {
        if (!_nearbyController.isClosed) {
          _nearbyController.add(beacon);
        }
      },
    );

    if (enableBle && (Platform.isAndroid || Platform.isMacOS || Platform.isIOS)) {
      try {
        final resp = await _channel.invokeMethod<dynamic>('startBleScanning');
        if (resp is Map) {
          final ok = resp['ok'] as bool? ?? true;
          final err = resp['error'] as String?;
          return OperationOutcome(ok: ok, error: err);
        }
      } catch (_) {}
    }

    return const OperationOutcome(ok: true);
  }

  @override
  Future<void> stopNearbyDiscovery() async {
    await _listenDiscovery.stopListening();
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('setMulticastLock', <String, Object?>{
          'enabled': false,
        });
      } catch (_) {}
    }
    if (Platform.isAndroid || Platform.isMacOS || Platform.isIOS) {
      try {
        await _channel.invokeMethod('stopBleScanning');
      } catch (_) {}
    }
  }

  @override
  Future<OperationOutcome> updateHostBroadcastBeacon(
    NearbyBoardBeacon? beacon, {
    bool enableBle = true,
  }) async {
    _ensureMethodCallHandler();
    if (beacon == null) {
      _latestHostBeacon = null;
      _hostUdpActive = false;
      await _hostDiscovery.stopBroadcasting();
      if (Platform.isAndroid || Platform.isMacOS || Platform.isIOS) {
        try {
          await _channel.invokeMethod('stopBleAdvertising');
        } catch (_) {}
      }
      return const OperationOutcome(ok: true);
    }

    _latestHostBeacon = beacon;
    if (!_hostUdpActive) {
      _hostUdpActive = true;
      await _hostDiscovery.startBroadcasting(
        buildBeacon: () => _latestHostBeacon ?? beacon,
      );
    } else {
      await _hostDiscovery.triggerBroadcastNow();
    }

    if (enableBle && (Platform.isAndroid || Platform.isMacOS || Platform.isIOS)) {
      try {
        final resp = await _channel.invokeMethod<dynamic>(
          'startBleAdvertising',
          <String, Object?>{
            'beaconJson': jsonEncode(beacon.toCompactJson()),
          },
        );
        if (resp is Map) {
          final ok = resp['ok'] as bool? ?? true;
          final err = resp['error'] as String?;
          return OperationOutcome(ok: ok, error: err);
        }
      } catch (_) {}
    }
    return const OperationOutcome(ok: true);
  }

  @override
  Future<HotspotStartOutcome> startLocalHotspot() async {
    if (!Platform.isAndroid) {
      return const HotspotStartOutcome(
        ok: false,
        error: '仅 Android 端支持应用内一键拉起本地直连热点',
      );
    }
    try {
      final resp = await _channel.invokeMethod<dynamic>('startLocalHotspot');
      if (resp is Map) {
        final ok = resp['ok'] as bool? ?? false;
        if (ok) {
          final ssid = (resp['ssid'] as String? ?? '').trim();
          final password = resp['password'] as String? ?? '';
          return HotspotStartOutcome(
            ok: ssid.isNotEmpty,
            credentials: HotspotCredentials(ssid: ssid, password: password),
            error: ssid.isEmpty ? '未能读取热点名称' : null,
          );
        }
        return HotspotStartOutcome(
          ok: false,
          error: resp['error'] as String? ?? '开启本地热点失败',
        );
      }
    } catch (e) {
      return HotspotStartOutcome(ok: false, error: e.toString());
    }
    return const HotspotStartOutcome(ok: false, error: '开启本地热点失败');
  }

  @override
  Future<void> stopLocalHotspot() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopLocalHotspot');
    } catch (_) {}
  }

  @override
  Future<OperationOutcome> connectToHotspot(String ssid, String password) async {
    if (!Platform.isAndroid) {
      return const OperationOutcome(
        ok: false,
        manualRequired: true,
        error: '请在系统 Wi-Fi 设置中连接该热点',
      );
    }
    try {
      final resp = await _channel.invokeMethod<dynamic>(
        'connectToHotspot',
        <String, Object?>{'ssid': ssid, 'password': password},
      );
      if (resp is Map) {
        return OperationOutcome(
          ok: resp['ok'] as bool? ?? false,
          error: resp['error'] as String?,
          manualRequired: resp['manualRequired'] as bool? ?? false,
        );
      }
    } catch (e) {
      return OperationOutcome(ok: false, error: e.toString());
    }
    return const OperationOutcome(ok: false, error: '连接热点失败');
  }

  @override
  Future<void> unbindHotspot() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('unbindHotspot');
    } catch (_) {}
  }

  @override
  Future<void> openSystemHotspotSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openSystemHotspotSettings');
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await stopNearbyDiscovery();
    await updateHostBroadcastBeacon(null);
    await stopLocalHotspot();
    await unbindHotspot();
    await stopEmbeddedServer();
    if (!_nearbyController.isClosed) {
      await _nearbyController.close();
    }
  }
}

PlatformAdapter createPlatformAdapter() => IoPlatformAdapter();
