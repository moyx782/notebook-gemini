import 'dart:io';

import 'package:notebook_core/notebook_core.dart';
import 'package:sync_canvas_server/lan_info.dart';
import 'package:sync_canvas_server/sync_hub.dart';
import 'package:sync_canvas_server/udp_discovery.dart';

Future<void> main(List<String> args) async {
  var host = '0.0.0.0';
  var port = 8787;
  var dataDir = 'server/data';
  var webDir = 'build/web';
  var apkPath = 'build/app/outputs/flutter-apk/app-release.apk';

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--help' || arg == '-h') {
      stdout.writeln('''
SyncCanvas Notebook Sync Server
Usage: dart run bin/server.dart [options]
  --host <ip>        Bind address (default: 0.0.0.0)
  --port <port>      Listen port (default: 8787)
  --data-dir <dir>   CRDT WAL & snapshot directory (default: server/data)
  --web-dir <dir>    Flutter web build directory (default: build/web)
  --apk-path <file>  Android release APK path (default: build/app/outputs/flutter-apk/app-release.apk)
''');
      return;
    }
    if (arg == '--host' && i + 1 < args.length) {
      host = args[++i];
    } else if (arg == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[++i]) ?? port;
    } else if (arg == '--data-dir' && i + 1 < args.length) {
      dataDir = args[++i];
    } else if (arg == '--web-dir' && i + 1 < args.length) {
      webDir = args[++i];
    } else if (arg == '--apk-path' && i + 1 < args.length) {
      apkPath = args[++i];
    }
  }

  final server = SyncServer();
  await server.start(
    host: host,
    port: port,
    dataDir: dataDir,
    webDir: webDir,
    apkPath: apkPath,
  );

  final ips = await discoverLanIpv4Addresses();
  final discovery = UdpDiscoveryService();
  final cliHostPeerId = 'cli-host-${Platform.localHostname}';
  await discovery.startBroadcasting(
    buildBeacon: () => NearbyBoardBeacon(
      hostPeerId: cliHostPeerId,
      hostName: '${Platform.localHostname} · 共享房主',
      formFactor: DeviceFormFactor.desktop,
      roomId: 'default',
      port: server.boundPort,
      lanIps: ips,
      lastSeenMs: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  final hasApk = await File(apkPath).exists();
  stdout.writeln('============================================================');
  stdout.writeln('  SyncCanvas Notebook 实时共享画板同步服务已启动');
  stdout.writeln('  监听端口: ${server.boundPort}  |  UDP 自动发现端口: ${UdpDiscoveryService.defaultDiscoveryPort}');
  stdout.writeln('  数据目录: $dataDir');
  if (await Directory(webDir).exists()) {
    stdout.writeln('  Web 客户端已托管: $webDir');
  } else {
    stdout.writeln('  提示: 未发现 $webDir，仅提供 WebSocket 同步服务');
  }
  if (hasApk) {
    stdout.writeln('  Android APK 安装包已托管: $apkPath');
  }
  stdout.writeln('------------------------------------------------------------');
  stdout.writeln('  本机浏览器 / 桌面端: http://127.0.0.1:${server.boundPort}');
  for (final ip in ips) {
    stdout.writeln('  局域网平板 / 手机打开: http://$ip:${server.boundPort}');
    if (hasApk) {
      stdout.writeln('  Android APK 局域网下载: http://$ip:${server.boundPort}/download/android.apk');
    }
    stdout.writeln('  原生客户端 WebSocket: ws://$ip:${server.boundPort}/ws');
  }
  stdout.writeln('============================================================');

  Future<void> shutdown(ProcessSignal _) async {
    stdout.writeln('\n正在保存画板快照并停止同步服务...');
    await discovery.stop();
    await server.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }
}
