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

/// Where model files are fetched from. Hugging Face is slow or unreachable
/// from some networks, so the base URL is replaceable by a mirror and an
/// explicit HTTP proxy can be given.
class ModelDownloadSettings {
  const ModelDownloadSettings({this.baseUrl = officialBaseUrl, this.proxy});

  static const officialBaseUrl = 'https://huggingface.co';
  static const mirrorBaseUrl = 'https://hf-mirror.com';

  final String baseUrl;

  /// `http://host:port` (or `host:port`); null uses the environment proxy.
  final String? proxy;

  bool get isOfficial => _normalize(baseUrl) == officialBaseUrl;

  /// Rewrites an official Hugging Face URL onto [base], keeping the path.
  static Uri rewrite(Uri official, String base) {
    final parsed = Uri.tryParse(_normalize(base));
    if (parsed == null || parsed.host.isEmpty) return official;
    final prefix = parsed.path.endsWith('/')
        ? parsed.path.substring(0, parsed.path.length - 1)
        : parsed.path;
    return official.replace(
      scheme: parsed.scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: '$prefix${official.path}',
    );
  }

  Uri resolve(Uri official) => rewrite(official, baseUrl);

  /// The proxy in the `host:port` form `HttpClient.findProxy` expects.
  String? get proxyHostPort {
    final raw = proxy?.trim();
    if (raw == null || raw.isEmpty) return null;
    final parsed = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
    if (parsed == null || parsed.host.isEmpty) return null;
    final port = parsed.hasPort ? parsed.port : 80;
    return '${parsed.host}:$port';
  }

  static String _normalize(String value) {
    var text = value.trim();
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  ModelDownloadSettings copyWith({String? baseUrl, String? proxy, bool clearProxy = false}) =>
      ModelDownloadSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        proxy: clearProxy ? null : proxy ?? this.proxy,
      );

  @override
  bool operator ==(Object other) =>
      other is ModelDownloadSettings && other.baseUrl == baseUrl && other.proxy == proxy;

  @override
  int get hashCode => Object.hash(baseUrl, proxy);
}

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
