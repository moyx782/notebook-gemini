import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'platform_adapter_stub.dart';

const String kSherpaOnnxRuntimeVersion = 'v2.0.3';
const String kSherpaOnnxLinuxX64Url =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/sherpa-onnx-v2.0.3-linux-x64-shared-no-tts-lib.tar.bz2';
const String kSherpaOnnxLinuxArm64Url =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/sherpa-onnx-v2.0.3-linux-aarch64-shared-cpu-lib.tar.bz2';

/// Parsed layout of a local ASR model directory or single-file checkpoint.
class InspectedLocalAsrModel {
  const InspectedLocalAsrModel({
    required this.isValid,
    required this.engineKind,
    required this.resolvedPath,
    required this.summary,
    this.tokensPath,
    this.encoderPath,
    this.decoderPath,
    this.joinerPath,
    this.ctcModelPath,
    this.whisperModelPath,
    this.error,
  });

  final bool isValid;
  final LocalAsrEngineKind engineKind;
  final String resolvedPath;
  final String summary;
  final String? tokensPath;
  final String? encoderPath;
  final String? decoderPath;
  final String? joinerPath;
  final String? ctcModelPath;
  final String? whisperModelPath;
  final String? error;
}

/// Resolves the persistent Linux user data folder for SyncCanvas local ASR
/// runtime libraries and downloaded models.
String resolveLinuxAsrRootDir({
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final xdg = env['XDG_DATA_HOME']?.trim();
  if (xdg != null && xdg.isNotEmpty) {
    return '$xdg/synccanvas/asr';
  }
  final home = env['HOME']?.trim();
  if (home != null && home.isNotEmpty) {
    return '$home/.local/share/synccanvas/asr';
  }
  return '${Directory.systemTemp.path}/synccanvas_asr';
}

/// Applies optional mirror rewriting for GitHub release downloads in restricted
/// network regions.
String rewriteGithubDownloadUrl(String originalUrl, {bool useMirror = false}) {
  if (!useMirror) return originalUrl;
  if (originalUrl.startsWith('https://github.com/')) {
    return 'https://ghfast.top/$originalUrl';
  }
  return originalUrl;
}

/// Returns the matching official Sherpa-ONNX shared runtime tarball URL for
/// the current Linux CPU architecture (`x86_64` or `aarch64`), or `null` when
/// unsupported.
String? resolveLinuxSherpaRuntimeArchiveUrl(String machineArch) {
  final arch = machineArch.toLowerCase().trim();
  if (arch == 'x86_64' || arch == 'amd64' || arch == 'x64') {
    return kSherpaOnnxLinuxX64Url;
  }
  if (arch == 'aarch64' || arch == 'arm64') {
    return kSherpaOnnxLinuxArm64Url;
  }
  return null;
}

Future<String> detectLinuxMachineArch() async {
  try {
    final result = await Process.run('uname', const ['-m']);
    if (result.exitCode == 0) {
      return result.stdout.toString().trim();
    }
  } catch (_) {}
  return '';
}

/// Inspects a user-selected or preset-downloaded model path and classifies it
/// as Sherpa-ONNX (`transducer` / `paraformer` / `zipformer2_ctc`) or
/// `whisper.cpp` (`.bin` / `.gguf`).
InspectedLocalAsrModel inspectLocalAsrModel(String rawPath) {
  final path = rawPath.trim();
  if (path.isEmpty) {
    return const InspectedLocalAsrModel(
      isValid: false,
      engineKind: LocalAsrEngineKind.unknown,
      resolvedPath: '',
      summary: '未配置本地模型',
      error: '请下载或选择本地模型目录 / whisper .bin 文件',
    );
  }

  final stat = FileStat.statSync(path);
  if (stat.type == FileSystemEntityType.notFound) {
    return InspectedLocalAsrModel(
      isValid: false,
      engineKind: LocalAsrEngineKind.unknown,
      resolvedPath: path,
      summary: '路径不存在',
      error: '模型路径不存在：$path',
    );
  }

  if (stat.type == FileSystemEntityType.file) {
    final lower = path.toLowerCase();
    final baseName = _basename(path);
    if (lower.endsWith('.bin') || lower.endsWith('.gguf')) {
      return InspectedLocalAsrModel(
        isValid: true,
        engineKind: LocalAsrEngineKind.whisperCli,
        resolvedPath: path,
        summary: 'whisper.cpp ($baseName)',
        whisperModelPath: path,
      );
    }
    return InspectedLocalAsrModel(
      isValid: false,
      engineKind: LocalAsrEngineKind.unknown,
      resolvedPath: path,
      summary: '不支持的文件格式',
      error: '单文件模型仅支持 whisper.cpp 的 .bin / .gguf；Sherpa-ONNX 请选择模型目录。',
    );
  }

  if (stat.type != FileSystemEntityType.directory) {
    return InspectedLocalAsrModel(
      isValid: false,
      engineKind: LocalAsrEngineKind.unknown,
      resolvedPath: path,
      summary: '无效模型路径',
      error: '所选路径既不是模型目录也不是 .bin/.gguf 模型文件：$path',
    );
  }

  final direct = _inspectSherpaDirectory(Directory(path));
  if (direct != null) return direct;

  // Support archives/folders wrapped inside a single subdirectory.
  try {
    for (final entity in Directory(path).listSync(followLinks: false)) {
      if (entity is Directory) {
        final nested = _inspectSherpaDirectory(entity);
        if (nested != null) return nested;
      }
    }
  } catch (_) {}

  return InspectedLocalAsrModel(
    isValid: false,
    engineKind: LocalAsrEngineKind.unknown,
    resolvedPath: path,
    summary: '未识别的模型目录',
    error:
        '目录 $path 中未同时找到 tokens.txt 与流式 .onnx 模型（encoder/decoder/joiner 或 model.onnx）。',
  );
}

InspectedLocalAsrModel? _inspectSherpaDirectory(Directory dir) {
  List<File> files;
  try {
    files = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .toList(growable: false);
  } catch (_) {
    return null;
  }

  if (files.isEmpty) return null;

  String? tokensPath;
  final onnxFiles = <File>[];
  for (final file in files) {
    final name = _basename(file.path).toLowerCase();
    if (name == 'tokens.txt') {
      tokensPath = file.path;
    } else if (name.endsWith('.onnx')) {
      onnxFiles.add(file);
    }
  }
  if (tokensPath == null || onnxFiles.isEmpty) return null;

  String? pickOnnx(bool Function(String lowerName) predicate) {
    final matches = onnxFiles
        .where((f) => predicate(_basename(f.path).toLowerCase()))
        .toList();
    if (matches.isEmpty) return null;
    // Prefer int8 quantized checkpoints over full-precision ones on CPU.
    matches.sort((a, b) {
      final aInt8 = _basename(a.path).toLowerCase().contains('.int8.');
      final bInt8 = _basename(b.path).toLowerCase().contains('.int8.');
      if (aInt8 != bInt8) return aInt8 ? -1 : 1;
      return a.path.compareTo(b.path);
    });
    return matches.first.path;
  }

  final encoder = pickOnnx((n) => n.contains('encoder'));
  final decoder = pickOnnx((n) => n.contains('decoder'));
  final joiner = pickOnnx((n) => n.contains('joiner'));

  final dirName = _basename(dir.path);

  if (encoder != null && decoder != null && joiner != null) {
    return InspectedLocalAsrModel(
      isValid: true,
      engineKind: LocalAsrEngineKind.sherpaTransducer,
      resolvedPath: dir.path,
      summary: 'Sherpa-ONNX 流式 Transducer ($dirName)',
      tokensPath: tokensPath,
      encoderPath: encoder,
      decoderPath: decoder,
      joinerPath: joiner,
    );
  }

  if (encoder != null && decoder != null) {
    return InspectedLocalAsrModel(
      isValid: true,
      engineKind: LocalAsrEngineKind.sherpaParaformer,
      resolvedPath: dir.path,
      summary: 'Sherpa-ONNX 流式 Paraformer ($dirName)',
      tokensPath: tokensPath,
      encoderPath: encoder,
      decoderPath: decoder,
    );
  }

  final ctcModel = pickOnnx(
        (n) =>
            !n.contains('encoder') &&
            !n.contains('decoder') &&
            !n.contains('joiner') &&
            (n.contains('model') || onnxFiles.length == 1),
      ) ??
      (onnxFiles.length == 1 ? onnxFiles.first.path : null);
  if (ctcModel != null) {
    return InspectedLocalAsrModel(
      isValid: true,
      engineKind: LocalAsrEngineKind.sherpaZipformerCtc,
      resolvedPath: dir.path,
      summary: 'Sherpa-ONNX 流式 Zipformer CTC ($dirName)',
      tokensPath: tokensPath,
      ctcModelPath: ctcModel,
    );
  }

  return null;
}

/// Resolves the `libsherpa-onnx-c-api.so` path from a user-specified file/dir,
/// `~/.local/share/synccanvas/asr/runtime`, bundled app `lib/`, or system paths.
Future<String?> resolveSherpaCapiLibraryPath({
  String? customRuntimePath,
  String? asrRootDir,
}) async {
  final root = asrRootDir ?? resolveLinuxAsrRootDir();
  final candidates = <String>[];

  final trimmedCustom = customRuntimePath?.trim();
  if (trimmedCustom != null && trimmedCustom.isNotEmpty) {
    candidates.add(trimmedCustom);
  }

  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add('$exeDir/lib/libsherpa-onnx-c-api.so');
    candidates.add('$exeDir/lib');
  } catch (_) {}

  candidates.add('$root/runtime');
  candidates.add('/usr/local/lib/libsherpa-onnx-c-api.so');
  candidates.add('/usr/lib/libsherpa-onnx-c-api.so');
  candidates.add('/usr/lib/x86_64-linux-gnu/libsherpa-onnx-c-api.so');
  candidates.add('/usr/lib/aarch64-linux-gnu/libsherpa-onnx-c-api.so');

  for (final candidate in candidates) {
    final found = _findSharedLibraryInPath(
      candidate,
      prefix: 'libsherpa-onnx-c-api.so',
    );
    if (found != null) return found;
  }

  final fromWhich = await _findExecutableOnPath('sherpa-onnx');
  if (fromWhich != null) {
    final parentLib = '${File(fromWhich).parent.parent.path}/lib';
    final found = _findSharedLibraryInPath(
      parentLib,
      prefix: 'libsherpa-onnx-c-api.so',
    );
    if (found != null) return found;
  }
  return null;
}

