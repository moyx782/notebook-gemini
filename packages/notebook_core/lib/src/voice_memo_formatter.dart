enum MemoFormatStyle {
  structuredMarkdown('结构化备忘'),
  cleanParagraphs('连贯正文'),
  bulletOutline('要点清单');

  const MemoFormatStyle(this.label);
  final String label;
}

class VoiceTranscriptSegment {
  const VoiceTranscriptSegment({
    required this.offsetMs,
    required this.text,
  });

  final int offsetMs;
  final String text;

  String get formattedTimestamp => formatVoiceDuration(offsetMs);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'offsetMs': offsetMs,
        'text': text,
      };

  factory VoiceTranscriptSegment.fromJson(Map<String, dynamic> json) {
    return VoiceTranscriptSegment(
      offsetMs: (json['offsetMs'] as num? ?? 0).toInt(),
      text: (json['text'] as String? ?? '').trim(),
    );
  }
}

class VoiceMemoDraft {
  const VoiceMemoDraft({
    required this.title,
    required this.completeMarkdown,
    required this.plainText,
    required this.paragraphs,
    required this.bulletPoints,
    required this.actionItems,
    required this.durationMs,
    required this.segmentCount,
  });

  final String title;
  final String completeMarkdown;
  final String plainText;
  final List<String> paragraphs;
  final List<String> bulletPoints;
  final List<String> actionItems;
  final int durationMs;
  final int segmentCount;
}

String formatVoiceDuration(int durationMs) {
  final totalSeconds = durationMs <= 0 ? 0 : (durationMs / 1000).floor();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$mm:$ss';
  }
  return '$mm:$ss';
}

final RegExp _cjkCharBetweenSpaces =
    RegExp(r'([\u4e00-\u9fff])\s+([\u4e00-\u9fff])');
final RegExp _cjkSpaceBeforePunct = RegExp(r'\s+([，。！？；：、,.!?;:])');
final RegExp _leadingUnspacedInterjection = RegExp(r'^(?:嗯+|呃+)');
final RegExp _leadingSimpleFillers = RegExp(
  r'^(?:嗯+|呃+|额+|啊+|哦+|uh+|um+|er+)(?:[，,、\s]+|$)',
  caseSensitive: false,
);
final RegExp _leadingTicWithPause = RegExp(
  r'^(?:那个(?:\s*那个)+|那个|就是说|然后呢)[，,、\s]+',
);
final RegExp _innerIsolatedFillers = RegExp(
  r'([，,、\s]+)(?:嗯+|呃+|额+|uh+|um+|er+)(?=[，,。！？!?\s]|$)',
  caseSensitive: false,
);
final RegExp _leadingPunct = RegExp(r'^[，,、.。；;:\s]+');
final RegExp _terminalPunct = RegExp(r'[。！？!?；;：:]$');
final RegExp _trailingComma = RegExp(r'[，,、]+$');
final RegExp _discourseMarkerPrefix = RegExp(
  r'^(?:首先|其次|第一|第二|第三|另外|此外|同时|最后|总结|总的来说|所以|因此|但是|不过|需要注意|接下来|下一步|remember|firstly|secondly|finally|however|therefore|next)\b',
  caseSensitive: false,
);
final RegExp _zhQuestionSuffix = RegExp(
  r'(?:吗|呢|么|是不是|对不对|好不好|行不行|能不能|可不可以)$',
);
final RegExp _questionPrefix = RegExp(
  r'^(?:为什么|为何|怎么办|怎么回事|请问|what|why|how|when|where|who|can we|could we|should we|is it|are there)\b',
  caseSensitive: false,
);
final RegExp _actionSentencePattern = RegExp(
  r'(?:待办|需要做|记得|下一步|会后|跟进|安排|截止|todo|action\s*item)',
  caseSensitive: false,
);
final RegExp _actionPrefixCleanup = RegExp(
  r'^(?:待办事项|待办|todo|action\s*item|下一步(?:需要|记得)?|会后(?:需要|记得)?|请记得|记得|需要做)\s*[:：,，]?\s*',
  caseSensitive: false,
);

