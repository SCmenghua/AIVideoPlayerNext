import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnostics/diagnostic_log_service.dart';
import '../domain/browser/browser_service.dart';
import '../domain/player/player_service.dart';
import '../domain/audio/audio_models.dart';
import '../domain/speech/speech_models.dart';
import '../domain/translation/translation_service.dart';
import '../features/browser/mobile_browser_service.dart';
import '../features/browser/windows_browser_service.dart';
import '../features/player/media_kit_player_service.dart';
import '../features/player/media_picker.dart';
import '../features/player/mock_services.dart';
import '../features/audio/audio_recognition_adapters.dart';
import '../features/audio/recognition_controller.dart';
import '../features/audio/windows_audio_decoder.dart';

String? _windowsArtifact(String fileName, String environmentVariable) {
  if (!Platform.isWindows) return null;
  final configured = Platform.environment[environmentVariable];
  if (configured != null && File(configured).existsSync()) return configured;
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  final candidates = <String>[
    '$executableDirectory\\$fileName',
    '$executableDirectory\\ai_$fileName',
    '$executableDirectory\\native\\$fileName',
    '$executableDirectory\\native\\ai_$fileName',
  ];
  for (final candidatePath in candidates) {
    if (File(candidatePath).existsSync()) return candidatePath;
  }
  return null;
}

String? _whisperModelPath() {
  final configured = Platform.environment['AI_VIDEO_WHISPER_MODEL'];
  if (configured != null && File(configured).existsSync()) return configured;
  if (!Platform.isWindows) return null;
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  final candidate = File(
    '$executableDirectory\\models\\'
    'ggml-large-v3-turbo-q5_0.bin',
  );
  return candidate.existsSync() ? candidate.path : null;
}

final diagnosticsLogProvider = Provider<DiagnosticLogService>((ref) {
  final logs = DiagnosticLogService();
  logs.info('应用', '诊断日志已启动', {
    '平台': defaultTargetPlatform.name,
  });
  return logs;
});

final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = MediaKitPlayerService(logs: ref.read(diagnosticsLogProvider));
  ref.onDispose(service.dispose);
  return service;
});

final mediaPickerProvider = Provider<MediaPicker>(
  (ref) => FileSelectorMediaPicker(),
);

final browserServiceProvider = AutoDisposeProvider<BrowserService>((ref) {
  final BrowserService service = defaultTargetPlatform == TargetPlatform.windows
      ? WindowsBrowserService(logs: ref.read(diagnosticsLogProvider))
      : MobileBrowserService(logs: ref.read(diagnosticsLogProvider));
  ref.onDispose(service.dispose);
  return service;
});

final speechRecognitionServiceProvider =
    Provider<SpeechRecognitionService>((ref) {
  final service = MockSpeechRecognitionService();
  ref.onDispose(() async {
    await service.stop();
  });
  return service;
});

final audioDecoderProvider = Provider<AudioDecoder>((ref) {
  final library = _windowsArtifact(
    'audio_decoder.dll',
    'AI_VIDEO_AUDIO_DECODER_LIBRARY',
  );
  final decoder = library == null
      ? UnavailableAudioDecoder(message: '未找到 Windows 音频解码 DLL。')
      : WindowsAudioDecoder(libraryPath: library);
  ref.onDispose(decoder.dispose);
  return decoder;
});

final windowRecognitionServiceProvider =
    Provider<WindowRecognitionService>((ref) {
  final nativeLibrary = _windowsArtifact(
    'speech_core.dll',
    'AI_VIDEO_SPEECH_CORE_LIBRARY',
  );
  final model = _whisperModelPath();
  final logs = ref.read(diagnosticsLogProvider);
  final WindowRecognitionService service =
      nativeLibrary != null && model != null && File(model).existsSync()
          ? WhisperWindowRecognitionService(
              libraryPath: nativeLibrary,
              modelPath: model,
              logs: logs,
              language: 'ja',
              threads: 16,
            )
          : _UnavailableWindowRecognitionService(
              message: nativeLibrary == null
                  ? '未找到 speech_core DLL。'
                  : '未配置本地 Whisper 模型。',
            );
  logs.info('识别音频', 'Whisper 模块初始化', {
    'speech_core DLL': nativeLibrary == null ? '未找到' : '已找到',
    '模型': model == null ? '未找到' : '已找到',
    '模型位置': model,
  });
  if (service is WhisperWindowRecognitionService) {
    unawaited(service.prepare());
  }
  ref.onDispose(service.dispose);
  return service;
});

final recognitionControllerProvider = Provider<RecognitionController>((ref) {
  final controller = RecognitionController(
    player: ref.read(playerServiceProvider),
    decoder: ref.read(audioDecoderProvider),
    recognizer: ref.read(windowRecognitionServiceProvider),
    logs: ref.read(diagnosticsLogProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final translationServiceProvider =
    Provider<TranslationService>((ref) => MockTranslationService());

final playbackSnapshotProvider = StreamProvider<PlaybackSnapshot>((ref) {
  return ref.watch(playerServiceProvider).snapshots;
});

class _UnavailableWindowRecognitionService
    implements WindowRecognitionService, WindowRecognitionStatusProvider {
  const _UnavailableWindowRecognitionService({required this.message});

  final String message;

  @override
  WindowRecognitionStatus get status =>
      WindowRecognitionStatus.unavailable(message: message);

  @override
  Stream<WindowRecognitionStatus> get statuses => const Stream.empty();

  @override
  Future<WindowRecognitionResult> recognize(RecognitionWindow window) async =>
      WindowRecognitionResult(window: window, events: const [], error: message);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
