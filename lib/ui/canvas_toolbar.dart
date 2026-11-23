import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/notebook_controller.dart';

Future<void> showInsertImageDialog(
  BuildContext context,
  NotebookController controller, {
  Offset? scenePos,
}) async {
  final urlCtrl = TextEditingController();
  final titleCtrl = TextEditingController(text: '插入图片');

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('插入图片 / 协作图示'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '方式一：本地文件或网页上传',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (controller.platform.canPickImage) ...<Widget>[
                FilledButton.icon(
                  onPressed: () async {
                    final dataUrl =
                        await controller.platform.pickImageAsDataUrl();
                    if (dataUrl != null && ctx.mounted) {
                      controller.createImageCard(
                        imageUri: dataUrl,
                        title: titleCtrl.text.trim().isEmpty
                            ? (controller.platform.isWeb ? '本地图片' : '相册图片')
                            : titleCtrl.text.trim(),
                        sceneCenter: scenePos,
                      );
                      Navigator.of(ctx).pop();
                    }
                  },
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: Text(
                    controller.platform.isWeb ? '从设备选择图片' : '从系统相册选择图片',
                  ),
                ),
                const SizedBox(height: 8),
              ] else
                const Text(
                  '可在下方直接粘贴图片 URL 或本机图片路径（如 /Users/.../demo.png）',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: '卡片标题',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: '图片 URL 或本地文件路径',
                  hintText: 'https://... 或 data:image/... 或 /path/to/img.png',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '方式二：离线一键插入内置结构模板',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ActionChip(
                    avatar: const Icon(Icons.hub_outlined, size: 16),
                    label: const Text('思维导图节点图'),
                    onPressed: () {
                      controller.createImageCard(
                        imageUri: 'preset://mindmap',
                        title: '思维导图节点',
                        sceneCenter: scenePos,
                      );
                      Navigator.of(ctx).pop();
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.devices_other_outlined, size: 16),
                    label: const Text('三端协同图'),
                    onPressed: () {
                      controller.createImageCard(
                        imageUri: 'preset://devices',
                        title: '三端协同架构',
                        sceneCenter: scenePos,
                      );
                      Navigator.of(ctx).pop();
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.grid_view_rounded, size: 16),
                    label: const Text('四象限看板'),
                    onPressed: () {
                      controller.createImageCard(
                        imageUri: 'preset://quadrant',
                        title: '四象限工作看板',
                        sceneCenter: scenePos,
                      );
                      Navigator.of(ctx).pop();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            final raw = urlCtrl.text.trim();
            if (raw.isEmpty) return;
            var uri = raw;
            if (!raw.startsWith('http://') &&
                !raw.startsWith('https://') &&
                !raw.startsWith('data:image/') &&
                !raw.startsWith('preset://')) {
              final loaded =
                  await controller.platform.loadImagePathAsDataUrl(raw);
              if (loaded != null) {
                uri = loaded;
              }
            }
            controller.createImageCard(
              imageUri: uri,
              title: titleCtrl.text.trim().isEmpty
                  ? '图片卡片'
                  : titleCtrl.text.trim(),
              sceneCenter: scenePos,
            );
            if (ctx.mounted) {
              Navigator.of(ctx).pop();
            }
          },
          child: const Text('插入画板'),
        ),
      ],
    ),
  );

  urlCtrl.dispose();
  titleCtrl.dispose();
}

Future<void> showImportPdfDialog(
  BuildContext context,
  NotebookController controller,
) async {
  var placement = PdfImportPlacement.newSinglePage;
  var maxPages = 30;
  var isImporting = false;
  String? errorMsg;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setStateDialog) {
        return AlertDialog(
          title: const Row(
            children: <Widget>[
              Icon(
                Icons.picture_as_pdf_rounded,
                color: Color(0xFFDC2626),
                size: 22,
              ),
              SizedBox(width: 8),
              Flexible(child: Text('导入 PDF 讲义 / 文档')),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '将多页 PDF 按阅读顺序从上到下连续渲染在同一个画板页上，并自动锁定为防误擦底图，支持上下滚动手写批注、荧光笔划重点与多端实时同步。',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: Color(0xFF475569),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '导入位置',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final option in PdfImportPlacement.values)
                        ChoiceChip(
                          label: Text(option.label),
                          selected: placement == option,
                          onSelected: isImporting
                              ? null
                              : (_) => setStateDialog(() => placement = option),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '单次最大导入页数',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final count in const <int>[15, 30, 60, 100])
                        ChoiceChip(
                          label: Text('前 $count 页'),
                          selected: maxPages == count,
                          onSelected: isImporting
                              ? null
                              : (_) => setStateDialog(() => maxPages = count),
                        ),
                    ],
                  ),
                  if (isImporting) ...<Widget>[
                    const SizedBox(height: 18),
                    const Row(
                      children: <Widget>[
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '正在解析并高清渲染 PDF 页面，请稍候...',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Color(0xFF4F46E5),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (errorMsg != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Text(
                        errorMsg!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFB91C1C),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: isImporting ? null : () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: isImporting
                  ? null
                  : () async {
                      setStateDialog(() {
                        isImporting = true;
                        errorMsg = null;
                      });
                      final doc = await controller.platform
                          .pickAndRenderPdf(maxPages: maxPages);
                      if (!ctx.mounted) return;
                      if (doc == null) {
                        setStateDialog(() => isImporting = false);
                        return;
                      }
                      if (doc.error != null && doc.error!.isNotEmpty) {
                        setStateDialog(() {
                          isImporting = false;
                          errorMsg = doc.error;
                        });
                        return;
                      }
                      if (doc.pages.isEmpty) {
                        setStateDialog(() {
                          isImporting = false;
                          errorMsg = '未能在该 PDF 中读取到可渲染的页面';
                        });
                        return;
                      }
                      final importedCount = await controller.importPdfDocument(
                        doc,
                        placement: placement,
                      );
                      if (!ctx.mounted) return;
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          behavior: SnackBarBehavior.floating,
                          margin: const EdgeInsets.fromLTRB(16, 0, 16, 82),
                          content: Text(
                            '已将《${doc.fileName}》共 $importedCount 页连续渲染至同一画板页（底图防误擦锁定，可上下滚动批注）',
                          ),
                        ),
                      );
                    },
              icon: const Icon(Icons.upload_file_rounded, size: 18),
              label: const Text('选择 PDF 并导入'),
            ),
          ],
        );
      },
    ),
  );
}

