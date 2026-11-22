import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:notebook_core/notebook_core.dart';

import '../state/notebook_controller.dart';
import 'stroke_geometry.dart';

final LinkedHashMap<String, Path> _strokePathCache =
    LinkedHashMap<String, Path>();

Path _cachedStrokeRibbonPath(CanvasElementModel el) {
  final key =
      's:${el.id}:${el.x.toStringAsFixed(2)}:${el.y.toStringAsFixed(2)}:${el.strokeWidth.toStringAsFixed(2)}:${el.points.length}';
  final hit = _strokePathCache.remove(key);
  if (hit != null) {
    _strokePathCache[key] = hit;
    return hit;
  }
  final built = buildVariableWidthStrokePath(
    el.points,
    el.strokeWidth,
    originX: el.x,
    originY: el.y,
  );
  if (_strokePathCache.length >= 1024) {
    _strokePathCache.remove(_strokePathCache.keys.first);
  }
  _strokePathCache[key] = built;
  return built;
}

Path _cachedHighlighterPath(CanvasElementModel el) {
  final key =
      'h:${el.id}:${el.x.toStringAsFixed(2)}:${el.y.toStringAsFixed(2)}:${el.points.length}';
  final hit = _strokePathCache.remove(key);
  if (hit != null) {
    _strokePathCache[key] = hit;
    return hit;
  }
  final pts = el.points.map((p) => Offset(el.x + p.dx, el.y + p.dy)).toList();
  final built = buildSmoothCenterlinePath(pts);
  if (_strokePathCache.length >= 1024) {
    _strokePathCache.remove(_strokePathCache.keys.first);
  }
  _strokePathCache[key] = built;
  return built;
}

class CommittedCanvasPainter extends CustomPainter {
  const CommittedCanvasPainter({
    required this.page,
    required this.elements,
    required this.panOffset,
    required this.zoom,
    required this.selectedElementId,
    this.revision = 0,
    this.paintPaper = true,
    this.paintInk = true,
  });

  final NotebookPageModel? page;
  final List<CanvasElementModel> elements;
  final Offset panOffset;
  final double zoom;
  final String? selectedElementId;
  final int revision;
  final bool paintPaper;
  final bool paintInk;

  @override
  void paint(Canvas canvas, Size size) {
    if (paintPaper) {
      final paperColor =
          Color(page?.backgroundColorValue ?? 0xFFFFFDF9);
      canvas.drawRect(Offset.zero & size, Paint()..color = paperColor);
    }

    canvas.save();
    canvas.translate(panOffset.dx, panOffset.dy);
    canvas.scale(zoom, zoom);

    if (paintPaper) {
      final visibleWorld = Rect.fromLTRB(
        -panOffset.dx / zoom - 40,
        -panOffset.dy / zoom - 40,
        (size.width - panOffset.dx) / zoom + 40,
        (size.height - panOffset.dy) / zoom + 40,
      );

      _paintPaperTemplate(
        canvas,
        visibleWorld,
        page?.background ?? PageBackground.grid,
      );
    }

    if (paintInk) {
      for (final el in elements) {
        if (el.deleted) continue;
        if (el.kind == ElementKind.stroke) {
          _paintStroke(canvas, el);
        } else if (el.kind == ElementKind.highlighter) {
          _paintHighlighter(canvas, el);
        } else if (el.kind == ElementKind.shape) {
          _paintShape(canvas, el);
        }

        if (el.id == selectedElementId) {
          _paintSelectionOverlay(canvas, el);
        }
      }
    }

    canvas.restore();
  }

