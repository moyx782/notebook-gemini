import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:notebook_core/notebook_core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../platform/platform_adapter.dart';

enum CanvasTool {
  select('选择', 'V'),
  pen('钢笔', 'P'),
  highlighter('荧光笔', 'H'),
  eraser('橡皮擦', 'E'),
  rectangle('矩形', 'R'),
  ellipse('圆形', 'O'),
  diamond('菱形', 'D'),
  line('直线', 'I'),
  arrow('箭头', 'A'),
  textCard('Markdown 卡片', 'T'),
  stickyNote('便签', 'S'),
  image('图片/图示', 'M'),
  laser('激光笔', 'L'),
  hand('抓手平移', 'Space');

  const CanvasTool(this.label, this.shortcutHint);
  final String label;
  final String shortcutHint;

  bool get isShapeTool =>
      this == rectangle ||
      this == ellipse ||
      this == diamond ||
      this == line ||
      this == arrow;

  ShapeKind? get asShapeKind {
    switch (this) {
      case CanvasTool.rectangle:
        return ShapeKind.rectangle;
      case CanvasTool.ellipse:
        return ShapeKind.ellipse;
      case CanvasTool.diamond:
        return ShapeKind.diamond;
      case CanvasTool.line:
        return ShapeKind.line;
      case CanvasTool.arrow:
        return ShapeKind.arrow;
      default:
        return null;
    }
  }
}

enum SyncConnectionState {
  offline('离线缓存'),
  connecting('正在连接'),
  connected('三端实时同步'),
  error('等待重连');

  const SyncConnectionState(this.label);
  final String label;
}

class LaserTrailState {
  LaserTrailState({
    required this.peerId,
    required this.peerName,
    required this.colorValue,
    required this.pageId,
    required this.points,
  });

  final String peerId;
  final String peerName;
  final int colorValue;
  final String pageId;
  final List<LaserPoint> points;
}

class ActiveStrokePreview {
  ActiveStrokePreview({
    required this.strokeId,
    required this.kind,
    required this.colorValue,
    required this.strokeWidth,
    required this.points,
  });

  final String strokeId;
  final ElementKind kind;
  final int colorValue;
  final double strokeWidth;
  final List<StrokePoint> points;
}

class ActiveShapePreview {
  ActiveShapePreview({
    required this.shapeKind,
    required this.startX,
    required this.startY,
    required this.currentX,
    required this.currentY,
    required this.colorValue,
    required this.strokeWidth,
  });

  final ShapeKind shapeKind;
  final double startX;
  final double startY;
  double currentX;
  double currentY;
  final int colorValue;
  final double strokeWidth;
}

class JoinBoardOutcome {
  const JoinBoardOutcome({
    required this.connected,
    this.needsManualWifiJoin = false,
    this.beacon,
    this.error,
  });

  final bool connected;
  final bool needsManualWifiJoin;
  final NearbyBoardBeacon? beacon;
  final String? error;
}

class NotebookController extends ChangeNotifier {
  NotebookController({
    PlatformAdapter? platformAdapter,
    String? initialPeerId,
    String? initialDisplayName,
    DeviceFormFactor? initialFormFactor,
    this.autoConnect = true,
  }) : _ownsPlatformAdapter = platformAdapter == null,
       _platform = platformAdapter ?? createPlatformAdapter() {
    _peerId = initialPeerId ?? _generatePeerId();
    _displayName = initialDisplayName ?? _platform.defaultDeviceName();
    _formFactor = initialFormFactor ??
        (_platform.isWeb ? DeviceFormFactor.web : DeviceFormFactor.desktop);
    _wsUrl = _platform.defaultWsUrl();
    _roomId = _platform.initialRoomFromUrl() ?? 'default';

    _doc = CrdtDocument(nodeId: _peerId);
    seedStarterWorkspace(_doc);
    _ensureValidSelection();
  }

  static const List<Color> inkPalette = <Color>[
    Color(0xFF0F172A),
    Color(0xFF4F46E5),
    Color(0xFF0284C7),
    Color(0xFF0D9488),
    Color(0xFF16A34A),
    Color(0xFFEA580C),
    Color(0xFFDC2626),
    Color(0xFF9333EA),
  ];

  static const List<Color> stickyPalette = <Color>[
    Color(0xFFFEF08A),
    Color(0xFFFED7AA),
    Color(0xFFBBF7D0),
    Color(0xFFBFDBFE),
    Color(0xFFFBCFE8),
  ];

  static const List<Color> paperPalette = <Color>[
    Color(0xFFFFFDF9),
    Color(0xFFFFFFFF),
    Color(0xFFF8FAFC),
    Color(0xFFFEFCE8),
    Color(0xFFF1F5F9),
  ];

  final bool _ownsPlatformAdapter;
  final PlatformAdapter _platform;
  final bool autoConnect;

  late CrdtDocument _doc;
  late String _peerId;
  late String _displayName;
  late DeviceFormFactor _formFactor;
  int _avatarColorValue = 0xFF4F46E5;
  String _wsUrl = 'ws://127.0.0.1:8787/ws';
  String _roomId = 'default';

  SyncConnectionState _connectionState = SyncConnectionState.offline;
  String? _lastError;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _reconnectTimer;
  Timer? _saveTimer;
  Timer? _laserDecayTimer;
  Timer? _uploadFlushTimer;
  Timer? _liveStrokeStreamTimer;
  Timer? _deferredInboundFlushTimer;
  int _reconnectAttempts = 0;
  bool _triedWebPortFallback = false;
  bool _disposed = false;
  bool _initialized = false;

  // Fine-grained paint revision notifiers so high-frequency stylus strokes &
  // remote cursors never force full-tree Widget rebuilds or static ink repaints.
  final ValueNotifier<int> _livePaintNotifier = ValueNotifier<int>(0);
  int _committedInkRevision = 0;
  String? _cachedElementsPageId;
  int _cachedElementsRevision = -1;
  List<CanvasElementModel> _cachedActiveElements = const <CanvasElementModel>[];

  // Local-first rendering -> asynchronous background upload queues
  final List<CrdtOp> _pendingOps = <CrdtOp>[];
  final List<CrdtOp> _outboundOpQueue = <CrdtOp>[];
  final List<CrdtOp> _deferredInboundOps = <CrdtOp>[];
  String? _pendingStrokeEndId;
  ElementKind _pendingStrokeEndKind = ElementKind.stroke;
  int _pendingStrokeEndColor = 0;
  double _pendingStrokeEndWidth = 3.5;
  double _activeStrokePathLength = 0.0;
  final List<UndoPatch> _undoStack = <UndoPatch>[];
  final List<UndoPatch> _redoStack = <UndoPatch>[];

  String _activeNotebookId = 'nb-welcome';
  String _activePageId = 'page-brainstorm';
  String? _selectedElementId;
  String? _editingCardId;
  String? _followingPeerId;

  CanvasTool _tool = CanvasTool.pen;
  Color _activeColor = const Color(0xFF0F172A);
  double _strokeWidth = 3.5;
  double _highlighterWidth = 18.0;
  bool _stylusOnlyMode = false;
  bool _phoneBrowseOnlyMode = false;
  bool _sidebarOpen = true;
  String _searchQuery = '';

  Offset _panOffset = const Offset(24, 24);
  double _zoom = 1.0;
  Size _viewportSize = const Size(1280, 800);

  ActiveStrokePreview? _activeStroke;
  ActiveShapePreview? _activeShape;

  final Map<String, PeerPresence> _remotePeers = <String, PeerPresence>{};
  final Map<String, LiveStrokeFrame> _remoteLiveStrokes =
      <String, LiveStrokeFrame>{};
  final Map<String, LaserTrailState> _laserTrails = <String, LaserTrailState>{};
  final List<LaserPoint> _pendingLocalLaserPoints = <LaserPoint>[];
  int _lastPresenceSentMs = 0;
  int _strokeStreamSeq = 0;
  int _lastLaserStreamSentMs = 0;

  List<String> _lanHttpUrls = <String>[];
  List<String> _lanWsUrls = <String>[];
  List<String> _lanApkUrls = <String>[];

  // Embedded Host, BLE & Hotspot self-organizing network state
  bool _isHostingLocalServer = false;
  int? _hostedServerPort;
  HotspotCredentials? _activeHotspot;
  String _manualHotspotSsid = '';
  String _manualHotspotPassword = '';
  String? _hostBroadcastNotice;
  Timer? _hostIpRefreshTimer;

  bool _isDiscoveringNearby = false;
  String? _discoveryNotice;
  bool _isJoiningNearby = false;
  StreamSubscription<NearbyBoardBeacon>? _nearbySub;
  final Map<String, NearbyBoardBeacon> _nearbyBoards =
      <String, NearbyBoardBeacon>{};

  CrdtDocument get doc => _doc;
  PlatformAdapter get platform => _platform;
  String get peerId => _peerId;
  String get displayName => _displayName;
  DeviceFormFactor get formFactor => _formFactor;
  int get avatarColorValue => _avatarColorValue;
  String get wsUrl => _wsUrl;
  String get roomId => _roomId;
  SyncConnectionState get connectionState => _connectionState;
  String? get lastError => _lastError;
  int get pendingOpCount => _pendingOps.length;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  String get activeNotebookId => _activeNotebookId;
  String get activePageId => _activePageId;
  String? get selectedElementId => _selectedElementId;
  String? get editingCardId => _editingCardId;
  String? get followingPeerId => _followingPeerId;

