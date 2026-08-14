import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/player/player_service.dart';
import '../domain/speech/speech_models.dart';
import '../domain/translation/translation_service.dart';
import '../features/player/mock_services.dart';

final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = MockPlayerService();
  ref.onDispose(service.dispose);
  return service;
});

final speechRecognitionServiceProvider = Provider<SpeechRecognitionService>((ref) {
  final service = MockSpeechRecognitionService();
  ref.onDispose(() async {
    await service.stop();
  });
  return service;
});

final translationServiceProvider = Provider<TranslationService>((ref) => MockTranslationService());

final playbackSnapshotProvider = StreamProvider<PlaybackSnapshot>((ref) {
  return ref.watch(playerServiceProvider).snapshots;
});
