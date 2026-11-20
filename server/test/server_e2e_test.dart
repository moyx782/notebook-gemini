import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:notebook_core/notebook_core.dart';
import 'package:sync_canvas_server/sync_hub.dart';
import 'package:sync_canvas_server/udp_discovery.dart';
import 'package:test/test.dart';

class _TestPeerClient {
  _TestPeerClient({
    required this.peerId,
    required this.displayName,
    required this.formFactor,
    required this.colorValue,
  }) : doc = CrdtDocument(nodeId: peerId);

  final String peerId;
  final String displayName;
  final DeviceFormFactor formFactor;
  final int colorValue;
  final CrdtDocument doc;
  final StreamController<SyncMessage> _events =
      StreamController<SyncMessage>.broadcast();

  WebSocket? _socket;
  final Map<String, PeerPresence> knownPeers = <String, PeerPresence>{};
  final List<LiveStrokeFrame> liveStrokes = <LiveStrokeFrame>[];
  final List<SyncMessage> laserMessages = <SyncMessage>[];

  Stream<SyncMessage> get messages => _events.stream;

  Future<void> connect(int port, {String roomId = 'team-room'}) async {
    final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws?room=$roomId');
    _socket = socket;

    final welcomeCompleter = Completer<void>();

    socket.listen((dynamic raw) {
      if (raw is! String) return;
      final msg = SyncMessage.decode(raw);
      switch (msg.type) {
        case SyncMessageType.welcome:
          final snapshot = msg.payload['snapshot'];
          if (snapshot is Map) {
            doc.mergeSnapshotJson(Map<String, dynamic>.from(snapshot));
          }
          knownPeers.clear();
          for (final p in msg.readPeersList()) {
            if (p.peerId != peerId) {
              knownPeers[p.peerId] = p;
            }
          }
          if (!welcomeCompleter.isCompleted) {
            welcomeCompleter.complete();
          }
          break;
        case SyncMessageType.opBatch:
          doc.applyOps(msg.readOps());
          break;
        case SyncMessageType.presence:
          final p = msg.readPeer();
          if (p != null && p.peerId != peerId) {
            knownPeers[p.peerId] = p;
          }
          break;
        case SyncMessageType.strokeStream:
          final frame = msg.readStrokeFrame();
          if (frame != null) liveStrokes.add(frame);
          break;
        case SyncMessageType.laserStream:
          laserMessages.add(msg);
          break;
        case SyncMessageType.peerLeft:
          final leftId = msg.payload['peerId'] as String?;
          if (leftId != null) knownPeers.remove(leftId);
          break;
        case SyncMessageType.hello:
        case SyncMessageType.ping:
        case SyncMessageType.pong:
        case SyncMessageType.error:
          break;
      }
      _events.add(msg);
    });

    final hello = SyncMessage.hello(
      roomId: roomId,
      peer: PeerPresence(
        peerId: peerId,
        displayName: displayName,
        formFactor: formFactor,
        colorValue: colorValue,
        activeNotebookId: 'nb-welcome',
        activePageId: 'page-brainstorm',
        cursorX: 0,
        cursorY: 0,
        cursorVisible: true,
        lastSeenMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    socket.add(hello.encode());
    await welcomeCompleter.future.timeout(const Duration(seconds: 5));
  }

  void sendOpBatch(List<CrdtOp> ops, {String roomId = 'team-room'}) {
    _socket?.add(
      SyncMessage.opBatch(
        roomId: roomId,
        senderId: peerId,
        ops: ops,
      ).encode(),
    );
  }

  void sendStrokeFrame(LiveStrokeFrame frame, {String roomId = 'team-room'}) {
    _socket?.add(
      SyncMessage.strokeStream(roomId: roomId, frame: frame).encode(),
    );
  }

  void sendLaser(
    List<LaserPoint> points, {
    String roomId = 'team-room',
  }) {
    _socket?.add(
      SyncMessage.laserStream(
        roomId: roomId,
        senderId: peerId,
        peerName: displayName,
        colorValue: colorValue,
        pageId: 'page-brainstorm',
        points: points,
      ).encode(),
    );
  }

  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not satisfied within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    '3 devices (Desktop + Tablet + Phone) sync live strokes, concurrent edits, offline reconnect & restart persistence',
    () async {
      final tempRoot =
          await Directory.systemTemp.createTemp('sync_canvas_server_e2e_');
      final dataDir = Directory('${tempRoot.path}/data');
      final webDir = Directory('${tempRoot.path}/web');
      await webDir.create(recursive: true);
      await File('${webDir.path}/index.html')
          .writeAsString('<html><body>SyncCanvas Web</body></html>');
      final apkFile = File('${tempRoot.path}/app-release.apk');
      await apkFile.writeAsBytes(<int>[0x50, 0x4b, 0x03, 0x04, 0x01, 0x02]);

      final server = SyncServer();
      await server.start(
        host: '127.0.0.1',
        port: 0,
        dataDir: dataDir.path,
        webDir: webDir.path,
        apkPath: apkFile.path,
      );

      final desktop = _TestPeerClient(
        peerId: 'peer-desktop',
        displayName: 'MacBook Pro',
        formFactor: DeviceFormFactor.desktop,
        colorValue: 0xFF4F46E5,
      );
      final tablet = _TestPeerClient(
        peerId: 'peer-tablet',
        displayName: 'iPad Pencil',
        formFactor: DeviceFormFactor.tablet,
        colorValue: 0xFF0D9488,
      );
      final phone = _TestPeerClient(
        peerId: 'peer-phone',
        displayName: 'iPhone',
        formFactor: DeviceFormFactor.phone,
        colorValue: 0xFFEA580C,
      );

      try {
        await desktop.connect(server.boundPort);
        await tablet.connect(server.boundPort);
        await phone.connect(server.boundPort);

        await _waitUntil(() =>
            desktop.knownPeers.length == 2 &&
            tablet.knownPeers.length == 2 &&
            phone.knownPeers.length == 2);

        // 1. Live stroke stream + laser relay from Tablet -> Desktop & Phone
        tablet.sendStrokeFrame(
          const LiveStrokeFrame(
            peerId: 'peer-tablet',
            peerName: 'iPad Pencil',
            pageId: 'page-brainstorm',
            strokeId: 'live-1',
            kind: ElementKind.stroke,
            colorValue: 0xFF0D9488,
            strokeWidth: 4.0,
            points: <StrokePoint>[
              StrokePoint(dx: 100, dy: 120, pressure: 0.7),
              StrokePoint(dx: 135, dy: 145, pressure: 0.9),
            ],
            seq: 1,
          ),
        );
        tablet.sendLaser(<LaserPoint>[
          LaserPoint(
            x: 200,
            y: 250,
            createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        ]);

        await _waitUntil(() =>
            desktop.liveStrokes.isNotEmpty &&
            phone.liveStrokes.isNotEmpty &&
            desktop.laserMessages.isNotEmpty &&
            phone.laserMessages.isNotEmpty);

        // 2. Concurrent op_batch edits from all 3 devices
        final opD = desktop.doc.mutateEntity(
          entityType: EntityType.element,
          entityId: 'el-from-desktop',
          fields: <String, Object?>{
            'pageId': 'page-brainstorm',
            'kind': ElementKind.textCard.name,
            'x': 90.0,
            'y': 540.0,
            'width': 280.0,
            'height': 140.0,
            'text': 'Desktop Card',
            'zIndex': 20,
            'deleted': false,
          },
        ).forward;

        final opT = tablet.doc.mutateEntity(
          entityType: EntityType.element,
          entityId: 'el-from-tablet',
          fields: <String, Object?>{
            'pageId': 'page-brainstorm',
            'kind': ElementKind.stroke.name,
            'x': 420.0,
            'y': 540.0,
            'colorValue': 0xFF0D9488,
            'strokeWidth': 5.0,
            'points': <List<num>>[
              <num>[0, 0, 0.8, 0],
              <num>[80, 30, 0.9, 15],
            ],
            'zIndex': 21,
            'deleted': false,
          },
        ).forward;

        final opP = phone.doc.mutateEntity(
          entityType: EntityType.element,
          entityId: 'el-from-phone',
          fields: <String, Object?>{
            'pageId': 'page-brainstorm',
            'kind': ElementKind.stickyNote.name,
            'x': 720.0,
            'y': 540.0,
            'width': 180.0,
            'height': 160.0,
            'text': 'Phone Note',
            'zIndex': 22,
            'deleted': false,
          },
        ).forward;

        desktop.sendOpBatch(<CrdtOp>[opD]);
        tablet.sendOpBatch(<CrdtOp>[opT]);
        phone.sendOpBatch(<CrdtOp>[opP]);

        await _waitUntil(() =>
            desktop.doc.getElement('el-from-tablet') != null &&
            desktop.doc.getElement('el-from-phone') != null &&
            tablet.doc.getElement('el-from-desktop') != null &&
            tablet.doc.getElement('el-from-phone') != null &&
            phone.doc.getElement('el-from-desktop') != null &&
            phone.doc.getElement('el-from-tablet') != null);

        expect(desktop.doc.deepDigest(), tablet.doc.deepDigest());
        expect(tablet.doc.deepDigest(), phone.doc.deepDigest());

        // 3. Offline disconnect + concurrent offline edits + reconnect flush
        await phone.disconnect();
        await _waitUntil(() => !desktop.knownPeers.containsKey('peer-phone'));

        final offlinePhoneOp = phone.doc.mutateEntity(
          entityType: EntityType.element,
          entityId: 'el-phone-offline',
          fields: <String, Object?>{
            'pageId': 'page-brainstorm',
            'kind': ElementKind.stickyNote.name,
            'x': 50.0,
            'y': 700.0,
            'width': 200.0,
            'height': 140.0,
            'text': 'Written offline on train',
            'zIndex': 23,
            'deleted': false,
          },
        ).forward;

        final onlineDesktopOp = desktop.doc.mutateEntity(
          entityType: EntityType.element,
          entityId: 'el-desktop-while-phone-away',
          fields: <String, Object?>{
            'pageId': 'page-brainstorm',
            'kind': ElementKind.shape.name,
            'shapeKind': ShapeKind.rectangle.name,
            'x': 320.0,
            'y': 700.0,
            'width': 150.0,
            'height': 90.0,
            'zIndex': 24,
            'deleted': false,
          },
        ).forward;
        desktop.sendOpBatch(<CrdtOp>[onlineDesktopOp]);

        await phone.connect(server.boundPort);
        phone.sendOpBatch(<CrdtOp>[offlinePhoneOp]);

        await _waitUntil(() =>
            desktop.doc.getElement('el-phone-offline') != null &&
            tablet.doc.getElement('el-phone-offline') != null &&
            phone.doc.getElement('el-desktop-while-phone-away') != null);

        expect(desktop.doc.deepDigest(), tablet.doc.deepDigest());
        expect(tablet.doc.deepDigest(), phone.doc.deepDigest());

        // 4. Verify REST endpoints (/api/health, /api/info, static web)
        final httpClient = HttpClient();
        try {
          final infoReq = await httpClient.get(
            '127.0.0.1',
            server.boundPort,
            '/api/info?room=team-room',
          );
          final infoResp = await infoReq.close();
          expect(infoResp.statusCode, HttpStatus.ok);
          final infoJson =
              jsonDecode(await utf8.decoder.bind(infoResp).join())
                  as Map<String, dynamic>;
          expect(infoJson['ok'], isTrue);
          expect(infoJson['webReady'], isTrue);
          expect(infoJson['apkReady'], isTrue);
          expect(infoJson['lanApkUrls'], isNotEmpty);

          final apkReq = await httpClient.get(
            '127.0.0.1',
            server.boundPort,
            '/download/android.apk',
          );
          final apkResp = await apkReq.close();
          expect(apkResp.statusCode, HttpStatus.ok);
          expect(
            apkResp.headers.contentType?.mimeType,
            'application/vnd.android.package-archive',
          );
          final apkBytes = await apkResp.fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
          expect(apkBytes, <int>[0x50, 0x4b, 0x03, 0x04, 0x01, 0x02]);

          final webReq =
              await httpClient.get('127.0.0.1', server.boundPort, '/');
          final webResp = await webReq.close();
          expect(webResp.statusCode, HttpStatus.ok);
          final html = await utf8.decoder.bind(webResp).join();
          expect(html, contains('SyncCanvas Web'));
        } finally {
          httpClient.close();
        }
      } finally {
        await desktop.dispose();
        await tablet.dispose();
        await phone.dispose();
        await server.close();
      }

      // 5. Restart server on same dataDir and verify persistence
      final restarted = SyncServer();
      await restarted.start(
        host: '127.0.0.1',
        port: 0,
        dataDir: dataDir.path,
      );
      final lateClient = _TestPeerClient(
        peerId: 'peer-restarted',
        displayName: 'Verify',
        formFactor: DeviceFormFactor.web,
        colorValue: 0xFF2563EB,
      );
      try {
        await lateClient.connect(restarted.boundPort);
        expect(lateClient.doc.getElement('el-phone-offline')?.text,
            'Written offline on train');
        expect(
          lateClient.doc.getElement('el-desktop-while-phone-away'),
          isNotNull,
        );
      } finally {
        await lateClient.dispose();
        await restarted.close();
        await tempRoot.delete(recursive: true);
      }
    },
  );

  test('UdpDiscoveryService broadcasts and receives NearbyBoardBeacon', () async {
    final listener = UdpDiscoveryService(discoveryPort: 0);
    final received = Completer<NearbyBoardBeacon>();
    final started = await listener.startListening(
      onBeacon: (beacon) {
        if (!received.isCompleted && beacon.hostPeerId == 'host-udp-test') {
          received.complete(beacon);
        }
      },
    );
    expect(started, isTrue);

    final broadcaster = UdpDiscoveryService(
      discoveryPort: listener.boundListenPort,
    );
    await broadcaster.startBroadcasting(
      extraTargets: <InternetAddress>[InternetAddress.loopbackIPv4],
      buildBeacon: () => NearbyBoardBeacon(
        hostPeerId: 'host-udp-test',
        hostName: '测试画板房主',
        formFactor: DeviceFormFactor.desktop,
        roomId: 'room-udp',
        port: 8787,
        lanIps: const <String>['192.168.43.1'],
        lastSeenMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    try {
      final beacon = await received.future.timeout(const Duration(seconds: 4));
      expect(beacon.hostName, '测试画板房主');
      expect(beacon.roomId, 'room-udp');
      expect(beacon.port, 8787);
      expect(beacon.lanIps, contains('192.168.43.1'));
      expect(beacon.transport, DiscoveryTransport.udpLan);
    } finally {
      await broadcaster.stop();
      await listener.stop();
    }
  });
}
