import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnostics/diagnostic_log_service.dart';
import '../domain/browser/browser_service.dart';
import '../domain/player/player_service.dart';
import '../domain/audio/audio_models.dart';
import '../domain/speech/speech_models.dart';
import '../domain/speech/speech_core_status.dart';
import '../domain/speech/whisper_model_catalog.dart';
import '../domain/translation/translation_glossary.dart';
import '../domain/translation/translation_service.dart';
import '../features/browser/mobile_browser_service.dart';
import '../features/browser/windows_browser_service.dart';
import '../features/player/media_kit_player_service.dart';
import '../features/player/media_picker.dart';
import '../features/player/mock_services.dart';
import '../features/player/shared_network_media_broker.dart';
import '../features/settings/app_settings.dart';
import '../features/speech/whisper_model_store.dart';
import '../features/translation/deepl_translation_service.dart';
import '../features/translation/local_model_translation_service.dart';
import '../features/translation/system_translation_service.dart';
import '../features/translation/openai_compatible_translation_service.dart';
import '../features/audio/audio_recognition_adapters.dart';
import '../features/audio/ios_audio_decoder.dart';
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

/// Sandbox store the installable weights live in. iOS ships without a model,
/// so this is the only place one can come from there; on Windows the weights
/// published beside the executable still take precedence.
final whisperModelStoreProvider = Provider<WhisperModelStore>(
  (ref) => WhisperModelStore(),
);

/// Path of the weight recognition should load, or null when none is usable.
///
/// Windows keeps its published `models/` directory. iOS has only what the user
/// installed, and falls back to any other installed weight when the selected
/// one is missing - a stored setting naming a model that was never downloaded
/// should not leave recognition dead when another one is right there.
Future<String?> resolveWhisperModelPathAsync(
  List<String> preferredModels,
  WhisperModelStore store,
) async {
  final windowsPath = resolveWhisperModelPath(preferredModels);
  if (windowsPath != null || Platform.isWindows) return windowsPath;
  for (final name in preferredModels) {
    final preferred = whisperModelByFileName(name);
    if (preferred == null) continue;
    final installed = await store.installedPath(preferred);
    if (installed != null) return installed;
  }
  for (final candidate in whisperModelCatalog) {
    final installed = await store.installedPath(candidate);
    if (installed != null) return installed;
  }
  return null;
}

String? resolveWhisperModelPath(List<String> preferredModels) {
  final configured = Platform.environment['AI_VIDEO_WHISPER_MODEL'];
  if (configured != null && File(configured).existsSync()) return configured;
  if (!Platform.isWindows) return null;
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  String modelFile(String fileName) =>
      '$executableDirectory\\models\\$fileName';
  for (final name in preferredModels) {
    final selected = File(modelFile(name));
    if (selected.existsSync()) return selected.path;
  }
  // No preferred model sits in the program directory: fall back to the first
  // installed known model instead of leaving recognition unavailable.
  for (final option in whisperModelOptions) {
    final fallback = File(modelFile(option.fileName));
    if (fallback.existsSync()) return fallback.path;
  }
  return null;
}

WhisperRequestedBackend _whisperRequestedBackend() {
  final configured =
      Platform.environment['AI_VIDEO_WHISPER_BACKEND']?.trim().toLowerCase();
  return switch (configured) {
    'cpu' => WhisperRequestedBackend.cpu,
    'metal' => WhisperRequestedBackend.metal,
    'vulkan' => WhisperRequestedBackend.vulkan,
    'auto' => WhisperRequestedBackend.auto,
    null => Platform.isIOS
        ? WhisperRequestedBackend.metal
        : WhisperRequestedBackend.vulkan,
    _ => Platform.isIOS
        ? WhisperRequestedBackend.metal
        : WhisperRequestedBackend.vulkan,
  };
}

final diagnosticsLogProvider = Provider<DiagnosticLogService>((ref) {
  final logs = DiagnosticLogService();
  logs.info('应用', '诊断日志已启动', {
    '平台': defaultTargetPlatform.name,
    '日志策略': logs.preserveSensitiveDetails ? '测试完整记录' : '正式构建脱敏',
  });
  return logs;
});

final sharedNetworkMediaBrokerProvider = Provider<SharedNetworkMediaBroker>((ref) {
  final broker = SharedNetworkMediaBroker(
    logs: ref.read(diagnosticsLogProvider),
  );
  ref.onDispose(broker.dispose);
  return broker;
});

