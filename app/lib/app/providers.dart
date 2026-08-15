import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/browser/browser_service.dart';
import '../domain/player/player_service.dart';
import '../domain/speech/speech_models.dart';
import '../domain/translation/translation_service.dart';
import '../features/browser/mobile_browser_service.dart';
import '../features/browser/windows_browser_service.dart';
import '../features/player/media_kit_player_service.dart';
import '../features/player/media_picker.dart';
import '../features/player/mock_services.dart';

final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = MediaKitPlayerService();
  ref.onDispose(service.dispose);
  return service;
});

final mediaPickerProvider = Provider<MediaPicker>(
  (ref) => FileSelectorMediaPicker(),
);

final browserServiceProvider = AutoDisposeProvider<BrowserService>((ref) {
  final BrowserService service = defaultTargetPlatform == TargetPlatform.windows
      ? WindowsBrowserService()
      : MobileBrowserService();
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
