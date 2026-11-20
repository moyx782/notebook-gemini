import 'package:flutter/material.dart';

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

class CanvasToolbar extends StatelessWidget {
  const CanvasToolbar({
    super.key,
    required this.controller,
    required this.compact,
    required this.onInsertImage,
  });

  final NotebookController controller;
  final bool compact;
  final VoidCallback onInsertImage;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final activeWidth =
        c.tool == CanvasTool.highlighter ? c.highlighterWidth : c.strokeWidth;

    return Material(
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(compact ? 18 : 20),
      color: Colors.white.withValues(alpha: 0.96),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12,
          vertical: compact ? 6 : 8,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(compact ? 18 : 20),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
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
              const SizedBox(width: 8),

              // Color dots
              for (final color in NotebookController.inkPalette.take(
                compact ? 5 : 8,
              ))
                GestureDetector(
                  onTap: () => c.setActiveColor(color),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    width: compact ? 18 : 20,
                    height: compact ? 18 : 20,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c.activeColor.toARGB32() == color.toARGB32()
                            ? const Color(0xFF0F172A)
                            : Colors.white,
                        width: c.activeColor.toARGB32() == color.toARGB32()
                            ? 2.2
                            : 1.2,
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.14),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),

              // Stroke width menu
              PopupMenuButton<double>(
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
              ),

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
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEEF2FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
            icon,
            size: 19,
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