String? _findSharedLibraryInPath(String path, {required String prefix}) {
  final stat = FileStat.statSync(path);
  if (stat.type == FileSystemEntityType.file &&
      _basename(path).startsWith(prefix)) {
    return path;
  }
  if (stat.type != FileSystemEntityType.directory) return null;

  final queue = <({Directory dir, int depth})>[
    (dir: Directory(path), depth: 0),
  ];
  while (queue.isNotEmpty) {
    final item = queue.removeAt(0);
    List<FileSystemEntity> entries;
    try {
      entries = item.dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final entity in entries) {
      if (entity is File && _basename(entity.path) == prefix) {
        return entity.path;
      }
    }
    for (final entity in entries) {
      if (entity is File && _basename(entity.path).startsWith(prefix)) {
        return entity.path;
      }
    }
    if (item.depth < 3) {
      for (final entity in entries) {
        if (entity is Directory) {
          queue.add((dir: entity, depth: item.depth + 1));
        }
      }
    }
  }
  return null;
}

/// Resolves an installed `whisper-cli` / `whisper-cpp` executable for `.bin` /
/// `.gguf` checkpoints.
Future<String?> resolveWhisperCliBinary({
  String? customRuntimePath,
  String? modelPath,
  String? asrRootDir,
}) async {
  final root = asrRootDir ?? resolveLinuxAsrRootDir();
  final candidates = <String>[];

  final custom = customRuntimePath?.trim();
  if (custom != null && custom.isNotEmpty) {
    final customStat = FileStat.statSync(custom);
    if (customStat.type == FileSystemEntityType.file &&
        !custom.endsWith('.so')) {
      candidates.add(custom);
    } else if (customStat.type == FileSystemEntityType.directory) {
      for (final name in const ['whisper-cli', 'whisper-cpp', 'whisper', 'main']) {
        candidates.add('$custom/$name');
      }
    }
  }

  if (modelPath != null && modelPath.trim().isNotEmpty) {
    final parent = File(modelPath.trim()).parent.path;
    candidates.add('$parent/whisper-cli');
    candidates.add('$parent/main');
  }

  candidates.add('$root/runtime/whisper-cli');

  for (final path in candidates) {
    if (FileStat.statSync(path).type == FileSystemEntityType.file) {
      return path;
    }
  }

  for (final bin in const ['whisper-cli', 'whisper-cpp', 'whisper']) {
    final onPath = await _findExecutableOnPath(bin);
    if (onPath != null) return onPath;
  }
  return null;
}

Future<({String executable, List<String> args, String label})?>
    detectLinuxAudioRecordCommand() async {
  if (await _findExecutableOnPath('pw-record') != null) {
    return (
      executable: 'pw-record',
      args: const ['--rate', '16000', '--channels', '1', '--format', 's16', '-'],
      label: 'pw-record (PipeWire)',
    );
  }
  if (await _findExecutableOnPath('parec') != null) {
    return (
      executable: 'parec',
      args: const ['--rate=16000', '--channels=1', '--format=s16le', '--raw'],
      label: 'parec (PulseAudio)',
    );
  }
  if (await _findExecutableOnPath('arecord') != null) {
    return (
      executable: 'arecord',
      args: const ['-q', '-f', 'S16_LE', '-r', '16000', '-c', '1', '-t', 'raw', '-'],
      label: 'arecord (ALSA)',
    );
  }
  return null;
}

Future<String?> _findExecutableOnPath(String command) async {
  try {
    final result = await Process.run('which', [command]);
    if (result.exitCode == 0) {
      final path = result.stdout
          .toString()
          .split('\n')
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      if (path.isNotEmpty) return path;
    }
  } catch (_) {}
  return null;
}

