import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notebook_core/notebook_core.dart';
import 'package:sync_canvas_notebook/canvas/board_stage.dart';
import 'package:sync_canvas_notebook/main.dart';
import 'package:sync_canvas_notebook/platform/platform_adapter.dart';
import 'package:sync_canvas_notebook/state/notebook_controller.dart';

class _FakeAndroidPlatformAdapter implements PlatformAdapter {
  static const String _tinyPngDataUrl =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

  final StreamController<NearbyBoardBeacon> beaconStream =
      StreamController<NearbyBoardBeacon>.broadcast();

  bool joinedHotspot = false;
  NearbyBoardBeacon? lastHostBeacon;
  bool serverRunning = false;

  @override
  bool get isWeb => false;

  @override
  bool get canPickImage => true;

  @override
  bool get canScanQrCode => true;

  @override
  bool get canHostServer => true;

  @override
  bool get canDiscoverNearby => true;

  @override
  bool get canManageHotspot => true;

  @override
  Stream<NearbyBoardBeacon> get nearbyBeacons => beaconStream.stream;

  @override
  String defaultWsUrl() => 'ws://127.0.0.1:8787/ws';

  @override
  String? initialRoomFromUrl() => null;

  @override
  String defaultDeviceName() => 'Pixel 9 Pro';

  @override
  DeviceFormFactor defaultFormFactor(double shortestSideLogicalPixels) =>
      shortestSideLogicalPixels >= 600
          ? DeviceFormFactor.tablet
          : DeviceFormFactor.phone;

  @override
  Future<String?> readLocalValue(String key) async => null;

  @override
  Future<void> writeLocalValue(String key, String value) async {}

  @override
  Future<HttpResponseData?> httpGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (joinedHotspot &&
        uri.host == '192.168.43.1' &&
        uri.path == '/api/health') {
      return const HttpResponseData(statusCode: 200, body: '{"ok":true}');
    }
    return null;
  }

  @override
  Future<HttpResponseData?> httpPostJson(Uri uri, String jsonBody) async =>
      null;

  @override
  Future<String?> pickImageAsDataUrl() async => _tinyPngDataUrl;

  @override
  Future<String?> scanQrCode() async =>
      'http://192.168.1.66:8787/?room=study';

  @override
  Future<String?> loadImagePathAsDataUrl(String filePath) async => null;

  @override
  Future<String?> saveExportFile(String filename, String content) async => null;

  @override
  Future<int?> startEmbeddedServer({int preferredPort = 8787}) async {
    serverRunning = true;
    return preferredPort;
  }

  @override
  Future<void> stopEmbeddedServer() async {
    serverRunning = false;
  }

  @override
  Future<List<String>> discoverLocalIps() async =>
      const <String>['192.168.43.1'];

  @override
  Future<OperationOutcome> startNearbyDiscovery({bool enableBle = true}) async =>
      const OperationOutcome(ok: true);

  @override
  Future<void> stopNearbyDiscovery() async {}

  @override
  Future<OperationOutcome> updateHostBroadcastBeacon(
    NearbyBoardBeacon? beacon, {
    bool enableBle = true,
  }) async {
    lastHostBeacon = beacon;
    return const OperationOutcome(ok: true);
  }

  @override
  Future<HotspotStartOutcome> startLocalHotspot() async =>
      const HotspotStartOutcome(
        ok: true,
        credentials: HotspotCredentials(
          ssid: 'SyncCanvas_Test',
          password: 'pass9999',
        ),
      );

  @override
  Future<void> stopLocalHotspot() async {}

  @override
  Future<OperationOutcome> connectToHotspot(String ssid, String password) async {
    if (ssid == 'SyncCanvas_Test' && password == 'pass9999') {
      joinedHotspot = true;
      return const OperationOutcome(ok: true);
    }
    return const OperationOutcome(ok: false, error: 'wrong hotspot');
  }

  @override
  Future<void> unbindHotspot() async {
    joinedHotspot = false;
  }

  @override
  Future<void> openSystemHotspotSettings() async {}

  @override
  Future<void> dispose() async {
    await beaconStream.close();
  }
}

