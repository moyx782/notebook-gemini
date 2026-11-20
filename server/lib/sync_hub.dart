import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:notebook_core/notebook_core.dart';

import 'lan_info.dart';
import 'storage.dart';

class _ConnectedPeer {
  _ConnectedPeer({
    required this.socket,
    required this.presence,
  });

  final WebSocket socket;
  PeerPresence presence;
}

class _RoomState {
  _RoomState({
    required this.roomId,
    required this.document,
    required this.storage,
  });

  final String roomId;
  final CrdtDocument document;
  final RoomStorage storage;
  final Map<String, _ConnectedPeer> peers = <String, _ConnectedPeer>{};
}

class SyncServer {
  HttpServer? _server;
  late Directory _dataDir;
  Directory? _webDir;
  String? _apkPath;
  final Map<String, _RoomState> _rooms = <String, _RoomState>{};
  final Map<String, Future<_RoomState>> _loadingRooms =
      <String, Future<_RoomState>>{};

  int get boundPort => _server?.port ?? 0;

  Future<void> start({
    String host = '0.0.0.0',
    int port = 8787,
    required String dataDir,
    String? webDir,
    String? apkPath = 'build/app/outputs/flutter-apk/app-release.apk',
  }) async {
    _dataDir = Directory(dataDir);
    await _dataDir.create(recursive: true);

    if (webDir != null && webDir.trim().isNotEmpty) {
      final candidate = Directory(webDir);
      if (await candidate.exists()) {
        _webDir = candidate.absolute;
      }
    }

    _apkPath = (apkPath != null && apkPath.trim().isNotEmpty)
        ? File(apkPath).absolute.path
        : null;

    _server = await HttpServer.bind(host, port, shared: true);
    _server!.listen(_handleHttpRequest, onError: (_) {});
  }

  Future<File?> _existingApkFile() async {
    final path = _apkPath;
    if (path == null) return null;
    final file = File(path);
    if (await file.exists()) return file;
    return null;
  }

