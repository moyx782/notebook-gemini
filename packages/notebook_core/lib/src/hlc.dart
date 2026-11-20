import 'dart:math' as math;

/// Hybrid Logical Clock timestamp providing a total causal ordering across
/// devices even when wall clocks experience moderate skew.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.wallTimeMs, this.logical, this.nodeId);

  static const Hlc zero = Hlc(0, 0, '');

  final int wallTimeMs;
  final int logical;
  final String nodeId;

  factory Hlc.parse(String raw) {
    final firstSep = raw.indexOf(':');
    if (firstSep <= 0) {
      throw FormatException('Invalid HLC timestamp: $raw');
    }
    final secondSep = raw.indexOf(':', firstSep + 1);
    if (secondSep <= firstSep + 1) {
      throw FormatException('Invalid HLC timestamp: $raw');
    }
    final wall = int.parse(raw.substring(0, firstSep));
    final counter = int.parse(raw.substring(firstSep + 1, secondSep));
    final node = raw.substring(secondSep + 1);
    return Hlc(wall, counter, node);
  }

  String pack() => '$wallTimeMs:$logical:$nodeId';

  @override
  int compareTo(Hlc other) {
    final wallCmp = wallTimeMs.compareTo(other.wallTimeMs);
    if (wallCmp != 0) return wallCmp;
    final logicalCmp = logical.compareTo(other.logical);
    if (logicalCmp != 0) return logicalCmp;
    return nodeId.compareTo(other.nodeId);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Hlc &&
          wallTimeMs == other.wallTimeMs &&
          logical == other.logical &&
          nodeId == other.nodeId;

  @override
  int get hashCode => Object.hash(wallTimeMs, logical, nodeId);

  @override
  String toString() => pack();
}

/// Mutable per-node HLC generator that guarantees monotonic ticks and merges
/// incoming remote timestamps without losing causal order.
class HlcClock {
  HlcClock({
    required this.nodeId,
    int initialWallTimeMs = 0,
    int initialLogical = 0,
  }) : _wallTimeMs = initialWallTimeMs,
       _logical = initialLogical;

  final String nodeId;
  int _wallTimeMs;
  int _logical;

  Hlc get current => Hlc(_wallTimeMs, _logical, nodeId);

  Hlc tick([int? nowMs]) {
    final physical = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final prevWall = _wallTimeMs;
    _wallTimeMs = math.max(prevWall, physical);
    if (_wallTimeMs == prevWall) {
      _logical += 1;
    } else {
      _logical = 0;
    }
    return Hlc(_wallTimeMs, _logical, nodeId);
  }

  Hlc receive(Hlc remote, [int? nowMs]) {
    final physical = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final prevWall = _wallTimeMs;
    _wallTimeMs = math.max(prevWall, math.max(remote.wallTimeMs, physical));
    if (_wallTimeMs == prevWall && _wallTimeMs == remote.wallTimeMs) {
      _logical = math.max(_logical, remote.logical) + 1;
    } else if (_wallTimeMs == prevWall) {
      _logical += 1;
    } else if (_wallTimeMs == remote.wallTimeMs) {
      _logical = remote.logical + 1;
    } else {
      _logical = 0;
    }
    return Hlc(_wallTimeMs, _logical, nodeId);
  }
}
