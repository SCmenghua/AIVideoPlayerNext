import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/translation/local_translation_model.dart';
import '../../domain/translation/translation_service.dart';
import '../recognition/recognition_settings.dart';
import '../recognition/whisper_model_catalog.dart';

enum TranslationMode { deepl, genericApi, systemTranslation, localModel }

enum SubtitleDisplayMode { bilingual, original, translation }

enum PlaybackStartStrategy {
  subtitlePriority,
  translationPriority,
  playbackPriority,
}

const defaultGenericModel = 'gpt-4.1-mini';

class AppSettings {
  const AppSettings({
    required this.recognition,
    required this.modelDownload,
    required this.translationMode,
    required this.localTranslationModel,
    required this.deeplApiKey,
    required this.deeplEndpoint,
    required this.genericEndpoint,
    required this.genericApiKey,
    required this.genericModel,
    required this.translationBatchSize,
    required this.translationMaxConcurrent,
    required this.translationContextEnabled,
    required this.translationTargetLanguage,
    required this.subtitleDisplayMode,
    required this.subtitleFontScale,
    required this.playbackStartStrategy,
    required this.waitForSubtitlePreparation,
  });

  final RecognitionSettings recognition;
  final ModelDownloadSettings modelDownload;
  final TranslationMode translationMode;
  final LocalTranslationModel localTranslationModel;
  final String? deeplApiKey;
  final Uri deeplEndpoint;
  final Uri? genericEndpoint;
  final String? genericApiKey;
  final String genericModel;
  final int translationBatchSize;
  final int translationMaxConcurrent;
  final bool translationContextEnabled;
  final String translationTargetLanguage;
  final SubtitleDisplayMode subtitleDisplayMode;
  final double subtitleFontScale;
  final PlaybackStartStrategy playbackStartStrategy;
  final bool waitForSubtitlePreparation;

  bool sameTranslationConfiguration(AppSettings other) =>
      translationMode == other.translationMode &&
      localTranslationModel == other.localTranslationModel &&
      deeplApiKey == other.deeplApiKey &&
      deeplEndpoint == other.deeplEndpoint &&
      genericEndpoint == other.genericEndpoint &&
      genericApiKey == other.genericApiKey &&
      genericModel == other.genericModel &&
      translationTargetLanguage == other.translationTargetLanguage;

  bool sameTranslationScheduling(AppSettings other) =>
      translationBatchSize == other.translationBatchSize &&
      translationMaxConcurrent == other.translationMaxConcurrent &&
      translationContextEnabled == other.translationContextEnabled;
}

class AppSettingsController extends ChangeNotifier {
  AppSettingsController({
    RecognitionSettings recognition = const RecognitionSettings(),
    ModelDownloadSettings modelDownload = const ModelDownloadSettings(),
    TranslationMode translationMode = TranslationMode.deepl,
    LocalTranslationModel localTranslationModel =
        LocalTranslationModel.gemma4E2BItQatMobileTransformers,
    String? deeplApiKey,
    Uri? deeplEndpoint,
    Uri? genericEndpoint,
    String? genericApiKey,
    String genericModel = defaultGenericModel,
    int translationBatchSize = 8,
    int translationMaxConcurrent = 10,
    bool translationContextEnabled = true,
    String translationTargetLanguage = 'zh-CN',
    SubtitleDisplayMode subtitleDisplayMode = SubtitleDisplayMode.bilingual,
    double subtitleFontScale = 1.0,
    PlaybackStartStrategy playbackStartStrategy = PlaybackStartStrategy.subtitlePriority,
    bool waitForSubtitlePreparation = true,
  })  : _recognition = recognition,
        _modelDownload = modelDownload,
        _translationMode = translationMode,
        _localTranslationModel = localTranslationModel,
        _deeplApiKey = _clean(deeplApiKey),
        _deeplEndpoint = deeplEndpoint ?? defaultDeepLEndpoint,
        _genericEndpoint =
            genericEndpoint == null ? null : normalizeOpenAiCompatibleEndpoint(genericEndpoint),
        _genericApiKey = _clean(genericApiKey),
        _genericModel = genericModel.trim().isEmpty ? defaultGenericModel : genericModel.trim(),
        _translationBatchSize = _boundedBatchSize(translationBatchSize),
        _translationMaxConcurrent = _boundedConcurrency(translationMaxConcurrent),
        _translationContextEnabled = translationContextEnabled,
        _translationTargetLanguage = _validTargetLanguage(translationTargetLanguage),
        _subtitleDisplayMode = subtitleDisplayMode,
        _subtitleFontScale = _boundedFontScale(subtitleFontScale),
        _playbackStartStrategy = playbackStartStrategy,
        _waitForSubtitlePreparation = waitForSubtitlePreparation {
    ready = _loadPersistedSettings();
  }

