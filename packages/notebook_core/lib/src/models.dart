import 'dart:math' as math;

enum PageBackground {
  blank('空白'),
  grid('方格'),
  dots('点阵'),
  ruled('横线'),
  cornell('康奈尔'),
  mistakeBook('错题本'),
  weeklyPlan('日程待办');

  const PageBackground(this.label);
  final String label;

  static PageBackground fromName(String? raw) {
    for (final value in PageBackground.values) {
      if (value.name == raw) return value;
    }
    return PageBackground.grid;
  }
}

enum ElementKind {
  stroke,
  highlighter,
  shape,
  textCard,
  stickyNote,
  image,
  token,
  connector,
  cluster;

  static ElementKind fromName(String? raw) {
    for (final value in ElementKind.values) {
      if (value.name == raw) return value;
    }
    return ElementKind.stroke;
  }
}

enum MindFlowColor {
  yellow('灵感黄', 0xFFF59E0B, 0xFFFEF9C3, 0xFF713F12),
  blue('核心蓝', 0xFF3B82F6, 0xFFDBEAFE, 0xFF1E3A8A),
  green('行动绿', 0xFF10B981, 0xFFD1FAE5, 0xFF064E3B),
  purple('洞察紫', 0xFF8B5CF6, 0xFFEDE9FE, 0xFF4C1D95),
  red('质疑红', 0xFFEF4444, 0xFFFEE2E2, 0xFF7F1D1D),
  neutral('中性灰', 0xFF94A3B8, 0xFFFFFFFF, 0xFF0F172A);

  const MindFlowColor(this.label, this.borderArgb, this.fillArgb, this.textArgb);
  final String label;
  final int borderArgb;
  final int fillArgb;
  final int textArgb;

  static MindFlowColor fromName(String? raw) {
    for (final c in MindFlowColor.values) {
      if (c.name == raw) return c;
    }
    return MindFlowColor.neutral;
  }

  static MindFlowColor fromColorValue(int argb) {
    for (final c in MindFlowColor.values) {
      if (c.borderArgb == argb || c.fillArgb == argb) return c;
    }
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    if (r > 200 && g > 170 && b < 140) return MindFlowColor.yellow;
    if (r > 190 && g < 110 && b < 110) return MindFlowColor.red;
    if (g > 150 && r < 140) return MindFlowColor.green;
    if (r > 120 && b > 180 && g < 130) return MindFlowColor.purple;
    if (b > 180 && r < 120) return MindFlowColor.blue;
    return MindFlowColor.neutral;
  }
}

enum ShapeKind {
  rectangle('矩形'),
  ellipse('圆形'),
  diamond('菱形'),
  line('直线'),
  arrow('箭头');

  const ShapeKind(this.label);
  final String label;

  static ShapeKind fromName(String? raw) {
    for (final value in ShapeKind.values) {
      if (value.name == raw) return value;
    }
    return ShapeKind.rectangle;
  }
}

enum DeviceFormFactor {
  desktop('桌面端'),
  tablet('平板端'),
  phone('手机端'),
  web('Web端');

  const DeviceFormFactor(this.label);
  final String label;

  static DeviceFormFactor fromName(String? raw) {
    for (final value in DeviceFormFactor.values) {
      if (value.name == raw) return value;
    }
    return DeviceFormFactor.web;
  }
}

class ElementBounds {
  const ElementBounds(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) * 0.5;
  double get centerY => (top + bottom) * 0.5;

  bool contains(double x, double y, {double padding = 0}) {
    return x >= left - padding &&
        x <= right + padding &&
        y >= top - padding &&
        y <= bottom + padding;
  }

  bool intersects(ElementBounds other) {
    return left <= other.right &&
        right >= other.left &&
        top <= other.bottom &&
        bottom >= other.top;
  }
}

double _round2(double value) => (value * 100.0).roundToDouble() / 100.0;

class StrokePoint {
  const StrokePoint({
    required this.dx,
    required this.dy,
    this.pressure = 0.5,
    this.dtMs = 0,
  });

  final double dx;
  final double dy;
  final double pressure;
  final int dtMs;

  StrokePoint copyWith({
    double? dx,
    double? dy,
    double? pressure,
    int? dtMs,
  }) {
    return StrokePoint(
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      pressure: pressure ?? this.pressure,
      dtMs: dtMs ?? this.dtMs,
    );
  }