final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = MediaKitPlayerService(
    logs: ref.read(diagnosticsLogProvider),
    sharedMedia: ref.watch(sharedNetworkMediaBrokerProvider),
  );
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
  if (Platform.isIOS) {
    final decoder = IosAudioDecoder();
    ref.onDispose(decoder.dispose);
    return decoder;
  }
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
  final requestedBackend = _whisperRequestedBackend();
  final recognitionLanguage =
      ref.read(appSettingsProvider).snapshot.recognitionLanguage;
  if (Platform.isIOS) {
    final service = IosWhisperWindowRecognitionService(
      logs: ref.read(diagnosticsLogProvider),
      threads: 4,
      language: recognitionLanguage,
      requestedBackend: requestedBackend,
    );
    ref.read(diagnosticsLogProvider).info('识别音频', 'iOS Whisper 模块初始化', {
      '请求后端': requestedBackend.name,
      '模型位置': 'Application Support/models（由用户在设置中下载）',
    });
    _scheduleWhisperModelBootstrap(service, ref.read(appSettingsProvider),
        ref.read(whisperModelStoreProvider));
    ref.onDispose(service.dispose);
    return service;
  }
  final nativeLibrary = _windowsArtifact(
    'speech_core.dll',
    'AI_VIDEO_SPEECH_CORE_LIBRARY',
  );
  final model = resolveWhisperModelPath(
      ref.read(appSettingsProvider).snapshot.whisperModelPreference);
  final logs = ref.read(diagnosticsLogProvider);
  final WindowRecognitionService service =
      nativeLibrary != null && model != null && File(model).existsSync()
          ? WhisperWindowRecognitionService(
              libraryPath: nativeLibrary,
              modelPath: model,
              logs: logs,
              language: recognitionLanguage,
              threads: 16,
              requestedBackend: requestedBackend,
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
    '请求后端': requestedBackend.name,
  });
  _scheduleWhisperModelBootstrap(service, ref.read(appSettingsProvider),
      ref.read(whisperModelStoreProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// Settings load asynchronously, so the service must be constructed before
/// the persisted model selection is known. This waits for the settings to
/// settle, applies the selected model (no-op when unchanged), and only then
/// loads it — preventing the startup race where the default model wins.
void _scheduleWhisperModelBootstrap(
  WindowRecognitionService service,
  AppSettingsController settings,
  WhisperModelStore store,
) {
  unawaited(() async {
    await settings.ready;
    final path = await resolveWhisperModelPathAsync(
        settings.snapshot.whisperModelPreference, store);
    if (service is WindowRecognitionModelController && path != null) {
      (service as WindowRecognitionModelController).setModel(path);
    }
    if (service is WhisperWindowRecognitionService) {
      await service.prepare();
    } else if (service is IosWhisperWindowRecognitionService) {
      await service.prepare();
    }
  }());
}

final recognitionControllerProvider = Provider<RecognitionController>((ref) {
  final settings = ref.read(appSettingsProvider).snapshot;
  final controller = RecognitionController(
    player: ref.read(playerServiceProvider),
    decoder: ref.read(audioDecoderProvider),
    recognizer: ref.read(windowRecognitionServiceProvider),
    logs: ref.read(diagnosticsLogProvider),
    prefetchMode: settings.prefetchMode,
    sharedMediaBroker: ref.read(sharedNetworkMediaBrokerProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final appSettingsProvider =
    ChangeNotifierProvider<AppSettingsController>((ref) {
  return AppSettingsController.fromEnvironment();
});

TranslationService createTranslationService(AppSettings settings) =>
    switch (settings.translationMode) {
      TranslationMode.deepl => DeepLTranslationService(
          endpoint: settings.deeplEndpoint,
          apiKey: settings.deeplApiKey,
        ),
      TranslationMode.genericApi => OpenAiCompatibleTranslationService(
          endpoint: settings.genericEndpoint,
          apiKey: settings.genericApiKey,
          model: settings.genericModel,
          glossary: parseTranslationGlossary(settings.translationGlossary),
        ),
      TranslationMode.systemTranslation => SystemTranslationService(),
      TranslationMode.localModel => LocalModelTranslationService(
          model: settings.localTranslationModel,
        ),
    };

final translationServiceProvider = Provider<TranslationService>((ref) {
  return createTranslationService(ref.watch(appSettingsProvider).snapshot);
});

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
