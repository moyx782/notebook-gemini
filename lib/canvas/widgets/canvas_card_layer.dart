import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

enum CardLayerFilter {
  all,
  lockedPdfOnly,
  foregroundCards,
}

class CanvasCardLayer extends StatelessWidget {
  const CanvasCardLayer({
    super.key,
    required this.controller,
    required this.interactive,
    this.filter = CardLayerFilter.all,
  });

  final NotebookController controller;
  final bool interactive;
  final CardLayerFilter filter;

  @override
  Widget build(BuildContext context) {
    final cards = controller.activeElements.where((e) {
      if (e.deleted) return false;
      final isCardKind = e.kind == ElementKind.textCard ||
          e.kind == ElementKind.stickyNote ||
          e.kind == ElementKind.image ||
          e.kind == ElementKind.token;
      if (!isCardKind) return false;
      final isLockedPdf =
          e.kind == ElementKind.image &&
          e.locked &&
          (e.zIndex <= -50 || e.text.trim().isEmpty);
      switch (filter) {
        case CardLayerFilter.all:
          return true;
        case CardLayerFilter.lockedPdfOnly:
          return isLockedPdf;
        case CardLayerFilter.foregroundCards:
          return !isLockedPdf;
      }
    }).toList();

    final zoom = controller.zoom;
    final pan = controller.panOffset;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewW =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 1440.0;
        final viewH =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 900.0;
        const preloadMargin = 900.0;

        final visibleCards = cards.where((el) {
          if (el.id == controller.editingCardId ||
              el.id == controller.selectedElementId ||
              controller.selectedElementIds.contains(el.id)) {
            return true;
          }
          final left = pan.dx + el.x * zoom;
          final top = pan.dy + el.y * zoom;
          final right = left + el.width * zoom;
          final bottom = top + el.height * zoom;
          return right >= -preloadMargin &&
              left <= viewW + preloadMargin &&
              bottom >= -preloadMargin &&
              top <= viewH + preloadMargin;
        }).toList();

        final selectedCard = interactive
            ? visibleCards
                .where(
                  (e) => !e.locked && e.id == controller.selectedElementId,
                )
                .firstOrNull
            : null;

        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            IgnorePointer(
              ignoring: !interactive,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  for (final el in visibleCards)
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
            ),
            if (selectedCard != null)
              _SelectedCardChromeOverlay(
                element: selectedCard,
                controller: controller,
                zoom: zoom,
                pan: pan,
                viewportWidth: viewW,
                viewportHeight: viewH,
              ),
          ],
        );
      },
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
  late final FocusNode _focusNode;

  double _dragStartX = 0;
  double _dragStartY = 0;
  double _dragStartW = 0;
  double _dragStartH = 0;
  DateTime? _lastCardTapAt;
  bool _wasEditing = false;

  bool get _isSelected =>
      widget.controller.selectedElementId == widget.element.id;
  bool get _isEditing =>
      widget.controller.editingCardId == widget.element.id;

  KeyEventResult _handleCardFocusKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _commitTextIfChanged();
      widget.controller.setEditingCard(null);
      return KeyEventResult.handled;
    }
    if (widget.element.kind == ElementKind.token) {
      if (event.logicalKey == LogicalKeyboardKey.tab &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _commitTextIfChanged();
        widget.controller.spawnChildTokenFromSelected();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _commitTextIfChanged();
        widget.controller.setEditingCard(null);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.element.text);
    _focusNode = FocusNode(onKeyEvent: _handleCardFocusKey);
    _wasEditing = _isEditing;
  }

  @override
  void didUpdateWidget(covariant _CanvasElementCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final editingNow = _isEditing;
    if (editingNow && !_wasEditing) {
      _textController.text = widget.element.text;
    } else if (widget.element.text != oldWidget.element.text &&
        !_focusNode.hasFocus &&
        _textController.text != widget.element.text) {
      _textController.text = widget.element.text;
    }
    _wasEditing = editingNow;
    if (editingNow && !_focusNode.hasFocus) {
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
    final isToken = el.kind == ElementKind.token;
    final sem = el.semanticColor;
    final isLockedPdfSheet =
        isImage && el.locked && (el.zIndex <= -50 || el.text.trim().isEmpty);
    final bgColor = isToken
        ? Color(sem.fillArgb)
        : (el.fillColorValue != 0
            ? Color(el.fillColorValue)
            : (isSticky ? const Color(0xFFFEF08A) : Colors.white));

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
                    : (isToken
                        ? _buildTokenBody(el)
                        : _buildTextOrStickyBody(el, isSticky)),
              ),
            ),
          ),
          if (isLockedPdfSheet && el.text.trim().isNotEmpty)
            Positioned(
              bottom: 8,
              right: 10,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.84),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Text(
                    el.text,
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF64748B),
                    ),
                  ),
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
              borderRadius: BorderRadius.circular(
                isToken ? 12 : (isSticky ? 6 : 14),
              ),
              border: Border.all(
                color: _isSelected
                    ? const Color(0xFF4F46E5)
                    : (isToken
                        ? Color(sem.borderArgb)
                        : (isSticky
                            ? Colors.black.withValues(alpha: 0.08)
                            : const Color(0xFFE2E8F0))),
                width: _isSelected ? 2.2 : (isToken ? 1.8 : 1.2),
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: isSticky ? 0.12 : (isToken ? 0.07 : 0.06),
                  ),
                  blurRadius: isSticky ? 14 : (isToken ? 12 : 16),
                  offset: Offset(0, isSticky ? 6 : 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                isToken ? 11 : (isSticky ? 5 : 13),
              ),
              child: isImage
                  ? _buildImageCardBody(el)
                  : (isToken
                      ? _buildTokenBody(el)
                      : _buildTextOrStickyBody(el, isSticky)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTokenBody(CanvasElementModel el) {
    final sem = el.semanticColor;
    final textColor = Color(sem.textArgb);
    final accentColor = Color(sem.borderArgb);

    if (_isEditing) {
      return Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: accentColor, width: 4.5)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        alignment: Alignment.centerLeft,
        child: TextField(
          controller: _textController,
          focusNode: _focusNode,
          maxLines: 3,
          minLines: 1,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            height: 1.35,
            color: textColor,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            isCollapsed: true,
            hintText: '输入概念词块 (Tab 快速派生分支)',
          ),
          onChanged: (val) => widget.controller.updateElementText(el.id, val),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: accentColor, width: 4.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      alignment: Alignment.centerLeft,
      child: Text(
        el.text.trim().isEmpty ? '核心概念' : el.text.trim(),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          height: 1.32,
          color: textColor,
        ),
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

class _SelectedCardChromeOverlay extends StatefulWidget {
  const _SelectedCardChromeOverlay({
    required this.element,
    required this.controller,
    required this.zoom,
    required this.pan,
    required this.viewportWidth,
    required this.viewportHeight,
  });

  final CanvasElementModel element;
  final NotebookController controller;
  final double zoom;
  final Offset pan;
  final double viewportWidth;
  final double viewportHeight;

  @override
  State<_SelectedCardChromeOverlay> createState() =>
      _SelectedCardChromeOverlayState();
}

class _SelectedCardChromeOverlayState extends State<_SelectedCardChromeOverlay> {
  double _resizeOrigX = 0;
  double _resizeOrigY = 0;
  double _resizeOrigW = 0;
  double _resizeOrigH = 0;
  Offset _connectPortScenePos = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final el = widget.element;
    final c = widget.controller;
    final zoom = widget.zoom;
    final pan = widget.pan;
    final isToken = el.kind == ElementKind.token;
    final isSticky = el.kind == ElementKind.stickyNote;
    final isImage = el.kind == ElementKind.image;
    final isEditing = c.editingCardId == el.id;
    final sem = el.semanticColor;

    final cardLeft = pan.dx + el.x * zoom;
    final cardTop = pan.dy + el.y * zoom;
    final cardRight = pan.dx + (el.x + el.width) * zoom;
    final cardMidY = pan.dy + (el.y + el.height * 0.5) * zoom;
    final cardBottom = pan.dy + (el.y + el.height) * zoom;

    final toolbarMaxLeft = math.max(8.0, widget.viewportWidth - 310.0);
    final toolbarLeft = cardLeft.clamp(8.0, toolbarMaxLeft).toDouble();
    final toolbarTop = (cardTop - 42.0)
        .clamp(6.0, math.max(6.0, widget.viewportHeight - 46.0))
        .toDouble();

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Top mini toolbar (unscaled, always within viewport & hit-testable)
        Positioned(
          left: toolbarLeft,
          top: toolbarTop,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(999),
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (!isImage)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => c.setEditingCard(isEditing ? null : el.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              isEditing
                                  ? Icons.check_circle_outline
                                  : Icons.edit_outlined,
                              size: 15,
                              color: const Color(0xFF4F46E5),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isEditing ? '完成' : '编辑',
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
                  if (isToken) ...<Widget>[
                    Tooltip(
                      message: '派生分支词块 (Tab)',
                      child: InkWell(
                        key: ValueKey<String>('spawn-branch-${el.id}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => c.spawnChildTokenFromSelected(),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                Icons.account_tree_outlined,
                                size: 14,
                                color: Color(0xFF0F766E),
                              ),
                              SizedBox(width: 3),
                              Text(
                                '分支',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF0F766E),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    for (final sc in MindFlowColor.values)
                      Tooltip(
                        message: sc.label,
                        child: GestureDetector(
                          onTap: () => c.updateElementSemanticColor(el.id, sc),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            width: 15,
                            height: 15,
                            decoration: BoxDecoration(
                              color: Color(sc.fillArgb),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: el.semanticColor == sc
                                    ? const Color(0xFF0F172A)
                                    : Color(sc.borderArgb),
                                width: el.semanticColor == sc ? 2.0 : 1.3,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                  if (isSticky)
                    for (final col in NotebookController.stickyPalette)
                      GestureDetector(
                        onTap: () => c.updateElementColor(el.id, col, fill: true),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          width: 15,
                          height: 15,
                          decoration: BoxDecoration(
                            color: col,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: el.fillColorValue == col.toARGB32()
                                  ? const Color(0xFF0F172A)
                                  : Colors.black26,
                              width:
                                  el.fillColorValue == col.toARGB32() ? 1.8 : 1,
                            ),
                          ),
                        ),
                      ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: '锁定为底图（防橡皮擦与误拖动）',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => c.toggleElementLocked(el.id),
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
                    onTap: () => c.deleteElement(el.id),
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

        // Right-edge MindFlow connection port handle
        if (el.isConnectibleNode)
          Positioned(
            left: cardRight - 10,
            top: cardMidY - 10,
            width: 20,
            height: 20,
            child: Tooltip(
              message: '拖拽连接到另一个节点，或拖到空白处生成新概念词块',
              child: GestureDetector(
                key: ValueKey<String>('connect-port-${el.id}'),
                onPanStart: (_) {
                  _connectPortScenePos = Offset(
                    el.x + el.width,
                    el.y + el.height * 0.5,
                  );
                  c.startLocalConnector(
                    _connectPortScenePos,
                    explicitSourceId: el.id,
                  );
                },
                onPanUpdate: (details) {
                  _connectPortScenePos += details.delta / c.zoom;
                  c.updateLocalConnector(_connectPortScenePos);
                },
                onPanEnd: (_) {
                  c.finishLocalConnector(_connectPortScenePos);
                },
                onPanCancel: c.cancelLocalConnector,
                child: Container(
                  decoration: BoxDecoration(
                    color: Color(sem.borderArgb),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2.0),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(color: Colors.black26, blurRadius: 4),
                    ],
                  ),
                  child: const Icon(
                    Icons.arrow_forward_rounded,
                    size: 11,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),

        // Bottom-right corner resize handle
        Positioned(
          left: cardRight - 10,
          top: cardBottom - 10,
          width: 20,
          height: 20,
          child: GestureDetector(
            onPanStart: (_) {
              _resizeOrigX = el.x;
              _resizeOrigY = el.y;
              _resizeOrigW = el.width;
              _resizeOrigH = el.height;
            },
            onPanUpdate: (details) {
              final z = c.zoom;
              final current = c.doc.getElement(el.id) ?? el;
              c.previewElementFrame(
                el.id,
                width: current.width + details.delta.dx / z,
                height: current.height + details.delta.dy / z,
              );
            },
            onPanEnd: (_) {
              c.commitElementTransformUndo(
                elementId: el.id,
                oldX: _resizeOrigX,
                oldY: _resizeOrigY,
                oldWidth: _resizeOrigW,
                oldHeight: _resizeOrigH,
              );
            },
            child: Container(
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
    );
  }
}
