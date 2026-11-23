import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
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
  final StreamController<VoiceSpeechEvent> speechStream =
      StreamController<VoiceSpeechEvent>.broadcast();

  bool joinedHotspot = false;
  NearbyBoardBeacon? lastHostBeacon;
  bool serverRunning = false;
  bool speechListening = false;
  String? lastSpeechLocale;
  String? lastLocalModelPath;
  String? lastLocalRuntimePath;
  bool simulateLinuxLocalAsr = false;
  LocalAsrStatus localAsrStatus = const LocalAsrStatus.unsupported();
  String? fakePickedAsrPath;
  Stream<LocalAsrDownloadProgress> Function(
    LocalAsrModelPreset preset, {
    bool useMirror,
  })? onInstallLinuxAsrPreset;
  String? lastExportedFilename;
  String? lastExportedText;
  Uint8List? lastExportedBytes;

  @override
  bool get isWeb => false;

  @override
  bool get canPickImage => true;

  @override
  bool get canImportPdf => true;

  @override
  bool get canScanQrCode => true;

  @override
  bool get canHostServer => true;

  @override
  bool get canDiscoverNearby => true;

  @override
  bool get canManageHotspot => true;

  @override
  bool get canTranscribeSpeech => true;

  @override
  bool get supportsLocalAsrModels => simulateLinuxLocalAsr;

  @override
  Stream<NearbyBoardBeacon> get nearbyBeacons => beaconStream.stream;

  @override
  Stream<VoiceSpeechEvent> get speechEvents => speechStream.stream;

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
  Future<HttpResponseData?> httpPostJson(
    Uri uri,
    String jsonBody, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (uri.path.endsWith('/chat/completions')) {
      return HttpResponseData(
        statusCode: 200,
        body: jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'content':
                    '# 实对称矩阵特征值课堂总结\n\n- 重点推导了矩阵的特征值与实对称矩阵正交对角化定理。\n- 注意构造正交特征向量组。\n\n### 待办跟进\n- [ ] 完成第三章课后习题',
              },
            },
          ],
        }),
      );
    }
    return null;
  }

  @override
  Future<String?> pickImageAsDataUrl() async => _tinyPngDataUrl;

  @override
  Future<PdfImportedDocument?> pickAndRenderPdf({int maxPages = 30}) async =>
      const PdfImportedDocument(
        fileName: '线性代数讲义.pdf',
        totalPages: 2,
        pages: <PdfRenderedPage>[
          PdfRenderedPage(
            pageNumber: 1,
            width: 595,
            height: 842,
            dataUrl: _tinyPngDataUrl,
          ),
          PdfRenderedPage(
            pageNumber: 2,
            width: 595,
            height: 842,
            dataUrl: _tinyPngDataUrl,
          ),
        ],
      );

  @override
  Future<String?> scanQrCode() async =>
      'http://192.168.1.66:8787/?room=study';

  @override
  Future<String?> loadImagePathAsDataUrl(String filePath) async => null;

  @override
  Future<String?> saveExportFile(String filename, String content) async {
    lastExportedFilename = filename;
    lastExportedText = content;
    return '/tmp/$filename';
  }

  @override
  Future<String?> saveExportBytes(
    String filename,
    Uint8List bytes, {
    String mimeType = 'image/png',
  }) async {
    lastExportedFilename = filename;
    lastExportedBytes = bytes;
    return '/tmp/$filename';
  }

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
  Future<OperationOutcome> startSpeechRecognition({
    String localeId = 'zh-CN',
    String? localModelPath,
    String? localRuntimePath,
  }) async {
    lastSpeechLocale = localeId;
    lastLocalModelPath = localModelPath;
    lastLocalRuntimePath = localRuntimePath;
    speechListening = true;
    return const OperationOutcome(ok: true);
  }

  @override
  Future<void> stopSpeechRecognition() async {
    speechListening = false;
  }

  @override
  Future<LocalAsrStatus> queryLocalAsrStatus({
    String? customModelPath,
    String? customRuntimePath,
  }) async {
    if (!simulateLinuxLocalAsr) {
      return const LocalAsrStatus.unsupported();
    }
    if (customModelPath != null && customModelPath.trim().isNotEmpty) {
      return LocalAsrStatus(
        supported: true,
        ready: localAsrStatus.hasRuntime,
        hasRuntime: localAsrStatus.hasRuntime,
        hasModel: true,
        engineKind: LocalAsrEngineKind.sherpaTransducer,
        engineSummary: '自定义测试模型',
        activeModelPath: customModelPath.trim(),
        activeRuntimePath:
            customRuntimePath?.trim().isNotEmpty == true
                ? customRuntimePath!.trim()
                : localAsrStatus.activeRuntimePath,
        modelsRootDir: localAsrStatus.modelsRootDir,
        audioTool: localAsrStatus.audioTool,
        installedPresetIds: localAsrStatus.installedPresetIds,
      );
    }
    return localAsrStatus;
  }

  @override
  Stream<LocalAsrDownloadProgress> installLinuxAsrPreset(
    LocalAsrModelPreset preset, {
    bool useMirror = false,
  }) {
    if (onInstallLinuxAsrPreset != null) {
      return onInstallLinuxAsrPreset!(preset, useMirror: useMirror);
    }
    return const Stream<LocalAsrDownloadProgress>.empty();
  }

  @override
  Future<String?> pickLocalAsrPath({required bool directory}) async =>
      fakePickedAsrPath;

  @override
  Future<void> dispose() async {
    await beaconStream.close();
    await speechStream.close();
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

  testWidgets(
    'Tablet stylus writing ignores multi-touch palm contacts and preserves ink on pointercancel',
    (WidgetTester tester) async {
      final tabletCtrl = NotebookController(
        initialPeerId: 'tablet-stylus-peer',
        initialDisplayName: 'iPad Pro',
        initialFormFactor: DeviceFormFactor.tablet,
        autoConnect: false,
      );
      addTearDown(tabletCtrl.dispose);

      await tester.binding.setSurfaceSize(const Size(834, 1194));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(SyncCanvasApp(controller: tabletCtrl));
      await tester.pumpAndSettle();

      tabletCtrl.setTool(CanvasTool.pen);
      await tester.pump();

      var rootRebuildsDuringStroke = 0;
      void countRootRebuild() => rootRebuildsDuringStroke++;
      tabletCtrl.addListener(countRootRebuild);

      var livePaintTicks = 0;
      void countLivePaint() => livePaintTicks++;
      tabletCtrl.livePaintListenable.addListener(countLivePaint);

      final beforeCount = tabletCtrl.activeElements.length;
      final boardCenter = tester.getCenter(find.byType(BoardStage));

      // 1. Start writing with a hardware stylus
      final stylus = await tester.startGesture(
        boardCenter + const Offset(-80, -30),
        kind: PointerDeviceKind.stylus,
        pointer: 11,
      );
      await stylus.moveBy(const Offset(24, 10));
      await stylus.moveBy(const Offset(24, 12));

      // 2. Two resting-palm touch contacts land mid-stroke — must NOT cancel or
      // hijack the active stylus stroke!
      final palm1 = await tester.startGesture(
        boardCenter + const Offset(90, 120),
        kind: PointerDeviceKind.touch,
        pointer: 21,
      );
      final palm2 = await tester.startGesture(
        boardCenter + const Offset(130, 145),
        kind: PointerDeviceKind.touch,
        pointer: 22,
      );
      await palm1.moveBy(const Offset(8, 6));
      await palm2.moveBy(const Offset(-6, 8));

      // Stylus keeps writing smoothly with zero root widget rebuilds
      await stylus.moveBy(const Offset(30, 15));
      await stylus.moveBy(const Offset(28, 8));
      expect(tabletCtrl.activeStroke, isNotNull);
      expect(rootRebuildsDuringStroke, 0);
      expect(livePaintTicks, greaterThanOrEqualTo(5));

      await palm1.up();
      await palm2.up();
      await stylus.up();
      await tester.pumpAndSettle();

      tabletCtrl.removeListener(countRootRebuild);
      tabletCtrl.livePaintListenable.removeListener(countLivePaint);

      expect(tabletCtrl.activeElements.length, beforeCount + 1);
      final stylusStroke = tabletCtrl.activeElements.last;
      expect(stylusStroke.kind, ElementKind.stroke);
      expect(stylusStroke.points.length, greaterThanOrEqualTo(5));
      expect(stylusStroke.width, greaterThan(90));

      // 3. Intentional touch stroke interrupted by OS/browser PointerCancelEvent
      // must still commit locally instead of flashing and disappearing!
      final countAfterStylus = tabletCtrl.activeElements.length;
      final finger = await tester.startGesture(
        boardCenter + const Offset(-60, 80),
        kind: PointerDeviceKind.touch,
        pointer: 31,
      );
      for (var i = 0; i < 6; i++) {
        await finger.moveBy(const Offset(14, 6));
      }
      expect(tabletCtrl.hasSubstantialActiveStroke, isTrue);
      await finger.cancel();
      await tester.pumpAndSettle();

      expect(tabletCtrl.activeElements.length, countAfterStylus + 1);
    },
  );

  test(
    'Collaborative end-to-end: local tablet renders stroke before async upload and buffers mid-stroke remote ops without dropping ink',
    () async {
      final hostAdapter = createPlatformAdapter();
      addTearDown(hostAdapter.dispose);
      final port = await hostAdapter.startEmbeddedServer(preferredPort: 0);
      expect(port, isNotNull);

      await HttpOverrides.runWithHttpOverrides(() async {
        final tabletCtrl = NotebookController(
          initialPeerId: 'collab-tablet',
          initialDisplayName: 'Tablet Writer',
          initialFormFactor: DeviceFormFactor.tablet,
          autoConnect: false,
        );
        final desktopCtrl = NotebookController(
          initialPeerId: 'collab-desktop',
          initialDisplayName: 'Desktop Collaborator',
          initialFormFactor: DeviceFormFactor.desktop,
          autoConnect: false,
        );
        addTearDown(tabletCtrl.dispose);
        addTearDown(desktopCtrl.dispose);

        await tabletCtrl.configureConnection(
          wsUrl: 'ws://127.0.0.1:$port/ws',
          roomId: 'smooth-ink-room',
        );
        await desktopCtrl.configureConnection(
          wsUrl: 'ws://127.0.0.1:$port/ws',
          roomId: 'smooth-ink-room',
        );
        await tabletCtrl.connect();
        await desktopCtrl.connect();

        // Wait for both clients to finish initial welcome handshake
        final deadline = DateTime.now().add(const Duration(seconds: 4));
        while (DateTime.now().isBefore(deadline) &&
            (tabletCtrl.connectionState != SyncConnectionState.connected ||
                desktopCtrl.connectionState != SyncConnectionState.connected)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(tabletCtrl.connectionState, SyncConnectionState.connected);
        expect(desktopCtrl.connectionState, SyncConnectionState.connected);

        var tabletRootNotifiesMidStroke = 0;
        void onTabletRootNotify() => tabletRootNotifiesMidStroke++;

        // Tablet starts drawing locally
        tabletCtrl.startLocalStroke(const Offset(100, 100), pressure: 0.7);
        tabletCtrl.addListener(onTabletRootNotify);

        for (var i = 1; i <= 12; i++) {
          tabletCtrl.appendLocalStrokePoint(
            Offset(100 + i * 8.0, 100 + i * 4.0),
            pressure: 0.75,
          );
          // Meanwhile Desktop blasts cursor presence + commits a sticky note mid-stroke!
          desktopCtrl.updateCursorPresence(
            Offset(300 + i * 5.0, 220),
            visible: true,
          );
          if (i == 6) {
            desktopCtrl.createStickyNote(initialText: '桌面端并发便签');
            desktopCtrl.flushPendingUploadsNow();
          }
          await Future<void>.delayed(const Duration(milliseconds: 12));
        }

        // Mid-stroke: zero root widget rebuilds occurred on the tablet even while
        // receiving remote cursor presence & remote opBatch!
        expect(tabletCtrl.activeStroke, isNotNull);
        expect(tabletRootNotifiesMidStroke, 0);
        tabletCtrl.removeListener(onTabletRootNotify);

        final beforeFinishCount = tabletCtrl.activeElements.length;
        tabletCtrl.finishLocalStroke();

        // Immediately on pen-up (BEFORE async network upload timer even fires),
        // the tablet's local committed elements ALREADY include the new stroke!
        expect(tabletCtrl.activeStroke, isNull);
        expect(
          tabletCtrl.activeElements.length,
          greaterThanOrEqualTo(beforeFinishCount + 1),
        );

        // Wait briefly for the 36ms background upload batch to reach Desktop
        final syncDeadline = DateTime.now().add(const Duration(seconds: 4));
        while (DateTime.now().isBefore(syncDeadline) &&
            tabletCtrl.doc.deepDigest() != desktopCtrl.doc.deepDigest()) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(tabletCtrl.doc.deepDigest(), desktopCtrl.doc.deepDigest());
      }, _RealSocketHttpOverrides());
    },
  );

  test(
    'Lasso multi-select group actions, single-step compound Undo, Hold-to-Snap straight line, and PenPresets work cleanly',
    () {
      final ctrl = NotebookController(
        initialPeerId: 'note-tools-peer',
        initialDisplayName: 'Note Tester',
        initialFormFactor: DeviceFormFactor.tablet,
        autoConnect: false,
      );
      addTearDown(ctrl.dispose);

      final pageId = ctrl.createPage(
        title: '套索与拉直测试页',
        background: PageBackground.mistakeBook,
      );
      expect(ctrl.activePageId, pageId);

      // 1. Draw two strokes in known positions
      ctrl.setActiveColor(const Color(0xFF0F172A));
      ctrl.startLocalStroke(const Offset(100, 120));
      ctrl.appendLocalStrokePoint(const Offset(140, 125));
      ctrl.appendLocalStrokePoint(const Offset(180, 122));
      ctrl.finishLocalStroke();

      ctrl.startLocalStroke(const Offset(110, 180));
      ctrl.appendLocalStrokePoint(const Offset(150, 185));
      ctrl.appendLocalStrokePoint(const Offset(190, 182));
      ctrl.finishLocalStroke();

      expect(ctrl.activeElements.length, 2);
      final s1 = ctrl.activeElements[0];
      final s2 = ctrl.activeElements[1];

      // 2. Circle both strokes with Lasso
      ctrl.setTool(CanvasTool.lasso);
      ctrl.startLasso(const Offset(80, 90));
      ctrl.appendLassoPoint(const Offset(220, 90));
      ctrl.appendLassoPoint(const Offset(220, 220));
      ctrl.appendLassoPoint(const Offset(80, 220));
      ctrl.finishLasso();

      expect(ctrl.selectedElementIds.length, 2);
      expect(ctrl.selectionBounds, isNotNull);

      // 3. Group move both strokes + single-step compound Undo
      final origins = ctrl.captureSelectedOrigins();
      ctrl.previewMoveSelectedElements(origins, const Offset(50, 30));
      ctrl.commitGroupMoveUndo(origins);
      expect(ctrl.doc.getElement(s1.id)!.x, closeTo(s1.x + 50, 0.01));
      expect(ctrl.doc.getElement(s2.id)!.y, closeTo(s2.y + 30, 0.01));

      ctrl.undo();
      expect(ctrl.doc.getElement(s1.id)!.x, closeTo(s1.x, 0.01));
      expect(ctrl.doc.getElement(s2.id)!.y, closeTo(s2.y, 0.01));

      // 4. Group recolor + duplicate + single-step compound Undo
      ctrl.recolorSelectedElements(const Color(0xFFDC2626));
      expect(ctrl.doc.getElement(s1.id)!.colorValue, 0xFFDC2626);
      expect(ctrl.doc.getElement(s2.id)!.colorValue, 0xFFDC2626);

      final cloned = ctrl.duplicateSelectedElements();
      expect(cloned.length, 2);
      expect(ctrl.activeElements.length, 4);
      ctrl.undo();
      expect(ctrl.activeElements.length, 2);

      // 5. Hold-to-Snap wobbly freehand stroke -> straight line + rubber-band aiming
      ctrl.setTool(CanvasTool.pen);
      ctrl.startLocalStroke(const Offset(200, 300));
      ctrl.appendLocalStrokePoint(const Offset(250, 318));
      ctrl.appendLocalStrokePoint(const Offset(300, 289));
      ctrl.appendLocalStrokePoint(const Offset(360, 305));
      expect(ctrl.snapActiveStrokeToStraightLine(), isTrue);
      expect(ctrl.isActiveStrokeSnappedLine, isTrue);

      // Aim snapped line horizontally to (400, 300)
      ctrl.appendLocalStrokePoint(const Offset(400, 300));
      ctrl.finishLocalStroke();
      final snappedStroke = ctrl.activeElements.last;
      for (final p in snappedStroke.points) {
        expect(snappedStroke.y + p.dy, closeTo(300.0, 0.05));
      }

      // 6. Pen presets apply & save
      ctrl.applyPenPreset(2);
      expect(ctrl.tool, CanvasTool.highlighter);
      expect(ctrl.activePenPresetIndex, 2);
      ctrl.setActiveColor(const Color(0xFF16A34A));
      ctrl.saveCurrentToPenPreset(1);
      expect(ctrl.penPresets[1].colorValue, 0xFF16A34A);
    },
  );

  testWidgets(
    'Multi-page PDF import renders all pages continuously on ONE locked canvas page immune to eraser, supports search/bookmark, and exports PNG & Markdown',
    (WidgetTester tester) async {
      final adapter = _FakeAndroidPlatformAdapter();
      addTearDown(adapter.dispose);

      final ctrl = NotebookController(
        platformAdapter: adapter,
        initialPeerId: 'pdf-note-peer',
        initialDisplayName: 'Mac PDF Tester',
        initialFormFactor: DeviceFormFactor.desktop,
        autoConnect: false,
      );
      addTearDown(ctrl.dispose);

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(SyncCanvasApp(controller: ctrl));
      await tester.pumpAndSettle();

      final initialPageCount = ctrl.activePages.length;

      // 1. Import 2-page PDF via toolbar dialog -> creates ONLY ONE continuous canvas page
      await tester.tap(find.byTooltip('导入 PDF 讲义'));
      await tester.pumpAndSettle();
      expect(find.text('导入 PDF 讲义 / 文档'), findsOneWidget);

      await tester.tap(find.text('选择 PDF 并导入'));
      await tester.pumpAndSettle();

      expect(ctrl.activePages.length, initialPageCount + 1);
      expect(ctrl.activePage!.title, '线性代数讲义');

      final sheets = List<CanvasElementModel>.from(ctrl.activeElements)
        ..sort((a, b) => a.y.compareTo(b.y));
      expect(sheets.length, 2);
      expect(sheets[0].kind, ElementKind.image);
      expect(sheets[1].kind, ElementKind.image);
      expect(sheets[0].locked, isTrue);
      expect(sheets[1].locked, isTrue);
      expect(sheets[0].zIndex, lessThanOrEqualTo(-50));
      expect(sheets[1].zIndex, lessThanOrEqualTo(-50));
      expect(sheets[1].y, greaterThan(sheets[0].y + sheets[0].height));
      expect(sheets[0].text, '线性代数讲义 · P1');
      expect(sheets[1].text, '线性代数讲义 · P2');

      final pdfSheet1 = sheets[0];
      final pdfSheet2 = sheets[1];

      // 2. Annotate across P1 & P2 on that SAME canvas page and verify eraser NEVER deletes locked PDF sheets
      ctrl.startLocalStroke(const Offset(200, 220));
      ctrl.appendLocalStrokePoint(const Offset(260, 225));
      ctrl.finishLocalStroke();
      ctrl.createStickyNote(
        sceneCenter: Offset(360, pdfSheet2.y + 180),
        initialText: '特征值与特征向量核心定理',
      );
      ctrl.setEditingCard(null);
      await tester.pumpAndSettle();
      expect(ctrl.activeElements.length, 4);

      // Erase directly over PDF sheet backgrounds & over the handwritten stroke
      ctrl.eraseAt(const Offset(100, 100)); // hits only locked PDF sheet P1 -> ignored
      ctrl.eraseAt(Offset(100, pdfSheet2.y + 80)); // hits only locked PDF sheet P2 -> ignored
      expect(ctrl.doc.getElement(pdfSheet1.id)!.deleted, isFalse);
      expect(ctrl.doc.getElement(pdfSheet2.id)!.deleted, isFalse);

      ctrl.eraseAt(const Offset(230, 222)); // erases handwritten stroke on top
      expect(ctrl.activeElements.length, 3);
      expect(ctrl.doc.getElement(pdfSheet1.id)!.deleted, isFalse);
      expect(ctrl.doc.getElement(pdfSheet2.id)!.deleted, isFalse);

      // 3. Bookmark active continuous PDF page, test currentPage placement, and run full-text search
      ctrl.togglePageBookmark(ctrl.activePageId);
      expect(ctrl.activePage!.bookmarked, isTrue);

      final hits = ctrl.searchWorkspaceContent('特征向量');
      expect(hits, isNotEmpty);
      ctrl.focusOnElement(hits.first.pageId, hits.first.elementId);
      expect(ctrl.activePage!.title, '线性代数讲义');

      // Embed another PDF directly into current canvas page below existing sheets
      await ctrl.importPdfDocument(
        const PdfImportedDocument(
          fileName: '补充习题.pdf',
          totalPages: 1,
          pages: <PdfRenderedPage>[
            PdfRenderedPage(
              pageNumber: 1,
              width: 595,
              height: 842,
              dataUrl: _FakeAndroidPlatformAdapter._tinyPngDataUrl,
            ),
          ],
        ),
        placement: PdfImportPlacement.currentPage,
      );
      expect(ctrl.activePages.length, initialPageCount + 1);
      final appendedSheet = ctrl.activeElements
          .where((e) => e.kind == ElementKind.image)
          .reduce((a, b) => a.y > b.y ? a : b);
      expect(appendedSheet.text, '补充习题 · P1');
      expect(appendedSheet.y, greaterThan(pdfSheet2.y + pdfSheet2.height));

      // 4. Export full notebook Markdown & tall continuous PNG
      final mdPath = await ctrl.saveActiveNotebookMarkdown();
      expect(mdPath, isNotNull);
      expect(adapter.lastExportedText, contains('线性代数讲义 ⭐'));
      expect(adapter.lastExportedText, contains('PDF 讲义连续底图'));
      expect(adapter.lastExportedText, contains('共 3 页'));
      expect(adapter.lastExportedText, contains('特征值与特征向量核心定理'));

      // Note: ui.Picture.toImage in headless widget tests requires tester.runAsync
      final pngPath = await tester.runAsync(() => ctrl.exportActivePagePng());
      expect(pngPath, isNotNull);
      expect(adapter.lastExportedBytes, isNotNull);
      expect(adapter.lastExportedBytes!.length, greaterThan(64));
      // Verify PNG magic signature: 89 50 4E 47
      expect(adapter.lastExportedBytes!.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
    },
  );

  testWidgets(
    'Toolbar drags across edges/floating, switches to vertical with Undo and Redo at top, and collapses to mini ball',
    (WidgetTester tester) async {
      final ctrl = NotebookController(
        initialPeerId: 'toolbar-drag-peer',
        initialDisplayName: 'Drag Tester',
        initialFormFactor: DeviceFormFactor.desktop,
        autoConnect: false,
      );
      addTearDown(ctrl.dispose);

      await tester.binding.setSurfaceSize(const Size(1200, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(SyncCanvasApp(controller: ctrl));
      await tester.pumpAndSettle();

      expect(ctrl.toolbarDock, ToolbarDock.bottom);
      expect(ctrl.toolbarIsVertical, isFalse);

      // Drag handle to the left edge -> switches to vertical dock on left
      final handleFinder = find.byKey(const ValueKey<String>('toolbar-drag-handle'));
      await tester.drag(handleFinder, const Offset(-540, -240));
      await tester.pumpAndSettle();

      expect(ctrl.toolbarDock, ToolbarDock.left);
      expect(ctrl.toolbarIsVertical, isTrue);
      expect(
        find.byKey(const ValueKey<String>('vertical-top-undo-redo')),
        findsOneWidget,
      );

      // Verify Undo & Redo are pinned above drawing tools in vertical mode
      final undoBtnFinder = find.byTooltip('撤销 (Ctrl/Cmd+Z)');
      final redoBtnFinder = find.byTooltip('重做 (Ctrl/Cmd+Shift+Z)');
      expect(undoBtnFinder, findsOneWidget);
      expect(redoBtnFinder, findsOneWidget);

      final undoTop = tester.getTopLeft(undoBtnFinder).dy;
      final redoTop = tester.getTopLeft(redoBtnFinder).dy;
      final selectTop = tester.getTopLeft(find.byTooltip('选择 / 移动 (V)')).dy;
      final penTop = tester.getTopLeft(find.byTooltip('压感钢笔 (P)')).dy;
      expect(undoTop, lessThan(selectTop));
      expect(redoTop, lessThan(selectTop));
      expect(undoTop, lessThan(penTop));

      // Verify drawing + top-pinned Undo & Redo buttons work smoothly
      final beforeCount = ctrl.activeElements.length;
      final boardCenter = tester.getCenter(find.byType(BoardStage));
      final gesture = await tester.startGesture(boardCenter + const Offset(80, -20));
      await gesture.moveBy(const Offset(75, 35));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(ctrl.activeElements.length, beforeCount + 1);

      await tester.tap(undoBtnFinder);
      await tester.pumpAndSettle();
      expect(ctrl.activeElements.length, beforeCount);

      await tester.tap(redoBtnFinder);
      await tester.pumpAndSettle();
      expect(ctrl.activeElements.length, beforeCount + 1);

      // Drag handle to center -> free floating (keeping vertical orientation)
      await tester.drag(handleFinder, const Offset(360, 40));
      await tester.pumpAndSettle();
      expect(ctrl.toolbarDock, ToolbarDock.floating);
      expect(ctrl.toolbarIsVertical, isTrue);
      expect(
        find.byKey(const ValueKey<String>('vertical-top-undo-redo')),
        findsOneWidget,
      );

      // Collapse to mini floating ball & expand back
      await tester.tap(find.byTooltip('收起为悬浮笔球'));
      await tester.pumpAndSettle();
      expect(ctrl.toolbarCollapsed, isTrue);
      expect(
        find.byKey(const ValueKey<String>('collapsed-toolbar-ball')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('展开画笔工具栏'));
      await tester.pumpAndSettle();
      expect(ctrl.toolbarCollapsed, isFalse);

      // Reset position back to bottom horizontal
      ctrl.resetToolbarPosition();
      await tester.pumpAndSettle();
      expect(ctrl.toolbarDock, ToolbarDock.bottom);
      expect(ctrl.toolbarIsVertical, isFalse);
    },
  );

  testWidgets(
    'MindFlow same-canvas tokens, branch spawning, directed connectors, cluster drag, auto-layout, cascade delete, and AI JSON import/export coexist with PDF & ink',
    (WidgetTester tester) async {
      final adapter = _FakeAndroidPlatformAdapter();
      addTearDown(adapter.dispose);

      final ctrl = NotebookController(
        platformAdapter: adapter,
        initialPeerId: 'mindflow-peer',
        initialDisplayName: 'MindFlow Tester',
        initialFormFactor: DeviceFormFactor.desktop,
        autoConnect: false,
      );
      addTearDown(ctrl.dispose);

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(SyncCanvasApp(controller: ctrl));
      await tester.pumpAndSettle();

      // 1. Import continuous 2-page PDF via toolbar dialog onto one canvas page
      await tester.tap(find.byTooltip('导入 PDF 讲义'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择 PDF 并导入'));
      await tester.pumpAndSettle();

      // 2. Select MindFlow token tool from toolbar and create root token on canvas
      final tokenToolBtn = find.byTooltip('概念词块 (N)');
      expect(tokenToolBtn, findsOneWidget);
      await tester.tap(tokenToolBtn);
      await tester.pumpAndSettle();
      expect(ctrl.tool, CanvasTool.token);

      final rootId = ctrl.createMindFlowToken(
        sceneCenter: const Offset(980, 140),
        initialText: '矩阵特征值',
        color: MindFlowColor.yellow,
        beginEditing: false,
      );
      await tester.pumpAndSettle();

      // 3. Click inline branch button to spawn a connected child token
      final branchFinder = find.byKey(ValueKey<String>('spawn-branch-$rootId'));
      expect(branchFinder, findsOneWidget);
      await tester.tap(branchFinder);
      await tester.pumpAndSettle();

      final activeAfterBranch =
          ctrl.activeElements.where((e) => !e.deleted).toList();
      final tokens =
          activeAfterBranch.where((e) => e.kind == ElementKind.token).toList();
      final connectors = activeAfterBranch
          .where((e) => e.kind == ElementKind.connector)
          .toList();
      final sheets = activeAfterBranch
          .where((e) => e.kind == ElementKind.image && e.locked)
          .toList();
      expect(sheets.length, 2);
      expect(tokens.length, 2);
      expect(connectors.length, 1);
      expect(connectors.first.sourceId, rootId);
      final childToken = tokens.firstWhere((t) => t.id != rootId);
      expect(connectors.first.targetId, childToken.id);

      // Exit text editing before checking cluster & AI actions
      ctrl.setEditingCard(null);
      await tester.pumpAndSettle();

      // 4. Multi-select both tokens & group them into a dashed cluster
      final lassoPoly = <Offset>[
        Offset(tokens[0].x - 40, tokens[0].y - 40),
        Offset(tokens[1].x + tokens[1].width + 40, tokens[0].y - 40),
        Offset(
          tokens[1].x + tokens[1].width + 40,
          tokens[1].y + tokens[1].height + 40,
        ),
        Offset(tokens[0].x - 40, tokens[1].y + tokens[1].height + 40),
      ];
      ctrl.startLasso(lassoPoly.first);
      for (final p in lassoPoly.skip(1)) {
        ctrl.appendLassoPoint(p);
      }
      ctrl.finishLasso();
      await tester.pumpAndSettle();
      expect(ctrl.selectedElementIds, containsAll(<String>[rootId, childToken.id]));

      final clusterId = ctrl.groupSelectionIntoCluster(title: '核心架构');
      expect(clusterId, isNotNull);
      await tester.pumpAndSettle();

      final clusterEl = ctrl.doc.getElement(clusterId!)!;
      final spatialMembers = computeSpatialMemberIds(clusterEl, tokens);
      expect(spatialMembers, containsAll(<String>[rootId, childToken.id]));

      // Drag cluster header via cluster origins -> spatial members follow!
      final rootXBefore = ctrl.doc.getElement(rootId)!.x;
      final origins = ctrl.captureClusterDragOrigins(clusterId);
      expect(origins.keys, containsAll(<String>[clusterId, rootId, childToken.id]));
      ctrl.previewMoveSelectedElements(origins, const Offset(40, 25));
      ctrl.commitGroupMoveUndo(origins);
      await tester.pumpAndSettle();
      expect(ctrl.doc.getElement(rootId)!.x, closeTo(rootXBefore + 40, 0.5));

      // 5. Auto-layout avoids locked PDF sheets (starts at x >= 920)
      final movedCount = ctrl.autoLayoutActivePageMindFlow();
      expect(movedCount, greaterThanOrEqualTo(1));
      expect(ctrl.doc.getElement(rootId)!.x, greaterThanOrEqualTo(920.0));
      expect(
        ctrl.doc.getElement(childToken.id)!.x,
        greaterThan(ctrl.doc.getElement(rootId)!.x),
      );

      // 6. Export canonical MindFlow JSON + SVG, then import AI JSON via dialog
      final boardJsonStr = ctrl.exportActivePageMindFlowBoardJson();
      final decodedBoard = jsonDecode(boardJsonStr) as Map<String, dynamic>;
      expect(decodedBoard['format'], 'mindflow');
      expect(decodedBoard['schemaVersion'], 1);
      expect((decodedBoard['tokens'] as List).length, 2);
      expect((decodedBoard['edges'] as List).length, 1);
      expect((decodedBoard['clusters'] as List).length, 1);
      expect(ctrl.exportActivePageMindFlowSvg(), contains('<svg'));

      await tester.tap(find.byTooltip('MindFlow AI 协同与 MCP'));
      await tester.pumpAndSettle();
      expect(find.text('MindFlow × SyncCanvas AI 协同中心'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).last,
        '''```json
{
  "title": "AI 生成扩展",
  "tokens": [
    { "id": "ai_node_1", "color": "green", "text": "特征分解应用", "x": 100, "y": 420 }
  ],
  "edges": []
}
```''',
      );
      final importBtn = find.byKey(const ValueKey<String>('import-mindflow-json-btn'));
      await tester.ensureVisible(importBtn);
      await tester.pumpAndSettle();
      await tester.tap(importBtn);
      await tester.pumpAndSettle();

      final importedAiNode = ctrl.doc.getElement('ai_node_1');
      expect(importedAiNode, isNotNull);
      expect(importedAiNode!.kind, ElementKind.token);
      expect(importedAiNode.x, greaterThanOrEqualTo(920.0));

      // Close MindFlow dialog
      await tester.tap(find.byIcon(Icons.close_rounded).last);
      await tester.pumpAndSettle();

      // 7. Deleting a connected token cascades to incident connectors & undo restores both
      ctrl.deleteElement(rootId);
      await tester.pumpAndSettle();
      expect(ctrl.doc.getElement(rootId)!.deleted, isTrue);
      expect(ctrl.doc.getElement(connectors.first.id)!.deleted, isTrue);

      ctrl.undo();
      await tester.pumpAndSettle();
      expect(ctrl.doc.getElement(rootId)!.deleted, isFalse);
      expect(ctrl.doc.getElement(connectors.first.id)!.deleted, isFalse);

      // Verify PNG & Markdown export work cleanly with MindFlow + PDF on page
      final md = ctrl.exportActiveNotebookMarkdown();
      expect(md, contains('矩阵特征值'));
      final png = await tester.runAsync(
        () => ctrl.renderActivePagePngBytes(pixelRatio: 1.0),
      );
      expect(png, isNotNull);
      expect(png!.isNotEmpty, isTrue);
    },
  );

  testWidgets(
    'Voice memo streams real-time partial & final speech while handwriting on PDF, consolidates into complete memo with optional AI polish, and syncs card to canvas',
    (WidgetTester tester) async {
      final adapter = _FakeAndroidPlatformAdapter();
      addTearDown(adapter.dispose);

      final ctrl = NotebookController(
        platformAdapter: adapter,
        initialPeerId: 'voice-memo-peer',
        initialDisplayName: 'Voice Tester',
        initialFormFactor: DeviceFormFactor.desktop,
        autoConnect: false,
      );
      addTearDown(ctrl.dispose);

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(SyncCanvasApp(controller: ctrl));
      await tester.pumpAndSettle();

      // 1. Import continuous PDF onto active canvas page
      await tester.tap(find.byTooltip('导入 PDF 讲义'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择 PDF 并导入'));
      await tester.pumpAndSettle();

      // 2. Open floating Voice Memo studio via toolbar button & start listening
      final voiceBtn = find.byTooltip('语音备忘实时转写 (U)');
      expect(voiceBtn, findsOneWidget);
      await tester.tap(voiceBtn);
      await tester.pumpAndSettle();

      expect(ctrl.voiceMemoOpen, isTrue);
      await tester.tap(find.byKey(const ValueKey<String>('toggle-voice-record-btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(ctrl.voiceMemoPhase, VoiceMemoPhase.recording);
      expect(adapter.speechListening, isTrue);

      // 3. Stream live partial hypothesis + RMS audio level
      adapter.speechStream.add(
        const VoiceSpeechEvent(type: VoiceSpeechEventType.level, level: 0.72),
      );
      adapter.speechStream.add(
        const VoiceSpeechEvent(
          type: VoiceSpeechEventType.partial,
          text: '嗯 今天我们推导',
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('voice-memo-live-partial')),
        findsOneWidget,
      );
      expect(find.textContaining('嗯 今天我们推导'), findsOneWidget);

      // 4. Write a freehand stroke on the unobstructed canvas area WHILE recording!
      ctrl.setTool(CanvasTool.pen);
      await tester.pump();
      final countBeforeStroke = ctrl.activeElements.length;
      final boardCenter = tester.getCenter(find.byType(BoardStage));
      final strokeGesture =
          await tester.startGesture(boardCenter + const Offset(220, 40));
      await strokeGesture.moveBy(const Offset(110, 45));
      await strokeGesture.up();
      await tester.pump();
      expect(ctrl.activeElements.length, countBeforeStroke + 1);
      expect(ctrl.voiceMemoPhase, VoiceMemoPhase.recording);

      // 5. Emit finalized speech segments + trailing live partial
      adapter.speechStream.add(
        const VoiceSpeechEvent(
          type: VoiceSpeechEventType.finalized,
          text: '嗯 今天我们推导矩阵的特征值性质',
        ),
      );
      adapter.speechStream.add(
        const VoiceSpeechEvent(
          type: VoiceSpeechEventType.finalized,
          text: '为什么实对称矩阵一定可以对角化呢',
        ),
      );
      adapter.speechStream.add(
        const VoiceSpeechEvent(
          type: VoiceSpeechEventType.finalized,
          text: '下一步记得完成第三章课后习题',
        ),
      );
      adapter.speechStream.add(
        const VoiceSpeechEvent(
          type: VoiceSpeechEventType.partial,
          text: '注意正交特征向量组',
        ),
      );
      await tester.pump();

      // 6. Finish recording -> consolidates into complete formatted text memo
      final finishBtn = find.byKey(const ValueKey<String>('finish-voice-memo-btn'));
      await tester.ensureVisible(finishBtn);
      await tester.tap(finishBtn);
      await tester.pumpAndSettle();

      expect(ctrl.voiceMemoPhase, VoiceMemoPhase.review);
      expect(adapter.speechListening, isFalse);
      expect(ctrl.voiceMemoDraftBody, contains('推导矩阵的特征值性质。'));
      expect(ctrl.voiceMemoDraftBody, contains('为什么实对称矩阵一定可以对角化呢？'));
      expect(ctrl.voiceMemoDraftBody, contains('注意正交特征向量组。'));
      expect(ctrl.voiceMemoDraftBody, contains('- [ ] 完成第三章课后习题'));
      expect(ctrl.voiceMemoDraftBody, isNot(contains('嗯')));

      // 7. Optional AI polish updates the complete memo text smoothly
      ctrl.configureVoiceMemoAi(
        apiBaseUrl: 'https://mock.ai.local/v1',
        apiKey: 'test-key',
        modelName: 'gpt-4o-mini',
      );
      final aiPolishBtn = find.byKey(const ValueKey<String>('ai-polish-memo-btn'));
      await tester.ensureVisible(aiPolishBtn);
      await tester.tap(aiPolishBtn);
      await tester.pumpAndSettle();

      expect(ctrl.voiceMemoDraftTitle, '实对称矩阵特征值课堂总结');
      expect(ctrl.voiceMemoDraftBody, contains('实对称矩阵正交对角化定理'));
      expect(ctrl.voiceMemoDraftBody, contains('- [ ] 完成第三章课后习题'));

      // 8. Commit complete memo to canvas as a synced Markdown card beside PDF
      final commitBtn =
          find.byKey(const ValueKey<String>('commit-voice-memo-card-btn'));
      await tester.ensureVisible(commitBtn);
      await tester.tap(commitBtn);
      await tester.pumpAndSettle();

      expect(ctrl.voiceMemoOpen, isFalse);
      final createdCard = ctrl.activeElements.firstWhere(
        (e) =>
            !e.deleted &&
            e.kind == ElementKind.textCard &&
            e.text.contains('实对称矩阵正交对角化定理'),
      );
      expect(createdCard.x, greaterThanOrEqualTo(920.0));

      // Single-step Undo removes committed memo card cleanly, and Redo restores it
      ctrl.undo();
      await tester.pumpAndSettle();
      expect(ctrl.activeElements.any((e) => e.id == createdCard.id), isFalse);

      ctrl.redo();
      await tester.pumpAndSettle();
      expect(ctrl.activeElements.any((e) => e.id == createdCard.id), isTrue);
    },
  );

  testWidgets(
    'Linux voice memo exposes local ASR manager, preset download, and custom model paths',
    (WidgetTester tester) async {
      final adapter = _FakeAndroidPlatformAdapter()
        ..simulateLinuxLocalAsr = true
        ..localAsrStatus = const LocalAsrStatus(
          supported: true,
          ready: false,
          hasRuntime: false,
          hasModel: false,
          modelsRootDir: '/home/test/.local/share/synccanvas/asr',
          audioTool: 'pw-record (PipeWire)',
          issueMessage: '尚未下载或配置本地语音模型',
        )
        ..onInstallLinuxAsrPreset = (preset, {bool useMirror = false}) {
          return Stream<LocalAsrDownloadProgress>.fromIterable(
            <LocalAsrDownloadProgress>[
              LocalAsrDownloadProgress(
                stage: '正在下载 ${preset.name}...',
                fraction: 0.45,
              ),
              LocalAsrDownloadProgress(
                stage: '就绪：${preset.name}',
                fraction: 1.0,
                done: true,
                installedModelPath:
                    '/home/test/.local/share/synccanvas/asr/models/${preset.extractedDirName}',
                installedRuntimePath:
                    '/home/test/.local/share/synccanvas/asr/runtime/lib/libsherpa-onnx-c-api.so',
              ),
            ],
          );
        };

      addTearDown(adapter.dispose);

      final ctrl = NotebookController(
        platformAdapter: adapter,
        initialPeerId: 'test-linux-asr',
        initialDisplayName: 'Linux 端侧测试',
        initialFormFactor: DeviceFormFactor.desktop,
        autoConnect: false,
      );
      addTearDown(ctrl.dispose);

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(SyncCanvasApp(controller: ctrl));
      await tester.pumpAndSettle();

      // Open voice memo panel
      await tester.tap(find.byTooltip('语音备忘实时转写 (U)'));
      await tester.pumpAndSettle();

      // Linux local ASR banner and manage button should be visible
      final manageBtn =
          find.byKey(const ValueKey<String>('open-linux-asr-model-btn'));
      expect(manageBtn, findsOneWidget);

      await tester.tap(manageBtn);
      await tester.pumpAndSettle();

      expect(find.text('Linux 端侧离线语音模型管理'), findsOneWidget);

      // Update fake status right before installing preset so refresh reads installed state
      adapter.localAsrStatus = LocalAsrStatus(
        supported: true,
        ready: true,
        hasRuntime: true,
        hasModel: true,
        engineKind: LocalAsrEngineKind.sherpaTransducer,
        engineSummary: 'Sherpa-ONNX 流式 Transducer',
        activeModelPath:
            '/home/test/.local/share/synccanvas/asr/models/${kLinuxAsrModelPresets.first.extractedDirName}',
        activeRuntimePath:
            '/home/test/.local/share/synccanvas/asr/runtime/lib/libsherpa-onnx-c-api.so',
        modelsRootDir: '/home/test/.local/share/synccanvas/asr',
        audioTool: 'pw-record (PipeWire)',
        installedPresetIds: <String>[kLinuxAsrModelPresets.first.id],
      );

      final presetBtn = find.byKey(
        ValueKey<String>('install-asr-preset-${kLinuxAsrModelPresets.first.id}'),
      );
      await tester.ensureVisible(presetBtn);
      await tester.tap(presetBtn);
      await tester.pumpAndSettle();

      expect(
        ctrl.localAsrModelPath,
        endsWith(kLinuxAsrModelPresets.first.extractedDirName),
      );
      expect(ctrl.localAsrStatus.ready, isTrue);

      // Enter custom whisper .bin model + custom whisper-cli runtime path
      final modelField = find.byKey(
        const ValueKey<String>('custom-local-model-path-field'),
      );
      final runtimeField = find.byKey(
        const ValueKey<String>('custom-local-runtime-path-field'),
      );
      await tester.ensureVisible(modelField);
      await tester.enterText(modelField, '/opt/models/ggml-base.bin');
      await tester.enterText(runtimeField, '/usr/local/bin/whisper-cli');

      final saveBtn = find.byKey(
        const ValueKey<String>('save-custom-local-asr-btn'),
      );
      await tester.ensureVisible(saveBtn);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      expect(ctrl.localAsrModelPath, '/opt/models/ggml-base.bin');
      expect(ctrl.localAsrRuntimePath, '/usr/local/bin/whisper-cli');

      // Starting voice recording passes custom paths to PlatformAdapter
      await tester.tap(
        find.byKey(const ValueKey<String>('toggle-voice-record-btn')),
      );
      await tester.pumpAndSettle();

      expect(adapter.speechListening, isTrue);
      expect(adapter.lastLocalModelPath, '/opt/models/ggml-base.bin');
      expect(adapter.lastLocalRuntimePath, '/usr/local/bin/whisper-cli');

      await ctrl.pauseVoiceMemoRecording();
      await tester.pumpAndSettle();
    },
  );
}

class _RealSocketHttpOverrides extends HttpOverrides {}
