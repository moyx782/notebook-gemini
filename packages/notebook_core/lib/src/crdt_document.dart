import 'dart:convert';

import 'hlc.dart';
import 'models.dart';

enum EntityType {
  notebook,
  page,
  element;

  static EntityType fromName(String? raw) {
    for (final value in EntityType.values) {
      if (value.name == raw) return value;
    }
    return EntityType.element;
  }
}

class FieldCell {
  const FieldCell({required this.value, required this.hlc});

  final Object? value;
  final Hlc hlc;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': value,
        'h': hlc.pack(),
      };

  factory FieldCell.fromJson(Map<String, dynamic> json) {
    return FieldCell(
      value: json['v'],
      hlc: Hlc.parse(json['h'] as String),
    );
  }
}

class EntityRecord {
  EntityRecord({
    required this.entityType,
    required this.entityId,
    Map<String, FieldCell>? fields,
  }) : fields = fields ?? <String, FieldCell>{};

  final EntityType entityType;
  final String entityId;
  final Map<String, FieldCell> fields;

  T? read<T>(String key) {
    final cell = fields[key];
    return cell?.value as T?;
  }

  Object? raw(String key) => fields[key]?.value;

  int maxWallTimeMs() {
    var latest = 0;
    for (final cell in fields.values) {
      if (cell.hlc.wallTimeMs > latest) {
        latest = cell.hlc.wallTimeMs;
      }
    }
    return latest;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': entityType.name,
        'id': entityId,
        'f': fields.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory EntityRecord.fromJson(Map<String, dynamic> json) {
    final rawFields = json['f'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return EntityRecord(
      entityType: EntityType.fromName(json['t'] as String?),
      entityId: json['id'] as String,
      fields: rawFields.map(
        (k, v) => MapEntry(
          k,
          FieldCell.fromJson(Map<String, dynamic>.from(v as Map)),
        ),
      ),
    );
  }
}

class CrdtOp {
  const CrdtOp({
    required this.opId,
    required this.hlc,
    required this.entityType,
    required this.entityId,
    required this.fields,
  });

  final String opId;
  final Hlc hlc;
  final EntityType entityType;
  final String entityId;
  final Map<String, Object?> fields;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'opId': opId,
        'hlc': hlc.pack(),
        'entityType': entityType.name,
        'entityId': entityId,
        'fields': fields,
      };

  factory CrdtOp.fromJson(Map<String, dynamic> json) {
    final rawFields = json['fields'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return CrdtOp(
      opId: json['opId'] as String? ?? '',
      hlc: Hlc.parse(json['hlc'] as String),
      entityType: EntityType.fromName(json['entityType'] as String?),
      entityId: json['entityId'] as String,
      fields: Map<String, Object?>.from(rawFields),
    );
  }
}

class UndoPatch {
  const UndoPatch({
    required this.entityType,
    required this.entityId,
    required this.fields,
  });

  final EntityType entityType;
  final String entityId;
  final Map<String, Object?> fields;
}

class MutationPair {
  const MutationPair({
    required this.forward,
    required this.undo,
    required this.undoPatch,
  });

  final CrdtOp forward;
  final CrdtOp undo;
  final UndoPatch undoPatch;
}

/// Field-level LWW-Element-Map CRDT document that merges edits from Desktop,
/// Tablet, Mobile Phone, and Web in any arrival order with exact convergence.
class CrdtDocument {
  CrdtDocument({required String nodeId}) : clock = HlcClock(nodeId: nodeId);

  final HlcClock clock;
  final Map<String, EntityRecord> notebooks = <String, EntityRecord>{};
  final Map<String, EntityRecord> pages = <String, EntityRecord>{};
  final Map<String, EntityRecord> elements = <String, EntityRecord>{};

  int _opSeq = 0;

  String nextOpId() {
    _opSeq += 1;
    return '${clock.nodeId}-$_opSeq-${clock.current.wallTimeMs}';
  }

  Map<String, EntityRecord> _bucketFor(EntityType type) {
    switch (type) {
      case EntityType.notebook:
        return notebooks;
      case EntityType.page:
        return pages;
      case EntityType.element:
        return elements;
    }
  }

  /// Applies an incoming CRDT operation. Returns true if at least one field
  /// changed in local state.
  bool applyOp(CrdtOp op, {int? nowMs}) {
    clock.receive(op.hlc, nowMs);
    final bucket = _bucketFor(op.entityType);
    final record = bucket.putIfAbsent(
      op.entityId,
      () => EntityRecord(entityType: op.entityType, entityId: op.entityId),
    );

    var changed = false;
    op.fields.forEach((fieldName, value) {
      final existing = record.fields[fieldName];
      if (existing == null || op.hlc > existing.hlc) {
        if (existing == null || !_deepEquals(existing.value, value)) {
          changed = true;
        }
        record.fields[fieldName] = FieldCell(value: _cloneValue(value), hlc: op.hlc);
      }
    });
    return changed;
  }

  List<CrdtOp> applyOps(Iterable<CrdtOp> ops, {int? nowMs}) {
    final applied = <CrdtOp>[];
    for (final op in ops) {
      if (applyOp(op, nowMs: nowMs)) {
        applied.add(op);
      }
    }
    return applied;
  }

  /// Mutates a single entity locally, returning both the forward CRDT op and
  /// the exact inverse patch for per-user Undo/Redo.
  MutationPair mutateEntity({
    required EntityType entityType,
    required String entityId,
    required Map<String, Object?> fields,
    Hlc? explicitHlc,
    int? nowMs,
  }) {
    final bucket = _bucketFor(entityType);
    final existing = bucket[entityId];
    final prevFields = <String, Object?>{};
    final existedBefore = existing != null && existing.fields.isNotEmpty;

    fields.forEach((key, _) {
      if (existing != null && existing.fields.containsKey(key)) {
        prevFields[key] = _cloneValue(existing.fields[key]!.value);
      } else if (key == 'deleted' && !existedBefore) {
        prevFields['deleted'] = true;
      } else {
        prevFields[key] = null;
      }
    });

    if (!existedBefore && !fields.containsKey('deleted')) {
      prevFields['deleted'] = true;
    }

    final hlc = explicitHlc ?? clock.tick(nowMs);
    final forward = CrdtOp(
      opId: nextOpId(),
      hlc: hlc,
      entityType: entityType,
      entityId: entityId,
      fields: _cloneMap(fields),
    );
    applyOp(forward, nowMs: nowMs);

    final undoPatch = UndoPatch(
      entityType: entityType,
      entityId: entityId,
      fields: prevFields,
    );
    final undo = CrdtOp(
      opId: '${forward.opId}-undo',
      hlc: hlc,
      entityType: entityType,
      entityId: entityId,
      fields: _cloneMap(prevFields),
    );
    return MutationPair(forward: forward, undo: undo, undoPatch: undoPatch);
  }

  /// Executes an undo/redo patch with a fresh HLC so it reliably supersedes
  /// the earlier mutation even after remote peer edits on other entities.
  MutationPair applyUndoPatch(UndoPatch patch, {int? nowMs}) {
    return mutateEntity(
      entityType: patch.entityType,
      entityId: patch.entityId,
      fields: patch.fields,
      nowMs: nowMs,
    );
  }

  List<NotebookModel> get activeNotebooks {
    final list = <NotebookModel>[];
    for (final r in notebooks.values) {
      final model = _toNotebook(r);
      if (model != null && !model.deleted) {
        list.add(model);
      }
    }
    list.sort((a, b) {
      final cmp = a.sortOrder.compareTo(b.sortOrder);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });
    return list;
  }

  NotebookModel? getNotebook(String id) {
    final r = notebooks[id];
    return r == null ? null : _toNotebook(r);
  }

  List<NotebookPageModel> pagesForNotebook(String notebookId) {
    final list = <NotebookPageModel>[];
    for (final r in pages.values) {
      final model = _toPage(r);
      if (model != null && !model.deleted && model.notebookId == notebookId) {
        list.add(model);
      }
    }
    list.sort((a, b) {
      final cmp = a.sortOrder.compareTo(b.sortOrder);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });
    return list;
  }

  NotebookPageModel? getPage(String id) {
    final r = pages[id];
    return r == null ? null : _toPage(r);
  }

  List<CanvasElementModel> elementsForPage(String pageId) {
    final list = <CanvasElementModel>[];
    for (final r in elements.values) {
      final model = _toElement(r);
      if (model != null && !model.deleted && model.pageId == pageId) {
        list.add(model);
      }
    }
    list.sort((a, b) {
      final cmp = a.zIndex.compareTo(b.zIndex);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });
    return list;
  }

  CanvasElementModel? getElement(String id) {
    final r = elements[id];
    return r == null ? null : _toElement(r);
  }

  int nextZIndex(String pageId) {
    var maxZ = 0;
    for (final el in elementsForPage(pageId)) {
      if (el.zIndex > maxZ) maxZ = el.zIndex;
    }
    return maxZ + 1;
  }

  Map<String, dynamic> toSnapshotJson() {
    return <String, dynamic>{
      'version': 1,
      'notebooks': notebooks.values.map((e) => e.toJson()).toList(),
      'pages': pages.values.map((e) => e.toJson()).toList(),
      'elements': elements.values.map((e) => e.toJson()).toList(),
    };
  }

  bool mergeSnapshotJson(Map<String, dynamic> snapshot, {int? nowMs}) {
    var anyChanged = false;
    void mergeList(String key, EntityType type) {
      final raw = snapshot[key] as List<dynamic>? ?? const <dynamic>[];
      final bucket = _bucketFor(type);
      for (final item in raw) {
        final incoming =
            EntityRecord.fromJson(Map<String, dynamic>.from(item as Map));
        final target = bucket.putIfAbsent(
          incoming.entityId,
          () => EntityRecord(entityType: type, entityId: incoming.entityId),
        );
        incoming.fields.forEach((fieldName, cell) {
          clock.receive(cell.hlc, nowMs);
          final existing = target.fields[fieldName];
          if (existing == null || cell.hlc > existing.hlc) {
            if (existing == null || !_deepEquals(existing.value, cell.value)) {
              anyChanged = true;
            }
            target.fields[fieldName] = FieldCell(
              value: _cloneValue(cell.value),
              hlc: cell.hlc,
            );
          }
        });
      }
    }

    mergeList('notebooks', EntityType.notebook);
    mergeList('pages', EntityType.page);
    mergeList('elements', EntityType.element);
    return anyChanged;
  }

  CrdtDocument clone({String? nodeId}) {
    final copy = CrdtDocument(nodeId: nodeId ?? clock.nodeId);
    copy.mergeSnapshotJson(toSnapshotJson());
    return copy;
  }

  String deepDigest() {
    Map<String, dynamic> sortBucket(Map<String, EntityRecord> bucket) {
      final keys = bucket.keys.toList()..sort();
      final out = <String, dynamic>{};
      for (final k in keys) {
        final rec = bucket[k]!;
        final fieldKeys = rec.fields.keys.toList()..sort();
        final sortedFields = <String, dynamic>{};
        for (final fk in fieldKeys) {
          sortedFields[fk] = rec.fields[fk]!.toJson();
        }
        out[k] = <String, dynamic>{
          't': rec.entityType.name,
          'id': rec.entityId,
          'f': sortedFields,
        };
      }
      return out;
    }

    return jsonEncode(<String, dynamic>{
      'notebooks': sortBucket(notebooks),
      'pages': sortBucket(pages),
      'elements': sortBucket(elements),
    });
  }

  NotebookModel? _toNotebook(EntityRecord r) {
    final title = r.raw('title') as String?;
    if (title == null) return null;
    return NotebookModel(
      id: r.entityId,
      title: title,
      colorValue: (r.raw('colorValue') as num? ?? 0xFF4F46E5).toInt(),
      sortOrder: (r.raw('sortOrder') as num? ?? 0).toInt(),
      deleted: r.raw('deleted') as bool? ?? false,
      updatedAtMs: r.maxWallTimeMs(),
    );
  }

  NotebookPageModel? _toPage(EntityRecord r) {
    final title = r.raw('title') as String?;
    final notebookId = r.raw('notebookId') as String?;
    if (title == null || notebookId == null) return null;
    return NotebookPageModel(
      id: r.entityId,
      notebookId: notebookId,
      title: title,
      background: PageBackground.fromName(r.raw('background') as String?),
      backgroundColorValue:
          (r.raw('backgroundColorValue') as num? ?? 0xFFFFFDF9).toInt(),
      sortOrder: (r.raw('sortOrder') as num? ?? 0).toInt(),
      deleted: r.raw('deleted') as bool? ?? false,
      updatedAtMs: r.maxWallTimeMs(),
    );
  }

  CanvasElementModel? _toElement(EntityRecord r) {
    final pageId = r.raw('pageId') as String?;
    final kindRaw = r.raw('kind') as String?;
    if (pageId == null || kindRaw == null) return null;
    final rawPoints = r.raw('points') as List<dynamic>? ?? const <dynamic>[];
    return CanvasElementModel(
      id: r.entityId,
      pageId: pageId,
      kind: ElementKind.fromName(kindRaw),
      x: (r.raw('x') as num? ?? 0).toDouble(),
      y: (r.raw('y') as num? ?? 0).toDouble(),
      width: (r.raw('width') as num? ?? 0).toDouble(),
      height: (r.raw('height') as num? ?? 0).toDouble(),
      colorValue: (r.raw('colorValue') as num? ?? 0xFF1F2937).toInt(),
      fillColorValue: (r.raw('fillColorValue') as num? ?? 0).toInt(),
      strokeWidth: (r.raw('strokeWidth') as num? ?? 3.0).toDouble(),
      points: rawPoints.map(StrokePoint.fromJson).toList(),
      shapeKind: ShapeKind.fromName(r.raw('shapeKind') as String?),
      text: r.raw('text') as String? ?? '',
      imageUri: r.raw('imageUri') as String? ?? '',
      zIndex: (r.raw('zIndex') as num? ?? 0).toInt(),
      authorId: r.raw('authorId') as String? ?? 'seed',
      authorName: r.raw('authorName') as String? ?? '系统模板',
      deleted: r.raw('deleted') as bool? ?? false,
      updatedAtMs: r.maxWallTimeMs(),
    );
  }

  static Object? _cloneValue(Object? value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _cloneValue(v)));
    }
    if (value is List) {
      return value.map(_cloneValue).toList();
    }
    return value;
  }

  static Map<String, Object?> _cloneMap(Map<String, Object?> source) {
    return source.map((k, v) => MapEntry(k, _cloneValue(v)));
  }

  static bool _deepEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }
    return a == b;
  }
}

