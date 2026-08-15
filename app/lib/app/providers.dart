import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnostics/diagnostic_log_service.dart';
import '../domain/browser/browser_service.dart';
import '../domain/player/player_service.dart';
import '../domain/speech/speech_models.dart';
import '../domain/translation/translation_service.dart';
import '../features/browser/mobile_browser_service.dart';
import '../features/browser/windows_browser_service.dart';
import '../features/player/media_kit_player_service.dart';
import '../features/player/media_picker.dart';
import '../features/player/mock_services.dart';

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

final translationServiceProvider =
    Provider<TranslationService>((ref) => MockTranslationService());

final playbackSnapshotProvider = StreamProvider<PlaybackSnapshot>((ref) {
  return ref.watch(playerServiceProvider).snapshots;
});
