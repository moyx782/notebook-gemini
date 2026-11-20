import 'dart:convert';

import 'crdt_document.dart';
import 'models.dart';

enum SyncMessageType {
  hello('hello'),
  welcome('welcome'),
  opBatch('op_batch'),
  presence('presence'),
  strokeStream('stroke_stream'),
  laserStream('laser_stream'),
  peerLeft('peer_left'),
  ping('ping'),
  pong('pong'),
  error('error');

  const SyncMessageType(this.wireName);
  final String wireName;

  static SyncMessageType fromWireName(String? raw) {
    for (final value in SyncMessageType.values) {
      if (value.wireName == raw) return value;
    }
    return SyncMessageType.error;
  }
}

class SyncMessage {
  const SyncMessage({
    required this.type,
    required this.roomId,
    required this.senderId,
    this.payload = const <String, dynamic>{},
  });

  final SyncMessageType type;
  final String roomId;
  final String senderId;
  final Map<String, dynamic> payload;

  String encode() => jsonEncode(<String, dynamic>{
        'type': type.wireName,
        'roomId': roomId,
        'senderId': senderId,
        'payload': payload,
      });

  factory SyncMessage.decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return SyncMessage(
      type: SyncMessageType.fromWireName(map['type'] as String?),
      roomId: map['roomId'] as String? ?? 'default',
      senderId: map['senderId'] as String? ?? '',
      payload: map['payload'] is Map
          ? Map<String, dynamic>.from(map['payload'] as Map)
          : const <String, dynamic>{},
    );
  }

  factory SyncMessage.hello({
    required String roomId,
    required PeerPresence peer,
  }) {
    return SyncMessage(
      type: SyncMessageType.hello,
      roomId: roomId,
      senderId: peer.peerId,
      payload: <String, dynamic>{'peer': peer.toJson()},
    );
  }

  factory SyncMessage.welcome({
    required String roomId,
    required Map<String, dynamic> snapshot,
    required List<PeerPresence> peers,
    List<String> lanWsUrls = const <String>[],
    List<String> lanHttpUrls = const <String>[],
    List<String> lanApkUrls = const <String>[],
  }) {
    return SyncMessage(
      type: SyncMessageType.welcome,
      roomId: roomId,
      senderId: 'server',
      payload: <String, dynamic>{
        'snapshot': snapshot,
        'peers': peers.map((p) => p.toJson()).toList(),
        'lanWsUrls': lanWsUrls,
        'lanHttpUrls': lanHttpUrls,
        'lanApkUrls': lanApkUrls,
      },
    );
  }

  factory SyncMessage.opBatch({
    required String roomId,
    required String senderId,
    required List<CrdtOp> ops,
  }) {
    return SyncMessage(
      type: SyncMessageType.opBatch,
      roomId: roomId,
      senderId: senderId,
      payload: <String, dynamic>{
        'ops': ops.map((op) => op.toJson()).toList(),
      },
    );
  }

  factory SyncMessage.presence({
    required String roomId,
    required PeerPresence peer,
  }) {
    return SyncMessage(
      type: SyncMessageType.presence,
      roomId: roomId,
      senderId: peer.peerId,
      payload: <String, dynamic>{'peer': peer.toJson()},
    );
  }

  factory SyncMessage.strokeStream({
    required String roomId,
    required LiveStrokeFrame frame,
  }) {
    return SyncMessage(
      type: SyncMessageType.strokeStream,
      roomId: roomId,
      senderId: frame.peerId,
      payload: <String, dynamic>{'frame': frame.toJson()},
    );
  }

  factory SyncMessage.laserStream({
    required String roomId,
    required String senderId,
    required String peerName,
    required int colorValue,
    required String pageId,
    required List<LaserPoint> points,
  }) {
    return SyncMessage(
      type: SyncMessageType.laserStream,
      roomId: roomId,
      senderId: senderId,
      payload: <String, dynamic>{
        'peerName': peerName,
        'colorValue': colorValue,
        'pageId': pageId,
        'points': points.map((p) => p.toJson()).toList(),
      },
    );
  }

  factory SyncMessage.peerLeft({
    required String roomId,
    required String peerId,
  }) {
    return SyncMessage(
      type: SyncMessageType.peerLeft,
      roomId: roomId,
      senderId: 'server',
      payload: <String, dynamic>{'peerId': peerId},
    );
  }

  List<CrdtOp> readOps() {
    final rawOps = payload['ops'] as List<dynamic>? ?? const <dynamic>[];
    return rawOps
        .map((e) => CrdtOp.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  PeerPresence? readPeer() {
    final rawPeer = payload['peer'];
    if (rawPeer is Map) {
      return PeerPresence.fromJson(Map<String, dynamic>.from(rawPeer));
    }
    return null;
  }

  List<PeerPresence> readPeersList() {
    final raw = payload['peers'] as List<dynamic>? ?? const <dynamic>[];
    return raw
        .map((e) => PeerPresence.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  LiveStrokeFrame? readStrokeFrame() {
    final raw = payload['frame'];
    if (raw is Map) {
      return LiveStrokeFrame.fromJson(Map<String, dynamic>.from(raw));
    }
    return null;
  }
}

class ParsedSyncEndpoint {
  const ParsedSyncEndpoint({
    required this.wsUrl,
    this.roomId,
  });

  final String wsUrl;
  final String? roomId;
}

/// Parses a QR code payload or manual host string into a normalized WebSocket
/// endpoint (`ws(s)://.../ws`) and optional room identifier.
ParsedSyncEndpoint? parseSyncQrPayload(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) {
    return null;
  }

  final hasExplicitScheme = trimmed.contains('://');
  final uri = Uri.tryParse(hasExplicitScheme ? trimmed : 'http://$trimmed');
  if (uri == null || uri.host.isEmpty) {
    return null;
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' &&
      scheme != 'https' &&
      scheme != 'ws' &&
      scheme != 'wss') {
    return null;
  }

  final wsScheme = (scheme == 'https' || scheme == 'wss') ? 'wss' : 'ws';
  final roomParam = uri.queryParameters['room']?.trim();
  final cleanRoom =
      (roomParam != null && roomParam.isNotEmpty) ? roomParam : null;

  final int? port;
  if (uri.hasPort) {
    port = uri.port;
  } else if (!hasExplicitScheme) {
    port = 8787;
  } else {
    port = null;
  }

  var path = uri.path;
  if (scheme == 'http' ||
      scheme == 'https' ||
      path.isEmpty ||
      path == '/' ||
      path == '/download/android.apk') {
    path = '/ws';
  }

  final filteredQuery = Map<String, String>.from(uri.queryParameters)
    ..remove('room');

  final normalized = Uri(
    scheme: wsScheme,
    host: uri.host,
    port: port,
    path: path,
    queryParameters: filteredQuery.isEmpty ? null : filteredQuery,
  );

  return ParsedSyncEndpoint(
    wsUrl: normalized.toString(),
    roomId: cleanRoom,
  );
}
