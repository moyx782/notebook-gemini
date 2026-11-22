import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:notebook_core/notebook_core.dart';

import '../../state/notebook_controller.dart';

final LinkedHashMap<String, Uint8List> _decodedImageCache =
    LinkedHashMap<String, Uint8List>();

Uint8List? _decodeDataUrlCached(String uri) {
  final existing = _decodedImageCache[uri];
  if (existing != null) return existing;
  final comma = uri.indexOf(',');
  if (comma < 0) return null;
  try {
    final bytes = base64Decode(uri.substring(comma + 1));
    if (_decodedImageCache.length > 64) {
      _decodedImageCache.remove(_decodedImageCache.keys.first);
    }
    _decodedImageCache[uri] = bytes;
    return bytes;
  } catch (_) {
    return null;
  }
}

class CanvasCardLayer extends StatelessWidget {
  const CanvasCardLayer({
    super.key,
    required this.controller,
    required this.interactive,
  });

  final NotebookController controller;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final cards = controller.activeElements
        .where(
          (e) =>
              !e.deleted &&
              (e.kind == ElementKind.textCard ||
                  e.kind == ElementKind.stickyNote ||
                  e.kind == ElementKind.image),
        )
        .toList();

    final zoom = controller.zoom;
    final pan = controller.panOffset;