  CanvasTool get tool => _tool;
  Color get activeColor => _activeColor;
  double get strokeWidth => _strokeWidth;
  double get highlighterWidth => _highlighterWidth;
  bool get stylusOnlyMode => _stylusOnlyMode;
  bool get phoneBrowseOnlyMode => _phoneBrowseOnlyMode;
  bool get sidebarOpen => _sidebarOpen;
  String get searchQuery => _searchQuery;

  Offset get panOffset => _panOffset;
  double get zoom => _zoom;

  ActiveStrokePreview? get activeStroke => _activeStroke;
  ActiveShapePreview? get activeShape => _activeShape;
  Listenable get livePaintListenable => _livePaintNotifier;
  int get committedInkRevision => _committedInkRevision;
  Map<String, PeerPresence> get remotePeersMap => _remotePeers;

  /// True when the local in-progress stroke has enough points or travel to be
  /// considered intentional handwriting rather than an accidental palm/pinch tap.
  bool get hasSubstantialActiveStroke {
    final s = _activeStroke;
    if (s == null) return false;
    return s.points.length >= 5 || _activeStrokePathLength >= 14.0;
  }

  void _bumpLivePaint() {
    if (!_disposed) {
      _livePaintNotifier.value = (_livePaintNotifier.value + 1) & 0x3fffffff;
    }
  }

  void _bumpCommittedInk() {
    _committedInkRevision = (_committedInkRevision + 1) & 0x3fffffff;
  }

