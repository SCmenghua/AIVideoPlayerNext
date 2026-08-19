import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../audio/recognition_controller.dart';
import '../../domain/translation/local_translation_model.dart';
import '../../domain/translation/translation_service.dart';

enum TranslationMode { deepl, genericApi, localModel }

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
  });

  final RecognitionPrefetchMode prefetchMode;
  final TranslationMode translationMode;
  final LocalTranslationModel localTranslationModel;
  final String? deeplApiKey;
  final Uri deeplEndpoint;
  final Uri? genericEndpoint;
  final String? genericApiKey;
  final String genericModel;

  bool sameTranslationConfiguration(AppSettings other) =>
      translationMode == other.translationMode &&
      localTranslationModel == other.localTranslationModel &&
      deeplApiKey == other.deeplApiKey &&
      deeplEndpoint == other.deeplEndpoint &&
      genericEndpoint == other.genericEndpoint &&
      genericApiKey == other.genericApiKey &&
      genericModel == other.genericModel;
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
            genericModel.trim().isEmpty ? 'gpt-4.1-mini' : genericModel.trim() {
    ready = _loadPersistedSettings();
  }

  factory AppSettingsController.fromEnvironment() {
    final genericEndpoint = Uri.tryParse(
        Platform.environment['AI_VIDEO_TRANSLATION_ENDPOINT'] ?? '');
    final genericApiKey = Platform.environment['AI_VIDEO_TRANSLATION_API_KEY'];
    final genericModel = Platform.environment['AI_VIDEO_TRANSLATION_MODEL'];
    final hasGenericConfiguration = genericEndpoint != null &&
        (genericEndpoint.scheme == 'https' ||
            genericEndpoint.scheme == 'http') &&
        _clean(genericApiKey) != null;
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

  AppSettings get snapshot => AppSettings(
        prefetchMode: _prefetchMode,
        translationMode: _translationMode,
        localTranslationModel: _localTranslationModel,
        deeplApiKey: _deeplApiKey,
        deeplEndpoint: _deeplEndpoint,
        genericEndpoint: _genericEndpoint,
        genericApiKey: _genericApiKey,
        genericModel: _genericModel,
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
        final value = _clean(values['deeplApiKey'] as String?);
        if (value != _deeplApiKey) {
          _deeplApiKey = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('deeplEndpoint')) {
        final value = _parseEndpoint(values['deeplEndpoint']);
        if (value != null && value != _deeplEndpoint) {
          _deeplEndpoint = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('genericEndpoint') &&
          values.containsKey('genericEndpoint')) {
        final value = _parseEndpoint(values['genericEndpoint']);
        if (value != _genericEndpoint) {
          _genericEndpoint = value;
          changed = true;
        }
      }
      if (!_changedBeforeLoad.contains('genericApiKey') &&
          values.containsKey('genericApiKey')) {
        final value = _clean(values['genericApiKey'] as String?);
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

  static Uri? _parseEndpoint(Object? raw) {
    if (raw is! String) return null;
    final endpoint = _optionalEndpoint(raw);
    return endpoint == null
        ? null
        : normalizeOpenAiCompatibleEndpoint(endpoint);
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
    final parsedEndpoint = _optionalEndpoint(endpoint);
    _genericEndpoint = parsedEndpoint == null
        ? null
        : normalizeOpenAiCompatibleEndpoint(parsedEndpoint);
    _genericApiKey = _clean(apiKey);
    _genericModel = model.trim().isEmpty ? 'gpt-4.1-mini' : model.trim();
    _markChanged('genericEndpoint');
    _markChanged('genericApiKey');
    _markChanged('genericModel');
    notifyListeners();
  }

  static Uri _validatedEndpoint(String value, Uri fallback) =>
      _optionalEndpoint(value) ?? fallback;

  static Uri? _optionalEndpoint(String value) {
    final candidate = Uri.tryParse(value.trim());
    if (candidate == null ||
        (candidate.scheme != 'https' && candidate.scheme != 'http')) {
      return null;
    }
    return candidate;
  }

  static String? _clean(String? value) {
    final result = value?.trim();
    return result == null || result.isEmpty ? null : result;
  }
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
    }));
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