  List<num> toCompactJson() => <num>[
        _round2(dx),
        _round2(dy),
        _round2(pressure.clamp(0.05, 1.0)),
        dtMs,
      ];

  factory StrokePoint.fromJson(Object? raw) {
    if (raw is List) {
      final dx = raw.isNotEmpty ? (raw[0] as num).toDouble() : 0.0;
      final dy = raw.length > 1 ? (raw[1] as num).toDouble() : 0.0;
      final pressure = raw.length > 2 ? (raw[2] as num).toDouble() : 0.5;
      final dtMs = raw.length > 3 ? (raw[3] as num).toInt() : 0;
      return StrokePoint(dx: dx, dy: dy, pressure: pressure, dtMs: dtMs);
    }
    if (raw is Map) {
      return StrokePoint(
        dx: (raw['dx'] as num? ?? 0).toDouble(),
        dy: (raw['dy'] as num? ?? 0).toDouble(),
        pressure: (raw['pressure'] as num? ?? 0.5).toDouble(),
        dtMs: (raw['dtMs'] as num? ?? 0).toInt(),
      );
    }
    return const StrokePoint(dx: 0, dy: 0);
  }
}

class NotebookModel {
  const NotebookModel({
    required this.id,
    required this.title,
    required this.colorValue,
    required this.sortOrder,
    required this.deleted,
    required this.updatedAtMs,
  });

  final String id;
  final String title;
  final int colorValue;
  final int sortOrder;
  final bool deleted;
  final int updatedAtMs;
}

class NotebookPageModel {
  const NotebookPageModel({
    required this.id,
    required this.notebookId,
    required this.title,
    required this.background,
    required this.backgroundColorValue,
    required this.sortOrder,
    required this.deleted,
    required this.updatedAtMs,
    this.bookmarked = false,
  });

  final String id;
  final String notebookId;
  final String title;
  final PageBackground background;
  final int backgroundColorValue;
  final int sortOrder;
  final bool deleted;
  final int updatedAtMs;
  final bool bookmarked;
}

class CanvasElementModel {
  const CanvasElementModel({
    required this.id,
    required this.pageId,
    required this.kind,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.colorValue,
    required this.strokeWidth,
    required this.points,
    required this.shapeKind,
    required this.text,
    required this.imageUri,
    required this.zIndex,
    required this.authorId,
    required this.authorName,
    required this.deleted,
    required this.updatedAtMs,
    this.fillColorValue = 0,
    this.locked = false,
    this.sourceId = '',
    this.targetId = '',
    this.semanticColor = MindFlowColor.neutral,
  });

  final String id;
  final String pageId;
  final ElementKind kind;
  final double x;
  final double y;
  final double width;
  final double height;
  final int colorValue;
  final int fillColorValue;
  final double strokeWidth;
  final List<StrokePoint> points;
  final ShapeKind shapeKind;
  final String text;
  final String imageUri;
  final int zIndex;
  final String authorId;
  final String authorName;
  final bool deleted;
  final int updatedAtMs;
  final bool locked;
  final String sourceId;
  final String targetId;
  final MindFlowColor semanticColor;

  bool get isConnectibleNode =>
      kind == ElementKind.token ||
      kind == ElementKind.stickyNote ||
      kind == ElementKind.textCard;

  ElementBounds get bounds {
    if (kind == ElementKind.stroke || kind == ElementKind.highlighter) {
      if (points.isEmpty) {
        return ElementBounds(x, y, x + width, y + height);
      }
      var minDx = points.first.dx;
      var maxDx = points.first.dx;
      var minDy = points.first.dy;
      var maxDy = points.first.dy;
      for (final p in points) {
        if (p.dx < minDx) minDx = p.dx;
        if (p.dx > maxDx) maxDx = p.dx;
        if (p.dy < minDy) minDy = p.dy;
        if (p.dy > maxDy) maxDy = p.dy;
      }
      final pad = math.max(4.0, strokeWidth * 0.5);
      return ElementBounds(
        x + minDx - pad,
        y + minDy - pad,
        x + maxDx + pad,
        y + maxDy + pad,
      );
    }

    final left = math.min(x, x + width);
    final right = math.max(x, x + width);
    final top = math.min(y, y + height);
    final bottom = math.max(y, y + height);
    return ElementBounds(left, top, right, bottom);
  }

