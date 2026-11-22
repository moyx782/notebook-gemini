import 'package:flutter/material.dart';
import 'package:notebook_core/notebook_core.dart';

import '../state/notebook_controller.dart';
import 'canvas_toolbar.dart';

class NotebookSidebar extends StatefulWidget {
  const NotebookSidebar({
    super.key,
    required this.controller,
    this.onCloseDrawer,
  });

  final NotebookController controller;
  final VoidCallback? onCloseDrawer;

  @override
  State<NotebookSidebar> createState() => _NotebookSidebarState();
}

class _NotebookSidebarState extends State<NotebookSidebar> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _showCreateNotebookDialog() async {
    final nameController = TextEditingController();
    var selectedColor = NotebookController.inkPalette[1];
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            return AlertDialog(
              title: const Text('新建共享笔记本'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '笔记本名称',
                      hintText: '例如：产品白板 / 数学草稿 / 会议纪要',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => Navigator.of(ctx).pop(true),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '封面主题色',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      for (final color in NotebookController.inkPalette)
                        GestureDetector(
                          onTap: () =>
                              setStateDialog(() => selectedColor = color),
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selectedColor == color
                                    ? const Color(0xFF0F172A)
                                    : Colors.transparent,
                                width: 2.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('创建'),
                ),
              ],
            );
          },
        );
      },
    );

    if (created == true) {
      widget.controller.createNotebook(
        nameController.text,
        color: selectedColor,
      );
      widget.onCloseDrawer?.call();
    }
    nameController.dispose();
  }

  Future<void> _showRenameDialog({
    required String title,
    required String initialValue,
    required ValueChanged<String> onConfirm,
  }) async {
    final ctrl = TextEditingController(text: initialValue);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (_) => Navigator.of(ctx).pop(true),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      onConfirm(ctrl.text.trim());
    }
    ctrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final query = c.searchQuery.trim().toLowerCase();
    final notebooks = c.notebooks;
    final activePage = c.activePage;
    final contentHits =
        query.isEmpty ? const <SearchHit>[] : c.searchWorkspaceContent(query);

    return Container(
      color: const Color(0xFFF8FAFC),
      child: Column(
        children: <Widget>[
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
            child: Row(
              children: <Widget>[
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: <Color>[Color(0xFF4F46E5), Color(0xFF0D9488)],
                    ),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(
                    Icons.draw_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'SyncCanvas',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      Text(
                        '三端共用共享画板',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '新建笔记本',
                  onPressed: _showCreateNotebookDialog,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                ),
              ],
            ),
          ),

          // Search box
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _searchController,
              onChanged: c.setSearchQuery,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: '搜索笔记本、页名或卡片全文...',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          c.setSearchQuery('');
                        },
                      ),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Quick note actions & star filter
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  FilterChip(
                    avatar: Icon(
                      c.bookmarkFilterOnly
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      size: 15,
                      color: c.bookmarkFilterOnly
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFF64748B),
                    ),
                    label: const Text('仅看星标', style: TextStyle(fontSize: 11.5)),
                    visualDensity: VisualDensity.compact,
                    selected: c.bookmarkFilterOnly,
                    onSelected: c.setBookmarkFilterOnly,
                  ),
                  if (c.platform.canImportPdf) ...<Widget>[
                    const SizedBox(width: 6),
                    ActionChip(
                      avatar: const Icon(
                        Icons.picture_as_pdf_outlined,
                        size: 15,
                        color: Color(0xFFDC2626),
                      ),
                      label:
                          const Text('导入 PDF', style: TextStyle(fontSize: 11.5)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => showImportPdfDialog(context, c),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),

          // Full-text card/sticky search hits
          if (contentHits.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 150),
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFC7D2FE)),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: contentHits.length,
                itemBuilder: (ctx, idx) {
                  final hit = contentHits[idx];
                  return InkWell(
                    onTap: () {
                      c.focusOnElement(hit.pageId, hit.elementId);
                      widget.onCloseDrawer?.call();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '${hit.notebookTitle} · ${hit.pageTitle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF4F46E5),
                            ),
                          ),
                          Text(
                            hit.snippet,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

          // Notebook + Pages tree
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: notebooks.length,
              itemBuilder: (context, index) {
                final nb = notebooks[index];
                final pages = c.doc.pagesForNotebook(nb.id);
                final nbMatches =
                    query.isEmpty || nb.title.toLowerCase().contains(query);
                var filteredPages = nbMatches
                    ? pages
                    : pages
                        .where((p) => p.title.toLowerCase().contains(query))
                        .toList();
                if (c.bookmarkFilterOnly) {
                  filteredPages =
                      filteredPages.where((p) => p.bookmarked).toList();
                }

                if ((query.isNotEmpty && !nbMatches && filteredPages.isEmpty) ||
                    (c.bookmarkFilterOnly && filteredPages.isEmpty)) {
                  return const SizedBox.shrink();
                }

                final isExpanded = nb.id == c.activeNotebookId ||
                    query.isNotEmpty ||
                    c.bookmarkFilterOnly;

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: nb.id == c.activeNotebookId
                        ? Colors.white
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: nb.id == c.activeNotebookId
                        ? Border.all(color: const Color(0xFFE2E8F0))
                        : null,
                  ),
                  child: Column(
                    children: <Widget>[
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => c.selectNotebook(nb.id),
                        onLongPress: () => _showRenameDialog(
                          title: '重命名笔记本',
                          initialValue: nb.title,
                          onConfirm: (val) => c.renameNotebook(nb.id, val),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
                          child: Row(
                            children: <Widget>[
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: Color(nb.colorValue),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  nb.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: nb.id == c.activeNotebookId
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                    color: const Color(0xFF0F172A),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '在此笔记本新增画板页',
                                icon: const Icon(Icons.add, size: 18),
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  c.createPage(notebookId: nb.id);
                                  widget.onCloseDrawer?.call();
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (isExpanded)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          child: Column(
                            children: <Widget>[
                              for (var pIdx = 0;
                                  pIdx < filteredPages.length;
                                  pIdx++)
                                _PageRowTile(
                                  page: filteredPages[pIdx],
                                  isActive:
                                      filteredPages[pIdx].id == c.activePageId,
                                  canDelete: pages.length > 1,
                                  canMoveUp:
                                      pages.indexOf(filteredPages[pIdx]) > 0,
                                  canMoveDown:
                                      pages.indexOf(filteredPages[pIdx]) <
                                          pages.length - 1,
                                  peersOnPage: c.remotePeers
                                      .where(
                                        (p) =>
                                            p.activePageId ==
                                            filteredPages[pIdx].id,
                                      )
                                      .toList(),
                                  onSelect: () {
                                    c.selectPage(filteredPages[pIdx].id);
                                    widget.onCloseDrawer?.call();
                                  },
                                  onToggleBookmark: () => c.togglePageBookmark(
                                    filteredPages[pIdx].id,
                                  ),
                                  onDuplicate: () =>
                                      c.duplicatePage(filteredPages[pIdx].id),
                                  onMoveUp: () => c.movePageOrder(
                                    filteredPages[pIdx].id,
                                    -1,
                                  ),
                                  onMoveDown: () => c.movePageOrder(
                                    filteredPages[pIdx].id,
                                    1,
                                  ),
                                  onRename: () => _showRenameDialog(
                                    title: '重命名画板页',
                                    initialValue: filteredPages[pIdx].title,
                                    onConfirm: (val) => c.renamePage(
                                      filteredPages[pIdx].id,
                                      val,
                                    ),
                                  ),
                                  onDelete: () =>
                                      c.deletePage(filteredPages[pIdx].id),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),

          // Active page paper & template panel
          if (activePage != null)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(Icons.layers_outlined,
                          size: 15, color: Color(0xFF475569)),
                      const SizedBox(width: 6),
                      const Text(
                        '当前页纸张底纹',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF334155),
                        ),
                      ),
                      const Spacer(),
                      for (final paperColor
                          in NotebookController.paperPalette)
                        GestureDetector(
                          onTap: () => c.updatePageBackground(
                            activePage.id,
                            paperColor: paperColor,
                          ),
                          child: Container(
                            margin: const EdgeInsets.only(left: 4),
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: paperColor,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: activePage.backgroundColorValue ==
                                        paperColor.toARGB32()
                                    ? const Color(0xFF4F46E5)
                                    : const Color(0xFFCBD5E1),
                                width: activePage.backgroundColorValue ==
                                        paperColor.toARGB32()
                                    ? 2.0
                                    : 1.0,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final bg in PageBackground.values)
                        ChoiceChip(
                          label: Text(bg.label),
                          labelStyle: const TextStyle(fontSize: 11.5),
                          visualDensity: VisualDensity.compact,
                          selected: activePage.background == bg,
                          onSelected: (_) => c.updatePageBackground(
                            activePage.id,
                            background: bg,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PageRowTile extends StatelessWidget {
  const _PageRowTile({
    required this.page,
    required this.isActive,
    required this.canDelete,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.peersOnPage,
    required this.onSelect,
    required this.onToggleBookmark,
    required this.onDuplicate,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRename,
    required this.onDelete,
  });

  final NotebookPageModel page;
  final bool isActive;
  final bool canDelete;
  final bool canMoveUp;
  final bool canMoveDown;
  final List<PeerPresence> peersOnPage;
  final VoidCallback onSelect;
  final VoidCallback onToggleBookmark;
  final VoidCallback onDuplicate;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  IconData _iconForBackground(PageBackground bg) {
    switch (bg) {
      case PageBackground.blank:
        return Icons.crop_square_rounded;
      case PageBackground.grid:
        return Icons.grid_on_rounded;
      case PageBackground.dots:
        return Icons.grain_rounded;
      case PageBackground.ruled:
        return Icons.view_headline_rounded;
      case PageBackground.cornell:
        return Icons.dashboard_customize_outlined;
      case PageBackground.mistakeBook:
        return Icons.rule_folder_outlined;
      case PageBackground.weeklyPlan:
        return Icons.calendar_view_week_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isActive ? const Color(0xFFEEF2FF) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onSelect,
        onLongPress: onRename,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: <Widget>[
              Icon(
                _iconForBackground(page.background),
                size: 15,
                color: isActive
                    ? const Color(0xFF4F46E5)
                    : const Color(0xFF64748B),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  page.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    color: isActive
                        ? const Color(0xFF312E81)
                        : const Color(0xFF334155),
                  ),
                ),
              ),
              for (final peer in peersOnPage.take(2))
                Tooltip(
                  message: '${peer.displayName} (${peer.formFactor.label}) 正在此页',
                  child: Container(
                    margin: const EdgeInsets.only(left: 3),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Color(peer.colorValue),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              if (page.bookmarked || isActive)
                InkWell(
                  onTap: onToggleBookmark,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      page.bookmarked
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      size: 15,
                      color: page.bookmarked
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFF94A3B8),
                    ),
                  ),
                ),
              if (isActive)
                PopupMenuButton<String>(
                  tooltip: '页面管理',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 136),
                  onSelected: (action) {
                    switch (action) {
                      case 'rename':
                        onRename();
                        break;
                      case 'duplicate':
                        onDuplicate();
                        break;
                      case 'up':
                        onMoveUp();
                        break;
                      case 'down':
                        onMoveDown();
                        break;
                      case 'delete':
                        onDelete();
                        break;
                    }
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(
                      value: 'rename',
                      height: 36,
                      child: Text('重命名本页', style: TextStyle(fontSize: 13)),
                    ),
                    const PopupMenuItem<String>(
                      value: 'duplicate',
                      height: 36,
                      child: Text('复制本页', style: TextStyle(fontSize: 13)),
                    ),
                    if (canMoveUp)
                      const PopupMenuItem<String>(
                        value: 'up',
                        height: 36,
                        child: Text('上移一页', style: TextStyle(fontSize: 13)),
                      ),
                    if (canMoveDown)
                      const PopupMenuItem<String>(
                        value: 'down',
                        height: 36,
                        child: Text('下移一页', style: TextStyle(fontSize: 13)),
                      ),
                    if (canDelete) ...<PopupMenuEntry<String>>[
                      const PopupMenuDivider(),
                      const PopupMenuItem<String>(
                        value: 'delete',
                        height: 36,
                        child: Text(
                          '删除本页',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFFDC2626),
                          ),
                        ),
                      ),
                    ],
                  ],
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.more_horiz_rounded,
                      size: 16,
                      color: Color(0xFF4F46E5),
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
