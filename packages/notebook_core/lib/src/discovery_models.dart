import 'models.dart';

enum DiscoveryTransport {
  udpLan('局域网/热点'),
  ble('BLE 蓝牙');

  const DiscoveryTransport(this.label);
  final String label;
}

class HotspotCredentials {
  const HotspotCredentials({
    required this.ssid,
    required this.password,
  });

  final String ssid;
  final String password;

  bool get isValid => ssid.trim().isNotEmpty;
}

class NearbyBoardBeacon {
  const NearbyBoardBeacon({
    required this.hostPeerId,
    required this.hostName,
    required this.formFactor,
    required this.roomId,
    required this.port,
    required this.lanIps,
    this.hotspotSsid,
    this.hotspotPassword,
    this.transport = DiscoveryTransport.udpLan,
    this.rssi,
    this.lastSeenMs = 0,
  });

  final String hostPeerId;
  final String hostName;
  final DeviceFormFactor formFactor;
  final String roomId;
  final int port;
  final List<String> lanIps;
  final String? hotspotSsid;
  final String? hotspotPassword;
  final DiscoveryTransport transport;
  final int? rssi;
  final int lastSeenMs;

  bool get hasHotspotCredentials =>
      hotspotSsid != null && hotspotSsid!.trim().isNotEmpty;

  String? primaryWsUrl() {
    if (lanIps.isEmpty) return null;
    return 'ws://${lanIps.first}:$port/ws';
  }

  List<String> candidateWsUrls() {
    return lanIps.map((ip) => 'ws://$ip:$port/ws').toList();
  }

  NearbyBoardBeacon copyWith({
    String? hostPeerId,
    String? hostName,
    DeviceFormFactor? formFactor,
    String? roomId,
    int? port,
    List<String>? lanIps,
    String? hotspotSsid,
    String? hotspotPassword,
    DiscoveryTransport? transport,
    int? rssi,
    int? lastSeenMs,
  }) {
    return NearbyBoardBeacon(
      hostPeerId: hostPeerId ?? this.hostPeerId,
      hostName: hostName ?? this.hostName,
      formFactor: formFactor ?? this.formFactor,
      roomId: roomId ?? this.roomId,
      port: port ?? this.port,
      lanIps: lanIps ?? this.lanIps,
      hotspotSsid: hotspotSsid ?? this.hotspotSsid,
      hotspotPassword: hotspotPassword ?? this.hotspotPassword,
      transport: transport ?? this.transport,
      rssi: rssi ?? this.rssi,
      lastSeenMs: lastSeenMs ?? this.lastSeenMs,
    );
  }

  /// Compact JSON representation kept short for single-packet UDP broadcast and
  /// fast BLE GATT characteristic reads.
  Map<String, dynamic> toCompactJson() {
    final map = <String, dynamic>{
      'v': 1,
      'p': hostPeerId,
      'n': hostName,
      'f': formFactor.name,
      'r': roomId,
      'pt': port,
      'ips': lanIps,
      'ts': lastSeenMs,
    };
    if (hotspotSsid != null && hotspotSsid!.trim().isNotEmpty) {
      map['ss'] = hotspotSsid!.trim();
    }
    if (hotspotPassword != null && hotspotPassword!.isNotEmpty) {
      map['pw'] = hotspotPassword!;
    }
    return map;
  }

  factory NearbyBoardBeacon.fromCompactJson(
    Map<String, dynamic> json, {
    DiscoveryTransport? transportOverride,
    String? senderIp,
    int? rssiOverride,
    int? nowMs,
  }) {
    final rawIps = (json['ips'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final mergedIps = <String>[];
    if (senderIp != null && senderIp.trim().isNotEmpty) {
      mergedIps.add(senderIp.trim());
    }
    for (final ip in rawIps) {
      if (!mergedIps.contains(ip)) {
        mergedIps.add(ip);
      }
    }

    final ssidRaw = (json['ss'] as String?)?.trim();
    final passRaw = json['pw'] as String?;

    return NearbyBoardBeacon(
      hostPeerId: (json['p'] as String? ?? '').trim(),
      hostName: (json['n'] as String? ?? '附近画板').trim(),
      formFactor: DeviceFormFactor.fromName(json['f'] as String?),
      roomId: (json['r'] as String? ?? 'default').trim(),
      port: (json['pt'] as num? ?? 8787).toInt(),
      lanIps: mergedIps,
      hotspotSsid: (ssidRaw != null && ssidRaw.isNotEmpty) ? ssidRaw : null,
      hotspotPassword: passRaw,
      transport: transportOverride ?? DiscoveryTransport.udpLan,
      rssi: rssiOverride ?? (json['rssi'] as num?)?.toInt(),
      lastSeenMs: nowMs ?? (json['ts'] as num? ?? 0).toInt(),
    );
  }
}
