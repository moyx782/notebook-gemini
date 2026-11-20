import 'package:notebook_core/notebook_core.dart';
import 'package:test/test.dart';

void main() {
  group('HLC', () {
    test('handles clock skew and round-trip serialization', () {
      final desktopClock = HlcClock(nodeId: 'desktop-1');
      final tabletClock = HlcClock(nodeId: 'tablet-2');

      final t1 = desktopClock.tick(1000);
      final t2 = desktopClock.tick(1000);
      expect(t2 > t1, isTrue);
      expect(t2.logical, 1);

      // Tablet is 5 seconds ahead; desktop receives tablet's future HLC even
      // though desktop's wall clock is still 1000ms.
      final ahead = tabletClock.tick(6000);
      final merged = desktopClock.receive(ahead, 1005);
      expect(merged > ahead, isTrue);
      expect(merged.wallTimeMs, 6000);

      final reparsed = Hlc.parse(merged.pack());
      expect(reparsed, merged);
    });
  });

  group('CrdtDocument convergence', () {
    test('3 nodes converge regardless of op arrival order and duplicates', () {
      final desktop = CrdtDocument(nodeId: 'desktop');
      final tablet = CrdtDocument(nodeId: 'tablet');
      final phone = CrdtDocument(nodeId: 'phone');

      seedStarterWorkspace(desktop);
      seedStarterWorkspace(tablet);
      seedStarterWorkspace(phone);

      final opDesktop = desktop.mutateEntity(
        entityType: EntityType.element,
        entityId: 'el-stroke-d',
        nowMs: 10000,
        fields: <String, Object?>{
          'pageId': 'page-brainstorm',
          'kind': ElementKind.stroke.name,
          'x': 50.0,
          'y': 60.0,
          'colorValue': 0xFF111827,
          'strokeWidth': 4.0,
          'points': <List<num>>[
            <num>[0, 0, 0.5, 0],
            <num>[30, 40, 0.8, 12],
          ],
          'zIndex': 10,
          'deleted': false,
        },
      ).forward;

      final opTablet = tablet.mutateEntity(
        entityType: EntityType.element,
        entityId: 'el-sticky-t',
        nowMs: 10005,
        fields: <String, Object?>{
          'pageId': 'page-brainstorm',
          'kind': ElementKind.stickyNote.name,
          'x': 300.0,
          'y': 200.0,
          'width': 200.0,
          'height': 180.0,
          'text': 'iPad 手写补充',
          'zIndex': 11,
          'deleted': false,
        },
      ).forward;

      final opPhone = phone.mutateEntity(
        entityType: EntityType.page,
        entityId: 'page-mobile-1',
        nowMs: 10002,
        fields: <String, Object?>{
          'notebookId': 'nb-welcome',
          'title': '手机灵感页',
          'background': PageBackground.dots.name,
          'sortOrder': 3,
          'deleted': false,
        },
      ).forward;

      // Deliver in completely different orders + duplicates
      desktop.applyOps(<CrdtOp>[opPhone, opTablet, opPhone]);
      tablet.applyOps(<CrdtOp>[opDesktop, opPhone, opDesktop]);
      phone.applyOps(<CrdtOp>[opTablet, opDesktop, opTablet]);

      expect(desktop.deepDigest(), tablet.deepDigest());
      expect(tablet.deepDigest(), phone.deepDigest());
      expect(phone.elementsForPage('page-brainstorm').any((e) => e.id == 'el-stroke-d'), isTrue);
      expect(desktop.pagesForNotebook('nb-welcome').any((p) => p.id == 'page-mobile-1'), isTrue);
    });

    test('concurrent multi-field edits on the same card all survive', () {
      final desktop = CrdtDocument(nodeId: 'desktop');
      final tablet = CrdtDocument(nodeId: 'tablet');
      final phone = CrdtDocument(nodeId: 'phone');

      seedStarterWorkspace(desktop);
      seedStarterWorkspace(tablet);
      seedStarterWorkspace(phone);

      // Desktop drags card position
      final moveOp = desktop.mutateEntity(
        entityType: EntityType.element,
        entityId: 'el-seed-title-card',
        nowMs: 20000,
        fields: <String, Object?>{'x': 240.0, 'y': 180.0},
      ).forward;

      // Tablet updates card markdown text concurrently
      final editOp = tablet.mutateEntity(
        entityType: EntityType.element,
        entityId: 'el-seed-title-card',
        nowMs: 20001,
        fields: <String, Object?>{'text': '# 已在 iPad 上更新内容'},
      ).forward;

      // Phone changes card fill color concurrently
      final colorOp = phone.mutateEntity(
        entityType: EntityType.element,
        entityId: 'el-seed-title-card',
        nowMs: 20002,
        fields: <String, Object?>{'fillColorValue': 0xFFEFF6FF},
      ).forward;

      for (final doc in <CrdtDocument>[desktop, tablet, phone]) {
        doc.applyOps(<CrdtOp>[moveOp, editOp, colorOp]);
      }

      final card = phone.getElement('el-seed-title-card')!;
      expect(card.x, 240.0);
      expect(card.y, 180.0);
      expect(card.text, '# 已在 iPad 上更新内容');
      expect(card.fillColorValue, 0xFFEFF6FF);
      expect(desktop.deepDigest(), tablet.deepDigest());
      expect(tablet.deepDigest(), phone.deepDigest());
    });

    test('tombstones ignore stale edits and per-user undo uses fresh HLC', () {
      final desktop = CrdtDocument(nodeId: 'desktop');
      final tablet = CrdtDocument(nodeId: 'tablet');

      final createPair = desktop.mutateEntity(
        entityType: EntityType.element,
        entityId: 'el-temp',
        nowMs: 30000,
        fields: <String, Object?>{
          'pageId': 'page-brainstorm',
          'kind': ElementKind.stickyNote.name,
          'x': 10.0,
          'y': 10.0,
          'width': 120.0,
          'height': 120.0,
          'text': 'v1',
          'deleted': false,
        },
      );
      tablet.applyOp(createPair.forward);

      // Tablet deletes at 30020
      final deletePair = tablet.mutateEntity(
        entityType: EntityType.element,
        entityId: 'el-temp',
        nowMs: 30020,
        fields: <String, Object?>{'deleted': true},
      );
      desktop.applyOp(deletePair.forward);
      expect(desktop.elementsForPage('page-brainstorm'), isEmpty);

      // Stale move at 30010 arrives late: does not resurrect deleted flag
      final staleOp = CrdtOp(
        opId: 'stale-1',
        hlc: const Hlc(30010, 0, 'phone'),
        entityType: EntityType.element,
        entityId: 'el-temp',
        fields: <String, Object?>{'deleted': false, 'x': 99.0},
      );
      desktop.applyOp(staleOp);
      expect(desktop.elementsForPage('page-brainstorm'), isEmpty);

      // Tablet undoes delete at 30030 with fresh HLC
      final undoPair = tablet.applyUndoPatch(deletePair.undoPatch, nowMs: 30030);
      desktop.applyOp(undoPair.forward);
      expect(desktop.elementsForPage('page-brainstorm').length, 1);
      expect(desktop.getElement('el-temp')!.x, 99.0);
    });

    test('snapshot merge preserves newer fields and hitTest works accurately', () {
      final a = CrdtDocument(nodeId: 'a');
      final b = CrdtDocument(nodeId: 'b');
      seedStarterWorkspace(a);

      a.mutateEntity(
        entityType: EntityType.element,
        entityId: 'el-stroke-hit',
        nowMs: 50000,
        fields: <String, Object?>{
          'pageId': 'page-brainstorm',
          'kind': ElementKind.stroke.name,
          'x': 100.0,
          'y': 100.0,
          'strokeWidth': 6.0,
          'points': <List<num>>[
            <num>[0, 0, 0.5, 0],
            <num>[100, 0, 0.5, 10],
          ],
          'deleted': false,
        },
      );

      b.mergeSnapshotJson(a.toSnapshotJson());
      final stroke = b.getElement('el-stroke-hit')!;
      expect(stroke.hitTest(150, 103), isTrue);
      expect(stroke.hitTest(150, 160), isFalse);

      final arrow = b.getElement('el-seed-arrow-2')!;
      expect(arrow.bounds.left, lessThan(arrow.bounds.right));
      expect(arrow.hitTest(580, 458), isTrue);
    });
  });

  group('parseSyncQrPayload', () {
    test('parses http, https, ws, wss, and bare host inputs', () {
      final lanHttp =
          parseSyncQrPayload('http://192.168.1.42:8787/?room=math-101');
      expect(lanHttp, isNotNull);
      expect(lanHttp!.wsUrl, 'ws://192.168.1.42:8787/ws');
      expect(lanHttp.roomId, 'math-101');

      final httpsUrl =
          parseSyncQrPayload('https://board.example.com/?room=team');
      expect(httpsUrl, isNotNull);
      expect(httpsUrl!.wsUrl, 'wss://board.example.com/ws');
      expect(httpsUrl.roomId, 'team');

      final wsUrl =
          parseSyncQrPayload('ws://10.0.0.5:8787/ws?room=alpha');
      expect(wsUrl, isNotNull);
      expect(wsUrl!.wsUrl, 'ws://10.0.0.5:8787/ws');
      expect(wsUrl.roomId, 'alpha');

      final bareHostPort = parseSyncQrPayload('192.168.31.8:9000');
      expect(bareHostPort, isNotNull);
      expect(bareHostPort!.wsUrl, 'ws://192.168.31.8:9000/ws');
      expect(bareHostPort.roomId, isNull);

      final bareHost = parseSyncQrPayload('192.168.31.8');
      expect(bareHost, isNotNull);
      expect(bareHost!.wsUrl, 'ws://192.168.31.8:8787/ws');

      expect(parseSyncQrPayload(''), isNull);
      expect(parseSyncQrPayload('not a url'), isNull);
      expect(parseSyncQrPayload('ftp://192.168.1.1/file'), isNull);
    });
  });

  group('NearbyBoardBeacon', () {
    test('serializes compactly and merges senderIp first', () {
      const original = NearbyBoardBeacon(
        hostPeerId: 'peer-host-1',
        hostName: 'Pixel 画板房主',
        formFactor: DeviceFormFactor.phone,
        roomId: 'team-sketch',
        port: 8787,
        lanIps: <String>['192.168.43.1', '10.0.0.2'],
        hotspotSsid: 'AndroidShare_9911',
        hotspotPassword: 'pass1234',
        lastSeenMs: 123456,
      );

      final compact = original.toCompactJson();
      final decoded = NearbyBoardBeacon.fromCompactJson(
        compact,
        transportOverride: DiscoveryTransport.ble,
        senderIp: '192.168.1.9',
        rssiOverride: -54,
        nowMs: 777,
      );

      expect(decoded.hostPeerId, 'peer-host-1');
      expect(decoded.hostName, 'Pixel 画板房主');
      expect(decoded.formFactor, DeviceFormFactor.phone);
      expect(decoded.roomId, 'team-sketch');
      expect(decoded.port, 8787);
      expect(decoded.lanIps.first, '192.168.1.9');
      expect(decoded.lanIps, contains('192.168.43.1'));
      expect(decoded.hotspotSsid, 'AndroidShare_9911');
      expect(decoded.hotspotPassword, 'pass1234');
      expect(decoded.hasHotspotCredentials, isTrue);
      expect(decoded.primaryWsUrl(), 'ws://192.168.1.9:8787/ws');
      expect(decoded.transport, DiscoveryTransport.ble);
      expect(decoded.rssi, -54);
      expect(decoded.lastSeenMs, 777);
    });
  });
}
