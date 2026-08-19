enum LocalTranslationModel {
  gemma4E2BItQatMobileTransformers,
}

extension LocalTranslationModelInfo on LocalTranslationModel {
  String get displayName => switch (this) {
        LocalTranslationModel.gemma4E2BItQatMobileTransformers =>
          'Gemma 4 E2B IT (QAT mobile)',
      };

  String get repository => switch (this) {
        LocalTranslationModel.gemma4E2BItQatMobileTransformers =>
          'google/gemma-4-E2B-it-qat-mobile-transformers',
      };

  String get directoryName => switch (this) {
        LocalTranslationModel.gemma4E2BItQatMobileTransformers =>
          'gemma-4-E2B-it-qat-mobile-transformers',
      };

  String get runtimeDescription => switch (this) {
        LocalTranslationModel.gemma4E2BItQatMobileTransformers =>
          'Gemma 4 wNa8o8 QAT；主候选使用 Google LiteRT-LM 与 .litertlm 模型包。',
      };

  String get license => switch (this) {
        LocalTranslationModel.gemma4E2BItQatMobileTransformers => 'Apache-2.0',
      };

  String get expectedWeightDescription => switch (this) {
        LocalTranslationModel.gemma4E2BItQatMobileTransformers =>
          '官方移动优化 QAT 权重；应用侧应优先使用已转换的 LiteRT-LM .litertlm 包，当前等待 runtime spike。',
      };
}