class LassoSelectionActionBar extends StatelessWidget {
  const LassoSelectionActionBar({
    super.key,
    required this.controller,
  });

  final NotebookController controller;

  @override
  Widget build(BuildContext context) {
    final count = controller.selectedElementIds.length;
    if (count == 0) return const SizedBox.shrink();

    return Material(
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(999),
      color: Colors.white.withValues(alpha: 0.97),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFC7D2FE)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.gesture_rounded,
                size: 16,
                color: Color(0xFF4F46E5),
              ),
              const SizedBox(width: 6),
              Text(
                '已选 $count 项',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF312E81),
                ),
              ),
              const SizedBox(width: 8),
              for (final color in NotebookController.inkPalette.take(5))
                GestureDetector(
                  onTap: () => controller.recolorSelectedElements(color),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.4),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              Container(width: 1, height: 18, color: const Color(0xFFE2E8F0)),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => controller.groupSelectionIntoCluster(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.workspaces_outline, size: 14, color: Color(0xFF4F46E5)),
                      SizedBox(width: 4),
                      Text(
                        '编组',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF312E81),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => controller.alignSelectedElements(horizontal: true),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.view_column_outlined, size: 14, color: Color(0xFF334155)),
                      SizedBox(width: 3),
                      Text(
                        '横排',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF334155),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => controller.alignSelectedElements(horizontal: false),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.view_agenda_outlined, size: 14, color: Color(0xFF334155)),
                      SizedBox(width: 3),
                      Text(
                        '竖排',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF334155),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () {
                  Clipboard.setData(
                    ClipboardData(
                      text: controller.buildActivePageAiSkillBundle(
                        scope: 'selected',
                      ),
                    ),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      duration: Duration(milliseconds: 1400),
                      behavior: SnackBarBehavior.floating,
                      margin: EdgeInsets.fromLTRB(16, 0, 16, 82),
                      content: Text('已复制选中区域的 MindFlow AI 上下文与技能规范'),
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.auto_awesome_outlined, size: 14, color: Color(0xFF0F766E)),
                      SizedBox(width: 3),
                      Text(
                        'AI 上下文',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0F766E),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => controller.duplicateSelectedElements(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.copy_rounded, size: 14, color: Color(0xFF334155)),
                      SizedBox(width: 4),
                      Text(
                        '复制',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF334155),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: controller.deleteSelectedElements,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.delete_outline_rounded,
                        size: 15,
                        color: Color(0xFFDC2626),
                      ),
                      SizedBox(width: 3),
                      Text(
                        '删除',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFDC2626),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: controller.clearSelection,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 15,
                    color: Color(0xFF64748B),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DraggableCanvasToolbar extends StatefulWidget {
  const DraggableCanvasToolbar({
    super.key,
    required this.controller,
    required this.stageSize,
    required this.compact,
    required this.onInsertImage,
    this.onImportPdf,
    this.onOpenMindFlowAi,
    this.onToggleVoiceMemo,
  });

  final NotebookController controller;
  final Size stageSize;
  final bool compact;
  final VoidCallback onInsertImage;
  final VoidCallback? onImportPdf;
  final VoidCallback? onOpenMindFlowAi;
  final VoidCallback? onToggleVoiceMemo;

  @override
  State<DraggableCanvasToolbar> createState() => _DraggableCanvasToolbarState();
}

class _DraggableCanvasToolbarState extends State<DraggableCanvasToolbar> {
  final GlobalKey _stageBoxKey = GlobalKey();
  final GlobalKey _barKey = GlobalKey();

  bool _dragging = false;
  double _dragFracX = 0.5;
  double _dragFracY = 0.92;
  ToolbarDock? _snapPreviewDock;

  Size get _safeStageSize {
    final s = widget.stageSize;
    return Size(
      s.width.isFinite && s.width > 0 ? s.width : 800.0,
      s.height.isFinite && s.height > 0 ? s.height : 600.0,
    );
  }

