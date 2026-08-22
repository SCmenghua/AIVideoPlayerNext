import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../audio/recognition_controller.dart';
import '../../domain/translation/local_translation_model.dart';
import '../../domain/translation/translation_service.dart';

enum TranslationMode { deepl, genericApi, localModel }

enum SubtitleDisplayMode { bilingual, original, translation }

enum PlaybackStartStrategy {
  subtitlePriority,
  translationPriority,
  playbackPriority,
}

class AppSettings {
  const AppSettings({
    required this.prefetchMode,
    required this.translationMode,
    required this.localTranslationModel,
    required this.deeplApiKey,
    required this.deeplEndpoint,
    required this.genericEndpoint,
    required this.genericApiKey,
    required this.genericModel,
    required this.translationBatchSize,
    required this.translationMaxConcurrent,
    required this.subtitleDisplayMode,
    required this.playbackStartStrategy,
    required this.waitForSubtitlePreparation,
  });

  final RecognitionPrefetchMode prefetchMode;
  final TranslationMode translationMode;
  final LocalTranslationModel localTranslationModel;
  final String? deeplApiKey;
  final Uri deeplEndpoint;
  final Uri? genericEndpoint;
  final String? genericApiKey;
  final String genericModel;
  final int translationBatchSize;
  final int translationMaxConcurrent;
  final SubtitleDisplayMode subtitleDisplayMode;
  final PlaybackStartStrategy playbackStartStrategy;
  final bool waitForSubtitlePreparation;

  bool sameTranslationConfiguration(AppSettings other) =>
      translationMode == other.translationMode &&
      localTranslationModel == other.localTranslationModel &&
      deeplApiKey == other.deeplApiKey &&
      deeplEndpoint == other.deeplEndpoint &&
      genericEndpoint == other.genericEndpoint &&
      genericApiKey == other.genericApiKey &&
      genericModel == other.genericModel;

  bool sameTranslationScheduling(AppSettings other) =>
      translationBatchSize == other.translationBatchSize &&
      translationMaxConcurrent == other.translationMaxConcurrent;
}

class AppSettingsController extends ChangeNotifier {
  AppSettingsController({
    RecognitionPrefetchMode prefetchMode = RecognitionPrefetchMode.fullMedia,
    TranslationMode translationMode = TranslationMode.deepl,
    LocalTranslationModel localTranslationModel =
        LocalTranslationModel.gemma4E2BItQatMobileTransformers,
    String? deeplApiKey,
    Uri? deeplEndpoint,
    Uri? genericEndpoint,
    String? genericApiKey,
    String genericModel = 'gpt-4.1-mini',
    int translationBatchSize = 4,
    int translationMaxConcurrent = 2,
    SubtitleDisplayMode subtitleDisplayMode = SubtitleDisplayMode.bilingual,
    PlaybackStartStrategy playbackStartStrategy =
        PlaybackStartStrategy.translationPriority,
    bool waitForSubtitlePreparation = true,
  })  : _prefetchMode = prefetchMode,
        _translationMode = translationMode,
        _localTranslationModel = localTranslationModel,
        _deeplApiKey = _clean(deeplApiKey),
        _deeplEndpoint = deeplEndpoint ?? defaultDeepLEndpoint,
        _genericEndpoint = genericEndpoint == null
            ? null
            : normalizeOpenAiCompatibleEndpoint(genericEndpoint),
        _genericApiKey = _clean(genericApiKey),
        _genericModel =
            genericModel.trim().isEmpty ? 'gpt-4.1-mini' : genericModel.trim(),
        _translationBatchSize = _boundedBatchSize(translationBatchSize),
        _translationMaxConcurrent =
            _boundedConcurrency(translationMaxConcurrent),
        _subtitleDisplayMode = subtitleDisplayMode,
        _playbackStartStrategy = playbackStartStrategy,
        _waitForSubtitlePreparation = waitForSubtitlePreparation {
    ready = _loadPersistedSettings();
  }

