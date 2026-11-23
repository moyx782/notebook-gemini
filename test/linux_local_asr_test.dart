import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_canvas_notebook/platform/linux_local_asr.dart';
import 'package:sync_canvas_notebook/platform/platform_adapter_stub.dart';

void main() {
  group('Linux local ASR model inspection & helpers', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('sc_linux_asr_test_');
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('detects Sherpa-ONNX Transducer and prefers int8 checkpoints', () async {
      final dir = Directory('${tempRoot.path}/zipformer_transducer');
      await dir.create(recursive: true);
      await File('${dir.path}/tokens.txt').writeAsString('a 0\nb 1\n');
      await File('${dir.path}/encoder-epoch-99-avg-1.onnx').writeAsBytes([1]);
      await File('${dir.path}/encoder-epoch-99-avg-1.int8.onnx').writeAsBytes([1]);
      await File('${dir.path}/decoder-epoch-99-avg-1.onnx').writeAsBytes([1]);
      await File('${dir.path}/joiner-epoch-99-avg-1.onnx').writeAsBytes([1]);
      await File('${dir.path}/joiner-epoch-99-avg-1.int8.onnx').writeAsBytes([1]);

      final result = inspectLocalAsrModel(dir.path);
      expect(result.isValid, isTrue);
      expect(result.engineKind, LocalAsrEngineKind.sherpaTransducer);
      expect(result.encoderPath, endsWith('encoder-epoch-99-avg-1.int8.onnx'));
      expect(result.decoderPath, endsWith('decoder-epoch-99-avg-1.onnx'));
      expect(result.joinerPath, endsWith('joiner-epoch-99-avg-1.int8.onnx'));
      expect(result.tokensPath, endsWith('tokens.txt'));
    });

    test('detects Paraformer, Zipformer2 CTC, nested folder, and whisper .bin', () async {
      // Paraformer
      final paraDir = Directory('${tempRoot.path}/paraformer');
      await paraDir.create(recursive: true);
      await File('${paraDir.path}/tokens.txt').writeAsString('x 0\n');
      await File('${paraDir.path}/encoder.int8.onnx').writeAsBytes([1]);
      await File('${paraDir.path}/decoder.int8.onnx').writeAsBytes([1]);

      final paraRes = inspectLocalAsrModel(paraDir.path);
      expect(paraRes.isValid, isTrue);
      expect(paraRes.engineKind, LocalAsrEngineKind.sherpaParaformer);

      // Zipformer CTC inside wrapper directory
      final wrapper = Directory('${tempRoot.path}/wrapped_ctc');
      final innerCtc = Directory('${wrapper.path}/nested_model');
      await innerCtc.create(recursive: true);
      await File('${innerCtc.path}/tokens.txt').writeAsString('y 0\n');
      await File('${innerCtc.path}/model.int8.onnx').writeAsBytes([1]);

      final ctcRes = inspectLocalAsrModel(wrapper.path);
      expect(ctcRes.isValid, isTrue);
      expect(ctcRes.engineKind, LocalAsrEngineKind.sherpaZipformerCtc);
      expect(ctcRes.resolvedPath, innerCtc.path);
      expect(ctcRes.ctcModelPath, endsWith('model.int8.onnx'));

      // whisper.cpp .bin and .gguf
      final whisperBin = File('${tempRoot.path}/ggml-base.bin');
      await whisperBin.writeAsBytes([1, 2, 3]);
      final whisperRes = inspectLocalAsrModel(whisperBin.path);
      expect(whisperRes.isValid, isTrue);
      expect(whisperRes.engineKind, LocalAsrEngineKind.whisperCli);
      expect(whisperRes.whisperModelPath, whisperBin.path);

      // Missing tokens.txt fails gracefully
      final broken = Directory('${tempRoot.path}/broken_dir');
      await broken.create(recursive: true);
      await File('${broken.path}/model.onnx').writeAsBytes([1]);
      final brokenRes = inspectLocalAsrModel(broken.path);
      expect(brokenRes.isValid, isFalse);
      expect(brokenRes.engineKind, LocalAsrEngineKind.unknown);
    });

    test('resolves storage dirs, mirror URLs, arch tarballs, and synthetic preset status', () async {
      expect(
        resolveLinuxAsrRootDir(environment: {'XDG_DATA_HOME': '/tmp/xdg_test'}),
        '/tmp/xdg_test/synccanvas/asr',
      );
      expect(
        resolveLinuxAsrRootDir(environment: {'HOME': '/home/alice'}),
        '/home/alice/.local/share/synccanvas/asr',
      );

      const url = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/test.tar.bz2';
      expect(rewriteGithubDownloadUrl(url, useMirror: false), url);
      expect(rewriteGithubDownloadUrl(url, useMirror: true), 'https://ghfast.top/$url');

      expect(resolveLinuxSherpaRuntimeArchiveUrl('x86_64'), kSherpaOnnxLinuxX64Url);
      expect(resolveLinuxSherpaRuntimeArchiveUrl('aarch64'), kSherpaOnnxLinuxArm64Url);
      expect(resolveLinuxSherpaRuntimeArchiveUrl('mips64'), isNull);

      final fakeRoot = Directory('${tempRoot.path}/asr_root');
      final preset = kLinuxAsrModelPresets.first;
      final presetDir = Directory('${fakeRoot.path}/models/${preset.extractedDirName}');
      final runtimeDir = Directory('${fakeRoot.path}/runtime/lib');
      await presetDir.create(recursive: true);
      await runtimeDir.create(recursive: true);
      await File('${presetDir.path}/tokens.txt').writeAsString('z 0\n');
      await File('${presetDir.path}/encoder-epoch-99-avg-1.onnx').writeAsBytes([1]);
      await File('${presetDir.path}/decoder-epoch-99-avg-1.onnx').writeAsBytes([1]);
      await File('${presetDir.path}/joiner-epoch-99-avg-1.onnx').writeAsBytes([1]);
      final cApiFile = File('${runtimeDir.path}/libsherpa-onnx-c-api.so');
      await cApiFile.writeAsBytes([1, 2, 3, 4]);

      final status = await queryLinuxLocalAsrStatus(asrRootDir: fakeRoot.path);
      expect(status.supported, isTrue);
      expect(status.hasModel, isTrue);
      expect(status.hasRuntime, isTrue);
      expect(status.installedPresetIds, contains(preset.id));
      expect(status.activeModelPath, presetDir.path);
      expect(status.activeRuntimePath, cApiFile.path);
      expect(status.engineKind, LocalAsrEngineKind.sherpaTransducer);
    });
  });
}