  factory AppSettingsController.fromEnvironment() {
    final genericEndpoint = parseOpenAiCompatibleEndpoint(
        Platform.environment['AI_VIDEO_TRANSLATION_ENDPOINT'] ?? '');
    final genericApiKey = Platform.environment['AI_VIDEO_TRANSLATION_API_KEY'];
    final genericModel = Platform.environment['AI_VIDEO_TRANSLATION_MODEL'];
    final hasGenericConfiguration = genericEndpoint != null && _clean(genericApiKey) != null;
    return AppSettingsController(
      translationMode: hasGenericConfiguration ? TranslationMode.genericApi : TranslationMode.deepl,
      genericEndpoint: genericEndpoint,
      genericApiKey: genericApiKey,
      genericModel: genericModel ?? defaultGenericModel,
    );
  }

  static final Uri defaultDeepLEndpoint = Uri.parse('https://api-free.deepl.com/v2/translate');

  RecognitionSettings _recognition;
  ModelDownloadSettings _modelDownload;
  TranslationMode _translationMode;
  LocalTranslationModel _localTranslationModel;
  String? _deeplApiKey;
  Uri _deeplEndpoint;
  Uri? _genericEndpoint;
  String? _genericApiKey;
  String _genericModel;
  int _translationBatchSize;
  int _translationMaxConcurrent;
  bool _translationContextEnabled;
  String _translationTargetLanguage;
  SubtitleDisplayMode _subtitleDisplayMode;
  double _subtitleFontScale;
  PlaybackStartStrategy _playbackStartStrategy;
  bool _waitForSubtitlePreparation;
  late final Future<void> ready;
  final Set<String> _changedBeforeLoad = <String>{};
  int _saveGeneration = 0;

  RecognitionSettings get recognition => _recognition;
  ModelDownloadSettings get modelDownload => _modelDownload;
  TranslationMode get translationMode => _translationMode;
  LocalTranslationModel get localTranslationModel => _localTranslationModel;
  String? get deeplApiKey => _deeplApiKey;
  Uri get deeplEndpoint => _deeplEndpoint;
  Uri? get genericEndpoint => _genericEndpoint;
  String? get genericApiKey => _genericApiKey;
  String get genericModel => _genericModel;
  int get translationBatchSize => _translationBatchSize;
  int get translationMaxConcurrent => _translationMaxConcurrent;
  bool get translationContextEnabled => _translationContextEnabled;
  String get translationTargetLanguage => _translationTargetLanguage;
  SubtitleDisplayMode get subtitleDisplayMode => _subtitleDisplayMode;
  double get subtitleFontScale => _subtitleFontScale;
  PlaybackStartStrategy get playbackStartStrategy => _playbackStartStrategy;
  bool get waitForSubtitlePreparation => _waitForSubtitlePreparation;

  AppSettings get snapshot => AppSettings(
        recognition: _recognition,
        modelDownload: _modelDownload,
        translationMode: _translationMode,
        localTranslationModel: _localTranslationModel,
        deeplApiKey: _deeplApiKey,
        deeplEndpoint: _deeplEndpoint,
        genericEndpoint: _genericEndpoint,
        genericApiKey: _genericApiKey,
        genericModel: _genericModel,
        translationBatchSize: _translationBatchSize,
        translationMaxConcurrent: _translationMaxConcurrent,
        translationContextEnabled: _translationContextEnabled,
        translationTargetLanguage: _translationTargetLanguage,
        subtitleDisplayMode: _subtitleDisplayMode,
        subtitleFontScale: _subtitleFontScale,
        playbackStartStrategy: _playbackStartStrategy,
        waitForSubtitlePreparation: _waitForSubtitlePreparation,
      );