  factory AppSettingsController.fromEnvironment() {
    final genericEndpoint = parseOpenAiCompatibleEndpoint(
        Platform.environment['AI_VIDEO_TRANSLATION_ENDPOINT'] ?? '');
    final genericApiKey = Platform.environment['AI_VIDEO_TRANSLATION_API_KEY'];
    final genericModel = Platform.environment['AI_VIDEO_TRANSLATION_MODEL'];
    final hasGenericConfiguration =
        genericEndpoint != null && _clean(genericApiKey) != null;
    return AppSettingsController(
      translationMode: hasGenericConfiguration
          ? TranslationMode.genericApi
          : TranslationMode.deepl,
      genericEndpoint: genericEndpoint,
      genericApiKey: genericApiKey,
      genericModel: genericModel ?? 'gpt-4.1-mini',
    );
  }

  static final Uri defaultDeepLEndpoint =
      Uri.parse('https://api-free.deepl.com/v2/translate');

  RecognitionPrefetchMode _prefetchMode;
  TranslationMode _translationMode;
  LocalTranslationModel _localTranslationModel;
  String? _deeplApiKey;
  Uri _deeplEndpoint;
  Uri? _genericEndpoint;
  String? _genericApiKey;
  String _genericModel;
  int _translationBatchSize;
  int _translationMaxConcurrent;
  SubtitleDisplayMode _subtitleDisplayMode;
  PlaybackStartStrategy _playbackStartStrategy;
  bool _waitForSubtitlePreparation;
  late final Future<void> ready;
  final Set<String> _changedBeforeLoad = <String>{};
  int _saveGeneration = 0;

  RecognitionPrefetchMode get prefetchMode => _prefetchMode;
  TranslationMode get translationMode => _translationMode;
  LocalTranslationModel get localTranslationModel => _localTranslationModel;
  String? get deeplApiKey => _deeplApiKey;
  Uri get deeplEndpoint => _deeplEndpoint;
  Uri? get genericEndpoint => _genericEndpoint;
  String? get genericApiKey => _genericApiKey;
  String get genericModel => _genericModel;
  int get translationBatchSize => _translationBatchSize;
  int get translationMaxConcurrent => _translationMaxConcurrent;
  SubtitleDisplayMode get subtitleDisplayMode => _subtitleDisplayMode;
  PlaybackStartStrategy get playbackStartStrategy => _playbackStartStrategy;
  bool get waitForSubtitlePreparation => _waitForSubtitlePreparation;