  void _paintPaperTemplate(
    Canvas canvas,
    Rect visible,
    PageBackground background,
  ) {
    switch (background) {
      case PageBackground.blank:
        return;

      case PageBackground.grid:
        const step = 32.0;
        final paint = Paint()
          ..color = const Color(0xFFE2E8F0).withValues(alpha: 0.72)
          ..strokeWidth = 1.0 / math.max(0.6, zoom);
        final startX = (visible.left / step).floor() * step;
        final startY = (visible.top / step).floor() * step;
        for (var x = startX; x <= visible.right; x += step) {
          canvas.drawLine(
            Offset(x, visible.top),
            Offset(x, visible.bottom),
            paint,
          );
        }
        for (var y = startY; y <= visible.bottom; y += step) {
          canvas.drawLine(
            Offset(visible.left, y),
            Offset(visible.right, y),
            paint,
          );
        }
        return;

      case PageBackground.dots:
        const step = 28.0;
        final paint = Paint()
          ..color = const Color(0xFFCBD5E1).withValues(alpha: 0.9)
          ..style = PaintingStyle.fill;
        final radius = 1.4 / math.max(0.6, zoom);
        final startX = (visible.left / step).floor() * step;
        final startY = (visible.top / step).floor() * step;
        for (var x = startX; x <= visible.right; x += step) {
          for (var y = startY; y <= visible.bottom; y += step) {
            canvas.drawCircle(Offset(x, y), radius, paint);
          }
        }
        return;

      case PageBackground.ruled:
        const lineStep = 36.0;
        final rulePaint = Paint()
          ..color = const Color(0xFFBFDBFE).withValues(alpha: 0.75)
          ..strokeWidth = 1.1 / math.max(0.6, zoom);
        final startY = (visible.top / lineStep).floor() * lineStep;
        for (var y = startY; y <= visible.bottom; y += lineStep) {
          canvas.drawLine(
            Offset(visible.left, y),
            Offset(visible.right, y),
            rulePaint,
          );
        }
        final marginPaint = Paint()
          ..color = const Color(0xFFFCA5A5).withValues(alpha: 0.75)
          ..strokeWidth = 1.5 / math.max(0.6, zoom);
        canvas.drawLine(
          Offset(88, visible.top),
          Offset(88, visible.bottom),
          marginPaint,
        );
        return;

      case PageBackground.cornell:
        const lineStep = 34.0;
        final rulePaint = Paint()
          ..color = const Color(0xFFE2E8F0).withValues(alpha: 0.75)
          ..strokeWidth = 1.0 / math.max(0.6, zoom);
        final startY = math.max(120.0, (visible.top / lineStep).floor() * lineStep);
        for (var y = startY; y <= visible.bottom; y += lineStep) {
          canvas.drawLine(
            Offset(visible.left, y),
            Offset(visible.right, y),
            rulePaint,
          );
        }
        final dividerPaint = Paint()
          ..color = const Color(0xFF6366F1).withValues(alpha: 0.45)
          ..strokeWidth = 2.0 / math.max(0.6, zoom);
        // Header horizontal bar
        canvas.drawLine(
          Offset(visible.left, 110),
          Offset(visible.right, 110),
          dividerPaint,
        );
        // Cue vertical divider
        canvas.drawLine(
          Offset(268, 110),
          Offset(268, math.max(552, visible.bottom)),
          dividerPaint,
        );
        // Summary horizontal divider
        canvas.drawLine(
          Offset(visible.left, 552),
          Offset(visible.right, 552),
          dividerPaint,
        );
        _paintCornellBadge(canvas, '主题 / Topic', const Offset(36, 74));
        _paintCornellBadge(canvas, '线索 / Cues', const Offset(36, 120));
        _paintCornellBadge(canvas, '笔记 / Notes', const Offset(286, 120));
        _paintCornellBadge(canvas, '总结 / Summary', const Offset(36, 560));
        return;
    }
  }

