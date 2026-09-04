import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/audio_models.dart';
import 'package:ai_video_player_next/features/audio/audio_recognition_adapters.dart';

void main() {
  test('window recognition service starts with the settings language', () {
    final service = WhisperWindowRecognitionService(
      libraryPath: 'speech_core.dll',
      modelPath: 'models/ggml-large-v3-turbo-q5_0.bin',
      language: 'en',
    );

    expect(service.language, 'en');
  });

  test('recognition language is mutable without rebuilding the model', () {
    final service = WhisperWindowRecognitionService(
      libraryPath: 'speech_core.dll',
      modelPath: 'models/ggml-large-v3-turbo-q5_0.bin',
    );

    expect(service, isA<WindowRecognitionLanguageController>());
    expect(service.language, 'ja');

    service.setLanguage('auto');
    expect(service.language, 'auto');

    service.setLanguage('en');
    expect(service.language, 'en');
  });

  test('setModel before prepare retargets the model without loading', () {
    final service = WhisperWindowRecognitionService(
      libraryPath: 'speech_core.dll',
      modelPath: 'models/ggml-large-v3-turbo-q5_0.bin',
    );

    expect(service, isA<WindowRecognitionModelController>());

    service.setModel('models/ggml-large-v3-q5_0.bin');

    expect(service.modelPath, 'models/ggml-large-v3-q5_0.bin');
    expect(service.status.modelName, 'ggml-large-v3-q5_0.bin');
  });

  test('setModel with the current path is a no-op', () {
    final service = WhisperWindowRecognitionService(
      libraryPath: 'speech_core.dll',
      modelPath: 'models/ggml-large-v3-turbo-q5_0.bin',
    );

    service.setModel('models/ggml-large-v3-turbo-q5_0.bin');

    expect(service.modelPath, 'models/ggml-large-v3-turbo-q5_0.bin');
  });
}
