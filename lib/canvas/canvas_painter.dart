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
    this.showPageGuide = false,
    this.paintPaper = true,
    this.paintGraph = false,
    this.paintInk = true,
  });

  final NotebookPageModel? page;
  final List<CanvasElementModel> elements;
  final Offset panOffset;
  final double zoom;
  final String? selectedElementId;
  final int revision;
  final bool showPageGuide;
  final bool paintPaper;
  final bool paintGraph;
  final bool paintInk;

  @override
  void paint(Canvas canvas, Size size) {
    final paperColor = Color(page?.backgroundColorValue ?? 0xFFFFFDF9);
    final isDarkPaper = paperColor.computeLuminance() < 0.35;
    if (paintPaper) {
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
        isDarkPaper: isDarkPaper,
      );

      if (showPageGuide) {
        _paintA4PageGuide(canvas, visibleWorld, isDarkPaper: isDarkPaper);
      }
    }

    if (paintGraph) {
      final activeEls = elements.where((e) => !e.deleted).toList();
      final byId = <String, CanvasElementModel>{
        for (final e in activeEls) e.id: e,
      };
      for (final el in activeEls) {
        if (el.kind == ElementKind.cluster) {
          _paintCluster(canvas, el, zoom);
          if (el.id == selectedElementId) {
            _paintSelectionOverlay(canvas, el);
          }
        }
      }
      for (final el in activeEls) {
        if (el.kind == ElementKind.connector) {
          _paintConnector(
            canvas,
            el,
            byId,
            zoom,
            selected: el.id == selectedElementId,
          );
        }
      }
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
        } else {
          continue;
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
    PageBackground background, {
    bool isDarkPaper = false,
  }) {
    final subtleLineColor = isDarkPaper
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFE2E8F0).withValues(alpha: 0.72);
    final accentColor = isDarkPaper
        ? const Color(0xFFA5B4FC).withValues(alpha: 0.65)
        : const Color(0xFF6366F1).withValues(alpha: 0.55);

    switch (background) {
      case PageBackground.blank:
        return;

      case PageBackground.grid:
        const step = 32.0;
        final paint = Paint()
          ..color = subtleLineColor
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
          ..color = isDarkPaper
              ? Colors.white.withValues(alpha: 0.24)
              : const Color(0xFFCBD5E1).withValues(alpha: 0.9)
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
          ..color = isDarkPaper
              ? Colors.white.withValues(alpha: 0.16)
              : const Color(0xFFBFDBFE).withValues(alpha: 0.75)
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
          ..color = isDarkPaper
              ? const Color(0xFFFCA5A5).withValues(alpha: 0.45)
              : const Color(0xFFFCA5A5).withValues(alpha: 0.75)
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
          ..color = subtleLineColor
          ..strokeWidth = 1.0 / math.max(0.6, zoom);
        final startY =
            math.max(120.0, (visible.top / lineStep).floor() * lineStep);
        for (var y = startY; y <= visible.bottom; y += lineStep) {
          canvas.drawLine(
            Offset(visible.left, y),
            Offset(visible.right, y),
            rulePaint,
          );
        }
        final dividerPaint = Paint()
          ..color = accentColor
          ..strokeWidth = 2.0 / math.max(0.6, zoom);
        canvas.drawLine(
          Offset(visible.left, 110),
          Offset(visible.right, 110),
          dividerPaint,
        );
        canvas.drawLine(
          Offset(268, 110),
          Offset(268, math.max(552, visible.bottom)),
          dividerPaint,
        );
        canvas.drawLine(
          Offset(visible.left, 552),
          Offset(visible.right, 552),
          dividerPaint,
        );
        _paintTemplateBadge(
          canvas,
          '主题 / Topic',
          const Offset(36, 74),
          color: accentColor,
        );
        _paintTemplateBadge(
          canvas,
          '线索 / Cues',
          const Offset(36, 120),
          color: accentColor,
        );
        _paintTemplateBadge(
          canvas,
          '笔记 / Notes',
          const Offset(286, 120),
          color: accentColor,
        );
        _paintTemplateBadge(
          canvas,
          '总结 / Summary',
          const Offset(36, 560),
          color: accentColor,
        );
        return;

      case PageBackground.mistakeBook:
        const gridStep = 32.0;
        final gridPaint = Paint()
          ..color = subtleLineColor
          ..strokeWidth = 0.9 / math.max(0.6, zoom);
        final startX = (visible.left / gridStep).floor() * gridStep;
        final startY =
            math.max(96.0, (visible.top / gridStep).floor() * gridStep);
        for (var x = startX; x <= visible.right; x += gridStep) {
          canvas.drawLine(
            Offset(x, math.max(96.0, visible.top)),
            Offset(x, visible.bottom),
            gridPaint,
          );
        }
        for (var y = startY; y <= visible.bottom; y += gridStep) {
          canvas.drawLine(
            Offset(visible.left, y),
            Offset(visible.right, y),
            gridPaint,
          );
        }

        final framePaint = Paint()
          ..color = isDarkPaper
              ? const Color(0xFFFCA5A5).withValues(alpha: 0.55)
              : const Color(0xFFDC2626).withValues(alpha: 0.38)
          ..strokeWidth = 1.8 / math.max(0.6, zoom);
        canvas.drawLine(
          Offset(visible.left, 96),
          Offset(visible.right, 96),
          framePaint,
        );
        canvas.drawLine(
          const Offset(438, 96),
          Offset(438, math.max(920, visible.bottom)),
          framePaint,
        );
        canvas.drawLine(
          Offset(visible.left, 920),
          Offset(visible.right, 920),
          framePaint,
        );
        final labelColor = isDarkPaper
            ? const Color(0xFFFCA5A5).withValues(alpha: 0.85)
            : const Color(0xFFB91C1C).withValues(alpha: 0.75);
        _paintTemplateBadge(
          canvas,
          '科目 / 章节 · 错题复盘页',
          const Offset(42, 62),
          color: labelColor,
        );
        _paintTemplateBadge(
          canvas,
          '原题摘录 & 错因诊断',
          const Offset(42, 108),
          color: labelColor,
        );
        _paintTemplateBadge(
          canvas,
          '规范解法 & 关键步骤',
          const Offset(454, 108),
          color: isDarkPaper
              ? const Color(0xFF6EE7B7).withValues(alpha: 0.85)
              : const Color(0xFF047857).withValues(alpha: 0.78),
        );
        _paintTemplateBadge(
          canvas,
          '同类变式 & 核心避坑总结',
          const Offset(42, 932),
          color: accentColor,
        );
        return;

      case PageBackground.weeklyPlan:
        const ruleStep = 36.0;
        final rulePaint = Paint()
          ..color = subtleLineColor
          ..strokeWidth = 1.0 / math.max(0.6, zoom);
        final startY =
            math.max(96.0, (visible.top / ruleStep).floor() * ruleStep);
        for (var y = startY; y <= visible.bottom; y += ruleStep) {
          canvas.drawLine(
            Offset(visible.left, y),
            Offset(visible.right, y),
            rulePaint,
          );
        }
        final dividerPaint = Paint()
          ..color = isDarkPaper
              ? const Color(0xFF5EEAD4).withValues(alpha: 0.55)
              : const Color(0xFF0D9488).withValues(alpha: 0.45)
          ..strokeWidth = 1.8 / math.max(0.6, zoom);
        canvas.drawLine(
          Offset(visible.left, 96),
          Offset(visible.right, 96),
          dividerPaint,
        );
        canvas.drawLine(
          const Offset(540, 96),
          Offset(540, math.max(1048, visible.bottom)),
          dividerPaint,
        );
        const days = <String>[
          '周一 Mon',
          '周二 Tue',
          '周三 Wed',
          '周四 Thu',
          '周五 Fri',
          '周六 Sat',
          '周日 Sun',
        ];
        final tealText = isDarkPaper
            ? const Color(0xFF5EEAD4).withValues(alpha: 0.85)
            : const Color(0xFF0F766E).withValues(alpha: 0.8);
        _paintTemplateBadge(
          canvas,
          '周计划与重点待办 · Weekly Planner',
          const Offset(42, 62),
          color: tealText,
        );
        _paintTemplateBadge(
          canvas,
          '本周核心目标 / 待办清单',
          const Offset(558, 108),
          color: tealText,
        );
        for (var i = 0; i < days.length; i++) {
          final slotTop = 96.0 + i * 136.0;
          if (i > 0) {
            canvas.drawLine(
              Offset(40, slotTop),
              Offset(540, slotTop),
              dividerPaint,
            );
          }
          _paintTemplateBadge(
            canvas,
            days[i],
            Offset(44, slotTop + 10),
            color: tealText,
          );
        }
        return;
    }
  }

  void _paintA4PageGuide(
    Canvas canvas,
    Rect visible, {
    required bool isDarkPaper,
  }) {
    const pageLeft = 40.0;
    const pageRight = 834.0; // 794px standard A4 width at 96 DPI
    const pageHeight = 1123.0;
    const topOrigin = 32.0;

    final guideColor = isDarkPaper
        ? Colors.white.withValues(alpha: 0.18)
        : const Color(0xFF94A3B8).withValues(alpha: 0.45);
    final guidePaint = Paint()
      ..color = guideColor
      ..strokeWidth = 1.1 / math.max(0.6, zoom);

    _drawDashedLine(
      canvas,
      Offset(pageLeft, math.max(topOrigin, visible.top)),
      Offset(pageLeft, math.max(topOrigin + pageHeight, visible.bottom)),
      guidePaint,
    );
    _drawDashedLine(
      canvas,
      Offset(pageRight, math.max(topOrigin, visible.top)),
      Offset(pageRight, math.max(topOrigin + pageHeight, visible.bottom)),
      guidePaint,
    );

    final firstIdx = math.max(0, ((visible.top - topOrigin) / pageHeight).floor());
    final lastIdx =
        math.max(1, ((visible.bottom - topOrigin) / pageHeight).ceil());
    for (var idx = firstIdx; idx <= lastIdx; idx++) {
      final y = topOrigin + idx * pageHeight;
      _drawDashedLine(
        canvas,
        Offset(pageLeft, y),
        Offset(pageRight, y),
        guidePaint,
      );
      if (idx >= 0 && idx < 30) {
        _paintTemplateBadge(
          canvas,
          'A4 · 第 ${idx + 1} 屏参考界',
          Offset(pageRight - 118, y + 6),
          color: guideColor,
          fontSize: 10.5,
        );
      }
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    double dashLen = 8.0,
    double gapLen = 6.0,
  }) {
    final total = (end - start).distance;
    if (total <= 0.1) return;
    final dir = (end - start) / total;
    var dist = 0.0;
    while (dist < total) {
      final segEnd = math.min(total, dist + dashLen);
      canvas.drawLine(start + dir * dist, start + dir * segEnd, paint);
      dist += dashLen + gapLen;
    }
  }

  void _paintTemplateBadge(
    Canvas canvas,
    String text,
    Offset pos, {
    required Color color,
    double fontSize = 12,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos);
  }

  void _paintCluster(Canvas canvas, CanvasElementModel el, double zoom) {
    final sem = el.semanticColor;
    final borderColor = Color(
      el.colorValue != 0 ? el.colorValue : sem.borderArgb,
    );
    final fillColor = Color(
      el.fillColorValue != 0 ? el.fillColorValue : sem.fillArgb,
    );
    final textColor = Color(sem.textArgb);
    final rect = Rect.fromLTWH(el.x, el.y, el.width, el.height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(16));

    final bgTint = sem == MindFlowColor.neutral
        ? borderColor.withValues(alpha: 0.08)
        : fillColor.withValues(alpha: 0.34);
    canvas.drawRRect(rrect, Paint()..color = bgTint);

    final dashedPaint = Paint()
      ..color = borderColor.withValues(alpha: 0.78)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (el.strokeWidth > 0 ? el.strokeWidth : 1.8)
      ..strokeCap = StrokeCap.round;
    _drawDashedPath(canvas, Path()..addRRect(rrect), dashedPaint);

    final title = el.text.trim().isEmpty ? '主题分组' : el.text.trim();
    final tp = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          color: textColor,
          fontSize: 12.0,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(60.0, el.width - 36.0));

    final headerRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(el.x + 12, el.y + 8, tp.width + 18, 24),
      const Radius.circular(999),
    );
    canvas.drawRRect(
      headerRect,
      Paint()..color = Colors.white.withValues(alpha: 0.92),
    );
    canvas.drawRRect(
      headerRect,
      Paint()
        ..color = borderColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
    tp.paint(canvas, Offset(el.x + 21, el.y + 8 + (24 - tp.height) * 0.5));
  }

  void _paintConnector(
    Canvas canvas,
    CanvasElementModel el,
    Map<String, CanvasElementModel> byId,
    double zoom, {
    required bool selected,
  }) {
    final curve = computeConnectorCurve(el, byId);
    final sx = curve?.sx ?? el.x;
    final sy = curve?.sy ?? el.y;
    final tx = curve?.tx ?? (el.x + el.width);
    final ty = curve?.ty ?? (el.y + el.height);
    final c1x = curve?.c1x ?? (sx + (tx - sx) * 0.45);
    final c1y = curve?.c1y ?? sy;
    final c2x = curve?.c2x ?? (tx - (tx - sx) * 0.45);
    final c2y = curve?.c2y ?? ty;
    final midX = curve?.midX ?? ((sx + tx) * 0.5);
    final midY = curve?.midY ?? ((sy + ty) * 0.5);

    final color = Color(
      el.colorValue != 0 ? el.colorValue : el.semanticColor.borderArgb,
    );
    final strokeW = el.strokeWidth > 0 ? el.strokeWidth : 2.4;

    final path = Path()
      ..moveTo(sx, sy)
      ..cubicTo(c1x, c1y, c2x, c2y, tx, ty);

    if (selected) {
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF4F46E5).withValues(alpha: 0.28)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW + 6.0 / math.max(0.5, zoom)
          ..strokeCap = StrokeCap.round,
      );
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    final tangentDir = (Offset(tx, ty) - Offset(c2x, c2y)).distanceSquared > 1.0
        ? Offset(tx - c2x, ty - c2y)
        : Offset(tx - sx, ty - sy);
    paintMindFlowArrowHead(
      canvas,
      Offset(tx, ty),
      tangentDir,
      selected ? const Color(0xFF4F46E5) : color,
      size: 10.5,
    );

    final label = el.text.trim();
    if (label.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: selected ? const Color(0xFF312E81) : const Color(0xFF334155),
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 160.0);

      final capsuleRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(midX, midY),
          width: tp.width + 16,
          height: tp.height + 8,
        ),
        const Radius.circular(999),
      );
      canvas.drawRRect(
        capsuleRect,
        Paint()..color = Colors.white.withValues(alpha: 0.96),
      );
      canvas.drawRRect(
        capsuleRect,
        Paint()
          ..color = (selected ? const Color(0xFF4F46E5) : color)
              .withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      tp.paint(
        canvas,
        Offset(midX - tp.width * 0.5, midY - tp.height * 0.5),
      );
    }
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
        paintGraph != oldDelegate.paintGraph ||
        paintInk != oldDelegate.paintInk ||
        panOffset != oldDelegate.panOffset ||
        zoom != oldDelegate.zoom) {
      return true;
    }
    if (paintPaper) {
      if (page?.id != oldDelegate.page?.id ||
          page?.background != oldDelegate.page?.background ||
          page?.backgroundColorValue != oldDelegate.page?.backgroundColorValue ||
          showPageGuide != oldDelegate.showPageGuide) {
        return true;
      }
    }
    if (paintInk || paintGraph) {
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

void _drawDashedPath(
  Canvas canvas,
  Path path,
  Paint paint, {
  double dashLen = 8.0,
  double gapLen = 5.0,
}) {
  for (final metric in path.computeMetrics()) {
    var dist = 0.0;
    while (dist < metric.length) {
      final end = math.min(metric.length, dist + dashLen);
      canvas.drawPath(metric.extractPath(dist, end), paint);
      dist += dashLen + gapLen;
    }
  }
}

void paintMindFlowArrowHead(
  Canvas canvas,
  Offset tip,
  Offset direction,
  Color color, {
  double size = 10.0,
}) {
  final angle = direction.distanceSquared > 0.01
      ? math.atan2(direction.dy, direction.dx)
      : 0.0;
  final wingA = Offset(
    tip.dx - size * math.cos(angle - math.pi / 6),
    tip.dy - size * math.sin(angle - math.pi / 6),
  );
  final wingB = Offset(
    tip.dx - size * math.cos(angle + math.pi / 6),
    tip.dy - size * math.sin(angle + math.pi / 6),
  );
  final arrowPath = Path()
    ..moveTo(tip.dx, tip.dy)
    ..lineTo(wingA.dx, wingA.dy)
    ..lineTo(wingB.dx, wingB.dy)
    ..close();
  canvas.drawPath(arrowPath, Paint()..color = color);
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
      if (controller.isActiveStrokeSnappedLine && local.points.length >= 2) {
        final pStart = Offset(local.points.first.dx, local.points.first.dy);
        final pEnd = Offset(local.points.last.dx, local.points.last.dy);
        final ringPaint = Paint()
          ..color = const Color(0xFF4F46E5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8 / zoom;
        final fillDot = Paint()..color = Colors.white;
        for (final pt in <Offset>[pStart, pEnd]) {
          canvas.drawCircle(pt, 5.0 / zoom, fillDot);
          canvas.drawCircle(pt, 5.0 / zoom, ringPaint);
        }
      }
    }

    // 1b. Freehand lasso loop & multi-selection group frame
    final lassoPts = controller.activeLassoPoints;
    if (lassoPts.length >= 2) {
      final polyPath = Path()..moveTo(lassoPts.first.dx, lassoPts.first.dy);
      for (var i = 1; i < lassoPts.length; i++) {
        polyPath.lineTo(lassoPts[i].dx, lassoPts[i].dy);
      }
      polyPath.close();
      canvas.drawPath(
        polyPath,
        Paint()
          ..color = const Color(0xFF4F46E5).withValues(alpha: 0.09)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        polyPath,
        Paint()
          ..color = const Color(0xFF4F46E5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8 / zoom
          ..strokeJoin = StrokeJoin.round,
      );
    }

    final groupBounds = controller.selectionBounds;
    if (groupBounds != null && controller.selectedElementIds.length > 1) {
      final padded = groupBounds.inflate(8.0);
      final rrect = RRect.fromRectAndRadius(padded, Radius.circular(8.0 / zoom));
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0xFF4F46E5).withValues(alpha: 0.05)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0xFF4F46E5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8 / zoom,
      );
      _paintPeerTag(
        canvas,
        Offset(padded.left, padded.top - 26.0 / zoom),
        '已套索选中 ${controller.selectedElementIds.length} 项 · 拖动整体平移',
        const Color(0xFF4F46E5),
        zoom,
      );
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

    // 4.5. MindFlow live cluster & connector creation previews
    final activeCluster = controller.activeCluster;
    if (activeCluster != null) {
      final rect = Rect.fromLTRB(
        math.min(activeCluster.startX, activeCluster.currentX),
        math.min(activeCluster.startY, activeCluster.currentY),
        math.max(activeCluster.startX, activeCluster.currentX),
        math.max(activeCluster.startY, activeCluster.currentY),
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(16));
      final previewColor = Color(activeCluster.colorValue);
      canvas.drawRRect(
        rrect,
        Paint()..color = previewColor.withValues(alpha: 0.12),
      );
      _drawDashedPath(
        canvas,
        Path()..addRRect(rrect),
        Paint()
          ..color = previewColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }

    final activeConnector = controller.activeConnector;
    if (activeConnector != null) {
      final start = Offset(activeConnector.startX, activeConnector.startY);
      final end = Offset(activeConnector.currentX, activeConnector.currentY);
      final dx = (end.dx - start.dx) * 0.45;
      final c1 = Offset(start.dx + dx, start.dy);
      final c2 = Offset(end.dx - dx, end.dy);
      final color = Color(activeConnector.colorValue);
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round,
      );
      paintMindFlowArrowHead(
        canvas,
        end,
        (end - c2).distanceSquared > 1.0 ? end - c2 : end - start,
        color,
        size: 11.0,
      );
      final hoveredId = activeConnector.hoveredTargetId;
      if (hoveredId != null) {
        final target = controller.doc.getElement(hoveredId);
        if (target != null && !target.deleted) {
          final ring = RRect.fromRectAndRadius(
            Rect.fromLTWH(target.x, target.y, target.width, target.height)
                .inflate(4.0),
            const Radius.circular(14),
          );
          canvas.drawRRect(
            ring,
            Paint()
              ..color = const Color(0xFF4F46E5)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.6,
          );
        }
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