  void _paintCornellBadge(Canvas canvas, String text, Offset pos) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xFF6366F1).withValues(alpha: 0.65),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos);
  }

  void _paintStroke(Canvas canvas, CanvasElementModel el) {
    final path = _cachedStrokeRibbonPath(el);
    canvas.drawPath(
      path,
      Paint()
        ..color = Color(el.colorValue)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  void _paintHighlighter(Canvas canvas, CanvasElementModel el) {
    final path = _cachedHighlighterPath(el);
    canvas.drawPath(
      path,
      Paint()
        ..color = Color(el.colorValue).withValues(alpha: 0.34)
        ..style = PaintingStyle.stroke
        ..strokeWidth = el.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  void _paintShape(Canvas canvas, CanvasElementModel el) {
    paintShapeGeometry(
      canvas: canvas,
      shapeKind: el.shapeKind,
      x: el.x,
      y: el.y,
      width: el.width,
      height: el.height,
      strokeColor: Color(el.colorValue),
      fillColor: el.fillColorValue != 0
          ? Color(el.fillColorValue)
          : Color(el.colorValue).withValues(alpha: 0.1),
      strokeWidth: el.strokeWidth,
      label: el.text,
    );
  }

  void _paintSelectionOverlay(Canvas canvas, CanvasElementModel el) {
    final b = el.bounds;
    final rect = Rect.fromLTRB(b.left - 4, b.top - 4, b.right + 4, b.bottom + 4);
    final outlinePaint = Paint()
      ..color = const Color(0xFF4F46E5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 / zoom;
    canvas.drawRect(rect, outlinePaint);

    final handlePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final handleStroke = Paint()
      ..color = const Color(0xFF4F46E5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / zoom;
    final r = 4.5 / zoom;
    for (final corner in <Offset>[
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawCircle(corner, r, handlePaint);
      canvas.drawCircle(corner, r, handleStroke);
    }
  }

  @override
  bool shouldRepaint(covariant CommittedCanvasPainter oldDelegate) {
    if (paintPaper != oldDelegate.paintPaper ||
        paintInk != oldDelegate.paintInk ||
        panOffset != oldDelegate.panOffset ||
        zoom != oldDelegate.zoom) {
      return true;
    }
    if (paintPaper) {
      if (page?.id != oldDelegate.page?.id ||
          page?.background != oldDelegate.page?.background ||
          page?.backgroundColorValue != oldDelegate.page?.backgroundColorValue) {
        return true;
      }
    }
    if (paintInk) {
      if (revision != oldDelegate.revision ||
          page?.id != oldDelegate.page?.id ||
          selectedElementId != oldDelegate.selectedElementId ||
          elements.length != oldDelegate.elements.length) {
        return true;
      }
    }
    return false;
  }
}

void paintShapeGeometry({
  required Canvas canvas,
  required ShapeKind shapeKind,
  required double x,
  required double y,
  required double width,
  required double height,
  required Color strokeColor,
  required Color fillColor,
  required double strokeWidth,
  String label = '',
}) {
  final strokePaint = Paint()
    ..color = strokeColor
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  final fillPaint = Paint()
    ..color = fillColor
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;

  final left = math.min(x, x + width);
  final top = math.min(y, y + height);
  final w = width.abs();
  final h = height.abs();
  final rect = Rect.fromLTWH(left, top, w, h);

  switch (shapeKind) {
    case ShapeKind.rectangle:
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
      canvas.drawRRect(rrect, fillPaint);
      canvas.drawRRect(rrect, strokePaint);
      break;

    case ShapeKind.ellipse:
      canvas.drawOval(rect, fillPaint);
      canvas.drawOval(rect, strokePaint);
      break;

    case ShapeKind.diamond:
      final path = Path()
        ..moveTo(rect.center.dx, rect.top)
        ..lineTo(rect.right, rect.center.dy)
        ..lineTo(rect.center.dx, rect.bottom)
        ..lineTo(rect.left, rect.center.dy)
        ..close();
      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, strokePaint);
      break;

    case ShapeKind.line:
      canvas.drawLine(Offset(x, y), Offset(x + width, y + height), strokePaint);
      break;

    case ShapeKind.arrow:
      final start = Offset(x, y);
      final end = Offset(x + width, y + height);
      canvas.drawLine(start, end, strokePaint);
      final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
      final headLen = math.max(12.0, strokeWidth * 3.8);
      const wingAngle = 0.48;
      final p1 = Offset(
        end.dx - headLen * math.cos(angle - wingAngle),
        end.dy - headLen * math.sin(angle - wingAngle),
      );
      final p2 = Offset(
        end.dx - headLen * math.cos(angle + wingAngle),
        end.dy - headLen * math.sin(angle + wingAngle),
      );
      final headPath = Path()
        ..moveTo(end.dx, end.dy)
        ..lineTo(p1.dx, p1.dy)
        ..moveTo(end.dx, end.dy)
        ..lineTo(p2.dx, p2.dy);
      canvas.drawPath(headPath, strokePaint);
      break;
  }

  if (label.trim().isNotEmpty &&
      shapeKind != ShapeKind.line &&
      shapeKind != ShapeKind.arrow) {
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: strokeColor,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 3,
    )..layout(maxWidth: math.max(40, w - 16));
    tp.paint(
      canvas,
      Offset(
        rect.center.dx - tp.width * 0.5,
        rect.center.dy - tp.height * 0.5,
      ),
    );
  }
}

class LiveOverlayPainter extends CustomPainter {
  LiveOverlayPainter({
    required this.controller,
  }) : super(repaint: controller.livePaintListenable);

  final NotebookController controller;

  @override
  void paint(Canvas canvas, Size size) {
    final activePageId = controller.activePageId;
    final panOffset = controller.panOffset;
    final zoom = controller.zoom;
    final activeStroke = controller.activeStroke;
    final activeShape = controller.activeShape;
    final remoteLiveStrokes = controller.remoteLiveStrokes;
    final laserTrails = controller.laserTrails;
    final remotePeers = controller.remotePeersMap.values;

    canvas.save();
    canvas.translate(panOffset.dx, panOffset.dy);
    canvas.scale(zoom, zoom);

    // 1. Active local in-progress stroke
    final local = activeStroke;
    if (local != null && local.points.isNotEmpty) {
      if (local.kind == ElementKind.highlighter) {
        final path = buildSmoothCenterlinePath(
          local.points.map((p) => Offset(p.dx, p.dy)).toList(),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = Color(local.colorValue).withValues(alpha: 0.34)
            ..style = PaintingStyle.stroke
            ..strokeWidth = local.strokeWidth
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );
      } else {
        final path = buildVariableWidthStrokePath(
          local.points,
          local.strokeWidth,
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = Color(local.colorValue)
            ..style = PaintingStyle.fill
            ..isAntiAlias = true,
        );
      }
    }

    // 2. Active local shape preview
    final shape = activeShape;
    if (shape != null) {
      final rawW = shape.currentX - shape.startX;
      final rawH = shape.currentY - shape.startY;
      final color = Color(shape.colorValue);
      paintShapeGeometry(
        canvas: canvas,
        shapeKind: shape.shapeKind,
        x: shape.startX,
        y: shape.startY,
        width: rawW,
        height: rawH,
        strokeColor: color,
        fillColor: color.withValues(alpha: 0.12),
        strokeWidth: shape.strokeWidth,
      );
    }

    // 3. Remote streaming strokes on the same page
    for (final frame in remoteLiveStrokes.values) {
      if (frame.pageId != activePageId || frame.points.isEmpty) continue;
      if (frame.kind == ElementKind.highlighter) {
        final path = buildSmoothCenterlinePath(
          frame.points.map((p) => Offset(p.dx, p.dy)).toList(),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = Color(frame.colorValue).withValues(alpha: 0.34)
            ..style = PaintingStyle.stroke
            ..strokeWidth = frame.strokeWidth
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );
      } else {
        final path = buildVariableWidthStrokePath(
          frame.points,
          frame.strokeWidth,
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = Color(frame.colorValue)
            ..style = PaintingStyle.fill
            ..isAntiAlias = true,
        );
      }
      final tip = Offset(frame.points.last.dx, frame.points.last.dy);
      _paintPeerTag(
        canvas,
        tip + const Offset(10, -18),
        '${frame.peerName} 正在书写',
        Color(frame.colorValue),
        zoom,
      );
    }

    // 4. Glowing fading laser trails
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final trail in laserTrails.values) {
      if (trail.pageId != activePageId || trail.points.isEmpty) continue;
      final baseColor = Color(trail.colorValue);
      for (var i = 0; i < trail.points.length - 1; i++) {
        final a = trail.points[i];
        final b = trail.points[i + 1];
        final age = (now - b.createdAtMs).clamp(0, 1200);
        final alpha = 1.0 - (age / 1200.0);
        if (alpha <= 0.02) continue;

        canvas.drawLine(
          Offset(a.x, a.y),
          Offset(b.x, b.y),
          Paint()
            ..color = baseColor.withValues(alpha: alpha * 0.35)
            ..strokeWidth = 12.0
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawLine(
          Offset(a.x, a.y),
          Offset(b.x, b.y),
          Paint()
            ..color = Colors.white.withValues(alpha: alpha * 0.92)
            ..strokeWidth = 3.5
            ..strokeCap = StrokeCap.round,
        );
      }
      final head = trail.points.last;
      final headAge = (now - head.createdAtMs).clamp(0, 1200);
      final headAlpha = 1.0 - (headAge / 1200.0);
      if (headAlpha > 0.05) {
        final headPos = Offset(head.x, head.y);
        canvas.drawCircle(
          headPos,
          10.0,
          Paint()..color = baseColor.withValues(alpha: headAlpha * 0.45),
        );
        canvas.drawCircle(
          headPos,
          4.5,
          Paint()..color = Colors.white.withValues(alpha: headAlpha),
        );
      }
    }

    // 5. Remote peer live cursors
    for (final peer in remotePeers) {
      if (peer.activePageId != activePageId || !peer.cursorVisible) continue;
      final pos = Offset(peer.cursorX, peer.cursorY);
      final peerColor = Color(peer.colorValue);
      final cursorPath = Path()
        ..moveTo(pos.dx, pos.dy)
        ..lineTo(pos.dx + 4, pos.dy + 17)
        ..lineTo(pos.dx + 9, pos.dy + 12)
        ..lineTo(pos.dx + 16, pos.dy + 13)
        ..close();
      canvas.drawPath(cursorPath, Paint()..color = peerColor);
      canvas.drawPath(
        cursorPath,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4 / zoom,
      );
      _paintPeerTag(
        canvas,
        pos + Offset(14 / zoom, 16 / zoom),
        '${peer.displayName} · ${peer.formFactor.label}',
        peerColor,
        zoom,
      );
    }

    canvas.restore();
  }

  void _paintPeerTag(
    Canvas canvas,
    Offset pos,
    String text,
    Color bgColor,
    double zoom,
  ) {
    final scale = 1.0 / zoom;
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    canvas.scale(scale, scale);

    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final pill = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, tp.width + 14, tp.height + 8),
      const Radius.circular(999),
    );
    canvas.drawRRect(pill, Paint()..color = bgColor.withValues(alpha: 0.94));
    tp.paint(canvas, const Offset(7, 4));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LiveOverlayPainter oldDelegate) {
    return !identical(controller, oldDelegate.controller);
  }
}