  AppSettings get snapshot => AppSettings(
        prefetchMode: _prefetchMode,
        translationMode: _translationMode,
        localTranslationModel: _localTranslationModel,
        deeplApiKey: _deeplApiKey,
        deeplEndpoint: _deeplEndpoint,
        genericEndpoint: _genericEndpoint,
        genericApiKey: _genericApiKey,
        genericModel: _genericModel,
        translationBatchSize: _translationBatchSize,
        translationMaxConcurrent: _translationMaxConcurrent,
        subtitleDisplayMode: _subtitleDisplayMode,
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
      if (!_changedBeforeLoad.contains('prefetchMode')) {
        final value =
            _enumValue(values['prefetchMode'], RecognitionPrefetchMode.values);
        if (value != null && value != _prefetchMode) {
          _prefetchMode = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('translationMode')) {
        final value =
            _enumValue(values['translationMode'], TranslationMode.values);
        if (value != null && value != _translationMode) {
          _translationMode = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('localTranslationModel')) {
        final value = _enumValue(
            values['localTranslationModel'], LocalTranslationModel.values);
        if (value != null && value != _localTranslationModel) {
          _localTranslationModel = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('deeplApiKey') &&
          values.containsKey('deeplApiKey')) {
        final value = _clean(values['deeplApiKey']);
        if (value != _deeplApiKey) {
          _deeplApiKey = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('deeplEndpoint')) {
        final value = _parseDeepLEndpoint(values['deeplEndpoint']);
        if (value != null && value != _deeplEndpoint) {
          _deeplEndpoint = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('genericEndpoint') &&
          values.containsKey('genericEndpoint')) {
        final value = _parseGenericEndpoint(values['genericEndpoint']);
        if (value != _genericEndpoint) {
          _genericEndpoint = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('genericApiKey') &&
          values.containsKey('genericApiKey')) {
        final value = _clean(values['genericApiKey']);
        if (value != _genericApiKey) {
          _genericApiKey = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('genericModel')) {
        final raw = values['genericModel'];
        final value = raw is String && raw.trim().isNotEmpty
            ? raw.trim()
            : 'gpt-4.1-mini';
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
      if (!_changedBeforeLoad.contains('subtitleDisplayMode')) {
        final value = _enumValue(
            values['subtitleDisplayMode'], SubtitleDisplayMode.values);
        if (value != null && value != _subtitleDisplayMode) {
          _subtitleDisplayMode = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('playbackStartStrategy')) {
        final value = _enumValue(
            values['playbackStartStrategy'], PlaybackStartStrategy.values);
        if (value != null && value != _playbackStartStrategy) {
          _playbackStartStrategy = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('waitForSubtitlePreparation') &&
          values.containsKey('waitForSubtitlePreparation')) {
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

  static Uri? _parseDeepLEndpoint(Object? raw) {
    if (raw is! String) return null;
    return _optionalEndpoint(raw);
  }

  static Uri? _parseGenericEndpoint(Object? raw) {
    if (raw is! String) return null;
    return _optionalGenericEndpoint(raw);
  }

  void setPrefetchMode(RecognitionPrefetchMode value) {
    if (_prefetchMode == value) return;
    _prefetchMode = value;
    _markChanged('prefetchMode');
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
    _deeplEndpoint = _validatedEndpoint(endpoint, defaultDeepLEndpoint);
    _markChanged('deeplApiKey');
    _markChanged('deeplEndpoint');
    notifyListeners();
  }

  void updateGenericApi({
    required String endpoint,
    required String apiKey,
    required String model,
  }) {
    _genericEndpoint = _optionalGenericEndpoint(endpoint);
    _genericApiKey = _clean(apiKey);
    _genericModel = model.trim().isEmpty ? 'gpt-4.1-mini' : model.trim();
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

  void setSubtitleDisplayMode(SubtitleDisplayMode value) {
    if (_subtitleDisplayMode == value) return;
    _subtitleDisplayMode = value;
    _markChanged('subtitleDisplayMode');
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

  static Uri _validatedEndpoint(String value, Uri fallback) =>
      _optionalEndpoint(value) ?? fallback;

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

  static Uri? _optionalGenericEndpoint(String value) {
    return parseOpenAiCompatibleEndpoint(value);
  }

  static String? _clean(Object? value) {
    final result = value is String ? value.trim() : null;
    return result == null || result.isEmpty ? null : result;
  }

  static int _boundedBatchSize(int value) => value.clamp(1, 20);

  static int _boundedConcurrency(int value) => value.clamp(1, 8);
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
      'prefetchMode': settings.prefetchMode.name,
      'translationMode': settings.translationMode.name,
      'localTranslationModel': settings.localTranslationModel.name,
      'deeplApiKey': settings.deeplApiKey,
      'deeplEndpoint': settings.deeplEndpoint.toString(),
      'genericEndpoint': settings.genericEndpoint?.toString(),
      'genericApiKey': settings.genericApiKey,
      'genericModel': settings.genericModel,
      'translationBatchSize': settings.translationBatchSize,
      'translationMaxConcurrent': settings.translationMaxConcurrent,
      'subtitleDisplayMode': settings.subtitleDisplayMode.name,
      'playbackStartStrategy': settings.playbackStartStrategy.name,
      'waitForSubtitlePreparation': settings.waitForSubtitlePreparation,
    }));
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