/// Scans the SyncCanvas Linux ASR directory and optional user overrides to
/// report readiness, installed presets, audio capture tool, and diagnostics.
Future<LocalAsrStatus> queryLinuxLocalAsrStatus({
  String? customModelPath,
  String? customRuntimePath,
  String? asrRootDir,
}) async {
  final root = asrRootDir ?? resolveLinuxAsrRootDir();
  final modelsDir = Directory('$root/models');
  final installedPresetIds = <String>[];
  String? firstPresetDir;

  if (modelsDir.existsSync()) {
    for (final preset in kLinuxAsrModelPresets) {
      final dirPath = '${modelsDir.path}/${preset.extractedDirName}';
      if (inspectLocalAsrModel(dirPath).isValid) {
        installedPresetIds.add(preset.id);
        firstPresetDir ??= dirPath;
      }
    }
  }

  final rawModelPath = customModelPath?.trim().isNotEmpty == true
      ? customModelPath!.trim()
      : (firstPresetDir ?? '');
  final inspected = inspectLocalAsrModel(rawModelPath);

  final sherpaLibPath = await resolveSherpaCapiLibraryPath(
    customRuntimePath: customRuntimePath,
    asrRootDir: root,
  );
  final whisperBinPath = await resolveWhisperCliBinary(
    customRuntimePath: customRuntimePath,
    modelPath: inspected.whisperModelPath,
    asrRootDir: root,
  );
  final audioCmd = await detectLinuxAudioRecordCommand();

  final isWhisper = inspected.engineKind == LocalAsrEngineKind.whisperCli;
  final activeRuntime = isWhisper ? (whisperBinPath ?? '') : (sherpaLibPath ?? '');
  final hasRuntime = activeRuntime.isNotEmpty;
  final hasModel = inspected.isValid;
  final hasAudio = audioCmd != null;
  final ready = hasRuntime && hasModel && hasAudio;

  String? issue;
  if (!hasAudio) {
    issue = '未检测到 Linux 录音工具，请安装 pipewire-bin / pulseaudio-utils / alsa-utils';
  } else if (!hasModel) {
    issue = inspected.error ?? '尚未下载或配置本地语音模型';
  } else if (!hasRuntime) {
    issue = isWhisper
        ? '未找到 whisper-cli 可执行文件，请在运行时路径中指定或加入 PATH'
        : '尚未安装 Sherpa-ONNX 原生运行时，点击“一键下载模型”会自动补齐';
  }

  return LocalAsrStatus(
    supported: true,
    ready: ready,
    hasRuntime: hasRuntime,
    hasModel: hasModel,
    engineKind: inspected.engineKind,
    engineSummary: inspected.summary,
    activeModelPath: inspected.isValid ? inspected.resolvedPath : rawModelPath,
    activeRuntimePath: activeRuntime,
    modelsRootDir: root,
    audioTool: audioCmd?.label ?? '未检测到 (需 pw-record / parec / arecord)',
    installedPresetIds: installedPresetIds,
    issueMessage: issue,
  );
}

/// Downloads and unpacks the matching Linux Sherpa-ONNX shared runtime (if
/// missing) plus the requested preset ASR model into `~/.local/share/synccanvas/asr`.
Stream<LocalAsrDownloadProgress> downloadAndInstallLinuxAsrPreset(
  LocalAsrModelPreset preset, {
  bool useMirror = false,
  String? asrRootDir,
}) async* {
  final root = asrRootDir ?? resolveLinuxAsrRootDir();
  final runtimeDir = Directory('$root/runtime');
  final modelsDir = Directory('$root/models');
  await runtimeDir.create(recursive: true);
  await modelsDir.create(recursive: true);

  String? runtimeLib = await resolveSherpaCapiLibraryPath(asrRootDir: root);
  if (runtimeLib == null) {
    final arch = await detectLinuxMachineArch();
    final runtimeUrl = resolveLinuxSherpaRuntimeArchiveUrl(arch);
    if (runtimeUrl == null) {
      yield LocalAsrDownloadProgress(
        stage: '不支持的 CPU 架构: ${arch.isEmpty ? "unknown" : arch}',
        fraction: 0.0,
        done: true,
        error: '预编译 Sherpa-ONNX 仅提供 x86_64 与 aarch64，请手动编译并指定 libsherpa-onnx-c-api.so。',
      );
      return;
    }

    final runtimeTar = File('$root/_runtime.tar.bz2');
    try {
      await for (final dl in _downloadFileWithProgress(
        Uri.parse(rewriteGithubDownloadUrl(runtimeUrl, useMirror: useMirror)),
        runtimeTar,
        stageLabel: '正在下载 Sherpa-ONNX 运行时 ($kSherpaOnnxRuntimeVersion)...',
        scaleStart: 0.02,
        scaleEnd: 0.24,
      )) {
        yield dl;
      }

      yield const LocalAsrDownloadProgress(
        stage: '正在解压 Sherpa-ONNX 原生库...',
        fraction: 0.25,
      );
      await _extractTarBz2(runtimeTar, runtimeDir);
      runtimeLib = await resolveSherpaCapiLibraryPath(asrRootDir: root);
      if (runtimeLib == null) {
        yield const LocalAsrDownloadProgress(
          stage: '运行时校验失败',
          fraction: 0.25,
          done: true,
          error: '解压后未找到 libsherpa-onnx-c-api.so，请检查磁盘空间或权限。',
        );
        return;
      }
    } catch (e) {
      yield LocalAsrDownloadProgress(
        stage: '下载运行时失败',
        fraction: 0.0,
        done: true,
        error: '下载或解压 Sherpa-ONNX 运行时失败: $e',
      );
      return;
    } finally {
      if (runtimeTar.existsSync()) {
        try {
          await runtimeTar.delete();
        } catch (_) {}
      }
    }
  }

  final targetModelDir = Directory('${modelsDir.path}/${preset.extractedDirName}');
  if (!inspectLocalAsrModel(targetModelDir.path).isValid) {
    final modelTar = File('$root/_${preset.id}.tar.bz2');
    try {
      await for (final dl in _downloadFileWithProgress(
        Uri.parse(
          rewriteGithubDownloadUrl(preset.archiveUrl, useMirror: useMirror),
        ),
        modelTar,
        stageLabel: '正在下载模型：${preset.name} (${preset.sizeLabel})...',
        scaleStart: 0.28,
        scaleEnd: 0.90,
      )) {
        yield dl;
      }

      yield LocalAsrDownloadProgress(
        stage: '正在解压模型 ${preset.name}...',
        fraction: 0.92,
      );
      await _extractTarBz2(modelTar, modelsDir);
    } catch (e) {
      yield LocalAsrDownloadProgress(
        stage: '下载模型失败',
        fraction: 0.3,
        done: true,
        error: '下载或解压模型失败: $e',
      );
      return;
    } finally {
      if (modelTar.existsSync()) {
        try {
          await modelTar.delete();
        } catch (_) {}
      }
    }
  }

  final inspected = inspectLocalAsrModel(targetModelDir.path);
  if (!inspected.isValid) {
    yield LocalAsrDownloadProgress(
      stage: '模型校验失败',
      fraction: 0.98,
      done: true,
      error: inspected.error ?? '解压后的模型目录不完整：${targetModelDir.path}',
    );
    return;
  }

  yield LocalAsrDownloadProgress(
    stage: '就绪：${preset.name}',
    fraction: 1.0,
    done: true,
    installedModelPath: inspected.resolvedPath,
    installedRuntimePath: runtimeLib,
  );
}

Stream<LocalAsrDownloadProgress> _downloadFileWithProgress(
  Uri uri,
  File destFile, {
  required String stageLabel,
  required double scaleStart,
  required double scaleEnd,
}) async* {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  IOSink? sink;
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'HTTP ${response.statusCode} while downloading $uri',
        uri: uri,
      );
    }
    final total = response.contentLength;
    sink = destFile.openWrite();
    var received = 0;
    var lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      final now = DateTime.now();
      if (now.difference(lastEmitAt).inMilliseconds >= 120) {
        lastEmitAt = now;
        final pct = (total > 0) ? (received / total).clamp(0.0, 1.0) : null;
        final scaled = pct != null
            ? scaleStart + (scaleEnd - scaleStart) * pct
            : null;
        final mb = (received / (1024 * 1024)).toStringAsFixed(1);
        final totalMb = total > 0
            ? ' / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB'
            : ' MB';
        yield LocalAsrDownloadProgress(
          stage: '$stageLabel ($mb$totalMb)',
          fraction: scaled,
        );
      }
    }
    await sink.flush();
    await sink.close();
    sink = null;
  } finally {
    await sink?.close();
    client.close(force: true);
  }
}

