import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:notebook_core/notebook_core.dart';

import 'lan_info.dart';

/// Zero-config LAN & mobile hotspot peer discovery using UDP broadcast
/// datagrams so devices on the same Wi-Fi/hotspot find each other instantly.
class UdpDiscoveryService {
  UdpDiscoveryService({this.discoveryPort = defaultDiscoveryPort});

  static const int defaultDiscoveryPort = 48788;

  final int discoveryPort;

  RawDatagramSocket? _listenSocket;
  RawDatagramSocket? _sendSocket;
  Timer? _broadcastTimer;
  NearbyBoardBeacon? Function()? _beaconBuilder;
  List<String> _cachedIps = const <String>[];
  List<InternetAddress> _extraTargets = const <InternetAddress>[];
  int _lastIpRefreshMs = 0;

  int get boundListenPort => _listenSocket?.port ?? 0;

  Future<void> startBroadcasting({
    required NearbyBoardBeacon Function() buildBeacon,
    Duration interval = const Duration(milliseconds: 1500),
    List<InternetAddress> extraTargets = const <InternetAddress>[],
  }) async {
    await stopBroadcasting();
    _beaconBuilder = buildBeacon;
    _extraTargets = extraTargets;

    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      _sendSocket = sock;
    } catch (_) {
      return;
    }

    await _sendOnce();
    _broadcastTimer = Timer.periodic(interval, (_) {
      unawaited(_sendOnce());
    });
  }

  Future<void> triggerBroadcastNow() => _sendOnce();

  Future<void> stopBroadcasting() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _beaconBuilder = null;
    _sendSocket?.close();
    _sendSocket = null;
  }

  Future<bool> startListening({
    required void Function(NearbyBoardBeacon beacon) onBeacon,
  }) async {
    await stopListening();

    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
    } catch (_) {
      try {
        sock = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
        );
      } catch (_) {
        return false;
      }
    }

    sock.broadcastEnabled = true;
    _listenSocket = sock;

    sock.listen(
      (RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        while (true) {
          final datagram = sock?.receive();
          if (datagram == null) break;
          try {
            final text = utf8.decode(datagram.data);
            final decoded = jsonDecode(text);
            if (decoded is! Map) continue;
            final map = Map<String, dynamic>.from(decoded);
            if (map['p'] is! String || (map['p'] as String).isEmpty) continue;
            final beacon = NearbyBoardBeacon.fromCompactJson(
              map,
              transportOverride: DiscoveryTransport.udpLan,
              senderIp: datagram.address.address,
              nowMs: DateTime.now().millisecondsSinceEpoch,
            );
            onBeacon(beacon);
          } catch (_) {
            // Ignore unrelated or malformed UDP traffic on the discovery port.
          }
        }
      },
      onError: (_) {},
    );
    return true;
  }

  Future<void> stopListening() async {
    _listenSocket?.close();
    _listenSocket = null;
  }

  Future<void> stop() async {
    await stopBroadcasting();
    await stopListening();
  }

  Future<void> _sendOnce() async {
    final sock = _sendSocket;
    final builder = _beaconBuilder;
    if (sock == null || builder == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_cachedIps.isEmpty || now - _lastIpRefreshMs > 4000) {
      _cachedIps = await discoverLanIpv4Addresses();
      _lastIpRefreshMs = now;
    }

    var beacon = builder();
    if (beacon == null) return;
    if (beacon.lanIps.isEmpty && _cachedIps.isNotEmpty) {
      beacon = beacon.copyWith(lanIps: _cachedIps);
    }
    final payload = utf8.encode(jsonEncode(beacon.toCompactJson()));

    final targets = <InternetAddress>[
      InternetAddress('255.255.255.255'),
      ..._extraTargets,
    ];
    for (final ip in _cachedIps) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
      }
    }

    final seen = <String>{};
    for (final target in targets) {
      if (!seen.add(target.address)) continue;
      try {
        sock.send(payload, target, discoveryPort);
      } catch (_) {}
    }
  }
}