    return IgnorePointer(
      ignoring: !interactive,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (final el in cards)
            Positioned(
              key: ValueKey<String>('card-${el.id}'),
              left: pan.dx + el.x * zoom,
              top: pan.dy + el.y * zoom,
              width: el.width * zoom,
              height: el.height * zoom,
              child: FittedBox(
                fit: BoxFit.fill,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: el.width,
                  height: el.height,
                  child: _CanvasElementCard(
                    element: el,
                    controller: controller,
                    showUnlockBadge: interactive,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CanvasElementCard extends StatefulWidget {
  const _CanvasElementCard({
    required this.element,
    required this.controller,
    this.showUnlockBadge = false,
  });

  final CanvasElementModel element;
  final NotebookController controller;
  final bool showUnlockBadge;

  @override
  State<_CanvasElementCard> createState() => _CanvasElementCardState();
}

class _CanvasElementCardState extends State<_CanvasElementCard> {
  late final TextEditingController _textController;
  final FocusNode _focusNode = FocusNode();

  double _dragStartX = 0;
  double _dragStartY = 0;
  double _dragStartW = 0;
  double _dragStartH = 0;
  DateTime? _lastCardTapAt;

  bool get _isSelected =>
      widget.controller.selectedElementId == widget.element.id;
  bool get _isEditing =>
      widget.controller.editingCardId == widget.element.id;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.element.text);
  }

  @override
  void didUpdateWidget(covariant _CanvasElementCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.element.text != oldWidget.element.text &&
        !_focusNode.hasFocus &&
        _textController.text != widget.element.text) {
      _textController.text = widget.element.text;
    }
    if (_isEditing && !_focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isEditing) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commitTextIfChanged() {
    widget.controller.updateElementText(
      widget.element.id,
      _textController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final el = widget.element;
    final isSticky = el.kind == ElementKind.stickyNote;
    final isImage = el.kind == ElementKind.image;
    final isLockedPdfSheet = isImage && el.locked && el.text.trim().isEmpty;
    final bgColor = el.fillColorValue != 0
        ? Color(el.fillColorValue)
        : (isSticky ? const Color(0xFFFEF08A) : Colors.white);

    if (el.locked) {
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          IgnorePointer(
            child: Container(
              width: el.width,
              height: el.height,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(
                  isLockedPdfSheet ? 4 : (isSticky ? 6 : 14),
                ),
                border: Border.all(
                  color: isLockedPdfSheet
                      ? const Color(0xFFCBD5E1)
                      : const Color(0xFFE2E8F0),
                  width: 1.0,
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: isLockedPdfSheet ? 0.08 : 0.05,
                    ),
                    blurRadius: isLockedPdfSheet ? 18 : 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(
                  isLockedPdfSheet ? 3 : (isSticky ? 5 : 13),
                ),
                child: isImage
                    ? _buildImageCardBody(el, fullBleed: isLockedPdfSheet)
                    : _buildTextOrStickyBody(el, isSticky),
              ),
            ),
          ),
          if (widget.showUnlockBadge)
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                elevation: 2,
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => widget.controller.toggleElementLocked(el.id),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 13,
                          color: Color(0xFF475569),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '底图已锁 · 点击解锁',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF475569),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final now = DateTime.now();
        final prev = _lastCardTapAt;
        _lastCardTapAt = now;
        widget.controller.selectElement(el.id);
        if (!isImage &&
            prev != null &&
            now.difference(prev) <= const Duration(milliseconds: 350)) {
          _lastCardTapAt = null;
          _textController.text = el.text;
          widget.controller.setEditingCard(el.id);
        }
      },
      onPanStart: _isEditing
          ? null
          : (_) {
              widget.controller.selectElement(el.id);
              _dragStartX = el.x;
              _dragStartY = el.y;
              _dragStartW = el.width;
              _dragStartH = el.height;
            },
      onPanUpdate: _isEditing
          ? null
          : (details) {
              final z = widget.controller.zoom;
              final current =
                  widget.controller.doc.getElement(el.id) ?? el;
              widget.controller.previewElementFrame(
                el.id,
                x: current.x + details.delta.dx / z,
                y: current.y + details.delta.dy / z,
              );
            },
      onPanEnd: _isEditing
          ? null
          : (_) {
              widget.controller.commitElementTransformUndo(
                elementId: el.id,
                oldX: _dragStartX,
                oldY: _dragStartY,
                oldWidth: _dragStartW,
                oldHeight: _dragStartH,
              );
            },
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            width: el.width,
            height: el.height,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(isSticky ? 6 : 14),
              border: Border.all(
                color: _isSelected
                    ? const Color(0xFF4F46E5)
                    : (isSticky
                        ? Colors.black.withValues(alpha: 0.08)
                        : const Color(0xFFE2E8F0)),
                width: _isSelected ? 2.2 : 1.2,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: isSticky ? 0.12 : 0.06,
                  ),
                  blurRadius: isSticky ? 14 : 16,
                  offset: Offset(0, isSticky ? 6 : 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(isSticky ? 5 : 13),
              child: isImage
                  ? _buildImageCardBody(el)
                  : _buildTextOrStickyBody(el, isSticky),
            ),
          ),

          // Mini toolbar when selected
          if (_isSelected)
            Positioned(
              top: -38,
              left: 0,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(999),
                color: Colors.white,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (!isImage)
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            if (_isEditing) {
                              _commitTextIfChanged();
                              widget.controller.setEditingCard(null);
                            } else {
                              _textController.text = el.text;
                              widget.controller.setEditingCard(el.id);
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  _isEditing
                                      ? Icons.check_circle_outline
                                      : Icons.edit_outlined,
                                  size: 15,
                                  color: const Color(0xFF4F46E5),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _isEditing ? '完成' : '编辑',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF4F46E5),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (isSticky)
                        for (final c in NotebookController.stickyPalette)
                          GestureDetector(
                            onTap: () => widget.controller
                                .updateElementColor(el.id, c, fill: true),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              width: 15,
                              height: 15,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: el.fillColorValue == c.toARGB32()
                                      ? const Color(0xFF0F172A)
                                      : Colors.black26,
                                  width: el.fillColorValue == c.toARGB32()
                                      ? 1.8
                                      : 1,
                                ),
                              ),
                            ),
                          ),
                      const SizedBox(width: 4),
                      Tooltip(
                        message: '锁定为底图（防橡皮擦与误拖动）',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () =>
                              widget.controller.toggleElementLocked(el.id),
                          child: const Padding(
                            padding: EdgeInsets.all(3),
                            child: Icon(
                              Icons.lock_open_rounded,
                              size: 15,
                              color: Color(0xFF475569),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => widget.controller.deleteElement(el.id),
                        child: const Padding(
                          padding: EdgeInsets.all(3),
                          child: Icon(
                            Icons.delete_outline,
                            size: 16,
                            color: Color(0xFFDC2626),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Resize handle
          if (_isSelected)
            Positioned(
              right: -7,
              bottom: -7,
              child: GestureDetector(
                onPanStart: (_) {
                  _dragStartX = el.x;
                  _dragStartY = el.y;
                  _dragStartW = el.width;
                  _dragStartH = el.height;
                },
                onPanUpdate: (details) {
                  final z = widget.controller.zoom;
                  final current =
                      widget.controller.doc.getElement(el.id) ?? el;
                  widget.controller.previewElementFrame(
                    el.id,
                    width: current.width + details.delta.dx / z,
                    height: current.height + details.delta.dy / z,
                  );
                },
                onPanEnd: (_) {
                  widget.controller.commitElementTransformUndo(
                    elementId: el.id,
                    oldX: _dragStartX,
                    oldY: _dragStartY,
                    oldWidth: _dragStartW,
                    oldHeight: _dragStartH,
                  );
                },
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF4F46E5),
                      width: 2.2,
                    ),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(color: Colors.black26, blurRadius: 4),
                    ],
                  ),
                  child: const Icon(
                    Icons.open_in_full,
                    size: 10,
                    color: Color(0xFF4F46E5),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTextOrStickyBody(CanvasElementModel el, bool isSticky) {
    if (_isEditing) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _textController,
                focusNode: _focusNode,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  fontSize: isSticky ? 14 : 13.5,
                  height: 1.45,
                  color: const Color(0xFF0F172A),
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: '输入 Markdown 笔记内容...',
                ),
                onChanged: (val) =>
                    widget.controller.updateElementText(el.id, val),
              ),
            ),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                '支持 # 标题 · **加粗** · - [ ] 待办',
                style: TextStyle(
                  fontSize: 10.5,
                  color: Colors.black.withValues(alpha: 0.45),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (isSticky) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  el.text,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: Color(0xFF1E293B),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            Text(
              '— ${el.authorName}',
              style: TextStyle(
                fontSize: 10.5,
                color: Colors.black.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: _MarkdownCardContent(
        markdown: el.text,
        onToggleTask: (lineIndex) =>
            widget.controller.toggleMarkdownTaskLine(el.id, lineIndex),
      ),
    );
  }

  Widget _buildImageCardBody(CanvasElementModel el, {bool fullBleed = false}) {
    final uri = el.imageUri.trim();
    Widget content;
    if (uri.startsWith('preset://')) {
      content = _PresetDiagramGraphic(presetId: uri);
    } else if (uri.startsWith('data:image/')) {
      final bytes = _decodeDataUrlCached(uri);
      if (bytes != null) {
        content = Image.memory(
          bytes,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      } else {
        content = _brokenImagePlaceholder('图片编码解析失败');
      }
    } else if (uri.startsWith('http://') || uri.startsWith('https://')) {
      content = Image.network(
        uri,
        fit: BoxFit.contain,
        errorBuilder: (ctx, error, stack) =>
            _brokenImagePlaceholder('网络图片加载失败'),
      );
    } else {
      content = _brokenImagePlaceholder('未识别的图片地址');
    }

    if (fullBleed) {
      return ColoredBox(
        color: Colors.white,
        child: content,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Container(
            color: const Color(0xFFF8FAFC),
            padding: const EdgeInsets.all(8),
            child: content,
          ),
        ),
        if (el.text.trim().isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Text(
              el.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF334155),
              ),
            ),
          ),
      ],
    );
  }

  Widget _brokenImagePlaceholder(String msg) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.broken_image_outlined,
              size: 32, color: Color(0xFF94A3B8)),
          const SizedBox(height: 6),
          Text(
            msg,
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
        ],
      ),
    );
  }
}

