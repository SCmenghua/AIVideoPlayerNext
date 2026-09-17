import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/features/recognition/recognition_settings.dart';
import 'package:ai_video_player_next/features/recognition/whisper_model_catalog.dart';

void main() {
  test('context follows the weight when no explicit choice is stored', () {
    const kotoba = RecognitionSettings(modelId: 'kotoba-whisper-v2.0');
    expect(kotoba.model.usesInitialPrompt, isTrue);
    expect(kotoba.effectiveContextEnabled, isTrue);

    const anime = RecognitionSettings(modelId: 'anime-whisper');
    expect(anime.model.usesInitialPrompt, isFalse);
    expect(anime.effectiveContextEnabled, isFalse);
  });

  test('an explicit choice overrides the weight in both directions', () {
    const forcedOn = RecognitionSettings(modelId: 'anime-whisper', contextEnabled: true);
    expect(forcedOn.effectiveContextEnabled, isTrue);

    const forcedOff = RecognitionSettings(modelId: 'kotoba-whisper-v2.0', contextEnabled: false);
    expect(forcedOff.effectiveContextEnabled, isFalse);
  });

  test('clearing the override restores the weight default', () {
    const settings = RecognitionSettings(modelId: 'anime-whisper', contextEnabled: true);
    final cleared = settings.copyWith(clearContextEnabled: true);
    expect(cleared.contextEnabled, isNull);
    expect(cleared.effectiveContextEnabled, isFalse);
  });

  test('every catalogued weight is reachable by id', () {
    for (final spec in WhisperModelCatalog.all) {
      expect(WhisperModelCatalog.byId(spec.id), same(spec));
    }
  });
}
