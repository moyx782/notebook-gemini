import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:notebook_core/notebook_core.dart';

/// Computes normalized ink pressure [0.18, 1.0] using hardware pressure for
/// Apple Pencil / stylus input and smooth velocity tapering for mouse/touch.
double computeEffectivePressure(
  PointerEvent event,
  Offset? prevLocalPos,
  int dtMs,
) {
  if (event.kind == PointerDeviceKind.stylus ||
      event.kind == PointerDeviceKind.invertedStylus) {
    final span = event.pressureMax - event.pressureMin;
    if (span > 0.001) {
      final norm = (event.pressure - event.pressureMin) / span;
      return norm.clamp(0.18, 1.0);
    }
    if (event.pressure > 0) {
      return event.pressure.clamp(0.18, 1.0);
    }
  }

  if (prevLocalPos == null || dtMs <= 0) {
    return 0.65;
  }
  final dist = (event.localPosition - prevLocalPos).distance;
  final velocity = dist / math.max(1, dtMs); // px per ms
  final tapered = 0.85 - (velocity * 0.18).clamp(0.0, 0.48);
  return tapered.clamp(0.32, 0.88);
}

/// Builds a smooth variable-width ribbon [Path] from relative [StrokePoint]s
/// anchored at ([originX], [originY]).
Path buildVariableWidthStrokePath(
  List<StrokePoint> points,
  double baseWidth, {
  double originX = 0.0,
  double originY = 0.0,
}) {
  final path = Path();
  if (points.isEmpty) return path;

  if (points.length == 1) {
    final p = points.first;
    final radius = math.max(1.2, baseWidth * (0.35 + p.pressure * 0.65) * 0.5);
    path.addOval(
      Rect.fromCircle(
        center: Offset(originX + p.dx, originY + p.dy),
        radius: radius,
      ),
    );
    return path;
  }

  final leftEdge = <Offset>[];
  final rightEdge = <Offset>[];

  for (var i = 0; i < points.length; i++) {
    final curr = Offset(originX + points[i].dx, originY + points[i].dy);
    final prev = i == 0
        ? curr
        : Offset(originX + points[i - 1].dx, originY + points[i - 1].dy);
    final next = i == points.length - 1
        ? curr
        : Offset(originX + points[i + 1].dx, originY + points[i + 1].dy);

    var tangent = next - prev;
    final len = tangent.distance;
    if (len < 0.001) {
      tangent = const Offset(1, 0);
    } else {
      tangent = tangent / len;
    }

    final normal = Offset(-tangent.dy, tangent.dx);
    var p = points[i].pressure.clamp(0.15, 1.0);
    if (i == 0 || i == points.length - 1) {
      p *= 0.78;
    }
    final halfWidth = math.max(0.7, baseWidth * (0.32 + p * 0.78) * 0.5);

    leftEdge.add(curr + normal * halfWidth);
    rightEdge.add(curr - normal * halfWidth);
  }

  path.moveTo(leftEdge.first.dx, leftEdge.first.dy);
  for (var i = 1; i < leftEdge.length - 1; i++) {
    final mid = (leftEdge[i] + leftEdge[i + 1]) * 0.5;
    path.quadraticBezierTo(leftEdge[i].dx, leftEdge[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(leftEdge.last.dx, leftEdge.last.dy);

  final lastCenter =
      Offset(originX + points.last.dx, originY + points.last.dy);
  path.quadraticBezierTo(
    lastCenter.dx,
    lastCenter.dy,
    rightEdge.last.dx,
    rightEdge.last.dy,
  );

  for (var i = rightEdge.length - 2; i > 0; i--) {
    final mid = (rightEdge[i] + rightEdge[i - 1]) * 0.5;
    path.quadraticBezierTo(rightEdge[i].dx, rightEdge[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(rightEdge.first.dx, rightEdge.first.dy);

  final firstCenter =
      Offset(originX + points.first.dx, originY + points.first.dy);
  path.quadraticBezierTo(
    firstCenter.dx,
    firstCenter.dy,
    leftEdge.first.dx,
    leftEdge.first.dy,
  );
  path.close();
  return path;
}

/// Builds a smooth quadratic centerline [Path] suitable for translucent
/// highlighters and glowing laser trails.
Path buildSmoothCenterlinePath(
  List<Offset> points,
) {
  final path = Path();
  if (points.isEmpty) return path;
  if (points.length == 1) {
    path.moveTo(points.first.dx, points.first.dy);
    path.lineTo(points.first.dx + 0.1, points.first.dy + 0.1);
    return path;
  }
  path.moveTo(points.first.dx, points.first.dy);
  for (var i = 1; i < points.length - 1; i++) {
    final mid = (points[i] + points[i + 1]) * 0.5;
    path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(points.last.dx, points.last.dy);
  return path;
}

/// Ray-casting point-in-polygon check in scene coordinates.
bool isPointInPolygon(Offset pt, List<Offset> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final xi = polygon[i].dx;
    final yi = polygon[i].dy;
    final xj = polygon[j].dx;
    final yj = polygon[j].dy;

    final intersects = ((yi > pt.dy) != (yj > pt.dy)) &&
        (pt.dx < (xj - xi) * (pt.dy - yi) / ((yj - yi) == 0 ? 1e-9 : (yj - yi)) + xi);
    if (intersects) {
      inside = !inside;
    }
  }
  return inside;
}

/// Returns true when [el] should be captured by a freehand lasso [polygon].
/// Locked elements (such as PDF background sheets) are never captured.
bool elementMatchesLasso(CanvasElementModel el, List<Offset> polygon) {
  if (el.deleted || el.locked || polygon.length < 3) return false;

  var minX = polygon.first.dx;
  var maxX = polygon.first.dx;
  var minY = polygon.first.dy;
  var maxY = polygon.first.dy;
  for (final p in polygon) {
    if (p.dx < minX) minX = p.dx;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dy > maxY) maxY = p.dy;
  }
  final polyBounds = Rect.fromLTRB(minX, minY, maxX, maxY);
  final rawB = el.bounds;
  final eb = Rect.fromLTRB(rawB.left, rawB.top, rawB.right, rawB.bottom);
  if (!polyBounds.overlaps(eb.inflate(6.0))) return false;

  if (el.kind == ElementKind.stroke || el.kind == ElementKind.highlighter) {
    if (el.points.isEmpty) {
      return isPointInPolygon(eb.center, polygon);
    }
    final step = math.max(1, el.points.length ~/ 20);
    for (var i = 0; i < el.points.length; i += step) {
      final p = el.points[i];
      if (isPointInPolygon(Offset(el.x + p.dx, el.y + p.dy), polygon)) {
        return true;
      }
    }
    final last = el.points.last;
    return isPointInPolygon(Offset(el.x + last.dx, el.y + last.dy), polygon);
  }

  if (isPointInPolygon(eb.center, polygon)) return true;
  var cornersInside = 0;
  for (final corner in <Offset>[
    eb.topLeft,
    eb.topRight,
    eb.bottomLeft,
    eb.bottomRight,
  ]) {
    if (isPointInPolygon(corner, polygon)) {
      cornersInside += 1;
      if (cornersInside >= 2) return true;
    }
  }
  return false;
}
