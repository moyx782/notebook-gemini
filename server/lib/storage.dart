import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:notebook_core/notebook_core.dart';

String sanitizeRoomId(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 'default';
  final cleaned = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  return cleaned.isEmpty ? 'default' : cleaned;
}

/// Persists a room's CRDT state using an atomic `.snapshot.json` plus an
/// append-only `.wal.jsonl` write-ahead log for durability across restarts.
class RoomStorage {
  RoomStorage({
    required this.dataDir,
    required String roomId,
    this.compactThreshold = 40,
  }) : roomId = sanitizeRoomId(roomId);

  final Directory dataDir;
  final String roomId;
  final int compactThreshold;

  Future<void> _writeQueue = Future<void>.value();
  Timer? _compactTimer;
  int _walOpsSinceCompact = 0;

  File get _snapshotFile => File('${dataDir.path}/$roomId.snapshot.json');
  File get _walFile => File('${dataDir.path}/$roomId.wal.jsonl');

  Future<CrdtDocument> loadOrSeed() async {
    await dataDir.create(recursive: true);
    final doc = CrdtDocument(nodeId: 'server-$roomId');
    var loadedExisting = false;

    if (await _snapshotFile.exists()) {
      final raw = await _snapshotFile.readAsString();
      if (raw.trim().isNotEmpty) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        doc.mergeSnapshotJson(json);
        loadedExisting = true;
      }
    }

    if (await _walFile.exists()) {
      final lines = await _walFile.readAsLines();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final parsed = jsonDecode(trimmed) as Map<String, dynamic>;
          final rawOps = parsed['ops'] as List<dynamic>? ?? const <dynamic>[];
          final ops = rawOps
              .map((e) => CrdtOp.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
          doc.applyOps(ops);
          _walOpsSinceCompact += ops.length;
          loadedExisting = true;
        } catch (_) {
          // Ignore a partially flushed trailing line on crash recovery.
        }
      }
    }

    if (!loadedExisting) {
      seedStarterWorkspace(doc);
      await saveSnapshotNow(doc);
    } else if (_walOpsSinceCompact > 0) {
      await compactNow(doc);
    }

    return doc;
  }

  void appendOps(List<CrdtOp> ops, CrdtDocument doc) {
    if (ops.isEmpty) return;
    _walOpsSinceCompact += ops.length;
    final line = '${jsonEncode(<String, dynamic>{
          'ts': DateTime.now().millisecondsSinceEpoch,
          'ops': ops.map((op) => op.toJson()).toList(),
        })}\n';

    _writeQueue = _writeQueue.then((_) async {
      await dataDir.create(recursive: true);
      await _walFile.writeAsString(line, mode: FileMode.append, flush: true);
    });

    if (_walOpsSinceCompact >= compactThreshold) {
      _compactTimer?.cancel();
      _compactTimer = null;
      _writeQueue = _writeQueue.then((_) => _writeSnapshotAndClearWal(doc));
    } else {
      _compactTimer?.cancel();
      _compactTimer = Timer(const Duration(seconds: 2), () {
        compactNow(doc);
      });
    }
  }

  Future<void> saveSnapshotNow(CrdtDocument doc) {
    _compactTimer?.cancel();
    _compactTimer = null;
    _writeQueue = _writeQueue.then((_) => _writeSnapshotAndClearWal(doc));
    return _writeQueue;
  }

  Future<void> compactNow(CrdtDocument doc) {
    _compactTimer?.cancel();
    _compactTimer = null;
    _writeQueue = _writeQueue.then((_) => _writeSnapshotAndClearWal(doc));
    return _writeQueue;
  }

  Future<void> flush() async {
    _compactTimer?.cancel();
    _compactTimer = null;
    await _writeQueue;
  }

  Future<void> _writeSnapshotAndClearWal(CrdtDocument doc) async {
    await dataDir.create(recursive: true);
    final tmpFile = File('${_snapshotFile.path}.tmp');
    final encoded = jsonEncode(doc.toSnapshotJson());
    await tmpFile.writeAsString(encoded, flush: true);
    await tmpFile.rename(_snapshotFile.path);
    if (await _walFile.exists()) {
      await _walFile.writeAsString('', flush: true);
    }
    _walOpsSinceCompact = 0;
  }
}
