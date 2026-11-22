import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notebook_core/notebook_core.dart';

import '../state/notebook_controller.dart';

Future<void> showMindFlowAiDialog(
  BuildContext context,
  NotebookController controller,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _MindFlowAiDialog(controller: controller),
  );
}

Future<void> showEditGraphLabelDialog(
  BuildContext context,
  NotebookController controller,
  CanvasElementModel element,
) async {
  final isCluster = element.kind == ElementKind.cluster;
  final textCtrl = TextEditingController(text: element.text);
  var selectedColor = element.semanticColor;

  final presets = isCluster
      ? const <String>['核心架构', '研究洞察', '待办行动', '风险清单', '知识总结']
      : const <String>['因果推导', '支撑论据', '拆解步骤', '依赖关系', '潜在风险'];

  try {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(isCluster ? '编辑 MindFlow 群组标题' : '编辑因果连线关系词'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: textCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: isCluster ? '群组标题' : '关系标签（建议 2–6 字，可留空）',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final preset in presets)
                      ActionChip(
                        label: Text(preset, style: const TextStyle(fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          textCtrl.text = preset;
                          textCtrl.selection = TextSelection.collapsed(
                            offset: preset.length,
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  '语义色标',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final sc in MindFlowColor.values)
                      ChoiceChip(
                        selected: selectedColor == sc,
                        label: Text(sc.label, style: const TextStyle(fontSize: 11.5)),
                        avatar: CircleAvatar(
                          backgroundColor: Color(sc.borderArgb),
                          radius: 7,
                        ),
                        onSelected: (_) => setState(() => selectedColor = sc),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                controller.updateElementText(element.id, textCtrl.text.trim());
                controller.updateElementSemanticColor(element.id, selectedColor);
                Navigator.of(ctx).pop();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  } finally {
    textCtrl.dispose();
  }
}

class _MindFlowAiDialog extends StatefulWidget {
  const _MindFlowAiDialog({required this.controller});

  final NotebookController controller;

  @override
  State<_MindFlowAiDialog> createState() => _MindFlowAiDialogState();
}

class _MindFlowAiDialogState extends State<_MindFlowAiDialog> {
  final TextEditingController _jsonImportCtrl = TextEditingController();
  String _contextScope = 'page';
  bool _importIntoNewPage = false;
  String? _statusMessage;
  bool _statusIsError = false;
  bool _loadingBackups = false;
  List<Map<String, dynamic>> _backups = const <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    final hasSel = widget.controller.selectedElementId != null ||
        widget.controller.selectedElementIds.isNotEmpty;
    _contextScope = hasSel ? 'selected' : 'page';
    _refreshBackups();
  }

  @override
  void dispose() {
    _jsonImportCtrl.dispose();
    super.dispose();
  }

  Future<void> _copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() {
      _statusMessage = '已复制$label到剪贴板';
      _statusIsError = false;
    });
  }

  Future<void> _refreshBackups() async {
    if (!mounted) return;
    setState(() => _loadingBackups = true);
    final list = await widget.controller.fetchMindFlowBackups();
    if (!mounted) return;
    setState(() {
      _backups = list;
      _loadingBackups = false;
    });
  }

  String _buildMcpConfigSnippet(NotebookController c) {
    final readOnlyFlag = c.mindflowMcpReadOnly ? ' --read-only' : '';
    final endpoint = c.mindflowMcpEndpointUrl;
    final room = c.roomId;
    final snippet = <String, dynamic>{
      'mcpServers': <String, dynamic>{
        'synccanvas-mindflow-http': <String, dynamic>{
          'url': endpoint,
        },
        'synccanvas-mindflow-stdio': <String, dynamic>{
          'command': 'node',
          'args': <String>[
            'scripts/mindflow_mcp_bridge.mjs',
            '--server=${c.serverHttpBaseUrl}',
            '--room=$room',
            if (readOnlyFlag.isNotEmpty) '--read-only',
          ],
        },
      },
    };
    return const JsonEncoder.withIndent('  ').convert(snippet);
  }

  void _runImportJson() {
    final raw = _jsonImportCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _statusMessage = '请先粘贴 AI 输出的 MindFlow JSON（支持带 ```json 代码块）';
        _statusIsError = true;
      });
      return;
    }
    try {
      final count = widget.controller.importMindFlowJsonString(
        raw,
        intoNewPage: _importIntoNewPage,
      );
      setState(() {
        _statusMessage = '成功导入 $count 个 MindFlow 图元到画板，支持 Ctrl/Cmd+Z 一键撤销';
        _statusIsError = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = '导入失败：$e';
        _statusIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final els = c.activeElements.where((e) => !e.deleted).toList();
        final tokenCount = els.where((e) => e.kind == ElementKind.token).length;
        final edgeCount =
            els.where((e) => e.kind == ElementKind.connector).length;
        final clusterCount =
            els.where((e) => e.kind == ElementKind.cluster).length;
        final selectedCount = c.selectedElementIds.isNotEmpty
            ? c.selectedElementIds.length
            : (c.selectedElementId != null ? 1 : 0);

        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
          contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          title: Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Color(0xFF4F46E5),
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'MindFlow × SyncCanvas AI 协同中心',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '空间词块导图 · AI 技能导出/导入 · 内置 MCP Server',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          content: SizedBox(
            width: 640,
            height: math.min(560.0, MediaQuery.sizeOf(context).height * 0.72),
            child: DefaultTabController(
              length: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const TabBar(
                    tabs: <Widget>[
                      Tab(
                        icon: Icon(Icons.hub_outlined, size: 17),
                        text: 'AI 技能与导图读写',
                      ),
                      Tab(
                        icon: Icon(Icons.dns_outlined, size: 17),
                        text: 'MCP 接入与版本恢复',
                      ),
                    ],
                  ),
                  if (_statusMessage != null)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: _statusIsError
                            ? const Color(0xFFFEF2F2)
                            : const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _statusIsError
                              ? const Color(0xFFFCA5A5)
                              : const Color(0xFF6EE7B7),
                        ),
                      ),
                      child: Text(
                        _statusMessage!,
                        style: TextStyle(
                          fontSize: 12,
                          color: _statusIsError
                              ? const Color(0xFFB91C1C)
                              : const Color(0xFF065F46),
                        ),
                      ),
                    ),
                  Expanded(
                    child: TabBarView(
                      children: <Widget>[
                        _buildAiSkillTab(
                          c,
                          tokenCount,
                          edgeCount,
                          clusterCount,
                          selectedCount,
                        ),
                        _buildMcpTab(c),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAiSkillTab(
    NotebookController c,
    int tokenCount,
    int edgeCount,
    int clusterCount,
    int selectedCount,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '当前画板页：$tokenCount 个词块 · $edgeCount 条连线 · $clusterCount 个分组（已选 $selectedCount 项）',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF334155),
                    ),
                  ),
                ),
                ChoiceChip(
                  label: const Text('选中作用域', style: TextStyle(fontSize: 11.5)),
                  selected: _contextScope == 'selected',
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _contextScope = 'selected'),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: const Text('整页作用域', style: TextStyle(fontSize: 11.5)),
                  selected: _contextScope == 'page',
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _contextScope = 'page'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: () => _copyText(
                  c.buildActivePageAiSkillBundle(scope: _contextScope),
                  'AI 技能指南 + 空间上下文',
                ),
                icon: const Icon(Icons.copy_all_rounded, size: 17),
                label: const Text('复制 AI Skill + 上下文'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  final moved = c.autoLayoutActivePageMindFlow();
                  setState(() {
                    _statusMessage = moved > 0
                        ? '已按拓扑层级自动整理 $moved 个词块位置'
                        : '当前没有需要重排的关联词块';
                    _statusIsError = false;
                  });
                },
                icon: const Icon(Icons.account_tree_rounded, size: 17),
                label: const Text('一键整理拓扑布局'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final path = await c.saveActivePageMindFlowJson();
                  if (!mounted) return;
                  setState(() {
                    _statusMessage = path != null
                        ? '已导出标准 MindFlow JSON：$path'
                        : '导出 MindFlow JSON 失败';
                    _statusIsError = path == null;
                  });
                },
                icon: const Icon(Icons.data_object_rounded, size: 17),
                label: const Text('导出 .mindflow.json'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final path = await c.saveActivePageSvg();
                  if (!mounted) return;
                  setState(() {
                    _statusMessage =
                        path != null ? '已导出矢量导图 SVG：$path' : '导出 SVG 失败';
                    _statusIsError = path == null;
                  });
                },
                icon: const Icon(Icons.polyline_rounded, size: 17),
                label: const Text('导出矢量图 .svg'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            '导入 AI 生成的 MindFlow JSON / 代码块',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            '把发给任意大模型后生成的 JSON（含 tokens / edges / clusters）粘贴到下方，若当前页含 PDF 讲义底图将自动排版在其右侧安全区。',
            style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _jsonImportCtrl,
            maxLines: 5,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText:
                  '{\n  "title": "主题拆解",\n  "tokens": [{ "id": "t1", "color": "yellow", "text": "核心论点", "x": 120, "y": 100 }],\n  "edges": []\n}',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: CheckboxListTile(
                  value: _importIntoNewPage,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    '导入到新建画板页（否则融合进当前页）',
                    style: TextStyle(fontSize: 12),
                  ),
                  onChanged: (v) =>
                      setState(() => _importIntoNewPage = v ?? false),
                ),
              ),
              FilledButton.icon(
                key: const ValueKey<String>('import-mindflow-json-btn'),
                onPressed: _runImportJson,
                icon: const Icon(Icons.download_done_rounded, size: 17),
                label: const Text('解析并写入画板'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMcpTab(NotebookController c) {
    final mcpConfig = _buildMcpConfigSnippet(c);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              '默认启用 MCP 只读保护 (--read-only)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              '开启后 AI Agent 仅能读取上下文、结构与 SKILL，禁止直接改写白板；关闭则允许通过 expectedRevision 乐观锁原子提交变更',
              style: TextStyle(fontSize: 11.5),
            ),
            value: c.mindflowMcpReadOnly,
            onChanged: c.setMindFlowMcpReadOnly,
          ),
          const Divider(height: 16),
          const Text(
            'Streamable HTTP MCP 接入地址',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SelectableText(
                    c.mindflowMcpEndpointUrl,
                    style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  tooltip: '复制地址',
                  onPressed: () =>
                      _copyText(c.mindflowMcpEndpointUrl, 'MCP Endpoint 地址'),
                  icon: const Icon(Icons.copy_rounded, size: 17),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'mcpServers 客户端配置 (Claude Desktop / Cursor / Antigravity / Windsurf)',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: () => _copyText(mcpConfig, 'mcpServers JSON 配置'),
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制配置'),
              ),
            ],
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              mcpConfig,
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  '服务端自动备份与版本恢复（最多保留最近 20 个修订版本）',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: '刷新备份列表',
                onPressed: _loadingBackups ? null : _refreshBackups,
                icon: _loadingBackups
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
          if (_backups.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '暂无远端修订备份（连接到协作主机或通过 MCP 写入变更后会自动在此显示可恢复的修订快照）。',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _backups.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final item = _backups[i];
                final rev = (item['revision'] as num? ?? 0).toInt();
                final updated = item['updatedAt'] as String? ?? '';
                final count = (item['tokenCount'] as num? ?? 0).toInt();
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'Revision #$rev · $count 个词块',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    updated,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      final ok = await c.restoreMindFlowBackup(rev);
                      if (!mounted) return;
                      setState(() {
                        _statusMessage =
                            ok ? '已恢复到 Revision #$rev' : '恢复版本失败';
                        _statusIsError = !ok;
                      });
                      await _refreshBackups();
                    },
                    child: const Text('恢复此版本'),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
