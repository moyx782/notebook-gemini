import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notebook_core/notebook_core.dart';

import '../platform/platform_adapter.dart';
import '../state/notebook_controller.dart';

class VoiceMemoFloatingPanel extends StatefulWidget {
  const VoiceMemoFloatingPanel({
    super.key,
    required this.controller,
    required this.stageSize,
    required this.compact,
  });

  final NotebookController controller;
  final Size stageSize;
  final bool compact;

  @override
  State<VoiceMemoFloatingPanel> createState() => _VoiceMemoFloatingPanelState();
}

class _VoiceMemoFloatingPanelState extends State<VoiceMemoFloatingPanel> {
  final TextEditingController _manualInputCtrl = TextEditingController();
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _bodyCtrl = TextEditingController();

  VoiceMemoInsertTarget _insertTarget = VoiceMemoInsertTarget.markdownCard;
  Timer? _clockTimer;
  String _lastSyncedTitle = '';
  String _lastSyncedBody = '';
  String? _localBanner;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncClockTimer();
    _syncDraftControllers();
  }

  @override
  void didUpdateWidget(covariant VoiceMemoFloatingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    _syncClockTimer();
    _syncDraftControllers();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _clockTimer?.cancel();
    _manualInputCtrl.dispose();
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _syncClockTimer();
    _syncDraftControllers();
  }

  void _syncClockTimer() {
    final isRecording =
        widget.controller.voiceMemoPhase == VoiceMemoPhase.recording;
    if (isRecording && _clockTimer == null) {
      _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else if (!isRecording && _clockTimer != null) {
      _clockTimer?.cancel();
      _clockTimer = null;
    }
  }

  void _syncDraftControllers() {
    final c = widget.controller;
    if (c.voiceMemoDraftTitle != _lastSyncedTitle) {
      _lastSyncedTitle = c.voiceMemoDraftTitle;
      if (_titleCtrl.text != c.voiceMemoDraftTitle) {
        _titleCtrl.text = c.voiceMemoDraftTitle;
        _titleCtrl.selection = TextSelection.collapsed(
          offset: _titleCtrl.text.length,
        );
      }
    }
    if (c.voiceMemoDraftBody != _lastSyncedBody) {
      _lastSyncedBody = c.voiceMemoDraftBody;
      if (_bodyCtrl.text != c.voiceMemoDraftBody) {
        _bodyCtrl.text = c.voiceMemoDraftBody;
        _bodyCtrl.selection = TextSelection.collapsed(
          offset: _bodyCtrl.text.length,
        );
      }
    }
  }

  void _submitManualNote() {
    final text = _manualInputCtrl.text.trim();
    if (text.isEmpty) return;
    widget.controller.appendManualVoiceNote(text);
    _manualInputCtrl.clear();
  }

  Future<void> _showAiConfigDialog(BuildContext context) async {
    final c = widget.controller;
    final baseCtrl = TextEditingController(text: c.aiApiBaseUrl);
    final keyCtrl = TextEditingController(text: c.aiApiKey);
    final modelCtrl = TextEditingController(text: c.aiModelName);

    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('可选 AI 润色接口配置'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '不配置也可直接使用内置本地智能断句与待办整理；如需大模型深度润色，可填 OpenAI 兼容或 Gemini 接口。',
                    style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      ActionChip(
                        label: const Text('OpenAI', style: TextStyle(fontSize: 11.5)),
                        onPressed: () {
                          baseCtrl.text = 'https://api.openai.com/v1';
                          modelCtrl.text = 'gpt-4o-mini';
                        },
                      ),
                      ActionChip(
                        label: const Text('DeepSeek', style: TextStyle(fontSize: 11.5)),
                        onPressed: () {
                          baseCtrl.text = 'https://api.deepseek.com/v1';
                          modelCtrl.text = 'deepseek-chat';
                        },
                      ),
                      ActionChip(
                        label: const Text('Gemini REST', style: TextStyle(fontSize: 11.5)),
                        onPressed: () {
                          baseCtrl.text =
                              'https://generativelanguage.googleapis.com/v1beta';
                          modelCtrl.text = 'gemini-2.5-flash';
                        },
                      ),
                      ActionChip(
                        label: const Text('本地 Ollama', style: TextStyle(fontSize: 11.5)),
                        onPressed: () {
                          baseCtrl.text = 'http://127.0.0.1:11434/v1';
                          modelCtrl.text = 'qwen2.5:7b';
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: baseCtrl,
                    decoration: const InputDecoration(
                      labelText: 'API Base URL',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: modelCtrl,
                    decoration: const InputDecoration(
                      labelText: '模型名称 (Model)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: keyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key（本地 Ollama 可留空）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
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
              onPressed: () {
                c.configureVoiceMemoAi(
                  apiBaseUrl: baseCtrl.text,
                  apiKey: keyCtrl.text,
                  modelName: modelCtrl.text,
                );
                Navigator.of(ctx).pop();
                setState(() => _localBanner = '已保存 AI 接口配置');
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      baseCtrl.dispose();
      keyCtrl.dispose();
      modelCtrl.dispose();
    }
  }

  Future<void> _showLinuxLocalAsrDialog(BuildContext context) async {
    final c = widget.controller;
    await c.refreshLocalAsrStatus();
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => _LinuxLocalAsrDialog(controller: c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final stageW = widget.stageSize.width.isFinite && widget.stageSize.width > 0
        ? widget.stageSize.width
        : 1000.0;
    final stageH = widget.stageSize.height.isFinite && widget.stageSize.height > 0
        ? widget.stageSize.height
        : 700.0;

    final panelWidth = c.voiceMemoMinimized
        ? math.min(300.0, stageW - 24.0)
        : (widget.compact ? math.max(280.0, stageW - 24.0) : 400.0);
    final panelMaxHeight = math.max(240.0, stageH - 92.0);
    final clampedX = c.voiceMemoOffset.dx
        .clamp(8.0, math.max(8.0, stageW - panelWidth - 8.0))
        .toDouble();
    final clampedY = c.voiceMemoOffset.dy
        .clamp(8.0, math.max(8.0, stageH - 120.0))
        .toDouble();

    return Positioned(
      left: clampedX,
      top: clampedY,
      child: c.voiceMemoMinimized
          ? _buildMinimizedPill(c, panelWidth)
          : ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: panelWidth,
                maxHeight: panelMaxHeight,
              ),
              child: SizedBox(
                width: panelWidth,
                child: Material(
                  elevation: 12,
                  shadowColor: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(18),
                  color: Colors.white.withValues(alpha: 0.98),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFCBD5E1)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _buildDraggableHeader(c, stageW, stageH, panelWidth),
                        Flexible(
                          child: c.voiceMemoPhase == VoiceMemoPhase.review
                              ? _buildReviewBody(context, c)
                              : _buildCaptureBody(c),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildMinimizedPill(NotebookController c, double maxW) {
    final isRec = c.voiceMemoPhase == VoiceMemoPhase.recording;
    final snippet = c.voicePartialText.isNotEmpty
        ? c.voicePartialText
        : (c.voiceSegments.isNotEmpty
            ? c.voiceSegments.last.text
            : (isRec ? '正在聆听…' : '语音备忘待命'));

    return GestureDetector(
      key: const ValueKey<String>('voice-memo-mini-pill'),
      onPanUpdate: (d) =>
          c.updateVoiceMemoOffset(c.voiceMemoOffset + d.delta),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(999),
        color: const Color(0xFF0F172A),
        child: Container(
          constraints: BoxConstraints(maxWidth: maxW),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                isRec ? Icons.mic_rounded : Icons.mic_none_rounded,
                size: 16,
                color: isRec ? const Color(0xFFF87171) : const Color(0xFF94A3B8),
              ),
              const SizedBox(width: 6),
              Text(
                formatVoiceDuration(c.voiceElapsedMs),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  snippet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11.5),
                ),
              ),
              const SizedBox(width: 6),
              if (c.hasVoiceTranscriptContent)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => c.finishVoiceMemoToCompleteText(),
                  child: const Text(
                    '成稿',
                    style: TextStyle(
                      color: Color(0xFF34D399),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                tooltip: '展开语音备忘面板',
                onPressed: () => c.setVoiceMemoMinimized(false),
                icon: const Icon(
                  Icons.open_in_full_rounded,
                  size: 15,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDraggableHeader(
    NotebookController c,
    double stageW,
    double stageH,
    double panelWidth,
  ) {
    final phase = c.voiceMemoPhase;
    final badgeColor = switch (phase) {
      VoiceMemoPhase.recording => const Color(0xFFDC2626),
      VoiceMemoPhase.paused => const Color(0xFFD97706),
      VoiceMemoPhase.review => const Color(0xFF059669),
      VoiceMemoPhase.idle => const Color(0xFF4F46E5),
    };
    final badgeText = switch (phase) {
      VoiceMemoPhase.recording => '实时转写中',
      VoiceMemoPhase.paused => '已暂停',
      VoiceMemoPhase.review => '完整备忘成稿',
      VoiceMemoPhase.idle => '语音备忘录',
    };

    return GestureDetector(
      onPanUpdate: (details) => c.updateVoiceMemoOffset(
        Offset(
          (c.voiceMemoOffset.dx + details.delta.dx)
              .clamp(8.0, math.max(8.0, stageW - panelWidth - 8.0))
              .toDouble(),
          (c.voiceMemoOffset.dy + details.delta.dy)
              .clamp(8.0, math.max(8.0, stageH - 120.0))
              .toDouble(),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: const BoxDecoration(
          color: Color(0xFFF8FAFC),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.drag_indicator_rounded, size: 17, color: Colors.grey[500]),
            const SizedBox(width: 4),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      phase == VoiceMemoPhase.recording
                          ? Icons.fiber_manual_record
                          : Icons.mic_rounded,
                      size: 11,
                      color: badgeColor,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        badgeText,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: badgeColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              formatVoiceDuration(c.voiceElapsedMs),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                color: Color(0xFF334155),
              ),
            ),
            const Spacer(),
            if (phase != VoiceMemoPhase.review)
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: c.voiceLocaleId,
                  isDense: true,
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF334155)),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'zh-CN', child: Text('普通话')),
                    DropdownMenuItem(value: 'zh-HK', child: Text('粤语')),
                    DropdownMenuItem(value: 'en-US', child: Text('English')),
                    DropdownMenuItem(value: 'ja-JP', child: Text('日本語')),
                  ],
                  onChanged: (v) {
                    if (v != null) c.setVoiceLocaleId(v);
                  },
                ),
              ),
            IconButton(
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              tooltip: '最小化悬浮条（不遮挡书写）',
              onPressed: () => c.setVoiceMemoMinimized(true),
              icon: const Icon(Icons.minimize_rounded, size: 17),
            ),
            IconButton(
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              tooltip: '关闭语音备忘面板',
              onPressed: () => c.closeVoiceMemo(),
              icon: const Icon(Icons.close_rounded, size: 17),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureBody(NotebookController c) {
    final segments = c.voiceSegments;
    final partial = c.voicePartialText;
    final isRecording = c.voiceMemoPhase == VoiceMemoPhase.recording;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Waveform activity strip
          Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: 22,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      for (var i = 0; i < 16; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 110),
                          width: 4.5,
                          height: isRecording
                              ? (4.0 +
                                      16.0 *
                                          (0.25 +
                                              0.75 *
                                                  ((math.sin(i * 0.9) + 1) * 0.5) *
                                                  math.max(0.15, c.voiceAudioLevel)))
                                  .clamp(4.0, 20.0)
                              : 4.0,
                          decoration: BoxDecoration(
                            color: isRecording
                                ? const Color(0xFFEF4444)
                                : const Color(0xFFCBD5E1),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${segments.length} 句',
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
              ),
            ],
          ),
          if (c.platform.supportsLocalAsrModels) ...<Widget>[
            const SizedBox(height: 8),
            _buildLinuxLocalAsrBanner(context, c),
          ],
          if (c.voiceError != null) ...<Widget>[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFCD34D)),
              ),
              child: Text(
                c.voiceError!,
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF92400E)),
              ),
            ),
          ],
          const SizedBox(height: 8),

          // Live transcript box
          Container(
            constraints: const BoxConstraints(minHeight: 110, maxHeight: 200),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: (!c.hasVoiceTranscriptContent)
                ? const Center(
                    child: Text(
                      '点击「开始实时转写」，可一边在 PDF 或白板上手写批注，一边自动口述转写。\n结束后将自动去重断句、补全标点并整理成完整文字备忘。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    reverse: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (final seg in segments)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text.rich(
                              TextSpan(
                                children: <InlineSpan>[
                                  TextSpan(
                                    text: '[${seg.formattedTimestamp}] ',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF64748B),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  TextSpan(
                                    text: seg.text,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      height: 1.4,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (partial.isNotEmpty)
                          Container(
                            key: const ValueKey<String>('voice-memo-live-partial'),
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEEF2FF),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '正在识别：$partial',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontStyle: FontStyle.italic,
                                color: Color(0xFF4338CA),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 8),

          // Hybrid quick note / system-IME dictation row
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('voice-memo-manual-input'),
                  controller: _manualInputCtrl,
                  style: const TextStyle(fontSize: 12.5),
                  onSubmitted: (_) => _submitManualNote(),
                  decoration: const InputDecoration(
                    hintText: '补充文字速记 / 系统语音听写内容…',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                key: const ValueKey<String>('voice-memo-manual-add-btn'),
                tooltip: '加入语音分段',
                onPressed: _submitManualNote,
                icon: const Icon(Icons.add_comment_outlined, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Recording control buttons
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey<String>('toggle-voice-record-btn'),
                  style: FilledButton.styleFrom(
                    backgroundColor: isRecording
                        ? const Color(0xFFD97706)
                        : const Color(0xFF4F46E5),
                  ),
                  onPressed: () {
                    if (isRecording) {
                      c.pauseVoiceMemoRecording();
                    } else if (c.voiceMemoPhase == VoiceMemoPhase.paused) {
                      c.resumeVoiceMemoRecording();
                    } else {
                      c.startVoiceMemoRecording(resetExisting: true);
                    }
                  },
                  icon: Icon(
                    isRecording
                        ? Icons.pause_rounded
                        : (c.voiceMemoPhase == VoiceMemoPhase.paused
                            ? Icons.play_arrow_rounded
                            : Icons.mic_rounded),
                    size: 18,
                  ),
                  label: Text(
                    isRecording
                        ? '暂停'
                        : (c.voiceMemoPhase == VoiceMemoPhase.paused
                            ? '继续录音'
                            : '开始实时转写'),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey<String>('finish-voice-memo-btn'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF059669),
                  ),
                  onPressed: c.hasVoiceTranscriptContent
                      ? () => c.finishVoiceMemoToCompleteText()
                      : null,
                  icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                  label: const Text(
                    '转为完整备忘',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
          if (c.hasVoiceTranscriptContent)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: c.clearVoiceMemoSession,
                child: const Text(
                  '清空重录',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLinuxLocalAsrBanner(
    BuildContext context,
    NotebookController c,
  ) {
    final status = c.localAsrStatus;
    final dl = c.localAsrDownloadProgress;
    final downloading = dl != null && !dl.done;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: status.ready
            ? const Color(0xFFECFDF5)
            : const Color(0xFFEEF2FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: status.ready
              ? const Color(0xFFA7F3D0)
              : const Color(0xFFC7D2FE),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                downloading
                    ? Icons.downloading_rounded
                    : (status.ready
                        ? Icons.offline_bolt_rounded
                        : Icons.memory_rounded),
                size: 16,
                color: status.ready
                    ? const Color(0xFF059669)
                    : const Color(0xFF4338CA),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  downloading
                      ? dl.stage
                      : (status.ready
                          ? '端侧离线：${status.engineSummary}'
                          : (status.issueMessage ?? 'Linux 端侧模型未就绪，点击下载或指定本地模型')),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: status.ready
                        ? const Color(0xFF065F46)
                        : const Color(0xFF3730A3),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                key: const ValueKey<String>('open-linux-asr-model-btn'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _showLinuxLocalAsrDialog(context),
                child: Text(
                  status.ready ? '模型管理' : '下载/配置',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (downloading) ...<Widget>[
            const SizedBox(height: 5),
            LinearProgressIndicator(value: dl.fraction),
          ],
        ],
      ),
    );
  }

  Widget _buildReviewBody(BuildContext context, NotebookController c) {
    final charCount = c.voiceMemoDraftBody.trim().length;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '已转为完整文字备忘（$charCount 字）',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF065F46),
                ),
              ),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: c.returnToVoiceRecording,
                child: const Text('返回补录', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Formatting style + cleanup toggles
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final style in MemoFormatStyle.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: ChoiceChip(
                      label: Text(style.label, style: const TextStyle(fontSize: 11)),
                      selected: c.voiceMemoFormatStyle == style,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => c.regenerateVoiceMemoDraft(style: style),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: FilterChip(
                    label: const Text('去口语词', style: TextStyle(fontSize: 11)),
                    selected: c.voiceMemoRemoveFillers,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) =>
                        c.regenerateVoiceMemoDraft(removeFillers: v),
                  ),
                ),
                FilterChip(
                  label: const Text('时间戳', style: TextStyle(fontSize: 11)),
                  selected: c.voiceMemoIncludeTimestamps,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) =>
                      c.regenerateVoiceMemoDraft(includeTimestamps: v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Title & complete memo editors
          TextField(
            key: const ValueKey<String>('voice-memo-title-field'),
            controller: _titleCtrl,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            onChanged: (v) {
              _lastSyncedTitle = v;
              c.updateVoiceMemoDraftEdits(title: v);
            },
            decoration: const InputDecoration(
              labelText: '备忘标题',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey<String>('voice-memo-complete-text-field'),
            controller: _bodyCtrl,
            minLines: 5,
            maxLines: 9,
            style: const TextStyle(fontSize: 12.5, height: 1.45),
            onChanged: (v) {
              _lastSyncedBody = v;
              c.updateVoiceMemoDraftEdits(body: v);
            },
            decoration: const InputDecoration(
              labelText: '完整文字备忘内容（支持 Markdown & - [ ] 待办）',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),

          // Optional AI polishing strip
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              OutlinedButton.icon(
                key: const ValueKey<String>('ai-polish-memo-btn'),
                onPressed: c.isPolishingVoiceMemo
                    ? null
                    : () async {
                        final outcome = await c.polishVoiceMemoDraftWithAi();
                        if (!mounted) return;
                        if (outcome.ok) {
                          setState(() => _localBanner = 'AI 润色完成，可微调后写入画板');
                        } else if (outcome.manualRequired) {
                          setState(() => _localBanner = outcome.error);
                          if (context.mounted) {
                            await _showAiConfigDialog(context);
                          }
                        } else {
                          setState(() => _localBanner = outcome.error);
                        }
                      },
                icon: c.isPolishingVoiceMemo
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 15),
                label: Text(
                  c.isPolishingVoiceMemo ? '润色中…' : 'AI 润色成稿',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
              IconButton(
                tooltip: 'AI 接口配置',
                visualDensity: VisualDensity.compact,
                onPressed: () => _showAiConfigDialog(context),
                icon: const Icon(Icons.tune_rounded, size: 18),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                ),
                onPressed: () async {
                  final prompt = buildVoiceMemoAiPolishPrompt(
                    c.voiceSegments.map((s) => s.text).join('\n'),
                    currentDraft: c.voiceMemoDraftBody,
                  );
                  await Clipboard.setData(ClipboardData(text: prompt));
                  if (mounted) {
                    setState(() => _localBanner = '已复制润色提示词+全文');
                  }
                },
                child: const Text('复制润色指令', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          if (_localBanner != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              _localBanner!,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF4338CA)),
            ),
          ],
          const SizedBox(height: 8),

          // Target format & final commit row
          DropdownButtonFormField<VoiceMemoInsertTarget>(
            initialValue: _insertTarget,
            isDense: true,
            decoration: const InputDecoration(
              labelText: '生成到当前画板页形式',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            items: <DropdownMenuItem<VoiceMemoInsertTarget>>[
              for (final t in VoiceMemoInsertTarget.values)
                DropdownMenuItem(
                  value: t,
                  child: Text(t.label, style: const TextStyle(fontSize: 12.5)),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _insertTarget = v);
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: () async {
                  final fullText = '# ${c.voiceMemoDraftTitle}\n\n${c.voiceMemoDraftBody}';
                  await Clipboard.setData(ClipboardData(text: fullText));
                  if (mounted) {
                    setState(() => _localBanner = '已复制完整文字备忘到剪贴板');
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制全文', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey<String>('commit-voice-memo-card-btn'),
                  onPressed: c.voiceMemoDraftBody.trim().isEmpty
                      ? null
                      : () => c.commitVoiceMemoToCanvas(target: _insertTarget),
                  icon: const Icon(Icons.note_add_rounded, size: 17),
                  label: const Text(
                    '生成画板备忘',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LinuxLocalAsrDialog extends StatefulWidget {
  const _LinuxLocalAsrDialog({required this.controller});

  final NotebookController controller;

  @override
  State<_LinuxLocalAsrDialog> createState() => _LinuxLocalAsrDialogState();
}

class _LinuxLocalAsrDialogState extends State<_LinuxLocalAsrDialog> {
  late final TextEditingController _modelCtrl;
  late final TextEditingController _runtimeCtrl;

  @override
  void initState() {
    super.initState();
    _modelCtrl = TextEditingController(text: widget.controller.localAsrModelPath);
    _runtimeCtrl = TextEditingController(
      text: widget.controller.localAsrRuntimePath,
    );
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _runtimeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AnimatedBuilder(
      animation: c,
      builder: (dialogCtx, child) {
        final status = c.localAsrStatus;
        final dl = c.localAsrDownloadProgress;
        final isDownloading = dl != null && !dl.done;

        return AlertDialog(
          title: const Row(
            children: <Widget>[
              Icon(
                Icons.memory_rounded,
                size: 20,
                color: Color(0xFF4F46E5),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Linux 端侧离线语音模型管理',
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 470,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: status.ready
                          ? const Color(0xFFECFDF5)
                          : const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: status.ready
                            ? const Color(0xFF6EE7B7)
                            : const Color(0xFFFCD34D),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(
                              status.ready
                                  ? Icons.check_circle_rounded
                                  : Icons.info_outline_rounded,
                              size: 16,
                              color: status.ready
                                  ? const Color(0xFF059669)
                                  : const Color(0xFFD97706),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                status.ready
                                    ? '端侧引擎已就绪 · ${status.engineSummary}'
                                    : (status.issueMessage ?? '尚未配置本地模型'),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: status.ready
                                      ? const Color(0xFF065F46)
                                      : const Color(0xFF92400E),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (status.audioTool.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            '采集通道：${status.audioTool}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF475569),
                            ),
                          ),
                        ],
                        if (status.activeModelPath.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            '模型路径：${status.activeModelPath}',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFF475569),
                            ),
                          ),
                        ],
                        if (status.activeRuntimePath.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            '运行时库：${status.activeRuntimePath}',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFF475569),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (dl != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      dl.stage,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: dl.error != null
                            ? const Color(0xFFB91C1C)
                            : const Color(0xFF334155),
                      ),
                    ),
                    const SizedBox(height: 5),
                    LinearProgressIndicator(value: dl.fraction),
                    if (dl.error != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        dl.error!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFFB91C1C),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '使用国内 GitHub 下载加速镜像 (ghfast.top)',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: c.localAsrUseMirror,
                    onChanged: isDownloading
                        ? null
                        : (v) => c.setLocalAsrUseMirror(v),
                  ),
                  const Divider(height: 14),
                  const Text(
                    '推荐端侧实时流式模型（Sherpa-ONNX，本地 CPU 推理）',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final preset in kLinuxAsrModelPresets) ...<Widget>[
                    Builder(
                      builder: (itemCtx) {
                        final isInstalled = status.installedPresetIds.contains(
                          preset.id,
                        );
                        final presetDirPath = status.modelsRootDir.isNotEmpty
                            ? '${status.modelsRootDir}/models/${preset.extractedDirName}'
                            : '';
                        final isActive = status.activeModelPath.isNotEmpty &&
                            presetDirPath.isNotEmpty &&
                            status.activeModelPath == presetDirPath;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isActive
                                ? const Color(0xFFEEF2FF)
                                : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isActive
                                  ? const Color(0xFF818CF8)
                                  : const Color(0xFFE2E8F0),
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Row(
                                      children: <Widget>[
                                        Flexible(
                                          child: Text(
                                            preset.name,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF0F172A),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          preset.sizeLabel,
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            color: Color(0xFF64748B),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      preset.subtitle,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF475569),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonal(
                                key: ValueKey<String>(
                                  'install-asr-preset-${preset.id}',
                                ),
                                onPressed: isDownloading
                                    ? null
                                    : () async {
                                        if (isInstalled &&
                                            status.hasRuntime &&
                                            presetDirPath.isNotEmpty) {
                                          _modelCtrl.text = presetDirPath;
                                          await c.configureLocalAsrPaths(
                                            modelPath: presetDirPath,
                                            runtimePath: _runtimeCtrl.text,
                                          );
                                        } else {
                                          await c.installLinuxLocalAsrPreset(
                                            preset,
                                          );
                                          if (!mounted) return;
                                          _modelCtrl.text = c.localAsrModelPath;
                                          _runtimeCtrl.text =
                                              c.localAsrRuntimePath;
                                        }
                                      },
                                child: Text(
                                  isActive
                                      ? '已启用'
                                      : (isInstalled ? '切换启用' : '下载启用'),
                                  style: const TextStyle(fontSize: 11.5),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                  const Divider(height: 16),
                  const Text(
                    '自定义本地模型路径（支持 Sherpa-ONNX 目录 或 whisper.cpp .bin）',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey<String>(
                      'custom-local-model-path-field',
                    ),
                    controller: _modelCtrl,
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      labelText: '模型目录 或 whisper .bin 文件路径（留空则自动识别预设）',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            tooltip: '选择模型目录 (Sherpa-ONNX)',
                            icon: const Icon(
                              Icons.folder_open_rounded,
                              size: 18,
                            ),
                            onPressed: () async {
                              final picked =
                                  await c.browseAndSelectLocalAsrPath(
                                directory: true,
                              );
                              if (mounted &&
                                  picked != null &&
                                  picked.isNotEmpty) {
                                _modelCtrl.text = picked;
                              }
                            },
                          ),
                          IconButton(
                            tooltip: '选择单文件模型 (.bin / .gguf)',
                            icon: const Icon(
                              Icons.audio_file_rounded,
                              size: 18,
                            ),
                            onPressed: () async {
                              final picked =
                                  await c.browseAndSelectLocalAsrPath(
                                directory: false,
                              );
                              if (mounted &&
                                  picked != null &&
                                  picked.isNotEmpty) {
                                _modelCtrl.text = picked;
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey<String>(
                      'custom-local-runtime-path-field',
                    ),
                    controller: _runtimeCtrl,
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      labelText:
                          '运行时路径（可选：libsherpa-onnx-c-api.so 或 whisper-cli）',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: IconButton(
                        tooltip: '选择运行时文件',
                        icon: const Icon(
                          Icons.settings_applications_rounded,
                          size: 18,
                        ),
                        onPressed: () async {
                          final picked = await c.browseAndSelectLocalAsrPath(
                            directory: false,
                          );
                          if (mounted &&
                              picked != null &&
                              picked.isNotEmpty) {
                            _runtimeCtrl.text = picked;
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: isDownloading
                  ? null
                  : () async {
                      _modelCtrl.clear();
                      _runtimeCtrl.clear();
                      await c.configureLocalAsrPaths(
                        modelPath: '',
                        runtimePath: '',
                      );
                    },
              child: const Text('重置自动识别'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
            FilledButton(
              key: const ValueKey<String>('save-custom-local-asr-btn'),
              onPressed: isDownloading
                  ? null
                  : () async {
                      await c.configureLocalAsrPaths(
                        modelPath: _modelCtrl.text,
                        runtimePath: _runtimeCtrl.text,
                      );
                      if (context.mounted) Navigator.of(context).pop();
                    },
              child: const Text('保存并应用'),
            ),
          ],
        );
      },
    );
  }
}