Future<void> _extractTarBz2(File archive, Directory destDir) async {
  final result = await Process.run(
    'tar',
    ['-xjf', archive.path, '-C', destDir.path],
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      'tar',
      ['-xjf', archive.path, '-C', destDir.path],
      '${result.stderr}'.trim(),
      result.exitCode,
    );
  }
}

/// Opens a native Linux file/folder chooser via `zenity` or `kdialog` when
/// available.
Future<String?> pickLinuxPathDialog({required bool directory}) async {
  if (await _findExecutableOnPath('zenity') != null) {
    final args = <String>[
      '--file-selection',
      '--title',
      directory ? '选择 Sherpa-ONNX 模型目录' : '选择本地模型 / 运行时文件',
      if (directory) '--directory',
    ];
    final res = await Process.run('zenity', args);
    if (res.exitCode == 0) {
      final chosen = res.stdout.toString().trim();
      if (chosen.isNotEmpty) return chosen;
    }
    return null;
  }
  if (await _findExecutableOnPath('kdialog') != null) {
    final res = await Process.run(
      'kdialog',
      [directory ? '--getexistingdirectory' : '--getopenfilename', Platform.environment['HOME'] ?? '/'],
    );
    if (res.exitCode == 0) {
      final chosen = res.stdout.toString().trim();
      if (chosen.isNotEmpty) return chosen;
    }
  }
  return null;
}

/// Manages active Linux local microphone ASR sessions (either streaming
/// `Sherpa-ONNX` in a worker `Isolate` via `dart:ffi`, or VAD-chunked
/// `whisper-cli` execution).
class LinuxLocalAsrRunner {
  LinuxLocalAsrRunner({
    required this.onEvent,
  });

  final void Function(VoiceSpeechEvent event) onEvent;

  Isolate? _sherpaIsolate;
  ReceivePort? _sherpaRx;
  SendPort? _sherpaStopPort;
  StreamSubscription<dynamic>? _sherpaSub;
  Completer<void>? _sherpaDoneCompleter;

  Process? _whisperAudioProcess;
  StreamSubscription<List<int>>? _whisperStdoutSub;
  bool _whisperStopping = false;
  Directory? _whisperTempDir;

  bool get isRunning =>
      _sherpaIsolate != null || _whisperAudioProcess != null;

  Future<OperationOutcome> start({
    required String localeId,
    String? customModelPath,
    String? customRuntimePath,
  }) async {
    await stop();

    final status = await queryLinuxLocalAsrStatus(
      customModelPath: customModelPath,
      customRuntimePath: customRuntimePath,
    );
    if (!status.ready) {
      return OperationOutcome(
        ok: false,
        manualRequired: true,
        error: status.issueMessage ?? 'Linux 端侧语音模型尚未就绪',
      );
    }

    final inspected = inspectLocalAsrModel(status.activeModelPath);
    final audioCmd = await detectLinuxAudioRecordCommand();
    if (!inspected.isValid || audioCmd == null) {
      return OperationOutcome(
        ok: false,
        manualRequired: true,
        error: status.issueMessage ?? '本地模型或录音工具不可用',
      );
    }

    if (inspected.engineKind == LocalAsrEngineKind.whisperCli) {
      return _startWhisperSession(
        localeId: localeId,
        whisperBin: status.activeRuntimePath,
        modelFilePath: inspected.whisperModelPath!,
        audioCmd: audioCmd,
      );
    }

    return _startSherpaIsolate(
      cApiPath: status.activeRuntimePath,
      model: inspected,
      audioCmd: audioCmd,
    );
  }