String _cleanSpokenText(String raw, {required bool removeFillers}) {
  var s = raw
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceAll(RegExp(r' {2,}'), ' ')
      .trim();
  if (s.isEmpty) return '';

  // Clean spoken fillers BEFORE collapsing CJK whitespace so pauses like
  // "嗯 今天" / "那个 那个 下一步" preserve their word boundary signal.
  if (removeFillers) {
    var prev = '';
    while (prev != s) {
      prev = s;
      s = s.replaceFirst(_leadingTicWithPause, '');
      s = s.replaceFirst(_leadingSimpleFillers, '');
      s = s.replaceFirst(_leadingUnspacedInterjection, '');
      s = s.replaceFirst(_leadingPunct, '');
    }
    s = s.replaceAllMapped(_innerIsolatedFillers, (m) => m.group(1)!);
    s = s.replaceFirst(_leadingPunct, '');
  }

  // Remove spurious recognizer spaces between Han characters while keeping English word spacing intact.
  while (_cjkCharBetweenSpaces.hasMatch(s)) {
    s = s.replaceAllMapped(
      _cjkCharBetweenSpaces,
      (m) => '${m.group(1)}${m.group(2)}',
    );
  }
  s = s.replaceAllMapped(_cjkSpaceBeforePunct, (m) => m.group(1)!);

  return s.trim();
}

bool _isAsciiDominant(String text) {
  var latin = 0;
  var cjk = 0;
  for (final code in text.runes) {
    if (code >= 0x4e00 && code <= 0x9fff) {
      cjk += 1;
    } else if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
      latin += 1;
    }
  }
  return latin > cjk * 2;
}

bool _looksLikeQuestion(String text) {
  final stripped = text.replaceFirst(RegExp(r'[？?。！!.,，\s]+$'), '').trim();
  if (stripped.isEmpty) return false;
  if (_zhQuestionSuffix.hasMatch(stripped)) return true;
  if (_questionPrefix.hasMatch(stripped) &&
      !stripped.startsWith('为什么这样说是因为')) {
    return true;
  }
  return false;
}

String _ensureClauseTerminator(String rawClause) {
  final text = rawClause.trim();
  if (text.isEmpty) return '';
  if (_terminalPunct.hasMatch(text)) return text;
  final body = text.replaceFirst(_trailingComma, '').trim();
  if (body.isEmpty) return '';
  final ascii = _isAsciiDominant(body);
  if (_looksLikeQuestion(body)) {
    return '$body${ascii ? '?' : '？'}';
  }
  return '$body${ascii ? '.' : '。'}';
}

class _CleanedSegment {
  const _CleanedSegment({
    required this.offsetMs,
    required this.text,
    required this.gapBeforeMs,
  });

  final int offsetMs;
  final String text;
  final int gapBeforeMs;
}

class _AssembledSentence {
  const _AssembledSentence({
    required this.offsetMs,
    required this.text,
    required this.gapBeforeMs,
    required this.startsWithDiscourse,
  });

  final int offsetMs;
  final String text;
  final int gapBeforeMs;
  final bool startsWithDiscourse;
}