  bool hitTest(double wx, double wy, {double tolerance = 12.0}) {
    if (deleted) return false;
    final b = bounds;
    if (!b.contains(wx, wy, padding: tolerance)) {
      return false;
    }

    if (kind == ElementKind.stroke || kind == ElementKind.highlighter) {
      if (points.isEmpty) return false;
      final threshold =
          tolerance + strokeWidth * (kind == ElementKind.highlighter ? 1.1 : 0.6);
      if (points.length == 1) {
        final dx = wx - (x + points.first.dx);
        final dy = wy - (y + points.first.dy);
        return (dx * dx + dy * dy) <= threshold * threshold;
      }
      for (var i = 0; i < points.length - 1; i++) {
        final a = points[i];
        final c = points[i + 1];
        final dist = _distancePointToSegment(
          wx,
          wy,
          x + a.dx,
          y + a.dy,
          x + c.dx,
          y + c.dy,
        );
        if (dist <= threshold) return true;
      }
      return false;
    }

    if (kind == ElementKind.cluster) {
      final headerBottom = math.min(b.bottom, b.top + 38.0);
      final inHeader = wx >= b.left - tolerance &&
          wx <= b.right + tolerance &&
          wy >= b.top - tolerance &&
          wy <= headerBottom;
      if (inHeader) return true;
      final nearLeft = (wx - b.left).abs() <= tolerance &&
          wy >= b.top - tolerance &&
          wy <= b.bottom + tolerance;
      final nearRight = (wx - b.right).abs() <= tolerance &&
          wy >= b.top - tolerance &&
          wy <= b.bottom + tolerance;
      final nearTop = (wy - b.top).abs() <= tolerance &&
          wx >= b.left - tolerance &&
          wx <= b.right + tolerance;
      final nearBottom = (wy - b.bottom).abs() <= tolerance &&
          wx >= b.left - tolerance &&
          wx <= b.right + tolerance;
      return nearLeft || nearRight || nearTop || nearBottom;
    }

    if (kind == ElementKind.connector ||
        (kind == ElementKind.shape &&
            (shapeKind == ShapeKind.line || shapeKind == ShapeKind.arrow))) {
      final dist = _distancePointToSegment(
        wx,
        wy,
        x,
        y,
        x + width,
        y + height,
      );
      return dist <= tolerance + strokeWidth * 0.5 + 4.0;
    }

    return b.contains(wx, wy, padding: tolerance * 0.5);
  }

  static double _distancePointToSegment(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final abx = bx - ax;
    final aby = by - ay;
    final lenSq = abx * abx + aby * aby;
    if (lenSq <= 0.0001) {
      final dx = px - ax;
      final dy = py - ay;
      return math.sqrt(dx * dx + dy * dy);
    }
    final t = (((px - ax) * abx) + ((py - ay) * aby)) / lenSq;
    final clamped = t.clamp(0.0, 1.0);
    final cx = ax + abx * clamped;
    final cy = ay + aby * clamped;
    final dx = px - cx;
    final dy = py - cy;
    return math.sqrt(dx * dx + dy * dy);
  }
}

class PeerPresence {
  const PeerPresence({
    required this.peerId,
    required this.displayName,
    required this.formFactor,
    required this.colorValue,
    required this.activeNotebookId,
    required this.activePageId,
    required this.cursorX,
    required this.cursorY,
    required this.cursorVisible,
    required this.lastSeenMs,
    this.selectedElementIds = const <String>[],
  });

  final String peerId;
  final String displayName;
  final DeviceFormFactor formFactor;
  final int colorValue;
  final String activeNotebookId;
  final String activePageId;
  final double cursorX;
  final double cursorY;
  final bool cursorVisible;
  final int lastSeenMs;
  final List<String> selectedElementIds;