  Future<OperationOutcome> _startSherpaIsolate({
    required String cApiPath,
    required InspectedLocalAsrModel model,
    required ({String executable, List<String> args, String label}) audioCmd,
  }) async {
    final rx = ReceivePort();
    _sherpaRx = rx;
    final startupCompleter = Completer<OperationOutcome>();
    final doneCompleter = Completer<void>();
    _sherpaDoneCompleter = doneCompleter;

    _sherpaSub = rx.listen((dynamic message) {
      if (message is SendPort) {
        _sherpaStopPort = message;
        return;
      }
      if (message is Map) {
        final map = Map<String, dynamic>.from(message);
        final kind = map['kind'] as String?;
        if (kind == 'ready') {
          if (!startupCompleter.isCompleted) {
            startupCompleter.complete(const OperationOutcome(ok: true));
          }
          onEvent(
            VoiceSpeechEvent(
              type: VoiceSpeechEventType.status,
              status: '端侧流式识别中 · ${model.engineKind.label}',
            ),
          );
          return;
        }
        if (kind == 'startupError') {
          final err = map['error'] as String? ?? 'Sherpa-ONNX 启动失败';
          if (!startupCompleter.isCompleted) {
            startupCompleter.complete(
              OperationOutcome(ok: false, manualRequired: true, error: err),
            );
          }
          if (!doneCompleter.isCompleted) {
            doneCompleter.complete();
          }
          return;
        }
        if (kind == 'event') {
          final evType = VoiceSpeechEventType.fromName(map['type'] as String?);
          onEvent(
            VoiceSpeechEvent(
              type: evType,
              text: map['text'] as String? ?? '',
              level: (map['level'] as num? ?? 0.0).toDouble().clamp(0.0, 1.0),
              status: map['status'] as String? ?? '',
              error: map['error'] as String?,
            ),
          );
        } else if (kind == 'done') {
          if (!doneCompleter.isCompleted) {
            doneCompleter.complete();
          }
          unawaited(_cleanupSherpaIsolate());
        }
      }
    });

    try {
      final numThreads = math.min(4, math.max(1, Platform.numberOfProcessors ~/ 2));
      _sherpaIsolate = await Isolate.spawn(
        _sherpaWorkerEntry,
        <String, dynamic>{
          'replyPort': rx.sendPort,
          'cApiPath': cApiPath,
          'tokensPath': model.tokensPath ?? '',
          'encoderPath': model.encoderPath ?? '',
          'decoderPath': model.decoderPath ?? '',
          'joinerPath': model.joinerPath ?? '',
          'ctcModelPath': model.ctcModelPath ?? '',
          'engineKind': model.engineKind.name,
          'numThreads': numThreads,
          'audioExe': audioCmd.executable,
          'audioArgs': audioCmd.args,
        },
        errorsAreFatal: false,
      );
      return await startupCompleter.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () async {
          await stop();
          return const OperationOutcome(
            ok: false,
            error: 'Sherpa-ONNX 模型加载超时，请确认运行时库与模型文件完整。',
          );
        },
      );
    } catch (e) {
      await _cleanupSherpaIsolate();
      return OperationOutcome(
        ok: false,
        manualRequired: true,
        error: '无法启动端侧识别线程: $e',
      );
    }
  }

  Future<OperationOutcome> _startWhisperSession({
    required String localeId,
    required String whisperBin,
    required String modelFilePath,
    required ({String executable, List<String> args, String label}) audioCmd,
  }) async {
    _whisperStopping = false;
    _whisperTempDir = await Directory.systemTemp.createTemp('sc_whisper_');
    try {
      final proc = await Process.start(audioCmd.executable, audioCmd.args);
      _whisperAudioProcess = proc;

      final lang = localeId.toLowerCase().startsWith('zh')
          ? 'zh'
          : (localeId.toLowerCase().startsWith('en') ? 'en' : 'auto');

      onEvent(
        const VoiceSpeechEvent(
          type: VoiceSpeechEventType.status,
          status: '端侧 whisper.cpp 实时分段识别中',
        ),
      );

      final pcmBuffer = BytesBuilder(copy: false);
      int? leftoverByte;
      var speechFrames = 0;
      var trailingSilenceChunks = 0;
      var chunkCounter = 0;
      var inferenceQueue = Future<void>.value();
      var utteranceSeq = 0;

      void enqueueWhisper({
        required Uint8List pcmBytes,
        required bool isFinal,
      }) {
        final dir = _whisperTempDir;
        if (dir == null || pcmBytes.length < 6400) return;
        final seq = ++utteranceSeq;
        inferenceQueue = inferenceQueue.then((_) async {
          if (_whisperStopping && !isFinal) return;
          final wavFile = File('${dir.path}/utt_$seq.wav');
          await wavFile.writeAsBytes(
            _wrapPcmAsWav(pcmBytes, sampleRate: 16000, channels: 1),
            flush: true,
          );
          try {
            final res = await Process.run(
              whisperBin,
              [
                '-m',
                modelFilePath,
                '-l',
                lang,
                '-f',
                wavFile.path,
                '-nt',
                '-np',
              ],
            );
            if (res.exitCode == 0) {
              final cleaned = _cleanWhisperStdout(res.stdout.toString());
              if (cleaned.isNotEmpty) {
                onEvent(
                  VoiceSpeechEvent(
                    type: isFinal
                        ? VoiceSpeechEventType.finalized
                        : VoiceSpeechEventType.partial,
                    text: cleaned,
                  ),
                );
              }
            }
          } catch (e) {
            onEvent(
              VoiceSpeechEvent(
                type: VoiceSpeechEventType.error,
                error: 'whisper-cli 执行失败: $e',
              ),
            );
          } finally {
            if (wavFile.existsSync()) {
              try {
                await wavFile.delete();
              } catch (_) {}
            }
          }
        });
      }

      _whisperStdoutSub = proc.stdout.listen(
        (chunk) {
          if (chunk.isEmpty || _whisperStopping) return;
          final normalized = _normalizeEvenPcmBytes(chunk, leftoverByte);
          leftoverByte = normalized.leftoverByte;
          final aligned = normalized.bytes;
          if (aligned.isEmpty) return;

          final level = _computePcm16RmsLevel(aligned);
          chunkCounter++;
          if (chunkCounter % 2 == 0) {
            onEvent(VoiceSpeechEvent(type: VoiceSpeechEventType.level, level: level));
          }

          pcmBuffer.add(aligned);
          final isSpeech = level >= 0.08;
          if (isSpeech) {
            speechFrames++;
            trailingSilenceChunks = 0;
          } else if (speechFrames > 0) {
            trailingSilenceChunks++;
          } else if (pcmBuffer.length > 16000) {
            // Keep max 0.5s pre-roll while waiting for speech onset.
            final recent = pcmBuffer.takeBytes();
            pcmBuffer.add(recent.sublist(recent.length - 16000));
          }

          final bufferedBytes = pcmBuffer.length;
          // Flush finalized utterance after ~1.1s trailing silence or ~12s max.
          if (speechFrames >= 3 &&
              (trailingSilenceChunks >= 8 || bufferedBytes >= 384000)) {
            final segment = pcmBuffer.takeBytes();
            speechFrames = 0;
            trailingSilenceChunks = 0;
            enqueueWhisper(pcmBytes: segment, isFinal: true);
          } else if (speechFrames >= 5 && chunkCounter % 14 == 0) {
            enqueueWhisper(pcmBytes: pcmBuffer.toBytes(), isFinal: false);
          }
        },
        onDone: () async {
          final remaining = pcmBuffer.takeBytes();
          if (speechFrames >= 2 && remaining.length >= 6400) {
            enqueueWhisper(pcmBytes: remaining, isFinal: true);
          }
          await inferenceQueue;
          onEvent(
            const VoiceSpeechEvent(
              type: VoiceSpeechEventType.status,
              status: 'stopped',
            ),
          );
        },
      );

      unawaited(
        proc.exitCode.then((_) {
          if (!_whisperStopping) {
            _whisperStopping = true;
          }
        }),
      );

      return const OperationOutcome(ok: true);
    } catch (e) {
      await stop();
      return OperationOutcome(
        ok: false,
        manualRequired: true,
        error: '无法启动麦克风录音或 whisper-cli: $e',
      );
    }
  }

  Future<void> stop() async {
    final stopPort = _sherpaStopPort;
    final doneCompleter = _sherpaDoneCompleter;
    if (stopPort != null) {
      _sherpaStopPort = null;
      stopPort.send('stop');
      if (doneCompleter != null && !doneCompleter.isCompleted) {
        await doneCompleter.future.timeout(
          const Duration(milliseconds: 900),
          onTimeout: () {},
        );
      }
    }
    await _cleanupSherpaIsolate();

    if (_whisperAudioProcess != null || _whisperStdoutSub != null) {
      _whisperStopping = true;
      try {
        _whisperAudioProcess?.kill(ProcessSignal.sigterm);
      } catch (_) {}
      await _whisperStdoutSub?.cancel();
      _whisperStdoutSub = null;
      _whisperAudioProcess = null;
    }
    if (_whisperTempDir != null) {
      try {
        await _whisperTempDir!.delete(recursive: true);
      } catch (_) {}
      _whisperTempDir = null;
    }
  }

  Future<void> _cleanupSherpaIsolate() async {
    _sherpaStopPort = null;
    if (_sherpaDoneCompleter != null && !_sherpaDoneCompleter!.isCompleted) {
      _sherpaDoneCompleter!.complete();
    }
    _sherpaDoneCompleter = null;
    await _sherpaSub?.cancel();
    _sherpaSub = null;
    _sherpaRx?.close();
    _sherpaRx = null;
    _sherpaIsolate?.kill(priority: Isolate.immediate);
    _sherpaIsolate = null;
  }
}

// ---------------------------------------------------------------------------
// Sherpa-ONNX C API structs (matching sherpa-onnx/c-api/c-api.h v2.0.3)
// ---------------------------------------------------------------------------

final class _SherpaOnlineRecognizer extends Opaque {}

final class _SherpaOnlineStream extends Opaque {}

final class _SherpaOnlineTransducerModelConfig extends Struct {
  external Pointer<Uint8> encoder;
  external Pointer<Uint8> decoder;
  external Pointer<Uint8> joiner;
}

final class _SherpaOnlineParaformerModelConfig extends Struct {
  external Pointer<Uint8> encoder;
  external Pointer<Uint8> decoder;
}

final class _SherpaOnlineZipformer2CtcModelConfig extends Struct {
  external Pointer<Uint8> model;
}

final class _SherpaOnlineNemoCtcModelConfig extends Struct {
  external Pointer<Uint8> model;
}

final class _SherpaOnlineToneCtcModelConfig extends Struct {
  external Pointer<Uint8> model;
}