  void _onDragStart(DragStartDetails details) {
    final stageBox =
        _stageBoxKey.currentContext?.findRenderObject() as RenderBox?;
    final barBox = _barKey.currentContext?.findRenderObject() as RenderBox?;
    final stage = _safeStageSize;
    var nextX = widget.controller.toolbarFracX;
    var nextY = widget.controller.toolbarFracY;

    if (stageBox != null && barBox != null) {
      final barTopLeft = stageBox.globalToLocal(barBox.localToGlobal(Offset.zero));
      final usableW = math.max(1.0, stage.width - barBox.size.width - 20.0);
      final usableH = math.max(1.0, stage.height - barBox.size.height - 20.0);
      nextX = ((barTopLeft.dx - 10.0) / usableW).clamp(0.0, 1.0);
      nextY = ((barTopLeft.dy - 10.0) / usableH).clamp(0.0, 1.0);
    }

    setState(() {
      _dragging = true;
      _dragFracX = nextX;
      _dragFracY = nextY;
      _snapPreviewDock = widget.controller.toolbarDock;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    final stageBox =
        _stageBoxKey.currentContext?.findRenderObject() as RenderBox?;
    final barBox = _barKey.currentContext?.findRenderObject() as RenderBox?;
    final stage = _safeStageSize;
    final childSize = barBox?.size ??
        (widget.controller.toolbarCollapsed
            ? const Size(48, 48)
            : (widget.controller.toolbarIsVertical
                ? const Size(72, 420)
                : const Size(360, 56)));

    final usableW = math.max(1.0, stage.width - childSize.width - 20.0);
    final usableH = math.max(1.0, stage.height - childSize.height - 20.0);
    final nextX = (_dragFracX + details.delta.dx / usableW).clamp(0.0, 1.0);
    final nextY = (_dragFracY + details.delta.dy / usableH).clamp(0.0, 1.0);

    var nextDock = ToolbarDock.floating;
    if (stageBox != null) {
      final localPt = stageBox.globalToLocal(details.globalPosition);
      if (localPt.dx <= 68.0) {
        nextDock = ToolbarDock.left;
      } else if (localPt.dx >= stage.width - 68.0) {
        nextDock = ToolbarDock.right;
      } else if (localPt.dy <= 64.0) {
        nextDock = ToolbarDock.top;
      } else if (localPt.dy >= stage.height - 68.0) {
        nextDock = ToolbarDock.bottom;
      }
    }

    setState(() {
      _dragFracX = nextX;
      _dragFracY = nextY;
      _snapPreviewDock = nextDock;
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    final targetDock = _snapPreviewDock ?? ToolbarDock.floating;
    final fx = _dragFracX;
    final fy = _dragFracY;
    setState(() {
      _dragging = false;
      _snapPreviewDock = null;
    });
    widget.controller.updateToolbarPlacement(
      dock: targetDock,
      fracX: fx,
      fracY: fy,
    );
  }

  void _onDragCancel() {
    if (!_dragging) return;
    setState(() {
      _dragging = false;
      _snapPreviewDock = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final stage = _safeStageSize;
    final effectiveDock =
        _dragging ? ToolbarDock.floating : c.toolbarDock;
    final showDockPreview = _dragging &&
        _snapPreviewDock != null &&
        _snapPreviewDock != ToolbarDock.floating;

    final fx = _dragging ? _dragFracX : c.toolbarFracX;
    final fy = _dragging ? _dragFracY : c.toolbarFracY;

    double ax;
    double ay;
    EdgeInsets padding;

    switch (effectiveDock) {
      case ToolbarDock.bottom:
        ax = (fx * 2.0 - 1.0).clamp(-1.0, 1.0);
        ay = 1.0;
        padding = EdgeInsets.fromLTRB(
          10,
          10,
          10,
          widget.compact ? 10 : 16,
        );
        break;
      case ToolbarDock.top:
        ax = (fx * 2.0 - 1.0).clamp(-1.0, 1.0);
        ay = -1.0;
        padding = const EdgeInsets.fromLTRB(10, 12, 10, 10);
        break;
      case ToolbarDock.left:
        ax = -1.0;
        ay = (fy * 2.0 - 1.0).clamp(-1.0, 1.0);
        padding = const EdgeInsets.fromLTRB(12, 12, 10, 12);
        break;
      case ToolbarDock.right:
        ax = 1.0;
        ay = (fy * 2.0 - 1.0).clamp(-1.0, 1.0);
        padding = EdgeInsets.fromLTRB(
          10,
          12,
          12,
          widget.compact ? 12 : 58,
        );
        break;
      case ToolbarDock.floating:
        ax = (fx * 2.0 - 1.0).clamp(-1.0, 1.0);
        ay = (fy * 2.0 - 1.0).clamp(-1.0, 1.0);
        padding = const EdgeInsets.all(10);
        break;
    }

    final isVertical = !c.toolbarCollapsed &&
        (c.toolbarIsVertical ||
            (_dragging &&
                (_snapPreviewDock == ToolbarDock.left ||
                    _snapPreviewDock == ToolbarDock.right)));

    final maxExtent = isVertical
        ? math.max(180.0, stage.height - padding.vertical)
        : math.max(200.0, stage.width - padding.horizontal);

    return Stack(
      key: _stageBoxKey,
      fit: StackFit.expand,
      children: <Widget>[
        if (showDockPreview) _DockSnapPreviewOverlay(dock: _snapPreviewDock!),
        Align(
          alignment: Alignment(ax, ay),
          child: Padding(
            padding: padding,
            child: KeyedSubtree(
              key: _barKey,
              child: c.toolbarCollapsed
                  ? _CollapsedToolbarBall(
                      controller: c,
                      onExpand: () => c.setToolbarCollapsed(false),
                      onDragStart: _onDragStart,
                      onDragUpdate: _onDragUpdate,
                      onDragEnd: _onDragEnd,
                      onDragCancel: _onDragCancel,
                    )
                  : CanvasToolbar(
                      controller: c,
                      compact: widget.compact,
                      direction: isVertical ? Axis.vertical : Axis.horizontal,
                      maxMainAxisExtent: maxExtent,
                      onInsertImage: widget.onInsertImage,
                      onImportPdf: widget.onImportPdf,
                      onOpenMindFlowAi: widget.onOpenMindFlowAi,
                      onToggleVoiceMemo: widget.onToggleVoiceMemo,
                      onDragStart: _onDragStart,
                      onDragUpdate: _onDragUpdate,
                      onDragEnd: _onDragEnd,
                      onDragCancel: _onDragCancel,
                      onToggleOrientation: c.toggleToolbarOrientation,
                      onCollapse: () => c.setToolbarCollapsed(true),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DockSnapPreviewOverlay extends StatelessWidget {
  const _DockSnapPreviewOverlay({required this.dock});

  final ToolbarDock dock;

  @override
  Widget build(BuildContext context) {
    final isVert = dock == ToolbarDock.left || dock == ToolbarDock.right;
    Alignment align;
    switch (dock) {
      case ToolbarDock.left:
        align = Alignment.centerLeft;
        break;
      case ToolbarDock.right:
        align = Alignment.centerRight;
        break;
      case ToolbarDock.top:
        align = Alignment.topCenter;
        break;
      case ToolbarDock.bottom:
      case ToolbarDock.floating:
        align = Alignment.bottomCenter;
        break;
    }
    return IgnorePointer(
      child: Align(
        alignment: align,
        child: Container(
          margin: const EdgeInsets.all(10),
          width: isVert ? 58 : 340,
          height: isVert ? 300 : 46,
          decoration: BoxDecoration(
            color: const Color(0xFF4F46E5).withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: const Color(0xFF4F46E5).withValues(alpha: 0.55),
              width: 1.6,
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsedToolbarBall extends StatelessWidget {
  const _CollapsedToolbarBall({
    required this.controller,
    required this.onExpand,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final NotebookController controller;
  final VoidCallback onExpand;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final GestureDragCancelCallback onDragCancel;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '展开画笔工具栏',
      child: GestureDetector(
        key: const ValueKey<String>('collapsed-toolbar-ball'),
        onTap: onExpand,
        onPanStart: onDragStart,
        onPanUpdate: onDragUpdate,
        onPanEnd: onDragEnd,
        onPanCancel: onDragCancel,
        child: Material(
          elevation: 8,
          shape: const CircleBorder(),
          color: Colors.white,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFC7D2FE), width: 1.6),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Icon(
                  Icons.edit_rounded,
                  size: 22,
                  color: controller.activeColor,
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4F46E5),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarDragHandle extends StatelessWidget {
  const _ToolbarDragHandle({
    required this.vertical,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
    this.onDoubleTap,
  });

  final bool vertical;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final GestureDragCancelCallback? onDragCancel;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '按住拖动工具栏（贴靠左右自动变竖排 · 双击切换横竖）',
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          key: const ValueKey<String>('toolbar-drag-handle'),
          behavior: HitTestBehavior.opaque,
          onPanStart: onDragStart,
          onPanUpdate: onDragUpdate,
          onPanEnd: onDragEnd,
          onPanCancel: onDragCancel,
          onDoubleTap: onDoubleTap,
          child: Padding(
            padding: vertical
                ? const EdgeInsets.symmetric(horizontal: 2, vertical: 2)
                : const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Transform.rotate(
              angle: vertical ? math.pi * 0.5 : 0.0,
              child: const Icon(
                Icons.drag_indicator_rounded,
                size: 16,
                color: Color(0xFF94A3B8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CanvasToolbar extends StatelessWidget {
  const CanvasToolbar({
    super.key,
    required this.controller,
    required this.compact,
    required this.onInsertImage,
    this.onImportPdf,
    this.onOpenMindFlowAi,
    this.onToggleVoiceMemo,
    this.direction = Axis.horizontal,
    this.maxMainAxisExtent,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
    this.onToggleOrientation,
    this.onCollapse,
  });

  final NotebookController controller;
  final bool compact;
  final VoidCallback onInsertImage;
  final VoidCallback? onImportPdf;
  final VoidCallback? onOpenMindFlowAi;
  final VoidCallback? onToggleVoiceMemo;
  final Axis direction;
  final double? maxMainAxisExtent;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final GestureDragCancelCallback? onDragCancel;
  final VoidCallback? onToggleOrientation;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final activeWidth =
        c.tool == CanvasTool.highlighter ? c.highlighterWidth : c.strokeWidth;

    if (direction == Axis.vertical) {
      return _buildVertical(context, c, activeWidth);
    }
    return _buildHorizontal(context, c, activeWidth);
  }

  Widget _buildVertical(
    BuildContext context,
    NotebookController c,
    double activeWidth,
  ) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxMainAxisExtent ?? 680),
      child: Material(
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(compact ? 18 : 20),
        color: Colors.white.withValues(alpha: 0.96),
        child: Container(
          width: compact ? 68 : 72,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(compact ? 18 : 20),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 1. Pinned Top Drag Handle & Orientation / Collapse controls
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _ToolbarDragHandle(
                      vertical: true,
                      onDragStart: onDragStart,
                      onDragUpdate: onDragUpdate,
                      onDragEnd: onDragEnd,
                      onDragCancel: onDragCancel,
                      onDoubleTap: onToggleOrientation,
                    ),
                    if (onToggleOrientation != null)
                      _MiniHeaderIconBtn(
                        icon: Icons.screen_rotation_alt_rounded,
                        tooltip: '切换横排 / 竖排工具栏',
                        onTap: onToggleOrientation!,
                      ),
                    if (onCollapse != null)
                      _MiniHeaderIconBtn(
                        icon: Icons.unfold_less_rounded,
                        tooltip: '收起为悬浮笔球',
                        onTap: onCollapse!,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 2),

              // 2. Pinned Top Undo & Redo Row (always above drawing tools!)
              Row(
                key: const ValueKey<String>('vertical-top-undo-redo'),
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _ToolBtn(
                    icon: Icons.undo_rounded,
                    tooltip: '撤销 (Ctrl/Cmd+Z)',
                    selected: false,
                    enabled: c.canUndo,
                    compactPadding: true,
                    onTap: c.canUndo ? c.undo : null,
                  ),
                  _ToolBtn(
                    icon: Icons.redo_rounded,
                    tooltip: '重做 (Ctrl/Cmd+Shift+Z)',
                    selected: false,
                    enabled: c.canRedo,
                    compactPadding: true,
                    onTap: c.canRedo ? c.redo : null,
                  ),
                ],
              ),
              Container(
                width: 46,
                height: 1,
                margin: const EdgeInsets.symmetric(vertical: 5),
                color: const Color(0xFFE2E8F0),
              ),

              // 3. Scrollable Vertical Tools, Colors & Widths
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _ToolBtn(
                        icon: Icons.near_me_outlined,
                        tooltip: '选择 / 移动 (V)',
                        selected: c.tool == CanvasTool.select,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.select),
                      ),
                      _ToolBtn(
                        icon: Icons.gesture_rounded,
                        tooltip: '套索框选 (G)',
                        selected: c.tool == CanvasTool.lasso,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.lasso),
                      ),
                      _ToolBtn(
                        icon: Icons.edit_outlined,
                        tooltip: '压感钢笔 (P)',
                        selected: c.tool == CanvasTool.pen,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.pen),
                      ),
                      _ToolBtn(
                        icon: Icons.brush_outlined,
                        tooltip: '荧光笔 (H)',
                        selected: c.tool == CanvasTool.highlighter,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.highlighter),
                      ),
                      _ToolBtn(
                        icon: Icons.cleaning_services_outlined,
                        tooltip: '橡皮擦 (E)',
                        selected: c.tool == CanvasTool.eraser,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.eraser),
                      ),
                      _ShapeMenuBtn(controller: c),
                      _ToolBtn(
                        icon: Icons.hub_outlined,
                        tooltip: '概念词块 (N)',
                        selected: c.tool == CanvasTool.token,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.token),
                      ),
                      _ToolBtn(
                        icon: Icons.timeline_rounded,
                        tooltip: '因果连线 (C)',
                        selected: c.tool == CanvasTool.connector,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.connector),
                      ),
                      _ToolBtn(
                        icon: Icons.dashboard_customize_outlined,
                        tooltip: '区域分组 (B)',
                        selected: c.tool == CanvasTool.cluster,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.cluster),
                      ),
                      _ToolBtn(
                        icon: Icons.article_outlined,
                        tooltip: '插入 Markdown 卡片 (T)',
                        selected: c.tool == CanvasTool.textCard,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.textCard),
                      ),
                      _ToolBtn(
                        icon: Icons.sticky_note_2_outlined,
                        tooltip: '插入便签 (S)',
                        selected: c.tool == CanvasTool.stickyNote,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.stickyNote),
                      ),
                      _ToolBtn(
                        icon: Icons.image_outlined,
                        tooltip: '插入图片 / 图示',
                        selected: c.tool == CanvasTool.image,
                        compactPadding: compact,
                        onTap: onInsertImage,
                      ),
                      if (c.platform.canImportPdf && onImportPdf != null)
                        _ToolBtn(
                          icon: Icons.picture_as_pdf_outlined,
                          tooltip: '导入 PDF 讲义',
                          selected: false,
                          compactPadding: compact,
                          onTap: onImportPdf,
                        ),
                      if (onOpenMindFlowAi != null)
                        _ToolBtn(
                          icon: Icons.auto_awesome_outlined,
                          tooltip: 'MindFlow AI 协同与 MCP',
                          selected: false,
                          compactPadding: compact,
                          onTap: onOpenMindFlowAi,
                        ),
                      if (onToggleVoiceMemo != null)
                        _ToolBtn(
                          icon: c.voiceMemoPhase == VoiceMemoPhase.recording
                              ? Icons.graphic_eq_rounded
                              : Icons.mic_none_rounded,
                          tooltip: '语音备忘实时转写 (U)',
                          selected: c.voiceMemoOpen,
                          compactPadding: compact,
                          onTap: onToggleVoiceMemo,
                        ),
                      _ToolBtn(
                        icon: Icons.flare_rounded,
                        tooltip: '协作激光笔 (L)',
                        selected: c.tool == CanvasTool.laser,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.laser),
                      ),
                      _ToolBtn(
                        icon: Icons.pan_tool_outlined,
                        tooltip: '抓手平移 (Space)',
                        selected: c.tool == CanvasTool.hand,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.hand),
                      ),

                      if (!compact) ...<Widget>[
                        Container(
                          width: 42,
                          height: 1,
                          margin: const EdgeInsets.symmetric(vertical: 5),
                          color: const Color(0xFFE2E8F0),
                        ),
                        for (var idx = 0; idx < c.penPresets.length; idx++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: _PenPresetSlotBtn(
                              preset: c.penPresets[idx],
                              selected: c.activePenPresetIndex == idx,
                              onTap: () => c.applyPenPreset(idx),
                              onLongPress: () => _savePresetWithToast(context, c, idx),
                            ),
                          ),
                      ],

                      Container(
                        width: 42,
                        height: 1,
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        color: const Color(0xFFE2E8F0),
                      ),

                      SizedBox(
                        width: 48,
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 5,
                          runSpacing: 5,
                          children: <Widget>[
                            for (final color in NotebookController.inkPalette.take(
                              compact ? 6 : 8,
                            ))
                              _ColorDot(
                                color: color,
                                selected: c.activeColor.toARGB32() == color.toARGB32(),
                                size: compact ? 17 : 18,
                                onTap: () => c.setActiveColor(color),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildStrokeWidthButton(c, activeWidth),

                      if (!compact) ...<Widget>[
                        const SizedBox(height: 2),
                        _ToolBtn(
                          icon: Icons.edit_note_rounded,
                          tooltip: '防误触笔模式：单指滑动只平移画布，Apple Pencil / 触控笔专职书写',
                          selected: c.stylusOnlyMode,
                          compactPadding: true,
                          onTap: () => c.setStylusOnlyMode(!c.stylusOnlyMode),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontal(
    BuildContext context,
    NotebookController c,
    double activeWidth,
  ) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxMainAxisExtent ?? 1200),
      child: Material(
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(compact ? 18 : 20),
        color: Colors.white.withValues(alpha: 0.96),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 6 : 10,
            vertical: compact ? 6 : 8,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(compact ? 18 : 20),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _ToolbarDragHandle(
                vertical: false,
                onDragStart: onDragStart,
                onDragUpdate: onDragUpdate,
                onDragEnd: onDragEnd,
                onDragCancel: onDragCancel,
                onDoubleTap: onToggleOrientation,
              ),
              Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.only(right: 4),
                color: const Color(0xFFE2E8F0),
              ),
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _ToolBtn(
                        icon: Icons.near_me_outlined,
                        tooltip: '选择 / 移动 (V)',
                        selected: c.tool == CanvasTool.select,
                        onTap: () => c.setTool(CanvasTool.select),
                      ),
                      _ToolBtn(
                        icon: Icons.gesture_rounded,
                        tooltip: '套索框选 (G)',
                        selected: c.tool == CanvasTool.lasso,
                        onTap: () => c.setTool(CanvasTool.lasso),
                      ),
                      _ToolBtn(
                        icon: Icons.edit_outlined,
                        tooltip: '压感钢笔 (P)',
                        selected: c.tool == CanvasTool.pen,
                        onTap: () => c.setTool(CanvasTool.pen),
                      ),
                      _ToolBtn(
                        icon: Icons.brush_outlined,
                        tooltip: '荧光笔 (H)',
                        selected: c.tool == CanvasTool.highlighter,
                        onTap: () => c.setTool(CanvasTool.highlighter),
                      ),
                      _ToolBtn(
                        icon: Icons.cleaning_services_outlined,
                        tooltip: '橡皮擦 (E)',
                        selected: c.tool == CanvasTool.eraser,
                        onTap: () => c.setTool(CanvasTool.eraser),
                      ),
                      _ShapeMenuBtn(controller: c),
                      _ToolBtn(
                        icon: Icons.hub_outlined,
                        tooltip: '概念词块 (N)',
                        selected: c.tool == CanvasTool.token,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.token),
                      ),
                      _ToolBtn(
                        icon: Icons.timeline_rounded,
                        tooltip: '因果连线 (C)',
                        selected: c.tool == CanvasTool.connector,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.connector),
                      ),
                      _ToolBtn(
                        icon: Icons.dashboard_customize_outlined,
                        tooltip: '区域分组 (B)',
                        selected: c.tool == CanvasTool.cluster,
                        compactPadding: compact,
                        onTap: () => c.setTool(CanvasTool.cluster),
                      ),
                      _ToolBtn(
                        icon: Icons.article_outlined,
                        tooltip: '插入 Markdown 卡片 (T)',
                        selected: c.tool == CanvasTool.textCard,
                        onTap: () => c.setTool(CanvasTool.textCard),
                      ),
                      _ToolBtn(
                        icon: Icons.sticky_note_2_outlined,
                        tooltip: '插入便签 (S)',
                        selected: c.tool == CanvasTool.stickyNote,
                        onTap: () => c.setTool(CanvasTool.stickyNote),
                      ),
                      _ToolBtn(
                        icon: Icons.image_outlined,
                        tooltip: '插入图片 / 图示',
                        selected: c.tool == CanvasTool.image,
                        onTap: onInsertImage,
                      ),
                      if (c.platform.canImportPdf && onImportPdf != null)
                        _ToolBtn(
                          icon: Icons.picture_as_pdf_outlined,
                          tooltip: '导入 PDF 讲义',
                          selected: false,
                          onTap: onImportPdf,
                        ),
                      if (onOpenMindFlowAi != null)
                        _ToolBtn(
                          icon: Icons.auto_awesome_outlined,
                          tooltip: 'MindFlow AI 协同与 MCP',
                          selected: false,
                          onTap: onOpenMindFlowAi,
                        ),
                      if (onToggleVoiceMemo != null)
                        _ToolBtn(
                          icon: c.voiceMemoPhase == VoiceMemoPhase.recording
                              ? Icons.graphic_eq_rounded
                              : Icons.mic_none_rounded,
                          tooltip: '语音备忘实时转写 (U)',
                          selected: c.voiceMemoOpen,
                          onTap: onToggleVoiceMemo,
                        ),
                      _ToolBtn(
                        icon: Icons.flare_rounded,
                        tooltip: '协作激光笔 (L)',
                        selected: c.tool == CanvasTool.laser,
                        onTap: () => c.setTool(CanvasTool.laser),
                      ),
                      _ToolBtn(
                        icon: Icons.pan_tool_outlined,
                        tooltip: '抓手平移 (Space)',
                        selected: c.tool == CanvasTool.hand,
                        onTap: () => c.setTool(CanvasTool.hand),
                      ),

                      const SizedBox(width: 6),
                      Container(width: 1, height: 24, color: const Color(0xFFE2E8F0)),
                      const SizedBox(width: 6),

                      // 3 one-tap favorite pen/highlighter presets
                      if (!compact) ...<Widget>[
                        for (var idx = 0; idx < c.penPresets.length; idx++)
                          _PenPresetSlotBtn(
                            preset: c.penPresets[idx],
                            selected: c.activePenPresetIndex == idx,
                            onTap: () => c.applyPenPreset(idx),
                            onLongPress: () => _savePresetWithToast(context, c, idx),
                          ),
                        const SizedBox(width: 4),
                        Container(width: 1, height: 24, color: const Color(0xFFE2E8F0)),
                        const SizedBox(width: 6),
                      ],

                      // Color dots
                      for (final color in NotebookController.inkPalette.take(
                        compact ? 5 : 8,
                      ))
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2.5),
                          child: _ColorDot(
                            color: color,
                            selected: c.activeColor.toARGB32() == color.toARGB32(),
                            size: compact ? 18 : 20,
                            onTap: () => c.setActiveColor(color),
                          ),
                        ),

                      // Stroke width menu
                      _buildStrokeWidthButton(c, activeWidth),

                      Container(width: 1, height: 24, color: const Color(0xFFE2E8F0)),
                      const SizedBox(width: 4),

                      _ToolBtn(
                        icon: Icons.undo_rounded,
                        tooltip: '撤销 (Ctrl/Cmd+Z)',
                        selected: false,
                        enabled: c.canUndo,
                        onTap: c.canUndo ? c.undo : null,
                      ),
                      _ToolBtn(
                        icon: Icons.redo_rounded,
                        tooltip: '重做 (Ctrl/Cmd+Shift+Z)',
                        selected: false,
                        enabled: c.canRedo,
                        onTap: c.canRedo ? c.redo : null,
                      ),

                      if (!compact) ...<Widget>[
                        const SizedBox(width: 2),
                        Tooltip(
                          message: '防误触笔模式：单指滑动只平移画布，Apple Pencil / 触控笔专职书写',
                          child: FilterChip(
                            label: const Text('笔防误触', style: TextStyle(fontSize: 11.5)),
                            avatar: const Icon(Icons.edit_note_rounded, size: 16),
                            selected: c.stylusOnlyMode,
                            visualDensity: VisualDensity.compact,
                            onSelected: c.setStylusOnlyMode,
                          ),
                        ),
                      ],

                      if (onToggleOrientation != null || onCollapse != null) ...<Widget>[
                        const SizedBox(width: 4),
                        Container(width: 1, height: 22, color: const Color(0xFFE2E8F0)),
                        const SizedBox(width: 2),
                      ],
                      if (onToggleOrientation != null)
                        _ToolBtn(
                          icon: Icons.screen_rotation_alt_rounded,
                          tooltip: '切换横排 / 竖排工具栏',
                          selected: false,
                          compactPadding: true,
                          onTap: onToggleOrientation,
                        ),
                      if (onCollapse != null)
                        _ToolBtn(
                          icon: Icons.unfold_less_rounded,
                          tooltip: '收起为悬浮笔球',
                          selected: false,
                          compactPadding: true,
                          onTap: onCollapse,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _savePresetWithToast(
    BuildContext context,
    NotebookController c,
    int idx,
  ) {
    c.saveCurrentToPenPreset(idx);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 82),
        content: Text('已将当前笔触保存到预设槽 ${idx + 1}'),
      ),
    );
  }

  Widget _buildStrokeWidthButton(NotebookController c, double activeWidth) {
    return PopupMenuButton<double>(
      tooltip: '调整笔触粗细',
      onSelected: c.setStrokeWidth,
      itemBuilder: (_) {
        final widths = c.tool == CanvasTool.highlighter
            ? <double>[12, 18, 26, 36]
            : <double>[2.0, 3.5, 6.0, 10.0];
        return widths
            .map(
              (w) => PopupMenuItem<double>(
                value: w,
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 28,
                      height: (w * 0.65).clamp(2.0, 14.0),
                      decoration: BoxDecoration(
                        color: c.activeColor,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('${w.toStringAsFixed(1)} px'),
                  ],
                ),
              ),
            )
            .toList();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 14,
              height: (activeWidth * 0.45).clamp(2.0, 10.0),
              decoration: BoxDecoration(
                color: c.activeColor,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${activeWidth.round()}',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF334155),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.size,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? const Color(0xFF0F172A) : Colors.white,
            width: selected ? 2.2 : 1.2,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 2,
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniHeaderIconBtn extends StatelessWidget {
  const _MiniHeaderIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: 14, color: const Color(0xFF64748B)),
        ),
      ),
    );
  }
}

class _PenPresetSlotBtn extends StatelessWidget {
  const _PenPresetSlotBtn({
    required this.preset,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final PenPreset preset;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final color = Color(preset.colorValue);
    return Tooltip(
      message: '${preset.label}（点击切换 · 长按保存当前笔触）',
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.14)
                : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? color : const Color(0xFFE2E8F0),
              width: selected ? 1.6 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                preset.isHighlighter
                    ? Icons.brush_rounded
                    : Icons.mode_edit_outline_rounded,
                size: 14,
                color: color,
              ),
              const SizedBox(width: 3),
              Container(
                width: 8,
                height: (preset.width * 0.35).clamp(2.5, 8.0),
                decoration: BoxDecoration(
                  color: preset.isHighlighter
                      ? color.withValues(alpha: 0.65)
                      : color,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShapeMenuBtn extends StatelessWidget {
  const _ShapeMenuBtn({required this.controller});

  final NotebookController controller;

  IconData _iconForTool(CanvasTool tool) {
    switch (tool) {
      case CanvasTool.ellipse:
        return Icons.circle_outlined;
      case CanvasTool.diamond:
        return Icons.diamond_outlined;
      case CanvasTool.line:
        return Icons.horizontal_rule_rounded;
      case CanvasTool.arrow:
        return Icons.arrow_forward_rounded;
      default:
        return Icons.crop_square_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isShape = controller.tool.isShapeTool;
    return PopupMenuButton<CanvasTool>(
      tooltip: '图形与箭头 (R / O / A)',
      onSelected: controller.setTool,
      itemBuilder: (_) => const <PopupMenuEntry<CanvasTool>>[
        PopupMenuItem(
          value: CanvasTool.rectangle,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.crop_square_rounded),
            title: Text('矩形 (R)'),
          ),
        ),
        PopupMenuItem(
          value: CanvasTool.ellipse,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.circle_outlined),
            title: Text('圆形 (O)'),
          ),
        ),
        PopupMenuItem(
          value: CanvasTool.diamond,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.diamond_outlined),
            title: Text('菱形 (D)'),
          ),
        ),
        PopupMenuItem(
          value: CanvasTool.line,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.horizontal_rule_rounded),
            title: Text('直线'),
          ),
        ),
        PopupMenuItem(
          value: CanvasTool.arrow,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.arrow_forward_rounded),
            title: Text('箭头连线 (A)'),
          ),
        ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
        decoration: BoxDecoration(
          color: isShape ? const Color(0xFFEEF2FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              _iconForTool(controller.tool),
              size: 19,
              color: isShape
                  ? const Color(0xFF4F46E5)
                  : const Color(0xFF475569),
            ),
            const Icon(Icons.arrow_drop_down, size: 14, color: Color(0xFF64748B)),
          ],
        ),
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  const _ToolBtn({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.compactPadding = false,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final bool enabled;
  final bool compactPadding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(compactPadding ? 9 : 11),
        child: Container(
          margin: EdgeInsets.all(compactPadding ? 1 : 2),
          padding: EdgeInsets.all(compactPadding ? 4 : 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEEF2FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(compactPadding ? 9 : 11),
          ),
          child: Icon(
            icon,
            size: compactPadding ? 17 : 19,
            color: !enabled
                ? const Color(0xFFCBD5E1)
                : (selected
                    ? const Color(0xFF4F46E5)
                    : const Color(0xFF475569)),
          ),
        ),
      ),
    );
  }
}