class _MarkdownCardContent extends StatelessWidget {
  const _MarkdownCardContent({
    required this.markdown,
    required this.onToggleTask,
  });

  final String markdown;
  final void Function(int lineIndex) onToggleTask;

  @override
  Widget build(BuildContext context) {
    final lines = markdown.split('\n');
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (var i = 0; i < lines.length; i++)
            _buildLine(lines[i], i),
        ],
      ),
    );
  }

  Widget _buildLine(String rawLine, int lineIndex) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty) {
      return const SizedBox(height: 6);
    }

    if (line.startsWith('# ')) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          line.substring(2),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF0F172A),
          ),
        ),
      );
    }
    if (line.startsWith('## ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 4),
        child: Text(
          line.substring(3),
          style: const TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1E293B),
          ),
        ),
      );
    }
    if (line.startsWith('### ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 3),
        child: Text(
          line.substring(4),
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF334155),
          ),
        ),
      );
    }

    final taskMatch =
        RegExp(r'^\s*[-*]\s+\[([ xX])\]\s+(.*)$').firstMatch(line);
    if (taskMatch != null) {
      final checked = taskMatch.group(1)!.toLowerCase() == 'x';
      final body = taskMatch.group(2)!;
      return InkWell(
        onTap: () => onToggleTask(lineIndex),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                checked ? Icons.check_box : Icons.check_box_outline_blank,
                size: 18,
                color: checked
                    ? const Color(0xFF16A34A)
                    : const Color(0xFF64748B),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildInlineRichText(
                  body,
                  baseStyle: TextStyle(
                    fontSize: 13.5,
                    height: 1.4,
                    color: checked
                        ? const Color(0xFF64748B)
                        : const Color(0xFF1E293B),
                    decoration:
                        checked ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (line.startsWith('> ')) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        decoration: const BoxDecoration(
          color: Color(0xFFEEF2FF),
          border: Border(
            left: BorderSide(color: Color(0xFF4F46E5), width: 3),
          ),
          borderRadius: BorderRadius.horizontal(right: Radius.circular(6)),
        ),
        child: _buildInlineRichText(
          line.substring(2),
          baseStyle: const TextStyle(
            fontSize: 13,
            height: 1.4,
            color: Color(0xFF312E81),
          ),
        ),
      );
    }

    if (line.startsWith('- ') || line.startsWith('* ')) {
      return Padding(
        padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '• ',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF4F46E5),
              ),
            ),
            Expanded(
              child: _buildInlineRichText(
                line.substring(2),
                baseStyle: const TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: Color(0xFF1E293B),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: _buildInlineRichText(
        line,
        baseStyle: const TextStyle(
          fontSize: 13.5,
          height: 1.45,
          color: Color(0xFF1E293B),
        ),
      ),
    );
  }

  Widget _buildInlineRichText(String text, {required TextStyle baseStyle}) {
    final spans = <InlineSpan>[];
    final tokenRegex = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`)');
    var cursor = 0;

    for (final match in tokenRegex.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('**') && token.endsWith('**')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: baseStyle.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      } else if (token.startsWith('`') && token.endsWith('`')) {
        spans.add(
          TextSpan(
            text: ' ${token.substring(1, token.length - 1)} ',
            style: baseStyle.copyWith(
              fontFamily: 'monospace',
              fontSize: (baseStyle.fontSize ?? 13.5) - 1,
              backgroundColor: const Color(0xFFF1F5F9),
              color: const Color(0xFF4338CA),
            ),
          ),
        );
      }
      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return RichText(
      text: TextSpan(style: baseStyle, children: spans),
    );
  }
}

class _PresetDiagramGraphic extends StatelessWidget {
  const _PresetDiagramGraphic({required this.presetId});

  final String presetId;

  @override
  Widget build(BuildContext context) {
    switch (presetId) {
      case 'preset://mindmap':
        return _buildCard(
          color: const Color(0xFFEEF2FF),
          accent: const Color(0xFF4F46E5),
          icon: Icons.hub_outlined,
          title: '思维导图节点图',
          subtitle: '可直接在其上方用荧光笔或手写圈点批注',
        );
      case 'preset://devices':
        return _buildCard(
          color: const Color(0xFFECFEFF),
          accent: const Color(0xFF0891B2),
          icon: Icons.devices_other_outlined,
          title: '三端协同架构示意图',
          subtitle: '桌面端 · iPad Apple Pencil · 手机扫码同屏',
        );
      default:
        return _buildCard(
          color: const Color(0xFFF0FDF4),
          accent: const Color(0xFF16A34A),
          icon: Icons.grid_view_rounded,
          title: '四象限工作看板模板',
          subtitle: '重要紧急 / 长期规划 / 快速跟进 / 灵感池',
        );
    }
  }

  Widget _buildCard({
    required Color color,
    required Color accent,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 42, color: accent),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
          ),
        ],
      ),
    );
  }
}
