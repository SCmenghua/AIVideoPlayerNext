import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/translation/local_translation_model.dart';
import 'package:ai_video_player_next/features/translation/local_model_translation_service.dart';

void main() {
  test('uses the corrected Gemma 4 repository identity', () {
    const model = LocalTranslationModel.gemma4E2BItQatMobileTransformers;

    expect(model.repository, 'google/gemma-4-E2B-it-qat-mobile-transformers');
    expect(model.directoryName, 'gemma-4-E2B-it-qat-mobile-transformers');
    expect(model.license, 'Apache-2.0');
    expect(model.runtimeDescription, contains('wNa8o8'));
    expect(model.expectedWeightDescription, contains('移动优化 QAT'));
  });

  test('does not report a missing runtime as a usable local provider', () {
    final service = LocalModelTranslationService(
      model: LocalTranslationModel.gemma4E2BItQatMobileTransformers,
    );

    expect(service.status.available, isFalse);
    expect(service.status.message, contains('LiteRT-LM'));
    expect(service.status.message, contains('主候选'));
  });
}
