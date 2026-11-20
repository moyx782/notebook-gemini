import 'dart:async';
import 'dart:js_interop';

import 'package:notebook_core/notebook_core.dart';

import 'platform_adapter_stub.dart';
export 'platform_adapter_stub.dart'
    show
        HotspotStartOutcome,
        HttpResponseData,
        OperationOutcome,
        PlatformAdapter;

@JS('window.localStorage')
external _DomStorage? get _localStorage;

@JS('window.fetch')
external JSPromise<_FetchResponse> _jsFetch(String url, [JSAny? init]);

@JS('document.createElement')
external _DomElement _createElement(String tagName);

@JS('document.body')
external _DomElement? get _documentBody;

@JS('URL.createObjectURL')
external String _createObjectUrl(JSObject blob);

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(String url);

@JS('Blob')
extension type _JsBlob._(JSObject _) implements JSObject {
  external factory _JsBlob(JSArray<JSString> parts, [JSAny? options]);
}

extension type _DomStorage(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
}

extension type _FetchResponse(JSObject _) implements JSObject {
  external int get status;
  external JSPromise<JSString> text();
}

extension type _DomElement(JSObject _) implements JSObject {
  external set type(String value);
  external set accept(String value);
  external set href(String value);
  external set download(String value);
  external _DomStyle get style;
  external _FileList? get files;
  external set onchange(JSFunction? cb);
  external set oncancel(JSFunction? cb);
  external void click();
  external void appendChild(_DomElement child);
  external void remove();
}

extension type _DomStyle(JSObject _) implements JSObject {
  external set display(String value);
}

extension type _FileList(JSObject _) implements JSObject {
  external int get length;
  external JSObject? item(int index);
}

@JS('FileReader')
extension type _JsFileReader._(JSObject _) implements JSObject {
  external factory _JsFileReader();
  external void readAsDataURL(JSObject file);
  external set onload(JSFunction? cb);
  external set onerror(JSFunction? cb);
  external JSAny? get result;
}

class WebPlatformAdapter implements PlatformAdapter {
  @override
  bool get isWeb => true;

  @override
  bool get canPickImage => true;

  @override
  bool get canScanQrCode => false;

  @override
  bool get canHostServer => false;

  @override
  bool get canDiscoverNearby => false;

  @override
  bool get canManageHotspot => false;

  @override
  Stream<NearbyBoardBeacon> get nearbyBeacons =>
      const Stream<NearbyBoardBeacon>.empty();

  @override
  String defaultWsUrl() {
    final base = Uri.base;
    final override = base.queryParameters['ws'];
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final host = base.host.isEmpty ? '127.0.0.1' : base.host;
    final port = base.hasPort ? base.port : (base.scheme == 'https' ? 443 : 8787);
    return '$scheme://$host:$port/ws';
  }

  @override
  String? initialRoomFromUrl() {
    final room = Uri.base.queryParameters['room'];
    if (room == null || room.trim().isEmpty) return null;
    return room.trim();
  }

  @override
  String defaultDeviceName() => '浏览器协作端';

  @override
  DeviceFormFactor defaultFormFactor(double shortestSideLogicalPixels) {
    if (shortestSideLogicalPixels < 600) {
      return DeviceFormFactor.phone;
    }
    if (shortestSideLogicalPixels < 1024) {
      return DeviceFormFactor.tablet;
    }
    return DeviceFormFactor.web;
  }

  @override
  Future<String?> readLocalValue(String key) async {
    try {
      return _localStorage?.getItem('synccanvas_$key');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeLocalValue(String key, String value) async {
    try {
      _localStorage?.setItem('synccanvas_$key', value);
    } catch (_) {}
  }

  @override
  Future<HttpResponseData?> httpGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      final response = await _jsFetch(uri.toString()).toDart.timeout(timeout);
      final text = (await response.text().toDart).toDart;
      return HttpResponseData(statusCode: response.status, body: text);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<HttpResponseData?> httpPostJson(Uri uri, String jsonBody) async {
    try {
      final init = <String, Object?>{
        'method': 'POST',
        'headers': <String, String>{'Content-Type': 'application/json'},
        'body': jsonBody,
      }.jsify();
      final response = await _jsFetch(uri.toString(), init).toDart;
      final text = (await response.text().toDart).toDart;
      return HttpResponseData(statusCode: response.status, body: text);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> pickImageAsDataUrl() async {
    final completer = Completer<String?>();
    final input = _createElement('input');
    input.type = 'file';
    input.accept = 'image/*';
    input.style.display = 'none';

    input.onchange = ((JSAny? _) {
      final files = input.files;
      if (files == null || files.length == 0) {
        if (!completer.isCompleted) completer.complete(null);
        input.remove();
        return;
      }
      final file = files.item(0);
      if (file == null) {
        if (!completer.isCompleted) completer.complete(null);
        input.remove();
        return;
      }
      final reader = _JsFileReader();
      reader.onload = ((JSAny? _) {
        final res = reader.result;
        String? dataUrl;
        if (res != null && res.isA<JSString>()) {
          dataUrl = (res as JSString).toDart;
        }
        if (!completer.isCompleted) completer.complete(dataUrl);
        input.remove();
      }).toJS;
      reader.onerror = ((JSAny? _) {
        if (!completer.isCompleted) completer.complete(null);
        input.remove();
      }).toJS;
      reader.readAsDataURL(file);
    }).toJS;

    input.oncancel = ((JSAny? _) {
      if (!completer.isCompleted) completer.complete(null);
      input.remove();
    }).toJS;

    _documentBody?.appendChild(input);
    input.click();
    return completer.future;
  }

  @override
  Future<String?> scanQrCode() async => null;

  @override
  Future<String?> loadImagePathAsDataUrl(String filePath) async => null;

  @override
  Future<String?> saveExportFile(String filename, String content) async {
    try {
      final blob = _JsBlob(
        <JSString>[content.toJS].toJS,
        <String, String>{'type': 'application/json;charset=utf-8'}.jsify(),
      );
      final url = _createObjectUrl(blob);
      final anchor = _createElement('a');
      anchor.href = url;
      anchor.download = filename;
      anchor.style.display = 'none';
      _documentBody?.appendChild(anchor);
      anchor.click();
      anchor.remove();
      _revokeObjectUrl(url);
      return filename;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> startEmbeddedServer({int preferredPort = 8787}) async => null;

  @override
  Future<void> stopEmbeddedServer() async {}

  @override
  Future<List<String>> discoverLocalIps() async => const <String>[];

  @override
  Future<OperationOutcome> startNearbyDiscovery({bool enableBle = true}) async =>
      const OperationOutcome(ok: false, error: 'Web 端不支持近场组网扫描');

  @override
  Future<void> stopNearbyDiscovery() async {}

  @override
  Future<OperationOutcome> updateHostBroadcastBeacon(
    NearbyBoardBeacon? beacon, {
    bool enableBle = true,
  }) async =>
      const OperationOutcome(ok: false, error: 'Web 端不支持创建房主服务');

  @override
  Future<HotspotStartOutcome> startLocalHotspot() async =>
      const HotspotStartOutcome(ok: false, error: 'Web 端不支持创建热点');

  @override
  Future<void> stopLocalHotspot() async {}

  @override
  Future<OperationOutcome> connectToHotspot(
    String ssid,
    String password,
  ) async =>
      const OperationOutcome(ok: false, manualRequired: true);

  @override
  Future<void> unbindHotspot() async {}

  @override
  Future<void> openSystemHotspotSettings() async {}

  @override
  Future<void> dispose() async {}
}

PlatformAdapter createPlatformAdapter() => WebPlatformAdapter();
