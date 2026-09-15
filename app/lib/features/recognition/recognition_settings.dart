import 'whisper_model_catalog.dart';

/// Languages offered in settings; `auto` lets Whisper detect.
const recognitionLanguageLabels = <String, String>{
  'auto': '自动检测',
  'ja': '日本語',
  'en': 'English',
  'zh': '中文',
  'ko': '한국어',
  'fr': 'Français',
  'de': 'Deutsch',
  'es': 'Español',
  'ru': 'Русский',
};

const translationTargetLanguageLabels = <String, String>{
  'zh-CN': '简体中文',
  'zh-TW': '繁體中文',
  'en': 'English',
  'ja': '日本語',
  'ko': '한국어',
};

class RecognitionSettings {
  const RecognitionSettings({
    this.language = 'ja',
    this.modelId,
    this.vadEnabled = true,
  });

  final String language;

  /// Null selects the catalog default for [language].
  final String? modelId;
  final bool vadEnabled;

  WhisperModelSpec get model {
    final chosen = modelId == null ? null : WhisperModelCatalog.byId(modelId!);
    if (chosen != null && WhisperModelCatalog.supports(chosen, language)) return chosen;
    return WhisperModelCatalog.defaultFor(language);
  }

  RecognitionSettings copyWith({
    String? language,
    String? modelId,
    bool clearModelId = false,
    bool? vadEnabled,
  }) =>
      RecognitionSettings(
        language: language ?? this.language,
        modelId: clearModelId ? null : modelId ?? this.modelId,
        vadEnabled: vadEnabled ?? this.vadEnabled,
      );

  @override
  bool operator ==(Object other) =>
      other is RecognitionSettings &&
      other.language == language &&
      other.modelId == modelId &&
      other.vadEnabled == vadEnabled;

  @override
  int get hashCode => Object.hash(language, modelId, vadEnabled);
}