final class _SherpaOnlineModelConfig extends Struct {
  external _SherpaOnlineTransducerModelConfig transducer;
  external _SherpaOnlineParaformerModelConfig paraformer;
  external _SherpaOnlineZipformer2CtcModelConfig zipformer2Ctc;
  external Pointer<Uint8> tokens;
  @Int32()
  external int numThreads;
  external Pointer<Uint8> provider;
  @Int32()
  external int debug;
  external Pointer<Uint8> modelType;
  external Pointer<Uint8> modelingUnit;
  external Pointer<Uint8> bpeVocab;
  external Pointer<Uint8> tokensBuf;
  @Int32()
  external int tokensBufSize;
  external _SherpaOnlineNemoCtcModelConfig nemoCtc;
  external _SherpaOnlineToneCtcModelConfig tOneCtc;
}

final class _SherpaFeatureConfig extends Struct {
  @Int32()
  external int sampleRate;
  @Int32()
  external int featureDim;
}

final class _SherpaOnlineCtcFstDecoderConfig extends Struct {
  external Pointer<Uint8> graph;
  @Int32()
  external int maxActive;
}

final class _SherpaHomophoneReplacerConfig extends Struct {
  external Pointer<Uint8> dictDir;
  external Pointer<Uint8> lexicon;
  external Pointer<Uint8> ruleFsts;
}

final class _SherpaOnlineRecognizerConfig extends Struct {
  external _SherpaFeatureConfig featConfig;
  external _SherpaOnlineModelConfig modelConfig;
  external Pointer<Uint8> decodingMethod;
  @Int32()
  external int maxActivePaths;
  @Int32()
  external int enableEndpoint;
  @Float()
  external double rule1MinTrailingSilence;
  @Float()
  external double rule2MinTrailingSilence;
  @Float()
  external double rule3MinUtteranceLength;
  external Pointer<Uint8> hotwordsFile;
  @Float()
  external double hotwordsScore;
  external _SherpaOnlineCtcFstDecoderConfig ctcFstDecoderConfig;
  external Pointer<Uint8> ruleFsts;
  external Pointer<Uint8> ruleFars;
  @Float()
  external double blankPenalty;
  external Pointer<Uint8> hotwordsBuf;
  @Int32()
  external int hotwordsBufSize;
  external _SherpaHomophoneReplacerConfig hr;
}

typedef _CallocNative = Pointer<Void> Function(Size num, Size size);
typedef _CallocDart = Pointer<Void> Function(int num, int size);
typedef _FreeNative = Void Function(Pointer<Void> ptr);
typedef _FreeDart = void Function(Pointer<Void> ptr);

typedef _CreateOnlineRecNative = Pointer<_SherpaOnlineRecognizer> Function(
  Pointer<_SherpaOnlineRecognizerConfig>,
);
typedef _CreateOnlineRecDart = Pointer<_SherpaOnlineRecognizer> Function(
  Pointer<_SherpaOnlineRecognizerConfig>,
);

typedef _DestroyOnlineRecNative = Void Function(Pointer<_SherpaOnlineRecognizer>);
typedef _DestroyOnlineRecDart = void Function(Pointer<_SherpaOnlineRecognizer>);

typedef _CreateOnlineStreamNative = Pointer<_SherpaOnlineStream> Function(
  Pointer<_SherpaOnlineRecognizer>,
);
typedef _CreateOnlineStreamDart = Pointer<_SherpaOnlineStream> Function(
  Pointer<_SherpaOnlineRecognizer>,
);

typedef _DestroyOnlineStreamNative = Void Function(Pointer<_SherpaOnlineStream>);
typedef _DestroyOnlineStreamDart = void Function(Pointer<_SherpaOnlineStream>);

typedef _AcceptWaveformNative = Void Function(
  Pointer<_SherpaOnlineStream>,
  Int32,
  Pointer<Float>,
  Int32,
);
typedef _AcceptWaveformDart = void Function(
  Pointer<_SherpaOnlineStream>,
  int,
  Pointer<Float>,
  int,
);

typedef _IsStreamReadyNative = Int32 Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);
typedef _IsStreamReadyDart = int Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);

typedef _DecodeStreamNative = Void Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);
typedef _DecodeStreamDart = void Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);

typedef _GetResultJsonNative = Pointer<Uint8> Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);
typedef _GetResultJsonDart = Pointer<Uint8> Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);

typedef _DestroyResultJsonNative = Void Function(Pointer<Uint8>);
typedef _DestroyResultJsonDart = void Function(Pointer<Uint8>);

typedef _ResetStreamNative = Void Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);
typedef _ResetStreamDart = void Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);

typedef _InputFinishedNative = Void Function(Pointer<_SherpaOnlineStream>);
typedef _InputFinishedDart = void Function(Pointer<_SherpaOnlineStream>);

typedef _IsEndpointNative = Int32 Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);
typedef _IsEndpointDart = int Function(
  Pointer<_SherpaOnlineRecognizer>,
  Pointer<_SherpaOnlineStream>,
);

class _NativeArena {
  _NativeArena() {
    DynamicLibrary libc;
    try {
      libc = DynamicLibrary.process();
      calloc = libc.lookupFunction<_CallocNative, _CallocDart>('calloc');
      free = libc.lookupFunction<_FreeNative, _FreeDart>('free');
    } catch (_) {
      libc = DynamicLibrary.open('libc.so.6');
      calloc = libc.lookupFunction<_CallocNative, _CallocDart>('calloc');
      free = libc.lookupFunction<_FreeNative, _FreeDart>('free');
    }
  }

  late final _CallocDart calloc;
  late final _FreeDart free;
  final List<Pointer<Void>> _allocations = <Pointer<Void>>[];

  Pointer<T> allocateStruct<T extends NativeType>(int byteCount) {
    final ptr = calloc(1, byteCount);
    _allocations.add(ptr);
    return ptr.cast<T>();
  }

  Pointer<Float> allocateFloatArray(int length) {
    final ptr = calloc(length, sizeOf<Float>());
    _allocations.add(ptr);
    return ptr.cast<Float>();
  }

  Pointer<Uint8> allocateUtf8(String text) {
    final bytes = utf8.encode(text);
    final ptr = calloc(bytes.length + 1, 1).cast<Uint8>();
    _allocations.add(ptr.cast<Void>());
    for (var i = 0; i < bytes.length; i++) {
      ptr[i] = bytes[i];
    }
    ptr[bytes.length] = 0;
    return ptr;
  }

  void releaseAll() {
    for (final ptr in _allocations) {
      free(ptr);
    }
    _allocations.clear();
  }
}

void _preloadSiblingOnnxRuntime(String cApiPath) {
  final dir = File(cApiPath).parent;
  if (!dir.existsSync()) return;
  try {
    final libs = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => _basename(f.path).startsWith('libonnxruntime.so'))
        .toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final lib in libs) {
      try {
        DynamicLibrary.open(lib.path);
      } catch (_) {}
    }
  } catch (_) {}
}

