import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_canvas_notebook/platform/platform_adapter_io.dart';

class _DirectHttpOverrides extends HttpOverrides {}

void main() {
  test('resolveEmbeddedWebDir locates bundled web directories across layouts',
      () async {
    final sep = Platform.pathSeparator;
    final tempRoot =
        await Directory.systemTemp.createTemp('sync_canvas_resolve_web_');
    try {
      // 1. <exeDir>/web layout (Windows / Linux portable & installed packages)
      final winExeDir = Directory('${tempRoot.path}${sep}win_pkg');
      final winWeb = Directory('${winExeDir.path}${sep}web');
      await winWeb.create(recursive: true);
      await File('${winWeb.path}${sep}index.html').writeAsString('<html>1</html>');

      final foundWin = await resolveEmbeddedWebDir(
        executablePath: '${winExeDir.path}${sep}sync_canvas_notebook.exe',
        currentDirPath: tempRoot.path,
        envOverride: '',
      );
      expect(foundWin, winWeb.absolute.path);

      // 2. <exeDir>/data/web layout
      final dataExeDir = Directory('${tempRoot.path}${sep}data_pkg');
      final dataWeb = Directory('${dataExeDir.path}${sep}data${sep}web');
      await dataWeb.create(recursive: true);
      await File('${dataWeb.path}${sep}index.html').writeAsString('<html>2</html>');

      final foundData = await resolveEmbeddedWebDir(
        executablePath: '${dataExeDir.path}${sep}sync_canvas_notebook.exe',
        currentDirPath: tempRoot.path,
        envOverride: '',
      );
      expect(foundData, dataWeb.absolute.path);

      // 3. <exeDir>/../Resources/web layout (macOS .app bundle)
      final macOsDir =
          Directory('${tempRoot.path}${sep}App.app${sep}Contents${sep}MacOS');
      final macResWeb = Directory(
          '${tempRoot.path}${sep}App.app${sep}Contents${sep}Resources${sep}web');
      await macOsDir.create(recursive: true);
      await macResWeb.create(recursive: true);
      await File('${macResWeb.path}${sep}index.html')
          .writeAsString('<html>3</html>');

      final foundMac = await resolveEmbeddedWebDir(
        executablePath: '${macOsDir.path}${sep}sync_canvas_notebook',
        currentDirPath: tempRoot.path,
        envOverride: '',
      );
      expect(foundMac, macResWeb.absolute.path);

      // 4. <cwd>/build/web source checkout fallback
      final repoDir = Directory('${tempRoot.path}${sep}repo');
      final buildWeb = Directory('${repoDir.path}${sep}build${sep}web');
      final unrelatedExeDir = Directory('${tempRoot.path}${sep}flutter_bin');
      await buildWeb.create(recursive: true);
      await unrelatedExeDir.create(recursive: true);
      await File('${buildWeb.path}${sep}index.html')
          .writeAsString('<html>4</html>');

      final foundCwd = await resolveEmbeddedWebDir(
        executablePath: '${unrelatedExeDir.path}${sep}runner',
        currentDirPath: repoDir.path,
        envOverride: '',
      );
      expect(foundCwd, buildWeb.absolute.path);
    } finally {
      try {
        await tempRoot.delete(recursive: true);
      } catch (_) {}
    }
  });

  test(
      'IoPlatformAdapter.startEmbeddedServer serves Web UI and reports webReady=true',
      () async {
    final sep = Platform.pathSeparator;
    final tempRoot =
        await Directory.systemTemp.createTemp('sync_canvas_embedded_web_');
    final webDir = Directory('${tempRoot.path}${sep}web');
    final canvasKitDir = Directory('${webDir.path}${sep}canvaskit');
    await canvasKitDir.create(recursive: true);
    await File('${webDir.path}${sep}index.html').writeAsString(
      '<!DOCTYPE html><html><body>Embedded SyncCanvas Web UI</body></html>',
    );
    await File('${canvasKitDir.path}${sep}canvaskit.wasm')
        .writeAsBytes(<int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);

    final adapter = IoPlatformAdapter(webDirOverride: webDir.path);
    try {
      final port = await adapter.startEmbeddedServer(preferredPort: 0);
      expect(port, isNotNull);
      expect(port!, greaterThan(0));

      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        try {
          final pageReq = await client.get('127.0.0.1', port, '/?room=default');
          final pageResp = await pageReq.close();
          expect(pageResp.statusCode, HttpStatus.ok);
          final html = await utf8.decoder.bind(pageResp).join();
          expect(html, contains('Embedded SyncCanvas Web UI'));
          expect(html, isNot(contains('flutter build web')));

          final infoReq =
              await client.get('127.0.0.1', port, '/api/info?room=default');
          final infoResp = await infoReq.close();
          expect(infoResp.statusCode, HttpStatus.ok);
          final info =
              jsonDecode(await utf8.decoder.bind(infoResp).join())
                  as Map<String, dynamic>;
          expect(info['webReady'], isTrue);

          final wasmReq =
              await client.get('127.0.0.1', port, '/canvaskit/canvaskit.wasm');
          final wasmResp = await wasmReq.close();
          expect(wasmResp.statusCode, HttpStatus.ok);
          expect(wasmResp.headers.contentType?.mimeType, 'application/wasm');
          await wasmResp.drain<void>();
        } finally {
          client.close(force: true);
        }
      }, _DirectHttpOverrides());
    } finally {
      await adapter.dispose();
      try {
        await tempRoot.delete(recursive: true);
      } catch (_) {}
    }
  });
}
