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
        PlatformAdapter;

class IoPlatformAdapter implements PlatformAdapter {
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
  bool get canPickImage => Platform.isAndroid || Platform.isLinux;

  @override
  bool get canScanQrCode => Platform.isAndroid;

  @override
  bool get canHostServer => true;

  @override
  bool get canDiscoverNearby =>
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isIOS ||
      Platform.isLinux;

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
    if (Platform.isAndroid) {
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

  @override
  Future<String?> saveExportFile(String filename, String content) async {
    try {
      final dir = await _ensureCacheDir();
      final out = File('${dir.path}/$filename');
      await out.writeAsString(content, flush: true);
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

    final server = SyncServer();
    try {
      await server.start(
        host: '0.0.0.0',
        port: preferredPort,
        dataDir: hostedDir.path,
        webDir: null,
        apkPath: null,
      );
    } on SocketException {
      await server.start(
        host: '0.0.0.0',
        port: 0,
        dataDir: hostedDir.path,
        webDir: null,
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