VoiceMemoDraft consolidateVoiceTranscriptToMemo(
  List<VoiceTranscriptSegment> rawSegments, {
  String pendingPartial = '',
  String? customTitle,
  int durationMs = 0,
  DateTime? recordedAt,
  MemoFormatStyle style = MemoFormatStyle.structuredMarkdown,
  bool removeFillers = true,
  bool includeTimestamps = false,
}) {
  final deduped = <VoiceTranscriptSegment>[];

  void pushCandidate(VoiceTranscriptSegment seg) {
    final text = seg.text.trim();
    if (text.isEmpty) return;
    final safeOffset = seg.offsetMs < 0 ? 0 : seg.offsetMs;
    if (deduped.isNotEmpty) {
      final prev = deduped.last;
      final delta = (safeOffset - prev.offsetMs).abs();
      if (delta <= 3000) {
        if (text == prev.text) return;
        if (text.startsWith(prev.text)) {
          deduped[deduped.length - 1] = VoiceTranscriptSegment(
            offsetMs: prev.offsetMs,
            text: text,
          );
          return;
        }
        if (prev.text.endsWith(text) && text.length >= 2) {
          return;
        }
      }
    }
    deduped.add(VoiceTranscriptSegment(offsetMs: safeOffset, text: text));
  }

  for (final seg in rawSegments) {
    pushCandidate(seg);
  }
  if (pendingPartial.trim().isNotEmpty) {
    final partialOffset = durationMs > 0
        ? durationMs
        : (deduped.isNotEmpty ? deduped.last.offsetMs : 0);
    pushCandidate(
      VoiceTranscriptSegment(offsetMs: partialOffset, text: pendingPartial),
    );
  }

  final cleanedSegments = <_CleanedSegment>[];
  var prevOffset = 0;
  for (var i = 0; i < deduped.length; i++) {
    final seg = deduped[i];
    final cleaned = _cleanSpokenText(seg.text, removeFillers: removeFillers);
    if (cleaned.isEmpty) continue;
    final gap = i == 0 ? 0 : (seg.offsetMs - prevOffset).clamp(0, 600000);
    cleanedSegments.add(
      _CleanedSegment(
        offsetMs: seg.offsetMs,
        text: cleaned,
        gapBeforeMs: gap,
      ),
    );
    prevOffset = seg.offsetMs;
  }

  final sentences = <_AssembledSentence>[];
  var i = 0;
  while (i < cleanedSegments.length) {
    var curText = cleanedSegments[i].text;
    final startOffset = cleanedSegments[i].offsetMs;
    final gapBefore = cleanedSegments[i].gapBeforeMs;
    final startsDiscourse = _discourseMarkerPrefix.hasMatch(curText);

    // Join short non-terminal spoken fragments when spoken smoothly without
    // long pauses, never merging across questions or action-item boundaries.
    while (!_terminalPunct.hasMatch(curText) &&
        !_looksLikeQuestion(curText) &&
        !_actionSentencePattern.hasMatch(curText) &&
        curText.length < 12 &&
        i + 1 < cleanedSegments.length &&
        cleanedSegments[i + 1].gapBeforeMs < 1800 &&
        !_looksLikeQuestion(cleanedSegments[i + 1].text) &&
        !_actionSentencePattern.hasMatch(cleanedSegments[i + 1].text) &&
        !_discourseMarkerPrefix.hasMatch(cleanedSegments[i + 1].text)) {
      final base = curText.replaceFirst(_trailingComma, '').trim();
      final next = cleanedSegments[i + 1].text;
      final comma = (_isAsciiDominant(base) && _isAsciiDominant(next))
          ? ', '
          : '，';
      curText = '$base$comma$next';
      i += 1;
    }

    final finalized = _ensureClauseTerminator(curText);
    if (finalized.isNotEmpty) {
      sentences.add(
        _AssembledSentence(
          offsetMs: startOffset,
          text: finalized,
          gapBeforeMs: gapBefore,
          startsWithDiscourse: startsDiscourse,
        ),
      );
    }
    i += 1;
  }

  // Group assembled sentences into coherent paragraphs.
  final paragraphs = <String>[];
  final paraOffsets = <int>[];
  var currentPara = <String>[];
  var currentParaOffset = 0;

  void flushParagraph() {
    if (currentPara.isEmpty) return;
    paragraphs.add(currentPara.join(' '));
    paraOffsets.add(currentParaOffset);
    currentPara = <String>[];
  }

  for (final s in sentences) {
    final shouldBreak = currentPara.isNotEmpty &&
        (s.gapBeforeMs >= 4500 ||
            (s.startsWithDiscourse && currentPara.isNotEmpty) ||
            currentPara.length >= 3);
    if (shouldBreak) {
      flushParagraph();
    }
    if (currentPara.isEmpty) {
      currentParaOffset = s.offsetMs;
    }
    currentPara.add(s.text);
  }
  flushParagraph();

  final actionItems = <String>[];
  final seenTodos = <String>{};
  for (final s in sentences) {
    if (!_actionSentencePattern.hasMatch(s.text)) continue;
    var todo = s.text
        .replaceFirst(_actionPrefixCleanup, '')
        .replaceFirst(RegExp(r'[。！？.!?\s]+$'), '')
        .trim();
    if (todo.isEmpty) {
      todo = s.text.replaceFirst(RegExp(r'[。！？.!?\s]+$'), '').trim();
    }
    if (todo.isNotEmpty && seenTodos.add(todo)) {
      actionItems.add(todo);
    }
  }

  final bulletPoints = sentences
      .map(
        (s) => includeTimestamps
            ? '[${formatVoiceDuration(s.offsetMs)}] ${s.text}'
            : s.text,
      )
      .toList();

  final maxSegmentMs = deduped.isNotEmpty ? deduped.last.offsetMs : 0;
  final effectiveDurationMs = durationMs > 0 ? durationMs : maxSegmentMs;

  final displayParagraphs = <String>[
    for (var p = 0; p < paragraphs.length; p++)
      includeTimestamps
          ? '[${formatVoiceDuration(paraOffsets[p])}] ${paragraphs[p]}'
          : paragraphs[p],
  ];

  final titleCandidate = (customTitle ?? '').trim();
  final derivedTitle = titleCandidate.isNotEmpty
      ? titleCandidate
      : _deriveVoiceMemoTitle(sentences);

  final bodyBuf = StringBuffer();
  switch (style) {
    case MemoFormatStyle.structuredMarkdown:
      final dateStamp = recordedAt == null
          ? ''
          : ' · ${recordedAt.hour.toString().padLeft(2, '0')}:${recordedAt.minute.toString().padLeft(2, '0')}';
      bodyBuf.writeln(
        '> 🎙️ 语音备忘 · 时长 ${formatVoiceDuration(effectiveDurationMs)} · ${sentences.length} 句转写$dateStamp',
      );
      if (displayParagraphs.isNotEmpty) {
        bodyBuf.writeln();
        bodyBuf.writeln(displayParagraphs.join('\n\n'));
      } else {
        bodyBuf.writeln();
        bodyBuf.writeln('（暂无转写内容）');
      }
      if (actionItems.isNotEmpty) {
        bodyBuf.writeln();
        bodyBuf.writeln('### 待办跟进');
        for (final item in actionItems) {
          bodyBuf.writeln('- [ ] $item');
        }
      }
      break;
    case MemoFormatStyle.cleanParagraphs:
      if (displayParagraphs.isNotEmpty) {
        bodyBuf.write(displayParagraphs.join('\n\n'));
      } else {
        bodyBuf.write('（暂无转写内容）');
      }
      break;
    case MemoFormatStyle.bulletOutline:
      if (sentences.isEmpty) {
        bodyBuf.write('- （暂无转写内容）');
      } else {
        for (final s in sentences) {
          final prefix = includeTimestamps
              ? '[${formatVoiceDuration(s.offsetMs)}] '
              : '';
          bodyBuf.writeln('- $prefix${s.text}');
        }
        if (actionItems.isNotEmpty) {
          bodyBuf.writeln();
          bodyBuf.writeln('### 待办跟进');
          for (final item in actionItems) {
            bodyBuf.writeln('- [ ] $item');
          }
        }
      }
      break;
  }

  final completeMarkdown = bodyBuf.toString().trim();
  final plainText = sentences.map((s) => s.text).join(' ').trim();

  return VoiceMemoDraft(
    title: derivedTitle,
    completeMarkdown: completeMarkdown,
    plainText: plainText,
    paragraphs: displayParagraphs,
    bulletPoints: bulletPoints,
    actionItems: actionItems,
    durationMs: effectiveDurationMs,
    segmentCount: deduped.length,
  );
}