  List<PeerPresence> get remotePeers =>
      _remotePeers.values.toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName));
  Map<String, LiveStrokeFrame> get remoteLiveStrokes => _remoteLiveStrokes;
  Map<String, LaserTrailState> get laserTrails => _laserTrails;
  List<String> get lanHttpUrls => _lanHttpUrls;
  List<String> get lanWsUrls => _lanWsUrls;
  List<String> get lanApkUrls => _lanApkUrls;
  bool get apkReady => _lanApkUrls.isNotEmpty;

  bool get isHostingLocalServer => _isHostingLocalServer;
  int? get hostedServerPort => _hostedServerPort;
  HotspotCredentials? get activeHotspot => _activeHotspot;
  String get manualHotspotSsid => _manualHotspotSsid;
  String get manualHotspotPassword => _manualHotspotPassword;
  String? get hostBroadcastNotice => _hostBroadcastNotice;
  bool get isDiscoveringNearby => _isDiscoveringNearby;
  String? get discoveryNotice => _discoveryNotice;
  bool get isJoiningNearby => _isJoiningNearby;
  List<NearbyBoardBeacon> get nearbyBoards {
    final list = _nearbyBoards.values.toList()
      ..sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
    return list;
  }

  List<NotebookModel> get notebooks => _doc.activeNotebooks;
  NotebookModel? get activeNotebook => _doc.getNotebook(_activeNotebookId);
  List<NotebookPageModel> get activePages =>
      _doc.pagesForNotebook(_activeNotebookId);
  NotebookPageModel? get activePage => _doc.getPage(_activePageId);
  List<CanvasElementModel> get activeElements {
    if (_cachedElementsPageId == _activePageId &&
        _cachedElementsRevision == _committedInkRevision) {
      return _cachedActiveElements;
    }
    _cachedElementsPageId = _activePageId;
    _cachedElementsRevision = _committedInkRevision;
    _cachedActiveElements = _doc.elementsForPage(_activePageId);
    return _cachedActiveElements;
  }

  Future<void> initialize({double shortestSideLogicalPixels = 1024}) async {
    if (_initialized) return;
    _initialized = true;

    _formFactor = _platform.defaultFormFactor(shortestSideLogicalPixels);
    await _loadLocalState();
    _ensureValidSelection();
    notifyListeners();

    if (autoConnect) {
      unawaited(connect());
      unawaited(fetchServerInfo());
    }
  }

  void updateViewportMetrics(Size size, double shortestSide) {
    _viewportSize = size;
    if (!_platform.isWeb) {
      final detected = _platform.defaultFormFactor(shortestSide);
      if (detected != _formFactor) {
        _formFactor = detected;
        sendPresence(force: true);
      }
    }
  }

  void setSidebarOpen(bool open) {
    if (_sidebarOpen == open) return;
    _sidebarOpen = open;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setTool(CanvasTool nextTool) {
    _tool = nextTool;
    if (nextTool != CanvasTool.select) {
      _editingCardId = null;
    }
    notifyListeners();
  }

  void setActiveColor(Color color) {
    _activeColor = color;
    if (_selectedElementId != null) {
      final el = _doc.getElement(_selectedElementId!);
      if (el != null && !el.deleted) {
        final fieldKey = el.kind == ElementKind.stickyNote
            ? 'fillColorValue'
            : 'colorValue';
        _commitPatch(
          EntityType.element,
          el.id,
          <String, Object?>{fieldKey: color.toARGB32()},
        );
      }
    }
    notifyListeners();
  }

  void setStrokeWidth(double width) {
    if (_tool == CanvasTool.highlighter) {
      _highlighterWidth = width.clamp(8.0, 42.0);
    } else {
      _strokeWidth = width.clamp(1.5, 18.0);
    }
    notifyListeners();
  }

  void setStylusOnlyMode(bool enabled) {
    if (_stylusOnlyMode == enabled) return;
    _stylusOnlyMode = enabled;
    notifyListeners();
  }

  void setPhoneBrowseOnlyMode(bool enabled) {
    if (_phoneBrowseOnlyMode == enabled) return;
    _phoneBrowseOnlyMode = enabled;
    notifyListeners();
  }

  void selectElement(String? elementId) {
    if (_selectedElementId == elementId) return;
    _selectedElementId = elementId;
    if (elementId != _editingCardId) {
      _editingCardId = null;
    }
    notifyListeners();
  }

  void setEditingCard(String? elementId) {
    _editingCardId = elementId;
    if (elementId != null) {
      _selectedElementId = elementId;
    }
    notifyListeners();
  }

  void updateViewport({Offset? panOffset, double? zoom}) {
    final nextZoom = (zoom ?? _zoom).clamp(0.25, 4.0);
    final nextPan = panOffset ?? _panOffset;
    if (nextZoom == _zoom && nextPan == _panOffset) return;
    _zoom = nextZoom;
    _panOffset = nextPan;
    _bumpLivePaint();
    notifyListeners();
  }

  void resetViewport() {
    _zoom = 1.0;
    _panOffset = const Offset(24, 24);
    _bumpLivePaint();
    notifyListeners();
  }

  void zoomByFactor(double factor, {Offset? focalLocalPoint}) {
    final focal = focalLocalPoint ??
        Offset(_viewportSize.width * 0.5, _viewportSize.height * 0.5);
    final nextZoom = (_zoom * factor).clamp(0.25, 4.0);
    if (nextZoom == _zoom) return;
    final scenePoint = (focal - _panOffset) / _zoom;
    final nextPan = focal - scenePoint * nextZoom;
    _zoom = nextZoom;
    _panOffset = nextPan;
    _bumpLivePaint();
    notifyListeners();
  }

  void selectNotebook(String notebookId) {
    if (_activeNotebookId == notebookId) return;
    if (_activeStroke != null) {
      finishLocalStroke();
    }
    _activeNotebookId = notebookId;
    final pages = _doc.pagesForNotebook(notebookId);
    if (pages.isNotEmpty) {
      _activePageId = pages.first.id;
    }
    _selectedElementId = null;
    _editingCardId = null;
    _followingPeerId = null;
    _bumpLivePaint();
    notifyListeners();
    sendPresence(force: true);
  }

  void selectPage(String pageId) {
    final page = _doc.getPage(pageId);
    if (page == null || page.deleted) return;
    if (_activeStroke != null && _activePageId != page.id) {
      finishLocalStroke();
    }
    _activeNotebookId = page.notebookId;
    _activePageId = page.id;
    _selectedElementId = null;
    _editingCardId = null;
    _bumpLivePaint();
    notifyListeners();
    sendPresence(force: true);
  }

  void toggleFollowPeer(String peerId) {
    if (_followingPeerId == peerId) {
      _followingPeerId = null;
      notifyListeners();
      return;
    }
    _followingPeerId = peerId;
    jumpToPeer(peerId);
    notifyListeners();
  }

  void jumpToPeer(String peerId) {
    final peer = _remotePeers[peerId];
    if (peer == null) return;
    if (peer.activePageId.isNotEmpty) {
      final page = _doc.getPage(peer.activePageId);
      if (page != null && !page.deleted) {
        _activeNotebookId = page.notebookId;
        _activePageId = page.id;
      }
    }
    if (peer.cursorVisible) {
      _panOffset = Offset(
        _viewportSize.width * 0.5 - peer.cursorX * _zoom,
        _viewportSize.height * 0.5 - peer.cursorY * _zoom,
      );
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Notebook & Page CRUD
  // ---------------------------------------------------------------------------

  String createNotebook(String title, {Color? color}) {
    final cleanTitle = title.trim().isEmpty ? '新建笔记本' : title.trim();
    final id = _newEntityId('nb');
    final order = notebooks.length;
    _commitPatch(
      EntityType.notebook,
      id,
      <String, Object?>{
        'title': cleanTitle,
        'colorValue': (color ?? const Color(0xFF0D9488)).toARGB32(),
        'sortOrder': order,
        'deleted': false,
      },
      recordUndo: false,
    );
    final firstPageId = createPage(
      notebookId: id,
      title: '第 1 页',
      background: PageBackground.grid,
      switchTo: false,
    );
    _activeNotebookId = id;
    _activePageId = firstPageId;
    notifyListeners();
    sendPresence(force: true);
    return id;
  }

  void renameNotebook(String notebookId, String newTitle) {
    final clean = newTitle.trim();
    if (clean.isEmpty) return;
    _commitPatch(
      EntityType.notebook,
      notebookId,
      <String, Object?>{'title': clean},
    );
  }

  String createPage({
    String? notebookId,
    String? title,
    PageBackground background = PageBackground.grid,
    bool switchTo = true,
  }) {
    final nbId = notebookId ?? _activeNotebookId;
    final existing = _doc.pagesForNotebook(nbId);
    final id = _newEntityId('page');
    final pageTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : '画板页 ${existing.length + 1}';

    _commitPatch(
      EntityType.page,
      id,
      <String, Object?>{
        'notebookId': nbId,
        'title': pageTitle,
        'background': background.name,
        'backgroundColorValue': 0xFFFFFDF9,
        'sortOrder': existing.length,
        'deleted': false,
      },
      recordUndo: false,
    );

    if (switchTo) {
      _activeNotebookId = nbId;
      _activePageId = id;
      _selectedElementId = null;
      _editingCardId = null;
      notifyListeners();
      sendPresence(force: true);
    }
    return id;
  }

  void renamePage(String pageId, String newTitle) {
    final clean = newTitle.trim();
    if (clean.isEmpty) return;
    _commitPatch(
      EntityType.page,
      pageId,
      <String, Object?>{'title': clean},
    );
  }

  void updatePageBackground(
    String pageId, {
    PageBackground? background,
    Color? paperColor,
  }) {
    final patch = <String, Object?>{};
    if (background != null) {
      patch['background'] = background.name;
    }
    if (paperColor != null) {
      patch['backgroundColorValue'] = paperColor.toARGB32();
    }
    if (patch.isEmpty) return;
    _commitPatch(EntityType.page, pageId, patch);
  }

  void deletePage(String pageId) {
    final page = _doc.getPage(pageId);
    if (page == null) return;
    final siblings = _doc.pagesForNotebook(page.notebookId);
    if (siblings.length <= 1) return;
    _commitPatch(
      EntityType.page,
      pageId,
      <String, Object?>{'deleted': true},
    );
    _ensureValidSelection();
    notifyListeners();
    sendPresence(force: true);
  }

  // ---------------------------------------------------------------------------
  // Canvas Drawing, Shapes, Cards, Sticky Notes, Images & Laser
  // ---------------------------------------------------------------------------

  void startLocalStroke(
    Offset scenePos, {
    double pressure = 0.5,
    bool forceHighlighter = false,
  }) {
    if (_activeStroke != null) {
      finishLocalStroke();
    }
    final isHighlighter = forceHighlighter || _tool == CanvasTool.highlighter;
    final kind = isHighlighter ? ElementKind.highlighter : ElementKind.stroke;
    final width = isHighlighter ? _highlighterWidth : _strokeWidth;
    final strokeId = _newEntityId('el');
    _strokeStreamSeq = 0;
    _activeStrokePathLength = 0.0;

    _activeStroke = ActiveStrokePreview(
      strokeId: strokeId,
      kind: kind,
      colorValue: _activeColor.toARGB32(),
      strokeWidth: width,
      points: <StrokePoint>[
        StrokePoint(
          dx: scenePos.dx,
          dy: scenePos.dy,
          pressure: pressure.clamp(0.1, 1.0),
          dtMs: 0,
        ),
      ],
    );
    // Render locally on LiveOverlayPainter immediately with ZERO widget rebuild
    // and ZERO synchronous network encoding on the touch event thread.
    _bumpLivePaint();
    _scheduleLiveStrokeStream();
  }

  void appendLocalStrokePoint(
    Offset scenePos, {
    double pressure = 0.5,
    int dtMs = 8,
  }) {
    final stroke = _activeStroke;
    if (stroke == null) return;
    final last = stroke.points.last;
    final dx = scenePos.dx - last.dx;
    final dy = scenePos.dy - last.dy;
    final distSq = dx * dx + dy * dy;
    final minDistSq = (0.35 / (_zoom * _zoom)).clamp(0.04, 1.0);
    if (distSq < minDistSq) return;

    _activeStrokePathLength += math.sqrt(distSq);
    stroke.points.add(
      StrokePoint(
        dx: scenePos.dx,
        dy: scenePos.dy,
        pressure: pressure.clamp(0.1, 1.0),
        dtMs: dtMs,
      ),
    );
    _bumpLivePaint();
    _scheduleLiveStrokeStream();
  }

  void finishLocalStroke() {
    _liveStrokeStreamTimer?.cancel();
    _liveStrokeStreamTimer = null;

    final stroke = _activeStroke;
    if (stroke == null) return;
    _activeStroke = null;
    _activeStrokePathLength = 0.0;

    if (stroke.points.isEmpty) {
      _flushDeferredInboundOps(notify: false);
      _bumpLivePaint();
      notifyListeners();
      return;
    }

    // Step 1: Render locally FIRST. Commit into local CRDT document in the exact
    // same frame _activeStroke is cleared so there is zero 1-frame flicker/gap.
    var minX = stroke.points.first.dx;
    var maxX = stroke.points.first.dx;
    var minY = stroke.points.first.dy;
    var maxY = stroke.points.first.dy;
    for (final p in stroke.points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }

    final normalizedPoints = stroke.points
        .map(
          (p) => p
              .copyWith(dx: p.dx - minX, dy: p.dy - minY)
              .toCompactJson(),
        )
        .toList();

    final pair = _doc.mutateEntity(
      entityType: EntityType.element,
      entityId: stroke.strokeId,
      fields: <String, Object?>{
        'pageId': _activePageId,
        'kind': stroke.kind.name,
        'x': minX,
        'y': minY,
        'width': math.max(4.0, maxX - minX),
        'height': math.max(4.0, maxY - minY),
        'colorValue': stroke.colorValue,
        'strokeWidth': stroke.strokeWidth,
        'points': normalizedPoints,
        'zIndex': _doc.nextZIndex(_activePageId),
        'authorId': _peerId,
        'authorName': _displayName,
        'deleted': false,
      },
    );
    _undoStack.add(pair.undoPatch);
    _redoStack.clear();

    _flushDeferredInboundOps(notify: false);
    _bumpCommittedInk();
    _bumpLivePaint();
    notifyListeners();

    // Step 2: Upload asynchronously in background batch AFTER local render.
    _enqueueStrokeUpload(
      pair.forward,
      endedStrokeId: stroke.strokeId,
      kind: stroke.kind,
      colorValue: stroke.colorValue,
      strokeWidth: stroke.strokeWidth,
    );
  }

  void cancelLocalStroke() {
    _liveStrokeStreamTimer?.cancel();
    _liveStrokeStreamTimer = null;
    final prev = _activeStroke;
    if (prev == null) return;
    _activeStroke = null;
    _activeStrokePathLength = 0.0;
    _pendingStrokeEndId = prev.strokeId;
    _pendingStrokeEndKind = prev.kind;
    _pendingStrokeEndColor = prev.colorValue;
    _pendingStrokeEndWidth = prev.strokeWidth;
    _scheduleOutboundUploadFlush();
    final hadDeferred = _flushDeferredInboundOps(notify: false);
    _bumpLivePaint();
    if (hadDeferred) {
      notifyListeners();
    }
  }

  void startLocalShape(Offset scenePos, ShapeKind shapeKind) {
    _activeShape = ActiveShapePreview(
      shapeKind: shapeKind,
      startX: scenePos.dx,
      startY: scenePos.dy,
      currentX: scenePos.dx,
      currentY: scenePos.dy,
      colorValue: _activeColor.toARGB32(),
      strokeWidth: math.max(2.5, _strokeWidth),
    );
    _bumpLivePaint();
  }

  void updateLocalShape(Offset scenePos) {
    final shape = _activeShape;
    if (shape == null) return;
    shape.currentX = scenePos.dx;
    shape.currentY = scenePos.dy;
    _bumpLivePaint();
  }

  void finishLocalShape() {
    final shape = _activeShape;
    if (shape == null) return;
    _activeShape = null;

    var x = shape.startX;
    var y = shape.startY;
    var w = shape.currentX - shape.startX;
    var h = shape.currentY - shape.startY;

    if (w.abs() < 8 && h.abs() < 8) {
      w = 150.0;
      h = (shape.shapeKind == ShapeKind.line ||
              shape.shapeKind == ShapeKind.arrow)
          ? 0.0
          : 92.0;
    } else if (shape.shapeKind != ShapeKind.line &&
        shape.shapeKind != ShapeKind.arrow) {
      if (w < 0) {
        x = shape.currentX;
        w = -w;
      }
      if (h < 0) {
        y = shape.currentY;
        h = -h;
      }
    }

    final id = _newEntityId('el');
    final fillAlpha =
        (shape.shapeKind == ShapeKind.line || shape.shapeKind == ShapeKind.arrow)
            ? 0
            : ((0x1A << 24) | (shape.colorValue & 0x00FFFFFF));

    _commitPatch(
      EntityType.element,
      id,
      <String, Object?>{
        'pageId': _activePageId,
        'kind': ElementKind.shape.name,
        'shapeKind': shape.shapeKind.name,
        'x': x,
        'y': y,
        'width': w,
        'height': h,
        'colorValue': shape.colorValue,
        'fillColorValue': fillAlpha,
        'strokeWidth': shape.strokeWidth,
        'text': '',
        'zIndex': _doc.nextZIndex(_activePageId),
        'authorId': _peerId,
        'authorName': _displayName,
        'deleted': false,
      },
    );
    _selectedElementId = id;
    _bumpLivePaint();
    notifyListeners();
  }

  void cancelLocalShape() {
    if (_activeShape == null) return;
    _activeShape = null;
    _bumpLivePaint();
  }

  String createTextCard({
    Offset? sceneCenter,
    String initialText =
        '## 新建笔记卡片\n\n- [ ] 待办事项 1\n- [ ] 待办事项 2\n\n双击此处即可编辑 Markdown 内容',
  }) {
    final center = sceneCenter ?? _screenCenterInScene();
    final id = _newEntityId('el');
    const width = 340.0;
    const height = 220.0;
    _commitPatch(
      EntityType.element,
      id,
      <String, Object?>{
        'pageId': _activePageId,
        'kind': ElementKind.textCard.name,
        'x': center.dx - width * 0.5,
        'y': center.dy - height * 0.5,
        'width': width,
        'height': height,
        'colorValue': 0xFF0F172A,
        'fillColorValue': 0xFFFFFFFF,
        'strokeWidth': 2.0,
        'text': initialText,
        'zIndex': _doc.nextZIndex(_activePageId),
        'authorId': _peerId,
        'authorName': _displayName,
        'deleted': false,
      },
    );
    _selectedElementId = id;
    _editingCardId = id;
    _tool = CanvasTool.select;
    notifyListeners();
    return id;
  }

  String createStickyNote({
    Offset? sceneCenter,
    Color? color,
    String initialText = '便签灵感\n\n写下一句想法...',
  }) {
    final center = sceneCenter ?? _screenCenterInScene();
    final id = _newEntityId('el');
    final noteColor = (color ?? stickyPalette[0]).toARGB32();
    const width = 220.0;
    const height = 190.0;
    _commitPatch(
      EntityType.element,
      id,
      <String, Object?>{
        'pageId': _activePageId,
        'kind': ElementKind.stickyNote.name,
        'x': center.dx - width * 0.5,
        'y': center.dy - height * 0.5,
        'width': width,
        'height': height,
        'colorValue': noteColor,
        'fillColorValue': noteColor,
        'strokeWidth': 2.0,
        'text': initialText,
        'zIndex': _doc.nextZIndex(_activePageId),
        'authorId': _peerId,
        'authorName': _displayName,
        'deleted': false,
      },
    );
    _selectedElementId = id;
    _editingCardId = id;
    _tool = CanvasTool.select;
    notifyListeners();
    return id;
  }

  String createImageCard({
    required String imageUri,
    String title = '图片 / 图示',
    Offset? sceneCenter,
    double width = 320.0,
    double height = 220.0,
  }) {
    final center = sceneCenter ?? _screenCenterInScene();
    final id = _newEntityId('el');
    _commitPatch(
      EntityType.element,
      id,
      <String, Object?>{
        'pageId': _activePageId,
        'kind': ElementKind.image.name,
        'x': center.dx - width * 0.5,
        'y': center.dy - height * 0.5,
        'width': width,
        'height': height,
        'colorValue': 0xFF1E293B,
        'fillColorValue': 0xFFFFFFFF,
        'strokeWidth': 2.0,
        'text': title,
        'imageUri': imageUri,
        'zIndex': _doc.nextZIndex(_activePageId),
        'authorId': _peerId,
        'authorName': _displayName,
        'deleted': false,
      },
    );
    _selectedElementId = id;
    _tool = CanvasTool.select;
    notifyListeners();
    return id;
  }

  void updateElementText(String elementId, String text) {
    final existing = _doc.getElement(elementId);
    if (existing == null || existing.text == text) return;
    _commitPatch(
      EntityType.element,
      elementId,
      <String, Object?>{'text': text},
    );
  }

  void updateElementColor(String elementId, Color color, {bool fill = false}) {
    _commitPatch(
      EntityType.element,
      elementId,
      <String, Object?>{
        fill ? 'fillColorValue' : 'colorValue': color.toARGB32(),
      },
    );
  }

  void toggleMarkdownTaskLine(String elementId, int lineIndex) {
    final el = _doc.getElement(elementId);
    if (el == null) return;
    final lines = el.text.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return;
    final line = lines[lineIndex];
    final unchecked = RegExp(r'^(\s*[-*]\s+)\[ \](\s+.*)$');
    final checked = RegExp(r'^(\s*[-*]\s+)\[[xX]\](\s+.*)$');
    if (unchecked.hasMatch(line)) {
      lines[lineIndex] = line.replaceFirstMapped(
        unchecked,
        (m) => '${m.group(1)}[x]${m.group(2)}',
      );
    } else if (checked.hasMatch(line)) {
      lines[lineIndex] = line.replaceFirstMapped(
        checked,
        (m) => '${m.group(1)}[ ]${m.group(2)}',
      );
    } else {
      return;
    }
    updateElementText(elementId, lines.join('\n'));
  }

  void previewElementFrame(
    String elementId, {
    double? x,
    double? y,
    double? width,
    double? height,
  }) {
    final patch = <String, Object?>{};
    if (x != null) patch['x'] = x;
    if (y != null) patch['y'] = y;
    if (width != null) patch['width'] = math.max(80.0, width);
    if (height != null) patch['height'] = math.max(60.0, height);
    if (patch.isEmpty) return;
    _commitPatch(EntityType.element, elementId, patch, recordUndo: false);
  }

  void commitElementTransformUndo({
    required String elementId,
    required double oldX,
    required double oldY,
    required double oldWidth,
    required double oldHeight,
  }) {
    final current = _doc.getElement(elementId);
    if (current == null) return;
    if (current.x == oldX &&
        current.y == oldY &&
        current.width == oldWidth &&
        current.height == oldHeight) {
      return;
    }
    _undoStack.add(
      UndoPatch(
        entityType: EntityType.element,
        entityId: elementId,
        fields: <String, Object?>{
          'x': oldX,
          'y': oldY,
          'width': oldWidth,
          'height': oldHeight,
        },
      ),
    );
    _redoStack.clear();
    notifyListeners();
  }

  void eraseAt(Offset scenePos) {
    final candidates = activeElements.reversed;
    for (final el in candidates) {
      if (el.hitTest(scenePos.dx, scenePos.dy, tolerance: 14.0)) {
        deleteElement(el.id);
        break;
      }
    }
  }

  CanvasElementModel? hitTestElement(Offset scenePos) {
    for (final el in activeElements.reversed) {
      if (el.hitTest(scenePos.dx, scenePos.dy, tolerance: 12.0)) {
        return el;
      }
    }
    return null;
  }

  void deleteElement(String elementId) {
    final el = _doc.getElement(elementId);
    if (el == null || el.deleted) return;
    if (_selectedElementId == elementId) _selectedElementId = null;
    if (_editingCardId == elementId) _editingCardId = null;
    _commitPatch(
      EntityType.element,
      elementId,
      <String, Object?>{'deleted': true},
    );
  }

  void clearActivePage() {
    final els = activeElements;
    if (els.isEmpty) return;
    final ops = <CrdtOp>[];
    for (final el in els) {
      final pair = _doc.mutateEntity(
        entityType: EntityType.element,
        entityId: el.id,
        fields: <String, Object?>{'deleted': true},
      );
      ops.add(pair.forward);
      _undoStack.add(pair.undoPatch);
    }
    _redoStack.clear();
    _selectedElementId = null;
    _editingCardId = null;
    _bumpCommittedInk();
    _dispatchOps(ops);
    notifyListeners();
  }

  void emitLaserPoint(Offset scenePos) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final pt = LaserPoint(x: scenePos.dx, y: scenePos.dy, createdAtMs: now);
    final trail = _laserTrails.putIfAbsent(
      _peerId,
      () => LaserTrailState(
        peerId: _peerId,
        peerName: _displayName,
        colorValue: _avatarColorValue,
        pageId: _activePageId,
        points: <LaserPoint>[],
      ),
    );
    if (trail.pageId != _activePageId) {
      trail.points.clear();
    }
    _laserTrails[_peerId] = LaserTrailState(
      peerId: _peerId,
      peerName: _displayName,
      colorValue: _avatarColorValue,
      pageId: _activePageId,
      points: <LaserPoint>[...trail.points, pt],
    );
    _pendingLocalLaserPoints.add(pt);
    _ensureLaserDecayTimer();
    _bumpLivePaint();

    if (now - _lastLaserStreamSentMs >= 45 && _channel != null) {
      _lastLaserStreamSentMs = now;
      final batch = List<LaserPoint>.from(_pendingLocalLaserPoints);
      _pendingLocalLaserPoints.clear();
      _safeSendMessage(
        SyncMessage.laserStream(
          roomId: _roomId,
          senderId: _peerId,
          peerName: _displayName,
          colorValue: _avatarColorValue,
          pageId: _activePageId,
          points: batch,
        ),
      );
    }
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final patch = _undoStack.removeLast();
    final pair = _doc.applyUndoPatch(patch);
    _redoStack.add(pair.undoPatch);
    _ensureValidSelection();
    _bumpCommittedInk();
    _dispatchOps(<CrdtOp>[pair.forward]);
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    final patch = _redoStack.removeLast();
    final pair = _doc.applyUndoPatch(patch);
    _undoStack.add(pair.undoPatch);
    _ensureValidSelection();
    _bumpCommittedInk();
    _dispatchOps(<CrdtOp>[pair.forward]);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Presence, CRDT Ops, Export/Import & WebSocket Connection
  // ---------------------------------------------------------------------------

  void updateCursorPresence(Offset scenePos, {bool visible = true}) {
    // Skip redundant cursor presence packets while actively writing a stroke so
    // the input event loop stays 100% focused on local 120Hz/240Hz ink rendering.
    if (_activeStroke != null && visible) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (visible && now - _lastPresenceSentMs < 75) return;
    _lastPresenceSentMs = now;
    _safeSendMessage(
      SyncMessage.presence(
        roomId: _roomId,
        peer: _buildLocalPresence(
          cursorX: scenePos.dx,
          cursorY: scenePos.dy,
          cursorVisible: visible,
        ),
      ),
    );
  }

  void sendPresence({bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastPresenceSentMs < 55) return;
    _lastPresenceSentMs = now;
    _safeSendMessage(
      SyncMessage.presence(
        roomId: _roomId,
        peer: _buildLocalPresence(
          cursorX: 0,
          cursorY: 0,
          cursorVisible: false,
        ),
      ),
    );
  }

  void updateIdentity({
    String? displayName,
    int? avatarColorValue,
    DeviceFormFactor? formFactor,
  }) {
    if (displayName != null && displayName.trim().isNotEmpty) {
      _displayName = displayName.trim();
    }
    if (avatarColorValue != null) {
      _avatarColorValue = avatarColorValue;
    }
    if (formFactor != null) {
      _formFactor = formFactor;
    }
    _scheduleSave();
    notifyListeners();
    sendPresence(force: true);
  }

  Future<ParsedSyncEndpoint?> applyScannedQr(String raw) async {
    final parsed = parseSyncQrPayload(raw);
    if (parsed == null) return null;
    await configureConnection(
      wsUrl: parsed.wsUrl,
      roomId: parsed.roomId ?? _roomId,
    );
    return parsed;
  }

  // ---------------------------------------------------------------------------
  // Embedded Host Mode, BLE Bootstrap, Hotspot Handoff & UDP Discovery
  // ---------------------------------------------------------------------------

  Future<bool> startLocalHostMode({bool requestAndroidHotspot = false}) async {
    if (!_platform.canHostServer || _disposed) return false;

    final port = await _platform.startEmbeddedServer(preferredPort: 8787);
    if (port == null || _disposed) {
      _hostBroadcastNotice = '本机无法启动内置同步服务';
      notifyListeners();
      return false;
    }

    _isHostingLocalServer = true;
    _hostedServerPort = port;
    _hostBroadcastNotice = null;
    notifyListeners();

    if (requestAndroidHotspot &&
        _platform.canManageHotspot &&
        _activeHotspot == null) {
      final hs = await _platform.startLocalHotspot();
      if (hs.ok && hs.credentials != null) {
        _activeHotspot = hs.credentials;
      } else if (hs.error != null) {
        _hostBroadcastNotice = hs.error;
      }
    }

    if (autoConnect) {
      // Seed the embedded host server with any offline drawings already present.
      await _platform.httpPostJson(
        Uri.parse('http://127.0.0.1:$port/api/rooms/$_roomId/import'),
        jsonEncode(<String, dynamic>{'snapshot': _doc.toSnapshotJson()}),
      );
      await configureConnection(
        wsUrl: 'ws://127.0.0.1:$port/ws',
        roomId: _roomId,
      );
    } else {
      _wsUrl = 'ws://127.0.0.1:$port/ws';
    }

    await _refreshHostBeacon();
    _hostIpRefreshTimer?.cancel();
    _hostIpRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_disposed && _isHostingLocalServer) {
        unawaited(_refreshHostBeacon());
      }
    });
    notifyListeners();
    return true;
  }

  Future<void> stopLocalHostMode() async {
    _hostIpRefreshTimer?.cancel();
    _hostIpRefreshTimer = null;
    _isHostingLocalServer = false;
    _hostedServerPort = null;
    _activeHotspot = null;
    _hostBroadcastNotice = null;
    await _platform.updateHostBroadcastBeacon(null);
    await _platform.stopLocalHotspot();
    await _platform.stopEmbeddedServer();
    notifyListeners();
  }

  Future<HotspotStartOutcome> toggleAndroidLocalHotspot() async {
    if (_activeHotspot != null) {
      await _platform.stopLocalHotspot();
      _activeHotspot = null;
      _hostBroadcastNotice = null;
      if (_isHostingLocalServer) {
        await _refreshHostBeacon();
      }
      notifyListeners();
      return const HotspotStartOutcome(ok: true);
    }

    final outcome = await _platform.startLocalHotspot();
    if (outcome.ok && outcome.credentials != null) {
      _activeHotspot = outcome.credentials;
      _hostBroadcastNotice = null;
    } else {
      _hostBroadcastNotice = outcome.error;
    }
    if (_isHostingLocalServer) {
      await _refreshHostBeacon();
    }
    notifyListeners();
    return outcome;
  }

  Future<void> setManualHotspotHint(String ssid, String password) async {
    _manualHotspotSsid = ssid.trim();
    _manualHotspotPassword = password;
    if (_isHostingLocalServer) {
      await _refreshHostBeacon();
    }
    notifyListeners();
  }

  Future<void> _refreshHostBeacon() async {
    if (!_isHostingLocalServer || _hostedServerPort == null || _disposed) {
      return;
    }
    final ips = await _platform.discoverLocalIps();
    final hotspotSsid = _activeHotspot?.ssid ??
        (_manualHotspotSsid.isNotEmpty ? _manualHotspotSsid : null);
    final hotspotPass = _activeHotspot?.password ??
        (_manualHotspotSsid.isNotEmpty ? _manualHotspotPassword : null);

    final beacon = NearbyBoardBeacon(
      hostPeerId: _peerId,
      hostName: _displayName,
      formFactor: _formFactor,
      roomId: _roomId,
      port: _hostedServerPort!,
      lanIps: ips,
      hotspotSsid: hotspotSsid,
      hotspotPassword: hotspotPass,
      lastSeenMs: DateTime.now().millisecondsSinceEpoch,
    );

    final res = await _platform.updateHostBroadcastBeacon(beacon);
    if (!res.ok && res.error != null && _hostBroadcastNotice == null) {
      _hostBroadcastNotice = '${res.error}（仍可通过局域网 UDP 自动发现与扫码连接）';
      notifyListeners();
    }
  }

  Future<void> startDiscovery() async {
    if (_disposed || _isDiscoveringNearby) return;
    _isDiscoveringNearby = true;
    _discoveryNotice = null;
    notifyListeners();

    await _nearbySub?.cancel();
    _nearbySub = _platform.nearbyBeacons.listen(_onNearbyBeacon);

    final res = await _platform.startNearbyDiscovery();
    if (!res.ok && res.error != null && !_disposed) {
      _discoveryNotice = '${res.error}（局域网 / 同热点自动发现仍继续监听中）';
      notifyListeners();
    }
  }

  Future<void> stopDiscovery() async {
    _isDiscoveringNearby = false;
    await _nearbySub?.cancel();
    _nearbySub = null;
    await _platform.stopNearbyDiscovery();
    notifyListeners();
  }

  void _onNearbyBeacon(NearbyBoardBeacon beacon) {
    if (_disposed || beacon.hostPeerId.isEmpty || beacon.hostPeerId == _peerId) {
      return;
    }
    final prev = _nearbyBoards[beacon.hostPeerId];
    final mergedIps = <String>[...beacon.lanIps];
    if (prev != null) {
      for (final ip in prev.lanIps) {
        if (!mergedIps.contains(ip)) {
          mergedIps.add(ip);
        }
      }
    }
    final ssid = beacon.hasHotspotCredentials
        ? beacon.hotspotSsid
        : prev?.hotspotSsid;
    final pass = beacon.hasHotspotCredentials
        ? beacon.hotspotPassword
        : prev?.hotspotPassword;

    _nearbyBoards[beacon.hostPeerId] = beacon.copyWith(
      lanIps: mergedIps,
      hotspotSsid: ssid,
      hotspotPassword: pass,
    );
    notifyListeners();
  }

  Future<String?> _findReachableHostIp(
    List<String> candidateIps,
    int port,
  ) async {
    final seen = <String>{};
    for (final ip in candidateIps) {
      final clean = ip.trim();
      if (clean.isEmpty || !seen.add(clean)) continue;
      final resp = await _platform.httpGet(
        Uri(scheme: 'http', host: clean, port: port, path: '/api/health'),
        timeout: const Duration(milliseconds: 1100),
      );
      if (resp != null && resp.statusCode == 200) {
        return clean;
      }
    }
    return null;
  }

  Future<JoinBoardOutcome> joinNearbyBoard(NearbyBoardBeacon beacon) async {
    if (_isJoiningNearby) {
      return const JoinBoardOutcome(connected: false, error: '正在连接中...');
    }
    _isJoiningNearby = true;
    notifyListeners();

    try {
      // 1. Fast path: test direct LAN/hotspot reachability first.
      final directIp = await _findReachableHostIp(beacon.lanIps, beacon.port);
      if (directIp != null) {
        await configureConnection(
          wsUrl: 'ws://$directIp:${beacon.port}/ws',
          roomId: beacon.roomId,
        );
        return JoinBoardOutcome(connected: true, beacon: beacon);
      }

      // 2. BLE-bootstrapped Hotspot handoff if hotspot credentials are present.
      if (beacon.hasHotspotCredentials) {
        if (_platform.canManageHotspot) {
          final hsRes = await _platform.connectToHotspot(
            beacon.hotspotSsid!,
            beacon.hotspotPassword ?? '',
          );
          if (!hsRes.ok) {
            return JoinBoardOutcome(
              connected: false,
              needsManualWifiJoin: hsRes.manualRequired,
              beacon: beacon,
              error: hsRes.error ?? '未能接入热点',
            );
          }

          // Probe host across advertised IPs + common Android hotspot gateway IPs
          // (or wait briefly for a fresh UDP beacon over the new hotspot interface).
          final deadline = DateTime.now().add(const Duration(seconds: 4));
          while (DateTime.now().isBefore(deadline) && !_disposed) {
            final latest = _nearbyBoards[beacon.hostPeerId] ?? beacon;
            final probeIps = <String>[
              ...latest.lanIps,
              '192.168.43.1',
              '192.168.49.1',
            ];
            final ip = await _findReachableHostIp(probeIps, latest.port);
            if (ip != null) {
              await configureConnection(
                wsUrl: 'ws://$ip:${latest.port}/ws',
                roomId: latest.roomId,
              );
              return JoinBoardOutcome(connected: true, beacon: latest);
            }
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }

          final fallbackIp =
              beacon.lanIps.isNotEmpty ? beacon.lanIps.first : '192.168.43.1';
          await configureConnection(
            wsUrl: 'ws://$fallbackIp:${beacon.port}/ws',
            roomId: beacon.roomId,
          );
          return JoinBoardOutcome(connected: true, beacon: beacon);
        }

        // iPad / iOS / macOS: prompt user to join the advertised Wi-Fi hotspot.
        return JoinBoardOutcome(
          connected: false,
          needsManualWifiJoin: true,
          beacon: beacon,
        );
      }

      // 3. Fallback to first known IP if health probe timed out.
      final firstIp = beacon.lanIps.isNotEmpty ? beacon.lanIps.first : null;
      if (firstIp != null) {
        await configureConnection(
          wsUrl: 'ws://$firstIp:${beacon.port}/ws',
          roomId: beacon.roomId,
        );
        return JoinBoardOutcome(connected: true, beacon: beacon);
      }

      return JoinBoardOutcome(
        connected: false,
        beacon: beacon,
        error: '暂未获取到房主的可达 IP 地址',
      );
    } finally {
      _isJoiningNearby = false;
      notifyListeners();
    }
  }

  Future<void> configureConnection({
    required String wsUrl,
    required String roomId,
  }) async {
    final cleanWs = wsUrl.trim();
    final cleanRoom = roomId.trim().isEmpty ? 'default' : roomId.trim();
    if (cleanWs.isEmpty) return;
    _wsUrl = cleanWs;
    _roomId = cleanRoom;
    _triedWebPortFallback = false;
    _reconnectAttempts = 0;
    _remotePeers.clear();
    _remoteLiveStrokes.clear();
    _scheduleSave();
    notifyListeners();
    if (autoConnect) {
      await connect();
      unawaited(fetchServerInfo());
    }
  }

  Future<void> connect() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeSocketOnly();

    _connectionState = SyncConnectionState.connecting;
    _lastError = null;
    notifyListeners();

    try {
      final parsed = Uri.parse(_wsUrl);
      final wsUri = parsed.replace(
        queryParameters: <String, String>{
          ...parsed.queryParameters,
          'room': _roomId,
        },
      );
      final channel = WebSocketChannel.connect(wsUri);
      _channel = channel;

      _wsSub = channel.stream.listen(
        _onSocketMessage,
        onError: (Object err) => _onSocketClosed(err.toString()),
        onDone: () => _onSocketClosed(null),
        cancelOnError: true,
      );

      await channel.ready;
      if (_disposed || !identical(_channel, channel)) return;

      _safeSendMessage(
        SyncMessage.hello(
          roomId: _roomId,
          peer: _buildLocalPresence(
            cursorX: 0,
            cursorY: 0,
            cursorVisible: false,
          ),
        ),
      );
    } catch (err) {
      _onSocketClosed(err.toString());
    }
  }

  Future<void> fetchServerInfo() async {
    try {
      final wsUri = Uri.parse(_wsUrl);
      final httpScheme = wsUri.scheme == 'wss' ? 'https' : 'http';
      final infoUri = Uri(
        scheme: httpScheme,
        host: wsUri.host,
        port: wsUri.hasPort ? wsUri.port : (httpScheme == 'https' ? 443 : 8787),
        path: '/api/info',
        queryParameters: <String, String>{'room': _roomId},
      );
      final resp = await _platform.httpGet(infoUri);
      if (resp == null || resp.statusCode != 200 || _disposed) return;
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      _lanHttpUrls =
          (decoded['lanHttpUrls'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString())
              .toList();
      _lanWsUrls =
          (decoded['lanWsUrls'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString())
              .toList();
      _lanApkUrls =
          (decoded['lanApkUrls'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString())
              .toList();
      notifyListeners();
    } catch (_) {}
  }

  /// Applies ops received from another controller/peer directly (also useful
  /// for deterministic in-memory synchronization tests).
  void applyExternalOps(List<CrdtOp> ops) {
    if (ops.isEmpty) return;
    final applied = _doc.applyOps(ops);
    if (applied.isEmpty) return;
    _ensureValidSelection();
    _bumpCommittedInk();
    _scheduleSave();
    notifyListeners();
  }

  String exportRoomJson() {
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'roomId': _roomId,
      'exportedAtMs': DateTime.now().millisecondsSinceEpoch,
      'snapshot': _doc.toSnapshotJson(),
    });
  }

  Future<String?> saveExportToDevice() {
    final filename = 'sync-canvas-$_roomId.nbk.json';
    return _platform.saveExportFile(filename, exportRoomJson());
  }

  Future<bool> importRoomJson(String rawJson) async {
    try {
      final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
      final snapshot = decoded['snapshot'] is Map
          ? Map<String, dynamic>.from(decoded['snapshot'] as Map)
          : decoded;
      final changed = _doc.mergeSnapshotJson(snapshot);
      _ensureValidSelection();
      _bumpCommittedInk();
      _scheduleSave();
      notifyListeners();

      final wsUri = Uri.parse(_wsUrl);
      final httpScheme = wsUri.scheme == 'wss' ? 'https' : 'http';
      final importUri = Uri(
        scheme: httpScheme,
        host: wsUri.host,
        port: wsUri.hasPort ? wsUri.port : (httpScheme == 'https' ? 443 : 8787),
        path: '/api/rooms/$_roomId/import',
      );
      await _platform.httpPostJson(
        importUri,
        jsonEncode(<String, dynamic>{'snapshot': snapshot}),
      );
      return changed || true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Internal Sync & Persistence Helpers
  // ---------------------------------------------------------------------------

  void _onSocketMessage(dynamic raw) {
    if (_disposed || raw is! String) return;
    SyncMessage msg;
    try {
      msg = SyncMessage.decode(raw);
    } catch (_) {
      return;
    }

    switch (msg.type) {
      case SyncMessageType.welcome:
        _connectionState = SyncConnectionState.connected;
        _reconnectAttempts = 0;
        _lastError = null;

        final snapshot = msg.payload['snapshot'];
        if (snapshot is Map) {
          _doc.mergeSnapshotJson(Map<String, dynamic>.from(snapshot));
        }

        _remotePeers.clear();
        for (final peer in msg.readPeersList()) {
          if (peer.peerId != _peerId) {
            _remotePeers[peer.peerId] = peer;
          }
        }

        final lanHttp = msg.payload['lanHttpUrls'] as List<dynamic>?;
        if (lanHttp != null && lanHttp.isNotEmpty) {
          _lanHttpUrls = lanHttp.map((e) => e.toString()).toList();
        }
        final lanWs = msg.payload['lanWsUrls'] as List<dynamic>?;
        if (lanWs != null && lanWs.isNotEmpty) {
          _lanWsUrls = lanWs.map((e) => e.toString()).toList();
        }
        final lanApk = msg.payload['lanApkUrls'] as List<dynamic>?;
        if (lanApk != null) {
          _lanApkUrls = lanApk.map((e) => e.toString()).toList();
        }

        if (_pendingOps.isNotEmpty || _outboundOpQueue.isNotEmpty) {
          final toFlush = <CrdtOp>[..._pendingOps, ..._outboundOpQueue];
          _pendingOps.clear();
          _outboundOpQueue.clear();
          _safeSendMessage(
            SyncMessage.opBatch(
              roomId: _roomId,
              senderId: _peerId,
              ops: toFlush,
            ),
          );
        }

        _ensureValidSelection();
        _bumpCommittedInk();
        _bumpLivePaint();
        _scheduleSave();
        notifyListeners();
        break;

      case SyncMessageType.opBatch:
        final ops = msg.readOps();
        if (ops.isEmpty) break;
        // Defer applying remote CRDT ops while the local stylus/finger is in
        // mid-stroke so incoming collaborative edits never stall or flash the
        // active stroke; flush automatically on pen-up (or within 1.2s max).
        if (_activeStroke != null) {
          _deferredInboundOps.addAll(ops);
          _deferredInboundFlushTimer ??= Timer(
            const Duration(milliseconds: 1200),
            () {
              _deferredInboundFlushTimer = null;
              _flushDeferredInboundOps(notify: true);
            },
          );
          break;
        }
        final applied = _doc.applyOps(ops);
        if (applied.isNotEmpty) {
          _ensureValidSelection();
          _bumpCommittedInk();
          _scheduleSave();
          notifyListeners();
        }
        break;

      case SyncMessageType.presence:
        final peer = msg.readPeer();
        if (peer == null || peer.peerId == _peerId) break;
        final prev = _remotePeers[peer.peerId];
        _remotePeers[peer.peerId] = peer;

        var needsWidgetRebuild = prev == null ||
            prev.displayName != peer.displayName ||
            prev.formFactor != peer.formFactor ||
            prev.colorValue != peer.colorValue ||
            prev.activePageId != peer.activePageId ||
            prev.activeNotebookId != peer.activeNotebookId;

        if (_followingPeerId == peer.peerId && _activeStroke == null) {
          if (peer.activePageId.isNotEmpty) {
            final page = _doc.getPage(peer.activePageId);
            if (page != null && !page.deleted) {
              _activeNotebookId = page.notebookId;
              _activePageId = page.id;
            }
          }
          if (peer.cursorVisible) {
            _panOffset = Offset(
              _viewportSize.width * 0.5 - peer.cursorX * _zoom,
              _viewportSize.height * 0.5 - peer.cursorY * _zoom,
            );
          }
          needsWidgetRebuild = true;
        }

        _bumpLivePaint();
        if (needsWidgetRebuild) {
          notifyListeners();
        }
        break;

      case SyncMessageType.strokeStream:
        final frame = msg.readStrokeFrame();
        if (frame == null || frame.peerId == _peerId) break;
        if (frame.isEnd) {
          _remoteLiveStrokes.remove(frame.peerId);
        } else {
          _remoteLiveStrokes[frame.peerId] = frame;
        }
        _bumpLivePaint();
        break;

      case SyncMessageType.laserStream:
        if (msg.senderId == _peerId) break;
        final rawPts =
            msg.payload['points'] as List<dynamic>? ?? const <dynamic>[];
        if (rawPts.isEmpty) break;
        final now = DateTime.now().millisecondsSinceEpoch;
        final incoming = rawPts
            .map(
              (e) => LaserPoint.fromJson(Map<String, dynamic>.from(e as Map))
                ..let((_) {}),
            )
            .map((p) => LaserPoint(x: p.x, y: p.y, createdAtMs: now))
            .toList();
        final existing = _laserTrails[msg.senderId];
        final pageId = msg.payload['pageId'] as String? ?? '';
        final peerName = msg.payload['peerName'] as String? ?? '协作者';
        final colorValue = (msg.payload['colorValue'] as num? ?? 0xFFEF4444).toInt();
        final baseList = (existing != null && existing.pageId == pageId)
            ? existing.points
            : <LaserPoint>[];
        _laserTrails[msg.senderId] = LaserTrailState(
          peerId: msg.senderId,
          peerName: peerName,
          colorValue: colorValue,
          pageId: pageId,
          points: <LaserPoint>[...baseList, ...incoming],
        );
        _ensureLaserDecayTimer();
        _bumpLivePaint();
        break;

      case SyncMessageType.peerLeft:
        final leftId = msg.payload['peerId'] as String?;
        if (leftId != null) {
          _remotePeers.remove(leftId);
          _remoteLiveStrokes.remove(leftId);
          if (_followingPeerId == leftId) {
            _followingPeerId = null;
          }
          _bumpLivePaint();
          notifyListeners();
        }
        break;

      case SyncMessageType.hello:
      case SyncMessageType.ping:
      case SyncMessageType.pong:
      case SyncMessageType.error:
        break;
    }
  }

  void _onSocketClosed(String? err) {
    if (_disposed) return;
    _wsSub?.cancel();
    _wsSub = null;
    _channel = null;
    if (_outboundOpQueue.isNotEmpty) {
      _pendingOps.addAll(_outboundOpQueue);
      _outboundOpQueue.clear();
    }

    if (_platform.isWeb && !_triedWebPortFallback) {
      final parsed = Uri.tryParse(_wsUrl);
      if (parsed != null &&
          parsed.scheme == 'ws' &&
          parsed.hasPort &&
          parsed.port != 8787) {
        _triedWebPortFallback = true;
        _wsUrl = parsed.replace(port: 8787).toString();
        unawaited(connect());
        unawaited(fetchServerInfo());
        return;
      }
    }

    _connectionState =
        err == null ? SyncConnectionState.offline : SyncConnectionState.error;
    _lastError = err;
    notifyListeners();

    if (!autoConnect) return;
    _reconnectAttempts += 1;
    final delaySecs = math.min(10, 1 << math.min(3, _reconnectAttempts - 1));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySecs), () {
      if (!_disposed) {
        unawaited(connect());
      }
    });
  }

  Future<void> _closeSocketOnly() async {
    await _wsSub?.cancel();
    _wsSub = null;
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        await ch.sink.close();
      } catch (_) {}
    }
  }

  void _commitPatch(
    EntityType type,
    String entityId,
    Map<String, Object?> fields, {
    bool recordUndo = true,
  }) {
    final pair = _doc.mutateEntity(
      entityType: type,
      entityId: entityId,
      fields: fields,
    );
    if (recordUndo) {
      _undoStack.add(pair.undoPatch);
      _redoStack.clear();
    }
    _bumpCommittedInk();
    _dispatchOps(<CrdtOp>[pair.forward]);
    notifyListeners();
  }

  void _dispatchOps(List<CrdtOp> ops) {
    if (ops.isEmpty) return;
    if (_connectionState == SyncConnectionState.connected && _channel != null) {
      _outboundOpQueue.addAll(ops);
      _scheduleOutboundUploadFlush();
    } else {
      _pendingOps.addAll(ops);
    }
    _scheduleSave();
  }

  void _enqueueStrokeUpload(
    CrdtOp strokeOp, {
    required String endedStrokeId,
    required ElementKind kind,
    required int colorValue,
    required double strokeWidth,
  }) {
    if (_connectionState == SyncConnectionState.connected && _channel != null) {
      _pendingStrokeEndId = endedStrokeId;
      _pendingStrokeEndKind = kind;
      _pendingStrokeEndColor = colorValue;
      _pendingStrokeEndWidth = strokeWidth;
      _outboundOpQueue.add(strokeOp);
      _scheduleOutboundUploadFlush();
    } else {
      _pendingOps.add(strokeOp);
    }
    _scheduleSave();
  }

  void _scheduleOutboundUploadFlush() {
    if (_uploadFlushTimer != null) return;
    _uploadFlushTimer = Timer(const Duration(milliseconds: 36), () {
      _uploadFlushTimer = null;
      flushPendingUploadsNow();
    });
  }

  /// Flushes locally rendered CRDT operations to the sync server in a single
  /// asynchronous batch after the local frame has already been presented.
  void flushPendingUploadsNow() {
    if (_disposed) return;
    final endedId = _pendingStrokeEndId;
    _pendingStrokeEndId = null;

    if (_connectionState != SyncConnectionState.connected || _channel == null) {
      if (_outboundOpQueue.isNotEmpty) {
        _pendingOps.addAll(_outboundOpQueue);
        _outboundOpQueue.clear();
      }
      return;
    }

    if (endedId != null) {
      _strokeStreamSeq += 1;
      _safeSendMessage(
        SyncMessage.strokeStream(
          roomId: _roomId,
          frame: LiveStrokeFrame(
            peerId: _peerId,
            peerName: _displayName,
            pageId: _activePageId,
            strokeId: endedId,
            kind: _pendingStrokeEndKind,
            colorValue: _pendingStrokeEndColor,
            strokeWidth: _pendingStrokeEndWidth,
            points: const <StrokePoint>[],
            seq: _strokeStreamSeq,
            isEnd: true,
          ),
        ),
      );
    }

    if (_outboundOpQueue.isEmpty) return;
    final batch = List<CrdtOp>.from(_outboundOpQueue);
    _outboundOpQueue.clear();
    final sent = _safeSendMessage(
      SyncMessage.opBatch(
        roomId: _roomId,
        senderId: _peerId,
        ops: batch,
      ),
    );
    if (!sent) {
      _pendingOps.addAll(batch);
    }
  }

  bool _flushDeferredInboundOps({required bool notify}) {
    _deferredInboundFlushTimer?.cancel();
    _deferredInboundFlushTimer = null;
    if (_deferredInboundOps.isEmpty) return false;
    final buffered = List<CrdtOp>.from(_deferredInboundOps);
    _deferredInboundOps.clear();
    final applied = _doc.applyOps(buffered);
    if (applied.isEmpty) return false;
    _ensureValidSelection();
    _bumpCommittedInk();
    _scheduleSave();
    if (notify) {
      notifyListeners();
    }
    return true;
  }

  void _scheduleLiveStrokeStream() {
    if (_connectionState != SyncConnectionState.connected || _channel == null) {
      return;
    }
    if (_liveStrokeStreamTimer != null) return;
    _liveStrokeStreamTimer = Timer(const Duration(milliseconds: 85), () {
      _liveStrokeStreamTimer = null;
      if (_disposed || _activeStroke == null || _channel == null) return;
      _emitStrokeStream(isEnd: false);
    });
  }

  void _emitStrokeStream({required bool isEnd}) {
    final stroke = _activeStroke;
    if (stroke == null || _channel == null) return;
    _strokeStreamSeq += 1;
    final tailPoints = isEnd
        ? const <StrokePoint>[]
        : (stroke.points.length > 72
            ? stroke.points.sublist(stroke.points.length - 72)
            : List<StrokePoint>.from(stroke.points));
    _safeSendMessage(
      SyncMessage.strokeStream(
        roomId: _roomId,
        frame: LiveStrokeFrame(
          peerId: _peerId,
          peerName: _displayName,
          pageId: _activePageId,
          strokeId: stroke.strokeId,
          kind: stroke.kind,
          colorValue: stroke.colorValue,
          strokeWidth: stroke.strokeWidth,
          points: tailPoints,
          seq: _strokeStreamSeq,
          isEnd: isEnd,
        ),
      ),
    );
  }

  bool _safeSendMessage(SyncMessage msg) {
    final ch = _channel;
    if (ch == null) return false;
    try {
      ch.sink.add(msg.encode());
      return true;
    } catch (_) {
      return false;
    }
  }

  PeerPresence _buildLocalPresence({
    required double cursorX,
    required double cursorY,
    required bool cursorVisible,
  }) {
    return PeerPresence(
      peerId: _peerId,
      displayName: _displayName,
      formFactor: _formFactor,
      colorValue: _avatarColorValue,
      activeNotebookId: _activeNotebookId,
      activePageId: _activePageId,
      cursorX: cursorX,
      cursorY: cursorY,
      cursorVisible: cursorVisible,
      lastSeenMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _ensureLaserDecayTimer() {
    if (_laserDecayTimer != null) return;
    _laserDecayTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_disposed) {
        _laserDecayTimer?.cancel();
        _laserDecayTimer = null;
        return;
      }
      final cutoff = DateTime.now().millisecondsSinceEpoch - 1200;
      final emptyKeys = <String>[];
      _laserTrails.forEach((key, trail) {
        trail.points.removeWhere((p) => p.createdAtMs < cutoff);
        if (trail.points.isEmpty) {
          emptyKeys.add(key);
        }
      });
      for (final k in emptyKeys) {
        _laserTrails.remove(k);
      }
      if (_laserTrails.isEmpty) {
        _laserDecayTimer?.cancel();
        _laserDecayTimer = null;
      }
      _bumpLivePaint();
    });
  }

  void _ensureValidSelection() {
    final nbs = notebooks;
    if (nbs.isEmpty) return;
    if (!nbs.any((n) => n.id == _activeNotebookId)) {
      _activeNotebookId = nbs.first.id;
    }
    final pages = _doc.pagesForNotebook(_activeNotebookId);
    if (pages.isNotEmpty && !pages.any((p) => p.id == _activePageId)) {
      _activePageId = pages.first.id;
    }
    if (_selectedElementId != null) {
      final sel = _doc.getElement(_selectedElementId!);
      if (sel == null || sel.deleted || sel.pageId != _activePageId) {
        _selectedElementId = null;
        _editingCardId = null;
      }
    }
  }

  Offset _screenCenterInScene() {
    final cx = (_viewportSize.width * 0.5 - _panOffset.dx) / _zoom;
    final cy = (_viewportSize.height * 0.5 - _panOffset.dy) / _zoom;
    return Offset(cx.isFinite ? cx : 360.0, cy.isFinite ? cy : 260.0);
  }

  Future<void> _loadLocalState() async {
    final rawMeta = await _platform.readLocalValue('meta');
    if (rawMeta != null && rawMeta.isNotEmpty) {
      try {
        final meta = jsonDecode(rawMeta) as Map<String, dynamic>;
        final savedPeerId = meta['peerId'] as String?;
        if (savedPeerId != null && savedPeerId.isNotEmpty) {
          _peerId = savedPeerId;
          _doc = CrdtDocument(nodeId: _peerId);
          seedStarterWorkspace(_doc);
        }
        final savedName = meta['displayName'] as String?;
        if (savedName != null && savedName.isNotEmpty) {
          _displayName = savedName;
        }
        final savedColor = meta['avatarColorValue'] as num?;
        if (savedColor != null) {
          _avatarColorValue = savedColor.toInt();
        }
        final savedWs = meta['wsUrl'] as String?;
        if (savedWs != null && savedWs.isNotEmpty && !_platform.isWeb) {
          _wsUrl = savedWs;
        }
        final savedRoom = meta['roomId'] as String?;
        if (_platform.initialRoomFromUrl() == null &&
            savedRoom != null &&
            savedRoom.isNotEmpty) {
          _roomId = savedRoom;
        }
      } catch (_) {}
    }

    final rawSnapshot = await _platform.readLocalValue('room_$_roomId');
    if (rawSnapshot != null && rawSnapshot.isNotEmpty) {
      try {
        final data = jsonDecode(rawSnapshot) as Map<String, dynamic>;
        final snap = data['snapshot'] as Map<String, dynamic>?;
        if (snap != null) {
          _doc.mergeSnapshotJson(snap);
        }
        final rawPending = data['pendingOps'] as List<dynamic>?;
        if (rawPending != null) {
          for (final item in rawPending) {
            final op = CrdtOp.fromJson(Map<String, dynamic>.from(item as Map));
            _pendingOps.add(op);
            _doc.applyOp(op);
          }
        }
        _bumpCommittedInk();
      } catch (_) {}
    }
  }

  void _scheduleSave() {
    if (!autoConnect) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), () {
      if (_disposed) return;
      // Avoid encoding the full room snapshot while the stylus is mid-stroke.
      if (_activeStroke != null) {
        _scheduleSave();
        return;
      }
      unawaited(_saveNow());
    });
  }

  Future<void> _saveNow() async {
    await _platform.writeLocalValue(
      'meta',
      jsonEncode(<String, dynamic>{
        'peerId': _peerId,
        'displayName': _displayName,
        'avatarColorValue': _avatarColorValue,
        'wsUrl': _wsUrl,
        'roomId': _roomId,
      }),
    );
    final unsentOps = <CrdtOp>[..._pendingOps, ..._outboundOpQueue];
    await _platform.writeLocalValue(
      'room_$_roomId',
      jsonEncode(<String, dynamic>{
        'snapshot': _doc.toSnapshotJson(),
        'pendingOps': unsentOps.map((o) => o.toJson()).toList(),
      }),
    );
  }

  String _generatePeerId() {
    final rand = math.Random().nextInt(999999).toString().padLeft(6, '0');
    return 'peer-${DateTime.now().millisecondsSinceEpoch}-$rand';
  }

  String _newEntityId(String prefix) {
    final rand = math.Random().nextInt(9999).toString().padLeft(4, '0');
    return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$rand';
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _saveTimer?.cancel();
    _laserDecayTimer?.cancel();
    _uploadFlushTimer?.cancel();
    _liveStrokeStreamTimer?.cancel();
    _deferredInboundFlushTimer?.cancel();
    _hostIpRefreshTimer?.cancel();
    _nearbySub?.cancel();
    _wsSub?.cancel();
    _livePaintNotifier.dispose();
    try {
      _channel?.sink.close();
    } catch (_) {}
    if (_ownsPlatformAdapter) {
      unawaited(_platform.dispose());
    }
    super.dispose();
  }
}

extension _LetExt<T> on T {
  T let(void Function(T value) fn) {
    fn(this);
    return this;
  }
}