  PeerPresence copyWith({
    String? displayName,
    DeviceFormFactor? formFactor,
    int? colorValue,
    String? activeNotebookId,
    String? activePageId,
    double? cursorX,
    double? cursorY,
    bool? cursorVisible,
    int? lastSeenMs,
    List<String>? selectedElementIds,
  }) {
    return PeerPresence(
      peerId: peerId,
      displayName: displayName ?? this.displayName,
      formFactor: formFactor ?? this.formFactor,
      colorValue: colorValue ?? this.colorValue,
      activeNotebookId: activeNotebookId ?? this.activeNotebookId,
      activePageId: activePageId ?? this.activePageId,
      cursorX: cursorX ?? this.cursorX,
      cursorY: cursorY ?? this.cursorY,
      cursorVisible: cursorVisible ?? this.cursorVisible,
      lastSeenMs: lastSeenMs ?? this.lastSeenMs,
      selectedElementIds: selectedElementIds ?? this.selectedElementIds,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'peerId': peerId,
        'displayName': displayName,
        'formFactor': formFactor.name,
        'colorValue': colorValue,
        'activeNotebookId': activeNotebookId,
        'activePageId': activePageId,
        'cursorX': _round2(cursorX),
        'cursorY': _round2(cursorY),
        'cursorVisible': cursorVisible,
        'lastSeenMs': lastSeenMs,
        if (selectedElementIds.isNotEmpty)
          'selectedElementIds': selectedElementIds,
      };

  factory PeerPresence.fromJson(Map<String, dynamic> json) {
    final rawSelected = json['selectedElementIds'] as List<dynamic>?;
    return PeerPresence(
      peerId: json['peerId'] as String? ?? 'peer',
      displayName: json['displayName'] as String? ?? '协作者',
      formFactor: DeviceFormFactor.fromName(json['formFactor'] as String?),
      colorValue: (json['colorValue'] as num? ?? 0xFF4F46E5).toInt(),
      activeNotebookId: json['activeNotebookId'] as String? ?? '',
      activePageId: json['activePageId'] as String? ?? '',
      cursorX: (json['cursorX'] as num? ?? 0).toDouble(),
      cursorY: (json['cursorY'] as num? ?? 0).toDouble(),
      cursorVisible: json['cursorVisible'] as bool? ?? false,
      lastSeenMs: (json['lastSeenMs'] as num? ?? 0).toInt(),
      selectedElementIds: rawSelected == null
          ? const <String>[]
          : rawSelected.map((e) => e.toString()).toList(),
    );
  }
}

class LaserPoint {
  const LaserPoint({
    required this.x,
    required this.y,
    required this.createdAtMs,
  });

  final double x;
  final double y;
  final int createdAtMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'x': _round2(x),
        'y': _round2(y),
        'createdAtMs': createdAtMs,
      };

  factory LaserPoint.fromJson(Map<String, dynamic> json) {
    return LaserPoint(
      x: (json['x'] as num? ?? 0).toDouble(),
      y: (json['y'] as num? ?? 0).toDouble(),
      createdAtMs: (json['createdAtMs'] as num? ?? 0).toInt(),
    );
  }
}

class LiveStrokeFrame {
  const LiveStrokeFrame({
    required this.peerId,
    required this.peerName,
    required this.pageId,
    required this.strokeId,
    required this.kind,
    required this.colorValue,
    required this.strokeWidth,
    required this.points,
    required this.seq,
    this.isEnd = false,
  });

  final String peerId;
  final String peerName;
  final String pageId;
  final String strokeId;
  final ElementKind kind;
  final int colorValue;
  final double strokeWidth;
  final List<StrokePoint> points;
  final int seq;
  final bool isEnd;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'peerId': peerId,
        'peerName': peerName,
        'pageId': pageId,
        'strokeId': strokeId,
        'kind': kind.name,
        'colorValue': colorValue,
        'strokeWidth': strokeWidth,
        'points': points.map((p) => p.toCompactJson()).toList(),
        'seq': seq,
        'isEnd': isEnd,
      };

  factory LiveStrokeFrame.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List<dynamic>? ?? const <dynamic>[];
    return LiveStrokeFrame(
      peerId: json['peerId'] as String? ?? '',
      peerName: json['peerName'] as String? ?? '协作者',
      pageId: json['pageId'] as String? ?? '',
      strokeId: json['strokeId'] as String? ?? '',
      kind: ElementKind.fromName(json['kind'] as String?),
      colorValue: (json['colorValue'] as num? ?? 0xFF111827).toInt(),
      strokeWidth: (json['strokeWidth'] as num? ?? 3.5).toDouble(),
      points: rawPoints.map(StrokePoint.fromJson).toList(),
      seq: (json['seq'] as num? ?? 0).toInt(),
      isEnd: json['isEnd'] as bool? ?? false,
    );
  }
}