/// Populates a deterministic starter workspace using a fixed epoch HLC so that
/// offline clients and a newly initialized server merge seamlessly with zero
/// duplication and user edits always win.
void seedStarterWorkspace(CrdtDocument doc) {
  const seedHlc = Hlc(1, 0, 'seed');

  void seed(EntityType type, String id, Map<String, Object?> fields) {
    doc.applyOp(
      CrdtOp(
        opId: 'seed-$id',
        hlc: seedHlc,
        entityType: type,
        entityId: id,
        fields: fields,
      ),
      nowMs: 1,
    );
  }

  seed(EntityType.notebook, 'nb-welcome', <String, Object?>{
    'title': '三端共享笔记本',
    'colorValue': 0xFF4F46E5,
    'sortOrder': 0,
    'deleted': false,
  });

  seed(EntityType.page, 'page-brainstorm', <String, Object?>{
    'notebookId': 'nb-welcome',
    'title': '三端白板概览',
    'background': PageBackground.grid.name,
    'backgroundColorValue': 0xFFFFFDF9,
    'sortOrder': 0,
    'deleted': false,
  });

  seed(EntityType.page, 'page-cornell', <String, Object?>{
    'notebookId': 'nb-welcome',
    'title': '康奈尔学习笔记',
    'background': PageBackground.cornell.name,
    'backgroundColorValue': 0xFFFFFDF9,
    'sortOrder': 1,
    'deleted': false,
  });

  seed(EntityType.page, 'page-freeform', <String, Object?>{
    'notebookId': 'nb-welcome',
    'title': '自由手写草稿纸',
    'background': PageBackground.dots.name,
    'backgroundColorValue': 0xFFFFFDF9,
    'sortOrder': 2,
    'deleted': false,
  });

  // Page 1: Architecture diagram + Interactive Markdown checklist + Sticky + Sample stroke
  seed(EntityType.element, 'el-seed-title-card', <String, Object?>{
    'pageId': 'page-brainstorm',
    'kind': ElementKind.textCard.name,
    'x': 80.0,
    'y': 72.0,
    'width': 390.0,
    'height': 290.0,
    'colorValue': 0xFF1E293B,
    'fillColorValue': 0xFFFFFFFF,
    'strokeWidth': 2.0,
    'text': '# SyncCanvas Notebook\n'
        '电脑 · 平板 · 手机 实时共用同一个画板\n\n'
        '- [x] **桌面端**：大屏目录树 + 键鼠快捷键\n'
        '- [x] **平板端**：Apple Pencil 压感 + 防误触\n'
        '- [ ] **手机端**：扫码秒连 + 随手批注激光笔\n'
        '- [ ] 双击任意卡片可编辑 Markdown，点击复选框实时同步',
    'zIndex': 1,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  seed(EntityType.element, 'el-seed-sticky', <String, Object?>{
    'pageId': 'page-brainstorm',
    'kind': ElementKind.stickyNote.name,
    'x': 520.0,
    'y': 76.0,
    'width': 230.0,
    'height': 200.0,
    'colorValue': 0xFFFEF08A,
    'fillColorValue': 0xFFFEF08A,
    'strokeWidth': 2.0,
    'text': '💡 协作提示\n\n点击右上角「三端连接」，用 iPad 或手机扫码即可在同一画板实时落笔！',
    'zIndex': 2,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  seed(EntityType.element, 'el-seed-arch-rect-desktop', <String, Object?>{
    'pageId': 'page-brainstorm',
    'kind': ElementKind.shape.name,
    'shapeKind': ShapeKind.rectangle.name,
    'x': 120.0,
    'y': 420.0,
    'width': 170.0,
    'height': 76.0,
    'colorValue': 0xFF4F46E5,
    'fillColorValue': 0x224F46E5,
    'strokeWidth': 3.0,
    'text': '💻 桌面端',
    'zIndex': 3,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  seed(EntityType.element, 'el-seed-arch-diamond-hub', <String, Object?>{
    'pageId': 'page-brainstorm',
    'kind': ElementKind.shape.name,
    'shapeKind': ShapeKind.diamond.name,
    'x': 375.0,
    'y': 405.0,
    'width': 160.0,
    'height': 106.0,
    'colorValue': 0xFF0D9488,
    'fillColorValue': 0x220D9488,
    'strokeWidth': 3.0,
    'text': 'CRDT 同步中心',
    'zIndex': 4,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  seed(EntityType.element, 'el-seed-arch-ellipse-mobile', <String, Object?>{
    'pageId': 'page-brainstorm',
    'kind': ElementKind.shape.name,
    'shapeKind': ShapeKind.ellipse.name,
    'x': 615.0,
    'y': 420.0,
    'width': 170.0,
    'height': 76.0,
    'colorValue': 0xFFEA580C,
    'fillColorValue': 0x22EA580C,
    'strokeWidth': 3.0,
    'text': '📱 平板 / 手机',
    'zIndex': 5,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  seed(EntityType.element, 'el-seed-arrow-1', <String, Object?>{
    'pageId': 'page-brainstorm',
    'kind': ElementKind.shape.name,
    'shapeKind': ShapeKind.arrow.name,
    'x': 295.0,
    'y': 458.0,
    'width': 74.0,
    'height': 0.0,
    'colorValue': 0xFF4F46E5,
    'strokeWidth': 3.0,
    'zIndex': 6,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  seed(EntityType.element, 'el-seed-arrow-2', <String, Object?>{
    'pageId': 'page-brainstorm',
    'kind': ElementKind.shape.name,
    'shapeKind': ShapeKind.arrow.name,
    'x': 610.0,
    'y': 458.0,
    'width': -68.0,
    'height': 0.0,
    'colorValue': 0xFFEA580C,
    'strokeWidth': 3.0,
    'zIndex': 7,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  seed(EntityType.element, 'el-seed-wave-stroke', <String, Object?>{
    'pageId': 'page-brainstorm',
    'kind': ElementKind.stroke.name,
    'x': 520.0,
    'y': 310.0,
    'width': 220.0,
    'height': 52.0,
    'colorValue': 0xFF2563EB,
    'strokeWidth': 4.5,
    'points': <List<num>>[
      <num>[0, 32, 0.35, 0],
      <num>[32, 8, 0.62, 18],
      <num>[72, 40, 0.85, 36],
      <num>[118, 12, 0.78, 54],
      <num>[164, 38, 0.65, 74],
      <num>[210, 14, 0.42, 92],
    ],
    'zIndex': 8,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  // Page 2: Cornell Study Notes starter
  seed(EntityType.element, 'el-seed-cornell-cue', <String, Object?>{
    'pageId': 'page-cornell',
    'kind': ElementKind.textCard.name,
    'x': 44.0,
    'y': 140.0,
    'width': 210.0,
    'height': 320.0,
    'colorValue': 0xFF334155,
    'fillColorValue': 0xFFF8FAFC,
    'strokeWidth': 2.0,
    'text': '## 线索区 (Cues)\n\n- 为什么需要 HLC？\n- CRDT 如何做到三端离线后不丢笔记？\n- 平板如何避免手掌误触？',
    'zIndex': 1,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  seed(EntityType.element, 'el-seed-cornell-notes', <String, Object?>{
    'pageId': 'page-cornell',
    'kind': ElementKind.textCard.name,
    'x': 290.0,
    'y': 140.0,
    'width': 480.0,
    'height': 320.0,
    'colorValue': 0xFF0F172A,
    'fillColorValue': 0xFFFFFFFF,
    'strokeWidth': 2.0,
    'text': '## 主笔记区 (Notes)\n\n'
        '1. **字段级 LWW CRDT**：每个元素的坐标、颜色、Markdown 文本各自独立合并。\n'
        '2. **压感笔迹**：`StrokePoint` 相对锚点存储，整体拖拽移动仅需同步 `x / y`。\n'
        '3. **WAL + Snapshot**：断网编辑先写入本地队列，重连后自动补发并收敛。\n\n'
        '> 用平板在右侧或下方直接手写批注，电脑端可实时看到笔迹轨迹。',
    'zIndex': 2,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });

  seed(EntityType.element, 'el-seed-cornell-summary', <String, Object?>{
    'pageId': 'page-cornell',
    'kind': ElementKind.textCard.name,
    'x': 44.0,
    'y': 580.0,
    'width': 726.0,
    'height': 145.0,
    'colorValue': 0xFF1E293B,
    'fillColorValue': 0xFFF0FDF4,
    'strokeWidth': 2.0,
    'text': '## 总结区 (Summary)\n\n'
        '- [x] 电脑负责结构化整理与快捷键编排\n'
        '- [ ] 平板负责手写推导与图形标注\n'
        '- [ ] 手机负责随时拍照/浏览与激光笔演示',
    'zIndex': 3,
    'authorId': 'seed',
    'authorName': '系统示例',
    'deleted': false,
  });
}
