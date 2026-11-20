import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../canvas/board_stage.dart';
import '../state/notebook_controller.dart';
import 'canvas_toolbar.dart';
import 'connect_qr_dialog.dart';
import 'notebook_sidebar.dart';
import 'peer_presence_bar.dart';

enum _ShellMode { desktop, tablet, phone }

class AdaptiveNotebookShell extends StatefulWidget {
  const AdaptiveNotebookShell({
    super.key,
    required this.controller,
  });

  final NotebookController controller;

  @override
  State<AdaptiveNotebookShell> createState() => _AdaptiveNotebookShellState();
}

class _AdaptiveNotebookShellState extends State<AdaptiveNotebookShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final FocusNode _keyboardFocusNode = FocusNode();
  bool _spacePressed = false;

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  _ShellMode _modeForWidth(double width) {
    if (width >= 1024) return _ShellMode.desktop;
    if (width >= 600) return _ShellMode.tablet;
    return _ShellMode.phone;
  }

  bool get _isEditingTextField {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || identical(focus, _keyboardFocusNode)) return false;
    final ctx = focus.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_isEditingTextField) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        widget.controller.setEditingCard(null);
        _keyboardFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.space) {
      final down = event is KeyDownEvent || event is KeyRepeatEvent;
      if (_spacePressed != down) {
        setState(() => _spacePressed = down);
      }
      return KeyEventResult.handled;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final c = widget.controller;
    final isCmdOrCtrl = kIsWeb ||
            defaultTargetPlatform == TargetPlatform.macOS
        ? HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed
        : HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    if (isCmdOrCtrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (isShift) {
        c.redo();
      } else {
        c.undo();
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      if (c.selectedElementId != null) {
        c.deleteElement(c.selectedElementId!);
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      c.selectElement(null);
      c.setEditingCard(null);
      return KeyEventResult.handled;
    }

    if (isCmdOrCtrl) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyV:
        c.setTool(CanvasTool.select);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyP:
        c.setTool(CanvasTool.pen);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyH:
        c.setTool(CanvasTool.highlighter);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyE:
        c.setTool(CanvasTool.eraser);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyR:
        c.setTool(CanvasTool.rectangle);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyO:
        c.setTool(CanvasTool.ellipse);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyD:
        c.setTool(CanvasTool.diamond);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyA:
        c.setTool(CanvasTool.arrow);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyT:
        c.setTool(CanvasTool.textCard);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyS:
        c.setTool(CanvasTool.stickyNote);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyL:
        c.setTool(CanvasTool.laser);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _openPhoneNotebookSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.78,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: AnimatedBuilder(
            animation: widget.controller,
            builder: (ctx, child) => NotebookSidebar(
              controller: widget.controller,
              onCloseDrawer: () => Navigator.of(ctx).pop(),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _scanAndJoinRoom() async {
    final raw = await widget.controller.platform.scanQrCode();
    if (raw == null || !mounted) return;
    final parsed = await widget.controller.applyScannedQr(raw);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 78),
        content: Text(
          parsed != null
              ? '已扫码连接到 ${parsed.wsUrl} (房间: ${widget.controller.roomId})'
              : '未能识别为有效的 SyncCanvas 同步地址',
        ),
      ),
    );
  }

  Future<void> _confirmClearPage() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空当前画板页？'),
        content: const Text('所有协作者画板上的笔迹与卡片都会清空，支持点击「撤销」恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      widget.controller.clearActivePage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mode = _modeForWidth(constraints.maxWidth);
          return AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              final c = widget.controller;
              return Scaffold(
                key: _scaffoldKey,
                backgroundColor: const Color(0xFFF8FAFC),
                drawer: mode == _ShellMode.tablet
                    ? Drawer(
                        width: 292,
                        child: SafeArea(
                          child: NotebookSidebar(
                            controller: c,
                            onCloseDrawer: () =>
                                _scaffoldKey.currentState?.closeDrawer(),
                          ),
                        ),
                      )
                    : null,
                body: SafeArea(
                  child: Column(
                    children: <Widget>[
                      _buildTopBar(context, c, mode, constraints.maxWidth),
                      Expanded(
                        child: Row(
                          children: <Widget>[
                            if (mode == _ShellMode.desktop && c.sidebarOpen)
                              SizedBox(
                                width: 268,
                                child: DecoratedBox(
                                  decoration: const BoxDecoration(
                                    border: Border(
                                      right: BorderSide(
                                        color: Color(0xFFE2E8F0),
                                      ),
                                    ),
                                  ),
                                  child: NotebookSidebar(controller: c),
                                ),
                              ),
                            Expanded(
                              child: Stack(
                                children: <Widget>[
                                  Positioned.fill(
                                    child: BoardStage(
                                      controller: c,
                                      isSpacePanPressed: _spacePressed,
                                      onRequestInsertImageAt: (scenePos) =>
                                          showInsertImageDialog(
                                        context,
                                        c,
                                        scenePos: scenePos,
                                      ),
                                    ),
                                  ),

                                  // Follow peer banner
                                  if (c.followingPeerId != null)
                                    Positioned(
                                      top: 12,
                                      left: 0,
                                      right: 0,
                                      child: Center(
                                        child: Material(
                                          elevation: 4,
                                          borderRadius:
                                              BorderRadius.circular(999),
                                          color: const Color(0xFF312E81),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 14,
                                              vertical: 6,
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: <Widget>[
                                                const Icon(
                                                  Icons.visibility_rounded,
                                                  size: 15,
                                                  color: Colors.white,
                                                ),
                                                const SizedBox(width: 6),
                                                const Text(
                                                  '正在实时跟随协作者视角',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                InkWell(
                                                  onTap: () => c.toggleFollowPeer(
                                                    c.followingPeerId!,
                                                  ),
                                                  child: const Text(
                                                    '退出跟随',
                                                    style: TextStyle(
                                                      color: Color(0xFFA5B4FC),
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),

                                  // Floating bottom toolbar
                                  Positioned(
                                    left: 10,
                                    right: 10,
                                    bottom: mode == _ShellMode.phone ? 10 : 16,
                                    child: Center(
                                      child: CanvasToolbar(
                                        controller: c,
                                        compact: mode == _ShellMode.phone,
                                        onInsertImage: () =>
                                            showInsertImageDialog(context, c),
                                      ),
                                    ),
                                  ),

                                  // Zoom control pill (Desktop & Tablet)
                                  if (mode != _ShellMode.phone)
                                    Positioned(
                                      right: 16,
                                      bottom: 18,
                                      child: _ZoomPill(controller: c),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    NotebookController c,
    _ShellMode mode,
    double maxWidth,
  ) {
    final pageTitle = c.activePage?.title ?? '未命名画板';
    final nbTitle = c.activeNotebook?.title ?? '笔记本';

    if (mode == _ShellMode.phone) {
      return Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: '笔记本与页面目录',
              onPressed: _openPhoneNotebookSheet,
              icon: const Icon(Icons.menu_book_rounded, size: 21),
            ),
            Expanded(
              child: InkWell(
                onTap: _openPhoneNotebookSheet,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      pageTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    Text(
                      nbTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => c.setPhoneBrowseOnlyMode(!c.phoneBrowseOnlyMode),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: c.phoneBrowseOnlyMode
                      ? const Color(0xFFF1F5F9)
                      : const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: c.phoneBrowseOnlyMode
                        ? const Color(0xFFCBD5E1)
                        : const Color(0xFF818CF8),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      c.phoneBrowseOnlyMode
                          ? Icons.pan_tool_alt_outlined
                          : Icons.edit_outlined,
                      size: 14,
                      color: c.phoneBrowseOnlyMode
                          ? const Color(0xFF475569)
                          : const Color(0xFF4F46E5),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      c.phoneBrowseOnlyMode ? '浏览' : '动笔',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: c.phoneBrowseOnlyMode
                            ? const Color(0xFF334155)
                            : const Color(0xFF4F46E5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            SyncStatusChip(
              controller: c,
              compact: true,
              onTap: () => showConnectQrDialog(context, c),
            ),
            if (c.platform.canScanQrCode)
              IconButton(
                tooltip: '扫码连接',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: _scanAndJoinRoom,
                icon: const Icon(
                  Icons.qr_code_scanner_rounded,
                  size: 20,
                  color: Color(0xFF0D9488),
                ),
              ),
            IconButton(
              tooltip: '三端扫码连接',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () => showConnectQrDialog(context, c),
              icon: const Icon(
                Icons.qr_code_2_rounded,
                size: 21,
                color: Color(0xFF4F46E5),
              ),
            ),
          ],
        ),
      );
    }

    // Desktop & Tablet Top Bar
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        children: <Widget>[
          if (mode == _ShellMode.desktop)
            IconButton(
              tooltip: c.sidebarOpen ? '收起目录侧栏' : '展开目录侧栏',
              onPressed: () => c.setSidebarOpen(!c.sidebarOpen),
              icon: Icon(
                c.sidebarOpen ? Icons.menu_open_rounded : Icons.menu_rounded,
              ),
            )
          else
            IconButton(
              tooltip: '打开笔记本目录',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: const Icon(Icons.menu_rounded),
            ),
          const SizedBox(width: 4),
          Expanded(
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    '$nbTitle  /  $pageTitle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '快速新建画板页',
                  onPressed: () => c.createPage(),
                  icon: const Icon(Icons.note_add_outlined, size: 19),
                ),
              ],
            ),
          ),
          PeerPresenceBar(
            controller: c,
            maxVisible: mode == _ShellMode.desktop
                ? 4
                : (maxWidth >= 760 ? 2 : 1),
          ),
          const SizedBox(width: 8),
          SyncStatusChip(
            controller: c,
            compact: maxWidth < 760,
            onTap: () => showConnectQrDialog(context, c),
          ),
          if (c.platform.canScanQrCode) ...<Widget>[
            const SizedBox(width: 6),
            IconButton(
              tooltip: '扫码连接',
              onPressed: _scanAndJoinRoom,
              icon: const Icon(
                Icons.qr_code_scanner_rounded,
                color: Color(0xFF0D9488),
              ),
            ),
          ],
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: () => showConnectQrDialog(context, c),
            icon: const Icon(Icons.qr_code_2_rounded, size: 18),
            label: Text(mode == _ShellMode.desktop ? '三端连接' : '连接'),
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: '画板页选项',
            onSelected: (value) {
              if (value == 'clear') {
                _confirmClearPage();
              } else if (value == 'reset_view') {
                c.resetViewport();
              } else if (value == 'stylus') {
                c.setStylusOnlyMode(!c.stylusOnlyMode);
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'stylus',
                child: Row(
                  children: <Widget>[
                    Icon(
                      c.stylusOnlyMode
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Text('平板防误触笔模式'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'reset_view',
                child: Row(
                  children: <Widget>[
                    Icon(Icons.center_focus_strong_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('重置画布视角 (100%)'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'clear',
                child: Row(
                  children: <Widget>[
                    Icon(Icons.delete_sweep_outlined,
                        size: 18, color: Color(0xFFDC2626)),
                    SizedBox(width: 8),
                    Text('清空当前页', style: TextStyle(color: Color(0xFFDC2626))),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ZoomPill extends StatelessWidget {
  const _ZoomPill({required this.controller});

  final NotebookController controller;

  @override
  Widget build(BuildContext context) {
    final pct = '${(controller.zoom * 100).round()}%';
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(999),
      color: Colors.white.withValues(alpha: 0.94),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            InkWell(
              onTap: () => controller.zoomByFactor(0.85),
              borderRadius: BorderRadius.circular(99),
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(Icons.remove, size: 16, color: Color(0xFF475569)),
              ),
            ),
            InkWell(
              onTap: controller.resetViewport,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  pct,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1E293B),
                  ),
                ),
              ),
            ),
            InkWell(
              onTap: () => controller.zoomByFactor(1.15),
              borderRadius: BorderRadius.circular(99),
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(Icons.add, size: 16, color: Color(0xFF475569)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
