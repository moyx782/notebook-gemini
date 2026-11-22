import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_canvas_server/mindflow_mcp_service.dart';
import 'package:sync_canvas_server/storage.dart';

/// Standalone stdio MCP server for SyncCanvas × MindFlow.
///
/// When a SyncCanvas server is running at `--url` (default http://127.0.0.1:8787),
/// JSON-RPC requests are forwarded to `/api/rooms/<room>/mindflow/mcp` so edits
/// appear instantaneously across all connected devices. Otherwise it falls back
/// seamlessly to the local CRDT room store in `--data-dir`.
Future<void> main(List<String> args) async {
  var roomId = 'default';
  var baseUrl = 'http://127.0.0.1:8787';
  var dataDir = 'server/data';
  var readOnly = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--read-only') {
      readOnly = true;
    } else if (arg == '--room' && i + 1 < args.length) {
      roomId = sanitizeRoomId(args[++i]);
    } else if (arg == '--url' && i + 1 < args.length) {
      baseUrl = args[++i].replaceAll(RegExp(r'/+$'), '');
    } else if (arg == '--data-dir' && i + 1 < args.length) {
      dataDir = args[++i];
    } else if (arg == '--help' || arg == '-h') {
      stderr.writeln('''
SyncCanvas × MindFlow MCP Server (stdio JSON-RPC 2.0)
Usage: dart run bin/mindflow_mcp.dart [options]
  --url <http://...>   SyncCanvas host base URL (default: http://127.0.0.1:8787)
  --room <roomId>      Target room ID (default: default)
  --data-dir <dir>     Fallback offline CRDT directory (default: server/data)
  --read-only          Disable write tools (recommended default for read-only exploration)
''');
      return;
    }
  }

  final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 600);
  RoomStorage? fallbackStorage;
  MindFlowMcpService? fallbackService;

  Future<MindFlowMcpService> ensureFallback() async {
    if (fallbackService != null) return fallbackService!;
    final dir = Directory(dataDir);
    final storage = RoomStorage(dataDir: dir, roomId: roomId);
    final doc = await storage.loadOrSeed();
    fallbackStorage = storage;
    fallbackService = MindFlowMcpService(
      dataDir: dir,
      roomId: roomId,
      document: doc,
      onOpsCommitted: (ops) async {
        storage.appendOps(ops, doc);
        await storage.flush();
      },
    );
    return fallbackService!;
  }

  Future<String?> forwardRemote(String rawLine) async {
    try {
      final ro = readOnly ? '1' : '0';
      final uri = Uri.parse(
        '$baseUrl/api/rooms/${Uri.encodeComponent(roomId)}/mindflow/mcp?readOnly=$ro',
      );
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(rawLine);
      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();
      if (resp.statusCode == HttpStatus.accepted || body.trim().isEmpty) {
        return '';
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return body;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    final remoteResp = await forwardRemote(trimmed);
    if (remoteResp != null) {
      if (remoteResp.isNotEmpty) {
        stdout.writeln(remoteResp);
      }
      continue;
    }

    try {
      final req = jsonDecode(trimmed) as Map<String, dynamic>;
      final localSvc = await ensureFallback();
      final res = await localSvc.handleJsonRpc(req, readOnly: readOnly);
      if (res != null) {
        stdout.writeln(jsonEncode(res));
      }
    } catch (e) {
      stdout.writeln(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': null,
          'error': <String, dynamic>{'code': -32700, 'message': e.toString()},
        }),
      );
    }
  }

  client.close(force: true);
  await fallbackStorage?.flush();
}
