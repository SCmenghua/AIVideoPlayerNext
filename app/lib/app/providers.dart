import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recognition/recognition.dart';

import '../core/diagnostics/diagnostic_log_service.dart';
import '../domain/browser/browser_service.dart';
import '../domain/player/player_service.dart';
import '../domain/translation/translation_service.dart';
import '../features/browser/mobile_browser_service.dart';
import '../features/browser/windows_browser_service.dart';
import '../features/player/media_kit_player_service.dart';
import '../features/player/media_picker.dart';
import '../features/player/shared_network_media_broker.dart';
import '../features/recognition/ios_pcm_source.dart';
import '../features/recognition/recognition_media_resolver.dart';
import '../features/recognition/recognition_service.dart';
import '../features/recognition/transcript_store.dart';
import '../features/recognition/whisper_model_store.dart';
import '../features/recognition/windows_pcm_source.dart';
import '../features/settings/app_settings.dart';
import '../features/translation/deepl_translation_service.dart';
import '../features/translation/local_model_translation_service.dart';
import '../features/translation/openai_compatible_translation_service.dart';
import '../features/translation/system_translation_service.dart';

String? _windowsArtifact(String fileName, String environmentVariable) {
  if (!Platform.isWindows) return null;
  final configured = Platform.environment[environmentVariable];
  if (configured != null && File(configured).existsSync()) return configured;
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  for (final candidate in [
    '$executableDirectory\\$fileName',
    '$executableDirectory\\ai_$fileName',
    '$executableDirectory\\native\\$fileName',
    '$executableDirectory\\native\\ai_$fileName',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

String? speechCoreLibraryPath() {
  if (Platform.isIOS || Platform.isMacOS) return '@process';
  return _windowsArtifact('speech_core.dll', 'AI_VIDEO_SPEECH_CORE_LIBRARY');
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
  final broker = SharedNetworkMediaBroker(logs: ref.read(diagnosticsLogProvider));
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

final mediaPickerProvider = Provider<MediaPicker>((ref) => FileSelectorMediaPicker());

final browserServiceProvider = AutoDisposeProvider<BrowserService>((ref) {
  final BrowserService service = defaultTargetPlatform == TargetPlatform.windows
      ? WindowsBrowserService(logs: ref.read(diagnosticsLogProvider))
      : MobileBrowserService(logs: ref.read(diagnosticsLogProvider));
  ref.onDispose(service.dispose);
  return service;
});

final appSettingsProvider = ChangeNotifierProvider<AppSettingsController>(
  (ref) => AppSettingsController.fromEnvironment(),
);

final transcriptStoreProvider = ChangeNotifierProvider<TranscriptStore>(
  (ref) => TranscriptStore(),
);

final recognitionServiceProvider = ChangeNotifierProvider<RecognitionService>((ref) {
  final logs = ref.read(diagnosticsLogProvider);
  final library = speechCoreLibraryPath();
  final PcmSource Function() sourceFactory;
  if (Platform.isIOS) {
    sourceFactory = IosPcmSource.new;
  } else {
    final decoder = _windowsArtifact('audio_decoder.dll', 'AI_VIDEO_AUDIO_DECODER_LIBRARY');
    sourceFactory = decoder == null
        ? () => UnavailablePcmSource(message: '未找到 Windows 音频解码 DLL。')
        : () => WindowsPcmSource(libraryPath: decoder);
    logs.info('识别', '识别运行时初始化', {
      'speech_core DLL': library ?? '未找到',
      '音频解码 DLL': decoder ?? '未找到',
    });
  }
  final service = RecognitionService(
    logs: logs,
    store: ref.read(transcriptStoreProvider),
    modelStore: WhisperModelStore.platformDefault(
      downloadSettings: () => ref.read(appSettingsProvider).modelDownload,
    ),
    resolver: RecognitionMediaResolver(
      broker: ref.read(sharedNetworkMediaBrokerProvider),
      logs: logs,
    ),
    sourceFactory: sourceFactory,
    libraryPath: library,
    settings: ref.read(appSettingsProvider).recognition,
  );
  final settings = ref.read(appSettingsProvider);
  void onSettings() => unawaited(service.applySettings(settings.recognition));
  settings.addListener(onSettings);
  ref.onDispose(() {
    settings.removeListener(onSettings);
    unawaited(service.dispose());
  });
  unawaited(settings.ready.then((_) => service.warmUp()));
  return service;
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