  Future<void> _loadPersistedSettings() async {
    try {
      final file = await AppSettingsStore.settingsFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final values = Map<String, dynamic>.from(decoded);
      var changed = false;

      if (!_changedBeforeLoad.contains('recognition')) {
        final language = values['recognitionLanguage'];
        final modelId = values['whisperModelId'];
        final vad = values['vadEnabled'];
        final next = RecognitionSettings(
          language: language is String && recognitionLanguageLabels.containsKey(language)
              ? language
              : _recognition.language,
          modelId: modelId is String && WhisperModelCatalog.byId(modelId) != null
              ? modelId
              : _recognition.modelId,
          vadEnabled: vad is bool ? vad : _recognition.vadEnabled,
        );
        if (next != _recognition) {
          _recognition = next;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('modelDownload')) {
        final base = values['modelDownloadBaseUrl'];
        final proxy = values['modelDownloadProxy'];
        final next = ModelDownloadSettings(
          baseUrl: base is String && Uri.tryParse(base)?.host.isNotEmpty == true
              ? base
              : _modelDownload.baseUrl,
          proxy: proxy is String ? _clean(proxy) : _modelDownload.proxy,
        );
        if (next != _modelDownload) {
          _modelDownload = next;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('translationMode')) {
        final value = _enumValue(values['translationMode'], TranslationMode.values);
        if (value != null && value != _translationMode) {
          _translationMode = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('localTranslationModel')) {
        final value = _enumValue(values['localTranslationModel'], LocalTranslationModel.values);
        if (value != null && value != _localTranslationModel) {
          _localTranslationModel = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('deeplApiKey') && values.containsKey('deeplApiKey')) {
        final value = _clean(values['deeplApiKey']);
        if (value != _deeplApiKey) {
          _deeplApiKey = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('deeplEndpoint')) {
        final raw = values['deeplEndpoint'];
        final value = raw is String ? _optionalEndpoint(raw) : null;
        if (value != null && value != _deeplEndpoint) {
          _deeplEndpoint = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('genericEndpoint') && values.containsKey('genericEndpoint')) {
        final raw = values['genericEndpoint'];
        final value = raw is String ? parseOpenAiCompatibleEndpoint(raw) : null;
        if (value != _genericEndpoint) {
          _genericEndpoint = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('genericApiKey') && values.containsKey('genericApiKey')) {
        final value = _clean(values['genericApiKey']);
        if (value != _genericApiKey) {
          _genericApiKey = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('genericModel')) {
        final raw = values['genericModel'];
        final value = raw is String && raw.trim().isNotEmpty ? raw.trim() : defaultGenericModel;
        if (value != _genericModel) {
          _genericModel = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('translationBatchSize')) {
        final raw = values['translationBatchSize'];
        if (raw is num) {
          final value = _boundedBatchSize(raw.toInt());
          if (value != _translationBatchSize) {
            _translationBatchSize = value;
            changed = true;
          }
        }
      }
      if (!_changedBeforeLoad.contains('translationMaxConcurrent')) {
        final raw = values['translationMaxConcurrent'];
        if (raw is num) {
          final value = _boundedConcurrency(raw.toInt());
          if (value != _translationMaxConcurrent) {
            _translationMaxConcurrent = value;
            changed = true;
          }
        }
      }
      if (!_changedBeforeLoad.contains('translationContextEnabled')) {
        final raw = values['translationContextEnabled'];
        if (raw is bool && raw != _translationContextEnabled) {
          _translationContextEnabled = raw;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('translationTargetLanguage')) {
        final raw = values['translationTargetLanguage'];
        if (raw is String && translationTargetLanguageLabels.containsKey(raw) &&
            raw != _translationTargetLanguage) {
          _translationTargetLanguage = raw;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('subtitleDisplayMode')) {
        final value = _enumValue(values['subtitleDisplayMode'], SubtitleDisplayMode.values);
        if (value != null && value != _subtitleDisplayMode) {
          _subtitleDisplayMode = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('subtitleFontScale')) {
        final raw = values['subtitleFontScale'];
        if (raw is num) {
          final value = _boundedFontScale(raw.toDouble());
          if (value != _subtitleFontScale) {
            _subtitleFontScale = value;
            changed = true;
          }
        }
      }
      if (!_changedBeforeLoad.contains('playbackStartStrategy')) {
        final value = _enumValue(values['playbackStartStrategy'], PlaybackStartStrategy.values);
        if (value != null && value != _playbackStartStrategy) {
          _playbackStartStrategy = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('waitForSubtitlePreparation')) {
        final raw = values['waitForSubtitlePreparation'];
        if (raw is bool && raw != _waitForSubtitlePreparation) {
          _waitForSubtitlePreparation = raw;
          changed = true;
        }
      }
      if (changed) notifyListeners();
    } on Object catch (_) {
      // Corrupt or unavailable settings must never prevent the app from opening.
    }
  }

  void _markChanged(String key) {
    _changedBeforeLoad.add(key);
    unawaited(_savePersistedSettings());
  }

  Future<void> _savePersistedSettings() async {
    final generation = ++_saveGeneration;
    await Future<void>.value();
    if (generation != _saveGeneration) return;
    try {
      await AppSettingsStore.write(snapshot);
    } on Object catch (_) {
      // Persistence is best effort; the in-memory setting remains valid.
    }
  }

  static T? _enumValue<T extends Enum>(Object? raw, List<T> values) {
    if (raw is! String) return null;
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  void setRecognitionLanguage(String value) {
    if (!recognitionLanguageLabels.containsKey(value) || value == _recognition.language) return;
    _recognition = _recognition.copyWith(language: value);
    _markChanged('recognition');
    notifyListeners();
  }

  /// Null restores the catalog default for the current language.
  void setWhisperModelId(String? value) {
    if (value != null && WhisperModelCatalog.byId(value) == null) return;
    if (value == _recognition.modelId) return;
    _recognition = value == null
        ? _recognition.copyWith(clearModelId: true)
        : _recognition.copyWith(modelId: value);
    _markChanged('recognition');
    notifyListeners();
  }

  void setVadEnabled(bool value) {
    if (value == _recognition.vadEnabled) return;
    _recognition = _recognition.copyWith(vadEnabled: value);
    _markChanged('recognition');
    notifyListeners();
  }

  void setModelDownload({required String baseUrl, required String proxy}) {
    final parsedBase = Uri.tryParse(baseUrl.trim());
    final next = ModelDownloadSettings(
      baseUrl: parsedBase != null && parsedBase.host.isNotEmpty
          ? baseUrl.trim()
          : ModelDownloadSettings.officialBaseUrl,
      proxy: _clean(proxy),
    );
    if (next == _modelDownload) return;
    _modelDownload = next;
    _markChanged('modelDownload');
    notifyListeners();
  }

  void setTranslationMode(TranslationMode value) {
    if (_translationMode == value) return;
    _translationMode = value;
    _markChanged('translationMode');
    notifyListeners();
  }

  void setLocalTranslationModel(LocalTranslationModel value) {
    if (_localTranslationModel == value) return;
    _localTranslationModel = value;
    _markChanged('localTranslationModel');
    notifyListeners();
  }

  void updateDeepL({required String apiKey, required String endpoint}) {
    _deeplApiKey = _clean(apiKey);
    _deeplEndpoint = _optionalEndpoint(endpoint) ?? defaultDeepLEndpoint;
    _markChanged('deeplApiKey');
    _markChanged('deeplEndpoint');
    notifyListeners();
  }

  void updateGenericApi({
    required String endpoint,
    required String apiKey,
    required String model,
  }) {
    _genericEndpoint = parseOpenAiCompatibleEndpoint(endpoint);
    _genericApiKey = _clean(apiKey);
    _genericModel = model.trim().isEmpty ? defaultGenericModel : model.trim();
    _markChanged('genericEndpoint');
    _markChanged('genericApiKey');
    _markChanged('genericModel');
    notifyListeners();
  }

  void setGenericModel(String model) {
    final value = model.trim();
    if (value.isEmpty || value == _genericModel) return;
    _genericModel = value;
    _markChanged('genericModel');
    notifyListeners();
  }

  void setTranslationBatchSize(int value) {
    final next = _boundedBatchSize(value);
    if (_translationBatchSize == next) return;
    _translationBatchSize = next;
    _markChanged('translationBatchSize');
    notifyListeners();
  }

  void setTranslationMaxConcurrent(int value) {
    final next = _boundedConcurrency(value);
    if (_translationMaxConcurrent == next) return;
    _translationMaxConcurrent = next;
    _markChanged('translationMaxConcurrent');
    notifyListeners();
  }

  void setTranslationContextEnabled(bool value) {
    if (_translationContextEnabled == value) return;
    _translationContextEnabled = value;
    _markChanged('translationContextEnabled');
    notifyListeners();
  }

  void setTranslationTargetLanguage(String value) {
    if (!translationTargetLanguageLabels.containsKey(value) ||
        value == _translationTargetLanguage) {
      return;
    }
    _translationTargetLanguage = value;
    _markChanged('translationTargetLanguage');
    notifyListeners();
  }

  void setSubtitleDisplayMode(SubtitleDisplayMode value) {
    if (_subtitleDisplayMode == value) return;
    _subtitleDisplayMode = value;
    _markChanged('subtitleDisplayMode');
    notifyListeners();
  }

  void setSubtitleFontScale(double value) {
    final next = _boundedFontScale(value);
    if (_subtitleFontScale == next) return;
    _subtitleFontScale = next;
    _markChanged('subtitleFontScale');
    notifyListeners();
  }

  void setPlaybackStartStrategy(PlaybackStartStrategy value) {
    if (_playbackStartStrategy == value) return;
    _playbackStartStrategy = value;
    _markChanged('playbackStartStrategy');
    notifyListeners();
  }

  void setWaitForSubtitlePreparation(bool value) {
    if (_waitForSubtitlePreparation == value) return;
    _waitForSubtitlePreparation = value;
    _markChanged('waitForSubtitlePreparation');
    notifyListeners();
  }

  static Uri? _optionalEndpoint(String value) {
    final candidate = Uri.tryParse(value.trim());
    if (candidate == null ||
        (candidate.scheme != 'https' && candidate.scheme != 'http') ||
        candidate.host.isEmpty ||
        candidate.userInfo.isNotEmpty) {
      return null;
    }
    return candidate;
  }

  static String? _clean(Object? value) {
    final result = value is String ? value.trim() : null;
    return result == null || result.isEmpty ? null : result;
  }

  static String _validTargetLanguage(String value) =>
      translationTargetLanguageLabels.containsKey(value) ? value : 'zh-CN';

  static int _boundedBatchSize(int value) => value.clamp(1, 20);

  static int _boundedConcurrency(int value) => value.clamp(1, 20);

  static double _boundedFontScale(double value) =>
      value.isNaN ? 1.0 : value.clamp(0.7, 1.8).toDouble();
}

class AppSettingsStore {
  static const _directoryName = 'ai-video-player';
  static const _fileName = 'settings.json';
  static Future<void> _writes = Future<void>.value();

  static Future<File> settingsFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}$_directoryName'
        '${Platform.pathSeparator}$_fileName');
  }

  static Future<void> write(AppSettings settings) async {
    final next = _writes.then((_) => _write(settings));
    _writes = next.catchError((_) {});
    await next;
  }

  static Future<void> _write(AppSettings settings) async {
    final file = await settingsFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode({
      'recognitionLanguage': settings.recognition.language,
      'whisperModelId': settings.recognition.modelId,
      'vadEnabled': settings.recognition.vadEnabled,
      'modelDownloadBaseUrl': settings.modelDownload.baseUrl,
      'modelDownloadProxy': settings.modelDownload.proxy,
      'translationMode': settings.translationMode.name,
      'localTranslationModel': settings.localTranslationModel.name,
      'deeplApiKey': settings.deeplApiKey,
      'deeplEndpoint': settings.deeplEndpoint.toString(),
      'genericEndpoint': settings.genericEndpoint?.toString(),
      'genericApiKey': settings.genericApiKey,
      'genericModel': settings.genericModel,
      'translationBatchSize': settings.translationBatchSize,
      'translationContextEnabled': settings.translationContextEnabled,
      'translationMaxConcurrent': settings.translationMaxConcurrent,
      'translationTargetLanguage': settings.translationTargetLanguage,
      'subtitleDisplayMode': settings.subtitleDisplayMode.name,
      'subtitleFontScale': settings.subtitleFontScale,
      'playbackStartStrategy': settings.playbackStartStrategy.name,
      'waitForSubtitlePreparation': settings.waitForSubtitlePreparation,
    }));
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