String _readUtf8CString(Pointer<Uint8> ptr) {
  if (ptr == nullptr) return '';
  final bytes = <int>[];
  var i = 0;
  while (i < 1024 * 1024) {
    final b = ptr[i];
    if (b == 0) break;
    bytes.add(b);
    i++;
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Future<void> _sherpaWorkerEntry(Map<String, dynamic> init) async {
  final replyPort = init['replyPort'] as SendPort;
  final controlPort = ReceivePort();
  replyPort.send(controlPort.sendPort);

  final cApiPath = init['cApiPath'] as String;
  final tokensPath = init['tokensPath'] as String;
  final encoderPath = init['encoderPath'] as String;
  final decoderPath = init['decoderPath'] as String;
  final joinerPath = init['joinerPath'] as String;
  final ctcModelPath = init['ctcModelPath'] as String;
  final engineKindName = init['engineKind'] as String;
  final numThreads = init['numThreads'] as int;
  final audioExe = init['audioExe'] as String;
  final audioArgs = List<String>.from(init['audioArgs'] as List);

  final arena = _NativeArena();
  DynamicLibrary? sherpaLib;
  Pointer<_SherpaOnlineRecognizer> recognizer = nullptr;
  Pointer<_SherpaOnlineStream> stream = nullptr;
  Process? audioProc;
  StreamSubscription<List<int>>? stdoutSub;

  try {
    _preloadSiblingOnnxRuntime(cApiPath);
    sherpaLib = DynamicLibrary.open(cApiPath);

    final createRec = sherpaLib.lookupFunction<_CreateOnlineRecNative, _CreateOnlineRecDart>(
      'SherpaOnnxCreateOnlineRecognizer',
    );
    final destroyRec = sherpaLib.lookupFunction<_DestroyOnlineRecNative, _DestroyOnlineRecDart>(
      'SherpaOnnxDestroyOnlineRecognizer',
    );
    final createStream = sherpaLib.lookupFunction<_CreateOnlineStreamNative, _CreateOnlineStreamDart>(
      'SherpaOnnxCreateOnlineStream',
    );
    final destroyStream = sherpaLib.lookupFunction<_DestroyOnlineStreamNative, _DestroyOnlineStreamDart>(
      'SherpaOnnxDestroyOnlineStream',
    );
    final acceptWaveform = sherpaLib.lookupFunction<_AcceptWaveformNative, _AcceptWaveformDart>(
      'SherpaOnnxOnlineStreamAcceptWaveform',
    );
    final isReady = sherpaLib.lookupFunction<_IsStreamReadyNative, _IsStreamReadyDart>(
      'SherpaOnnxIsOnlineStreamReady',
    );
    final decodeStream = sherpaLib.lookupFunction<_DecodeStreamNative, _DecodeStreamDart>(
      'SherpaOnnxDecodeOnlineStream',
    );
    final getResultJson = sherpaLib.lookupFunction<_GetResultJsonNative, _GetResultJsonDart>(
      'SherpaOnnxGetOnlineStreamResultAsJson',
    );
    final destroyResultJson = sherpaLib.lookupFunction<_DestroyResultJsonNative, _DestroyResultJsonDart>(
      'SherpaOnnxDestroyOnlineStreamResultJson',
    );
    final resetStream = sherpaLib.lookupFunction<_ResetStreamNative, _ResetStreamDart>(
      'SherpaOnnxOnlineStreamReset',
    );
    final inputFinished = sherpaLib.lookupFunction<_InputFinishedNative, _InputFinishedDart>(
      'SherpaOnnxOnlineStreamInputFinished',
    );
    final isEndpoint = sherpaLib.lookupFunction<_IsEndpointNative, _IsEndpointDart>(
      'SherpaOnnxOnlineStreamIsEndpoint',
    );

    final emptyStr = arena.allocateUtf8('');
    final cfgPtr = arena.allocateStruct<_SherpaOnlineRecognizerConfig>(
      sizeOf<_SherpaOnlineRecognizerConfig>(),
    );
    final cfg = cfgPtr.ref;

    cfg.featConfig.sampleRate = 16000;
    cfg.featConfig.featureDim = 80;

    cfg.modelConfig.transducer.encoder = emptyStr;
    cfg.modelConfig.transducer.decoder = emptyStr;
    cfg.modelConfig.transducer.joiner = emptyStr;
    cfg.modelConfig.paraformer.encoder = emptyStr;
    cfg.modelConfig.paraformer.decoder = emptyStr;
    cfg.modelConfig.zipformer2Ctc.model = emptyStr;
    cfg.modelConfig.nemoCtc.model = emptyStr;
    cfg.modelConfig.tOneCtc.model = emptyStr;

    if (engineKindName == LocalAsrEngineKind.sherpaParaformer.name) {
      cfg.modelConfig.paraformer.encoder = arena.allocateUtf8(encoderPath);
      cfg.modelConfig.paraformer.decoder = arena.allocateUtf8(decoderPath);
    } else if (engineKindName == LocalAsrEngineKind.sherpaZipformerCtc.name) {
      cfg.modelConfig.zipformer2Ctc.model = arena.allocateUtf8(ctcModelPath);
    } else {
      cfg.modelConfig.transducer.encoder = arena.allocateUtf8(encoderPath);
      cfg.modelConfig.transducer.decoder = arena.allocateUtf8(decoderPath);
      cfg.modelConfig.transducer.joiner = arena.allocateUtf8(joinerPath);
    }

    cfg.modelConfig.tokens = arena.allocateUtf8(tokensPath);
    cfg.modelConfig.numThreads = numThreads;
    cfg.modelConfig.provider = arena.allocateUtf8('cpu');
    cfg.modelConfig.debug = 0;
    cfg.modelConfig.modelType = emptyStr;
    cfg.modelConfig.modelingUnit = emptyStr;
    cfg.modelConfig.bpeVocab = emptyStr;
    cfg.modelConfig.tokensBuf = emptyStr;
    cfg.modelConfig.tokensBufSize = 0;

    cfg.decodingMethod = arena.allocateUtf8('greedy_search');
    cfg.maxActivePaths = 4;
    cfg.enableEndpoint = 1;
    cfg.rule1MinTrailingSilence = 2.4;
    cfg.rule2MinTrailingSilence = 1.2;
    cfg.rule3MinUtteranceLength = 20.0;
    cfg.hotwordsFile = emptyStr;
    cfg.hotwordsScore = 1.5;
    cfg.ctcFstDecoderConfig.graph = emptyStr;
    cfg.ctcFstDecoderConfig.maxActive = 3000;
    cfg.ruleFsts = emptyStr;
    cfg.ruleFars = emptyStr;
    cfg.blankPenalty = 0.0;
    cfg.hotwordsBuf = emptyStr;
    cfg.hotwordsBufSize = 0;
    cfg.hr.dictDir = emptyStr;
    cfg.hr.lexicon = emptyStr;
    cfg.hr.ruleFsts = emptyStr;

    recognizer = createRec(cfgPtr);
    if (recognizer == nullptr) {
      replyPort.send({
        'kind': 'startupError',
        'error': 'Sherpa-ONNX 初始化识别器失败，请确认模型文件与 C API 版本匹配。',
      });
      return;
    }

    stream = createStream(recognizer);
    if (stream == nullptr) {
      destroyRec(recognizer);
      recognizer = nullptr;
      replyPort.send({
        'kind': 'startupError',
        'error': 'Sherpa-ONNX 创建识别流失败。',
      });
      return;
    }

    audioProc = await Process.start(audioExe, audioArgs);
    final stderrBuf = StringBuffer();
    final stderrSub = audioProc.stderr.transform(utf8.decoder).listen((chunk) {
      if (stderrBuf.length < 1024) {
        stderrBuf.write(chunk);
      }
    });
    replyPort.send({'kind': 'ready'});

    const int maxChunkSamples = 4096;
    final floatScratch = arena.allocateFloatArray(maxChunkSamples);
    final pcmAcc = BytesBuilder(copy: false);
    int? leftoverByte;
    var lastPartial = '';
    var stopping = false;
    final finishCompleter = Completer<void>();

    String readStreamText() {
      final jsonPtr = getResultJson(recognizer, stream);
      if (jsonPtr == nullptr) return '';
      try {
        final raw = _readUtf8CString(jsonPtr);
        if (raw.isEmpty) return '';
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          return (parsed['text'] as String? ?? '').trim();
        }
      } catch (_) {} finally {
        destroyResultJson(jsonPtr);
      }
      return '';
    }

    void decodeAvailable({required double level}) {
      while (isReady(recognizer, stream) != 0) {
        decodeStream(recognizer, stream);
      }
      final text = readStreamText();
      if (isEndpoint(recognizer, stream) != 0) {
        if (text.isNotEmpty) {
          replyPort.send({
            'kind': 'event',
            'type': 'finalized',
            'text': text,
            'level': level,
          });
        }
        resetStream(recognizer, stream);
        lastPartial = '';
      } else if (text != lastPartial) {
        lastPartial = text;
        replyPort.send({
          'kind': 'event',
          'type': 'partial',
          'text': text,
          'level': level,
        });
      }
    }

    controlPort.listen((msg) {
      if (msg == 'stop' && !stopping) {
        stopping = true;
        try {
          audioProc?.kill(ProcessSignal.sigterm);
        } catch (_) {}
      }
    });

    stdoutSub = audioProc.stdout.listen(
      (chunk) {
        if (stopping || chunk.isEmpty) return;
        pcmAcc.add(chunk);
        // Process ~80ms (2560 bytes = 1280 samples at 16kHz s16le) per batch.
        if (pcmAcc.length < 2560) return;

        final raw = pcmAcc.takeBytes();
        final norm = _normalizeEvenPcmBytes(raw, leftoverByte);
        leftoverByte = norm.leftoverByte;
        final aligned = norm.bytes;
        if (aligned.isEmpty) return;

        final totalSamples = aligned.length ~/ 2;
        final level = _computePcm16RmsLevel(aligned);
        final byteView = ByteData.sublistView(aligned);

        var offset = 0;
        while (offset < totalSamples) {
          final count = math.min(maxChunkSamples, totalSamples - offset);
          for (var i = 0; i < count; i++) {
            final s = byteView.getInt16((offset + i) * 2, Endian.little);
            floatScratch[i] = s / 32768.0;
          }
          acceptWaveform(stream, 16000, floatScratch, count);
          offset += count;
        }

        decodeAvailable(level: level);
      },
      onDone: () async {
        final tail = pcmAcc.takeBytes();
        if (tail.isNotEmpty) {
          final norm = _normalizeEvenPcmBytes(tail, leftoverByte);
          final aligned = norm.bytes;
          if (aligned.isNotEmpty) {
            final byteView = ByteData.sublistView(aligned);
            final totalSamples = aligned.length ~/ 2;
            var offset = 0;
            while (offset < totalSamples) {
              final count = math.min(maxChunkSamples, totalSamples - offset);
              for (var i = 0; i < count; i++) {
                final s = byteView.getInt16((offset + i) * 2, Endian.little);
                floatScratch[i] = s / 32768.0;
              }
              acceptWaveform(stream, 16000, floatScratch, count);
              offset += count;
            }
          }
        }
        inputFinished(stream);
        while (isReady(recognizer, stream) != 0) {
          decodeStream(recognizer, stream);
        }
        final finalText = readStreamText();
        if (finalText.isNotEmpty) {
          replyPort.send({
            'kind': 'event',
            'type': 'finalized',
            'text': finalText,
            'level': 0.0,
          });
        }
        if (!stopping) {
          final code = await audioProc!.exitCode.timeout(
            const Duration(milliseconds: 250),
            onTimeout: () => 0,
          );
          final errMsg = stderrBuf.toString().trim();
          if (code != 0) {
            replyPort.send({
              'kind': 'event',
              'type': 'error',
              'error': errMsg.isNotEmpty
                  ? '录音进程异常 ($audioExe, exit $code): $errMsg'
                  : '录音进程异常退出 ($audioExe, exit $code)',
            });
          }
        }
        replyPort.send({
          'kind': 'event',
          'type': 'status',
          'status': 'stopped',
          'level': 0.0,
        });
        if (!finishCompleter.isCompleted) {
          finishCompleter.complete();
        }
      },
      onError: (Object err) {
        replyPort.send({
          'kind': 'event',
          'type': 'error',
          'error': '音频采集流异常: $err',
        });
        if (!finishCompleter.isCompleted) {
          finishCompleter.complete();
        }
      },
    );

    await finishCompleter.future;
    await stderrSub.cancel();
    await stdoutSub.cancel();
    if (stream != nullptr) {
      destroyStream(stream);
      stream = nullptr;
    }
    if (recognizer != nullptr) {
      destroyRec(recognizer);
      recognizer = nullptr;
    }
  } catch (e) {
    replyPort.send({
      'kind': 'startupError',
      'error': '加载 Sherpa-ONNX 失败 ($cApiPath): $e',
    });
  } finally {
    try {
      audioProc?.kill();
    } catch (_) {}
    await stdoutSub?.cancel();
    controlPort.close();
    arena.releaseAll();
    replyPort.send({'kind': 'done'});
  }
}

({Uint8List bytes, int? leftoverByte}) _normalizeEvenPcmBytes(
  List<int> rawChunk,
  int? previousLeftover,
) {
  final builder = BytesBuilder(copy: false);
  if (previousLeftover != null) {
    builder.addByte(previousLeftover);
  }
  builder.add(rawChunk);
  final combined = builder.takeBytes();
  if (combined.isEmpty) {
    return (bytes: Uint8List(0), leftoverByte: null);
  }
  if (combined.length.isOdd) {
    return (
      bytes: Uint8List.sublistView(combined, 0, combined.length - 1),
      leftoverByte: combined.last,
    );
  }
  return (bytes: combined, leftoverByte: null);
}

double _computePcm16RmsLevel(Uint8List pcm16Bytes) {
  final sampleCount = pcm16Bytes.length ~/ 2;
  if (sampleCount == 0) return 0.0;
  final view = ByteData.sublistView(pcm16Bytes);
  var sumSquares = 0.0;
  for (var i = 0; i < sampleCount; i++) {
    final norm = view.getInt16(i * 2, Endian.little) / 32768.0;
    sumSquares += norm * norm;
  }
  final rms = math.sqrt(sumSquares / sampleCount);
  return (rms * 4.5).clamp(0.0, 1.0);
}

Uint8List _wrapPcmAsWav(
  Uint8List pcmBytes, {
  required int sampleRate,
  required int channels,
}) {
  final header = ByteData(44);
  final byteRate = sampleRate * channels * 2;
  final blockAlign = channels * 2;
  final totalDataLen = pcmBytes.length;

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  header.setUint32(4, 36 + totalDataLen, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  header.setUint32(40, totalDataLen, Endian.little);

  final out = Uint8List(44 + totalDataLen);
  out.setRange(0, 44, header.buffer.asUint8List());
  out.setRange(44, 44 + totalDataLen, pcmBytes);
  return out;
}

String _cleanWhisperStdout(String raw) {
  return raw
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'^\[[^\]]+\]\s*'), '').trim())
      .where((line) => line.isNotEmpty)
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final idx = normalized.lastIndexOf('/');
  return idx >= 0 ? normalized.substring(idx + 1) : normalized;
}