String _deriveVoiceMemoTitle(List<_AssembledSentence> sentences) {
  if (sentences.isEmpty) return '语音备忘录';
  var first = sentences.first.text
      .replaceFirst(RegExp(r'[。！？.!?,，、;；\s]+$'), '')
      .replaceFirst(
        RegExp(r'^(?:关于|讨论|今天我们(?:主要|先)?(?:讲一下|讨论|推导|聊聊)?|我们来看看)\s*'),
        '',
      )
      .trim();
  if (first.isEmpty) first = sentences.first.text;
  final commaSplit = first.split(RegExp(r'[，,]'));
  if (commaSplit.isNotEmpty && commaSplit.first.trim().length >= 4) {
    first = commaSplit.first.trim();
  }
  if (first.length > 18) {
    return first.substring(0, 18);
  }
  return first.isEmpty ? '语音备忘录' : first;
}

String buildVoiceMemoAiPolishPrompt(
  String rawTranscript, {
  String? currentDraft,
}) {
  final buf = StringBuffer()
    ..writeln('请将下面这段实时语音转写的口述记录整理成一份条理清晰、完整通顺的中文（或双语）Markdown 文字备忘：')
    ..writeln('要求：')
    ..writeln('1. 保留所有关键事实、数据、结论与专有名词，禁止臆造未提及内容；')
    ..writeln('2. 自动去除口语赘词与重复断句，补全准确标点并合理分段；')
    ..writeln('3. 若包含行动项、截止时间或待办事项，请单独用 `- [ ] ...` 清单列出；')
    ..writeln('4. 首行用 `# 简洁标题` 概括主题，正文直接输出整理后的 Markdown。')
    ..writeln()
    ..writeln('### 原始语音转写')
    ..writeln(rawTranscript.trim());

  if (currentDraft != null && currentDraft.trim().isNotEmpty) {
    buf
      ..writeln()
      ..writeln('### 本地初稿（仅供参考）')
      ..writeln(currentDraft.trim());
  }
  return buf.toString();
}