  Future<void> close() async {
    final rooms = _rooms.values.toList();
    for (final room in rooms) {
      for (final peer in room.peers.values.toList()) {
        try {
          await peer.socket.close();
        } catch (_) {}
      }
      room.peers.clear();
      await room.storage.compactNow(room.document);
      await room.storage.flush();
    }
    _rooms.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<_RoomState> _getOrLoadRoom(String rawRoomId) {
    final roomId = sanitizeRoomId(rawRoomId);
    final existing = _rooms[roomId];
    if (existing != null) {
      return Future<_RoomState>.value(existing);
    }
    return _loadingRooms.putIfAbsent(roomId, () async {
      try {
        final storage = RoomStorage(dataDir: _dataDir, roomId: roomId);
        final doc = await storage.loadOrSeed();
        final room = _RoomState(
          roomId: roomId,
          document: doc,
          storage: storage,
        );
        _rooms[roomId] = room;
        return room;
      } finally {
        _loadingRooms.remove(roomId);
      }
    });
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;

      if (request.method == 'OPTIONS') {
        _applyCors(request.response);
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
        await _handleWebSocketUpgrade(request);
        return;
      }

      if (path == '/api/health') {
        await _handleHealth(request);
        return;
      }

      if (path == '/api/info') {
        await _handleInfo(request);
        return;
      }

      if (path == '/download/android.apk') {
        await _handleApkDownload(request);
        return;
      }

      if (path.startsWith('/api/rooms/')) {
        await _handleRoomApi(request);
        return;
      }

      await _handleStaticWeb(request);
    } catch (err) {
      try {
        _applyCors(request.response);
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(jsonEncode(<String, dynamic>{
          'ok': false,
          'error': err.toString(),
        }));
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleApkDownload(HttpRequest request) async {
    final apkFile = await _existingApkFile();
    if (apkFile == null) {
      _applyCors(request.response);
      request.response.statusCode = HttpStatus.notFound;
      await _writeJson(request.response, <String, dynamic>{
        'ok': false,
        'error': 'Android APK not built yet',
      });
      return;
    }

    final length = await apkFile.length();
    _applyCors(request.response);
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.android.package-archive',
    );
    request.response.headers.contentLength = length;
    request.response.headers.set(
      'Content-Disposition',
      'attachment; filename="SyncCanvas-Notebook.apk"',
    );
    await request.response.addStream(apkFile.openRead());
    await request.response.close();
  }

  Future<void> _handleHealth(HttpRequest request) async {
    var totalPeers = 0;
    for (final room in _rooms.values) {
      totalPeers += room.peers.length;
    }
    final apkReady = await _existingApkFile() != null;
    await _writeJson(request.response, <String, dynamic>{
      'ok': true,
      'rooms': _rooms.length,
      'connectedPeers': totalPeers,
      'webReady': _webDir != null,
      'apkReady': apkReady,
    });
  }

  Future<void> _handleInfo(HttpRequest request) async {
    final roomId = sanitizeRoomId(request.uri.queryParameters['room'] ?? 'default');
    final room = _rooms[roomId];
    final ips = await discoverLanIpv4Addresses();
    final port = boundPort;
    final hostList = ips.isEmpty ? <String>['127.0.0.1'] : ips;
    final apkReady = await _existingApkFile() != null;

    final httpUrls = hostList
        .map((ip) => 'http://$ip:$port/?room=${Uri.encodeQueryComponent(roomId)}')
        .toList();
    final wsUrls = hostList.map((ip) => 'ws://$ip:$port/ws').toList();
    final apkUrls = apkReady
        ? hostList
            .map((ip) => 'http://$ip:$port/download/android.apk')
            .toList()
        : const <String>[];

    await _writeJson(request.response, <String, dynamic>{
      'ok': true,
      'port': port,
      'roomId': roomId,
      'lanHttpUrls': httpUrls,
      'lanWsUrls': wsUrls,
      'lanApkUrls': apkUrls,
      'webReady': _webDir != null,
      'apkReady': apkReady,
      'peers': room == null
          ? <dynamic>[]
          : room.peers.values.map((p) => p.presence.toJson()).toList(),
    });
  }

  Future<void> _handleRoomApi(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    // Expected: ['api', 'rooms', '<roomId>', 'export' | 'import']
    if (segments.length != 4) {
      request.response.statusCode = HttpStatus.notFound;
      await _writeJson(request.response, <String, dynamic>{
        'ok': false,
        'error': 'Unknown room endpoint',
      });
      return;
    }

    final roomId = sanitizeRoomId(segments[2]);
    final action = segments[3];
    final room = await _getOrLoadRoom(roomId);

    if (request.method == 'GET' && action == 'export') {
      _applyCors(request.response);
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set(
        'Content-Disposition',
        'attachment; filename="sync-canvas-$roomId.nbk.json"',
      );
      request.response.write(jsonEncode(<String, dynamic>{
        'roomId': roomId,
        'exportedAtMs': DateTime.now().millisecondsSinceEpoch,
        'snapshot': room.document.toSnapshotJson(),
      }));
      await request.response.close();
      return;
    }

    if (request.method == 'POST' && action == 'import') {
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final snapshot = decoded['snapshot'] is Map
          ? Map<String, dynamic>.from(decoded['snapshot'] as Map)
          : decoded;
      final changed = room.document.mergeSnapshotJson(snapshot);
      await room.storage.saveSnapshotNow(room.document);

      if (changed) {
        final ips = await discoverLanIpv4Addresses();
        final port = boundPort;
        final lanWs = ips.map((ip) => 'ws://$ip:$port/ws').toList();
        final lanHttp = ips
            .map((ip) =>
                'http://$ip:$port/?room=${Uri.encodeQueryComponent(roomId)}')
            .toList();
        final welcome = SyncMessage.welcome(
          roomId: roomId,
          snapshot: room.document.toSnapshotJson(),
          peers: room.peers.values.map((p) => p.presence).toList(),
          lanWsUrls: lanWs,
          lanHttpUrls: lanHttp,
        ).encode();
        for (final peer in room.peers.values) {
          _safeSend(peer.socket, welcome);
        }
      }

      await _writeJson(request.response, <String, dynamic>{
        'ok': true,
        'roomId': roomId,
        'changed': changed,
      });
      return;
    }

    request.response.statusCode = HttpStatus.methodNotAllowed;
    await _writeJson(request.response, <String, dynamic>{
      'ok': false,
      'error': 'Unsupported method or action',
    });
  }

  Future<void> _handleWebSocketUpgrade(HttpRequest request) async {
    final roomId =
        sanitizeRoomId(request.uri.queryParameters['room'] ?? 'default');
    final room = await _getOrLoadRoom(roomId);
    final socket = await WebSocketTransformer.upgrade(request);
    socket.pingInterval = const Duration(seconds: 20);

    String? boundPeerId;

    socket.listen(
      (dynamic raw) async {
        if (raw is! String) return;
        SyncMessage msg;
        try {
          msg = SyncMessage.decode(raw);
        } catch (_) {
          return;
        }

        switch (msg.type) {
          case SyncMessageType.hello:
            final peer = msg.readPeer() ??
                PeerPresence(
                  peerId: msg.senderId.isNotEmpty
                      ? msg.senderId
                      : 'peer-${DateTime.now().microsecondsSinceEpoch}',
                  displayName: '协作者',
                  formFactor: DeviceFormFactor.web,
                  colorValue: 0xFF4F46E5,
                  activeNotebookId: '',
                  activePageId: '',
                  cursorX: 0,
                  cursorY: 0,
                  cursorVisible: false,
                  lastSeenMs: DateTime.now().millisecondsSinceEpoch,
                );
            boundPeerId = peer.peerId;
            room.peers[peer.peerId] = _ConnectedPeer(
              socket: socket,
              presence: peer.copyWith(
                lastSeenMs: DateTime.now().millisecondsSinceEpoch,
              ),
            );

            final ips = await discoverLanIpv4Addresses();
            final port = boundPort;
            final hostList = ips.isEmpty ? <String>['127.0.0.1'] : ips;
            final apkReady = await _existingApkFile() != null;
            final lanWs = hostList.map((ip) => 'ws://$ip:$port/ws').toList();
            final lanHttp = hostList
                .map((ip) =>
                    'http://$ip:$port/?room=${Uri.encodeQueryComponent(roomId)}')
                .toList();
            final lanApk = apkReady
                ? hostList
                    .map((ip) => 'http://$ip:$port/download/android.apk')
                    .toList()
                : const <String>[];

            final welcome = SyncMessage.welcome(
              roomId: roomId,
              snapshot: room.document.toSnapshotJson(),
              peers: room.peers.values.map((p) => p.presence).toList(),
              lanWsUrls: lanWs,
              lanHttpUrls: lanHttp,
              lanApkUrls: lanApk,
            );
            _safeSend(socket, welcome.encode());

            final announce = SyncMessage.presence(
              roomId: roomId,
              peer: room.peers[peer.peerId]!.presence,
            ).encode();
            _broadcast(room, announce, excludePeerId: peer.peerId);
            break;

          case SyncMessageType.opBatch:
            final ops = msg.readOps();
            if (ops.isEmpty) break;
            final applied = room.document.applyOps(ops);
            if (applied.isNotEmpty) {
              room.storage.appendOps(applied, room.document);
              final relay = SyncMessage.opBatch(
                roomId: roomId,
                senderId: msg.senderId,
                ops: applied,
              ).encode();
              _broadcast(room, relay, excludePeerId: boundPeerId ?? msg.senderId);
            }
            break;

          case SyncMessageType.presence:
            final peer = msg.readPeer();
            if (peer == null) break;
            boundPeerId ??= peer.peerId;
            final updated = peer.copyWith(
              lastSeenMs: DateTime.now().millisecondsSinceEpoch,
            );
            final existing = room.peers[peer.peerId];
            if (existing != null) {
              existing.presence = updated;
            } else {
              room.peers[peer.peerId] =
                  _ConnectedPeer(socket: socket, presence: updated);
            }
            _broadcast(
              room,
              SyncMessage.presence(roomId: roomId, peer: updated).encode(),
              excludePeerId: peer.peerId,
            );
            break;

          case SyncMessageType.strokeStream:
          case SyncMessageType.laserStream:
            _broadcast(
              room,
              raw,
              excludePeerId: boundPeerId ?? msg.senderId,
            );
            break;

          case SyncMessageType.ping:
            _safeSend(
              socket,
              SyncMessage(
                type: SyncMessageType.pong,
                roomId: roomId,
                senderId: 'server',
              ).encode(),
            );
            break;

          case SyncMessageType.welcome:
          case SyncMessageType.peerLeft:
          case SyncMessageType.pong:
          case SyncMessageType.error:
            break;
        }
      },
      onDone: () {
        _removePeer(room, boundPeerId, socket);
      },
      onError: (_) {
        _removePeer(room, boundPeerId, socket);
      },
      cancelOnError: true,
    );
  }

  void _removePeer(_RoomState room, String? peerId, WebSocket socket) {
    if (peerId != null) {
      final current = room.peers[peerId];
      if (current != null && identical(current.socket, socket)) {
        room.peers.remove(peerId);
        final leftMsg = SyncMessage.peerLeft(
          roomId: room.roomId,
          peerId: peerId,
        ).encode();
        _broadcast(room, leftMsg);
      }
      return;
    }
    String? matchedId;
    room.peers.forEach((key, value) {
      if (identical(value.socket, socket)) {
        matchedId = key;
      }
    });
    if (matchedId != null) {
      room.peers.remove(matchedId);
      _broadcast(
        room,
        SyncMessage.peerLeft(roomId: room.roomId, peerId: matchedId!).encode(),
      );
    }
  }

  void _broadcast(_RoomState room, String encoded, {String? excludePeerId}) {
    for (final entry in room.peers.entries.toList()) {
      if (excludePeerId != null && entry.key == excludePeerId) continue;
      _safeSend(entry.value.socket, encoded);
    }
  }

  void _safeSend(WebSocket socket, String data) {
    try {
      if (socket.readyState == WebSocket.open) {
        socket.add(data);
      }
    } catch (_) {}
  }

  Future<void> _handleStaticWeb(HttpRequest request) async {
    final webDir = _webDir;
    if (webDir == null) {
      _applyCors(request.response);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.html;
      request.response.write('''
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>SyncCanvas Sync Server</title></head>
<body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 32px; max-width: 680px; margin: auto;">
  <h2>SyncCanvas 同步服务正在运行</h2>
  <p>当前未检测到 <code>build/web</code> 静态构建产物。请在项目根目录执行：</p>
  <pre style="background: #f3f4f6; padding: 12px; border-radius: 8px;">flutter build web</pre>
  <p>WebSocket 地址：<code>ws://&lt;LAN-IP&gt;:$boundPort/ws</code></p>
  <p>房间状态 API：<a href="/api/info">/api/info</a></p>
</body>
</html>
''');
      await request.response.close();
      return;
    }

    var relativePath = Uri.decodeComponent(request.uri.path);
    if (relativePath == '/' || relativePath.isEmpty) {
      relativePath = '/index.html';
    }
    final sanitized = relativePath
        .split('/')
        .where((seg) => seg.isNotEmpty && seg != '.' && seg != '..')
        .join(Platform.pathSeparator);

    var target = File('${webDir.path}${Platform.pathSeparator}$sanitized');
    if (!await target.exists()) {
      final hasExtension = sanitized.contains('.') &&
          !sanitized.endsWith('.html');
      if (!hasExtension) {
        target = File('${webDir.path}${Platform.pathSeparator}index.html');
      }
    }

    final resolvedRoot = webDir.resolveSymbolicLinksSync();
    if (!await target.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final resolvedTarget = target.resolveSymbolicLinksSync();
    if (!resolvedTarget.startsWith(resolvedRoot)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    final fileName = resolvedTarget.split(Platform.pathSeparator).last;
    final mime = _mimeTypeFor(fileName);
    request.response.headers.set(HttpHeaders.contentTypeHeader, mime);
    if (fileName == 'index.html' ||
        fileName == 'flutter_bootstrap.js' ||
        fileName == 'version.json' ||
        fileName == 'manifest.json') {
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    }
    await request.response.addStream(target.openRead());
    await request.response.close();
  }

  void _applyCors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  }

  Future<void> _writeJson(
    HttpResponse response,
    Map<String, dynamic> body,
  ) async {
    _applyCors(response);
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  String _mimeTypeFor(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.html')) return 'text/html; charset=utf-8';
    if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
      return 'application/javascript; charset=utf-8';
    }
    if (lower.endsWith('.wasm')) return 'application/wasm';
    if (lower.endsWith('.json')) return 'application/json; charset=utf-8';
    if (lower.endsWith('.css')) return 'text/css; charset=utf-8';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.otf')) return 'font/otf';
    if (lower.endsWith('.ttf')) return 'font/ttf';
    if (lower.endsWith('.woff2')) return 'font/woff2';
    if (lower.endsWith('.ico')) return 'image/x-icon';
    return 'application/octet-stream';
  }
}