void main() {
  testWidgets(
    'Desktop, Tablet, and Phone shells render without overflow and sync CRDT edits',
    (WidgetTester tester) async {
      final desktopCtrl = NotebookController(
        initialPeerId: 'test-desktop',
        initialDisplayName: 'Mac 测试端',
        initialFormFactor: DeviceFormFactor.desktop,
        autoConnect: false,
      );
      addTearDown(desktopCtrl.dispose);

      // 1. Desktop viewport (1440x900)
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(SyncCanvasApp(controller: desktopCtrl));
      await tester.pumpAndSettle();

      expect(find.text('SyncCanvas'), findsOneWidget);
      expect(find.text('三端共享笔记本'), findsOneWidget);
      expect(find.text('三端连接'), findsOneWidget);

      // Switch to Select tool and toggle a Markdown task checkbox in the seeded starter card
      await tester.tap(find.byTooltip('选择 / 移动 (V)'));
      await tester.pumpAndSettle();

      final initialText =
          desktopCtrl.doc.getElement('el-seed-title-card')!.text;
      expect(initialText, contains('- [ ] **手机端**'));

      await tester.tap(find.textContaining('扫码秒连', findRichText: true));
      await tester.pumpAndSettle();

      final updatedText =
          desktopCtrl.doc.getElement('el-seed-title-card')!.text;
      expect(updatedText, contains('- [x] **手机端**'));

      // Switch to Pen tool and draw a stroke on the canvas
      await tester.tap(find.byTooltip('压感钢笔 (P)'));
      await tester.pumpAndSettle();
      final beforeCount = desktopCtrl.activeElements.length;
      final boardFinder = find.byType(BoardStage);
      final center = tester.getCenter(boardFinder);
      final gesture = await tester.startGesture(center + const Offset(120, -40));
      await gesture.moveBy(const Offset(90, 45));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(desktopCtrl.activeElements.length, beforeCount + 1);

      // Undo and Redo stroke
      desktopCtrl.undo();
      await tester.pumpAndSettle();
      expect(desktopCtrl.activeElements.length, beforeCount);

      desktopCtrl.redo();
      await tester.pumpAndSettle();
      expect(desktopCtrl.activeElements.length, beforeCount + 1);

      // Create a new page
      await tester.tap(find.byTooltip('快速新建画板页'));
      await tester.pumpAndSettle();
      expect(desktopCtrl.activePages.length, 4);

      // Open Tri-Platform QR Connect dialog and verify zero overflow
      await tester.tap(find.text('三端连接'));
      await tester.pumpAndSettle();
      expect(find.text('三端连接与同步中心'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();

      // 2. Tablet / iPad viewport (834x1194)
      await tester.binding.setSurfaceSize(const Size(834, 1194));
      await tester.pumpWidget(SyncCanvasApp(controller: desktopCtrl));
      await tester.pumpAndSettle();
      expect(find.byTooltip('打开笔记本目录'), findsOneWidget);
      expect(find.text('连接'), findsOneWidget);

      // 3. Phone viewport (390x844)
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(SyncCanvasApp(controller: desktopCtrl));
      await tester.pumpAndSettle();
      expect(find.byTooltip('笔记本与页面目录'), findsOneWidget);
      expect(find.text('动笔'), findsOneWidget);

      // Toggle Phone browse-only mode
      await tester.tap(find.text('动笔'));
      await tester.pumpAndSettle();
      expect(find.text('浏览'), findsOneWidget);
    },
  );

  test('Two NotebookController instances converge via CRDT ops', () {
    final tabletCtrl = NotebookController(
      initialPeerId: 'ctrl-tablet',
      initialDisplayName: 'iPad',
      initialFormFactor: DeviceFormFactor.tablet,
      autoConnect: false,
    );
    final phoneCtrl = NotebookController(
      initialPeerId: 'ctrl-phone',
      initialDisplayName: 'Phone',
      initialFormFactor: DeviceFormFactor.phone,
      autoConnect: false,
    );
    addTearDown(tabletCtrl.dispose);
    addTearDown(phoneCtrl.dispose);

    final stickyId = tabletCtrl.createStickyNote(initialText: 'iPad 灵感便签');
    final tabletSnap = tabletCtrl.doc.toSnapshotJson();

    final cardId = phoneCtrl.createTextCard(initialText: '# 手机端卡片');
    final phoneSnap = phoneCtrl.doc.toSnapshotJson();

    tabletCtrl.doc.mergeSnapshotJson(phoneSnap);
    phoneCtrl.doc.mergeSnapshotJson(tabletSnap);

    expect(phoneCtrl.doc.getElement(stickyId)?.text, 'iPad 灵感便签');
    expect(tabletCtrl.doc.getElement(cardId)?.text, '# 手机端卡片');
    expect(tabletCtrl.doc.deepDigest(), phoneCtrl.doc.deepDigest());
  });

  testWidgets(
    'Android native scan-to-pair and gallery image picker insert work on Phone viewport',
    (WidgetTester tester) async {
      final androidCtrl = NotebookController(
        platformAdapter: _FakeAndroidPlatformAdapter(),
        initialPeerId: 'test-android',
        initialFormFactor: DeviceFormFactor.phone,
        autoConnect: false,
      );
      addTearDown(androidCtrl.dispose);

      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(SyncCanvasApp(controller: androidCtrl));
      await tester.pumpAndSettle();

      // 1. One-tap camera QR pairing from Phone top bar
      expect(find.byTooltip('扫码连接'), findsOneWidget);
      await tester.tap(find.byTooltip('扫码连接'));
      await tester.pumpAndSettle();

      expect(androidCtrl.wsUrl, 'ws://192.168.1.66:8787/ws');
      expect(androidCtrl.roomId, 'study');

      // 2. Gallery image picker inside Insert Image dialog
      final beforeCount = androidCtrl.activeElements.length;
      final imageBtn = find.byTooltip('插入图片 / 图示');
      await tester.ensureVisible(imageBtn);
      await tester.tap(imageBtn);
      await tester.pumpAndSettle();

      expect(find.text('从系统相册选择图片'), findsOneWidget);
      await tester.tap(find.text('从系统相册选择图片'));
      await tester.pumpAndSettle();

      expect(androidCtrl.activeElements.length, beforeCount + 1);
      final inserted = androidCtrl.activeElements.last;
      expect(inserted.kind, ElementKind.image);
      expect(inserted.imageUri, startsWith('data:image/png;base64,'));

      // 3. Open Connect dialog and verify Host & Radar sections render cleanly
      await tester.tap(find.byTooltip('三端扫码连接'));
      await tester.pumpAndSettle();
      expect(find.text('随身房主模式（无路由器自组网）'), findsOneWidget);
      expect(find.text('附近画板雷达（BLE 蓝牙 + 局域网自动发现）'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
    },
  );

  test(
    'Embedded host mode + BLE beacon -> hotspot handoff configures WebSocket',
    () async {
      final hostAdapter = _FakeAndroidPlatformAdapter();
      final clientAdapter = _FakeAndroidPlatformAdapter();
      addTearDown(hostAdapter.dispose);
      addTearDown(clientAdapter.dispose);

      final hostCtrl = NotebookController(
        platformAdapter: hostAdapter,
        initialPeerId: 'host-android-1',
        initialDisplayName: 'Android 房主',
        initialFormFactor: DeviceFormFactor.phone,
        autoConnect: false,
      );
      final clientCtrl = NotebookController(
        platformAdapter: clientAdapter,
        initialPeerId: 'client-android-2',
        initialDisplayName: 'Android 协作者',
        initialFormFactor: DeviceFormFactor.phone,
        autoConnect: false,
      );
      addTearDown(hostCtrl.dispose);
      addTearDown(clientCtrl.dispose);

      // Start embedded host + local hotspot
      final started = await hostCtrl.startLocalHostMode(
        requestAndroidHotspot: true,
      );
      expect(started, isTrue);
      expect(hostCtrl.isHostingLocalServer, isTrue);
      expect(hostCtrl.hostedServerPort, 8787);
      expect(hostCtrl.activeHotspot?.ssid, 'SyncCanvas_Test');
      expect(hostAdapter.lastHostBeacon?.hotspotSsid, 'SyncCanvas_Test');
      expect(hostAdapter.lastHostBeacon?.hotspotPassword, 'pass9999');

      // Peer discovers host via BLE beacon and automatically joins hotspot
      await clientCtrl.startDiscovery();
      clientAdapter.beaconStream.add(
        hostAdapter.lastHostBeacon!.copyWith(
          roomId: 'ble-room',
          transport: DiscoveryTransport.ble,
          rssi: -48,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(clientCtrl.nearbyBoards.length, 1);

      final joinOutcome =
          await clientCtrl.joinNearbyBoard(clientCtrl.nearbyBoards.first);
      expect(joinOutcome.connected, isTrue);
      expect(clientAdapter.joinedHotspot, isTrue);
      expect(clientCtrl.wsUrl, 'ws://192.168.43.1:8787/ws');
      expect(clientCtrl.roomId, 'ble-room');

      await hostCtrl.stopLocalHostMode();
      await clientCtrl.stopDiscovery();
    },
  );
}
