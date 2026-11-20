import 'dart:io';

/// Discovers non-loopback LAN IPv4 addresses sorted by common Wi-Fi / LAN
/// private subnet priority (192.168.x.x -> 10.x.x.x -> 172.16-31.x.x).
Future<List<String>> discoverLanIpv4Addresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final addresses = <String>{};
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback && addr.address.isNotEmpty) {
          addresses.add(addr.address);
        }
      }
    }
    final sorted = addresses.toList()
      ..sort((a, b) => _scoreIp(a).compareTo(_scoreIp(b)));
    return sorted;
  } catch (_) {
    return const <String>[];
  }
}

int _scoreIp(String ip) {
  if (ip.startsWith('192.168.')) return 0;
  if (ip.startsWith('10.')) return 1;
  if (ip.startsWith('172.')) {
    final parts = ip.split('.');
    if (parts.length >= 2) {
      final second = int.tryParse(parts[1]) ?? 0;
      if (second >= 16 && second <= 31) return 2;
    }
  }
  if (ip.startsWith('169.254.')) return 9;
  return 5;
}
