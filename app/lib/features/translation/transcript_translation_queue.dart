import 'dart:async';

import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../core/diagnostics/recognition_result_store.dart';
import '../../domain/subtitles/transcript_document.dart';
import '../../domain/translation/translation_service.dart';

/// Bounded session-aware translation queue. It only accepts assembled final
/// transcript segments and drops every late result whose session or source text
/// no longer matches the current document.
class TranscriptTranslationQueue {
  TranscriptTranslationQueue({
    required RecognitionResultStore results,
    required TranslationService service,
    required String targetLanguage,
    this.maxConcurrent = 2,
    this.maxQueued = 200,
    this.timeout = const Duration(seconds: 20),
    DiagnosticLogService? logs,
  })  : _results = results,
        _service = service,
        _targetLanguage = targetLanguage,
        _logs = logs {
    if (maxConcurrent < 1 || maxQueued < maxConcurrent) {
      throw ArgumentError('translation queue limits are invalid');
    }
    _results.addListener(sync);
    sync();
  }

  final RecognitionResultStore _results;
  TranslationService _service;
  final DiagnosticLogService? _logs;
  String _targetLanguage;
  final int maxConcurrent;
  final int maxQueued;
  final Duration timeout;
  final List<_TranslationJob> _waiting = [];
  final Set<String> _knownKeys = {};
  String? _sessionId;
  int _generation = 0;
  int _active = 0;
  bool _disposed = false;
  bool _unavailableLogged = false;

  TranslationServiceStatus get serviceStatus =>
      _service is TranslationServiceStatusProvider
          ? (_service as TranslationServiceStatusProvider).status
          : const TranslationServiceStatus.available(provider: 'custom');

  String get targetLanguage => _targetLanguage;

  int get waitingCount => _waiting.length;
  int get activeCount => _active;

  void updateConfiguration({
    required TranslationService service,
    required String targetLanguage,
  }) {
    if (_disposed ||
        (identical(_service, service) && _targetLanguage == targetLanguage)) {
      return;
    }
    final previousTargetLanguage = _targetLanguage;
    _service = service;
    _targetLanguage = targetLanguage;
    ++_generation;
    _active = 0;
    _waiting.clear();
    _knownKeys.clear();
    _unavailableLogged = false;
    _results.clearTranslationsForTargetLanguage(previousTargetLanguage);
    if (previousTargetLanguage != targetLanguage) {
      _results.clearTranslationsForTargetLanguage(targetLanguage);
    }
    sync();
  }

  void sync() {
    if (_disposed) return;
    final document = _results.document;
    final nextSessionId = document?.sessionId;
    if (nextSessionId != _sessionId) {
      _sessionId = nextSessionId;
      ++_generation;
      // Old provider calls are cooperative-only. Detach them from the new
      // session's concurrency budget so a slow timeout cannot stall it.
      _active = 0;
      _waiting.clear();
      _knownKeys.clear();
      _unavailableLogged = false;
    }
    if (document == null) return;
    final status = serviceStatus;
    if (!status.available) {
      if (!_unavailableLogged) {
        _unavailableLogged = true;
        _logs?.warning('翻译', '翻译服务未配置，稳定字幕将保留原文', {
          'Provider': status.provider,
          '原因': status.message,
        });
      }
      return;
    }
    _unavailableLogged = false;
    for (final segment in document.orderedSegments) {
      final key = _jobKey(document.sessionId, segment);
      if (_knownKeys.contains(key) ||
          _hasCurrentTranslation(document, segment)) {
        continue;
      }
      if (_sameLanguage(segment.language, targetLanguage)) {
        _knownKeys.add(key);
        _results.upsertTranslation(TranscriptTranslation(
          segmentId: segment.id,
          targetLanguage: targetLanguage,
          text: segment.text,
          status: TranscriptTranslationStatus.translated,
          sourceText: segment.text,
          sourceLanguage: segment.language,
          provider: 'identity',
        ));
        continue;
      }
      if (_waiting.length + _active >= maxQueued) break;
      _knownKeys.add(key);
      _waiting.add(_TranslationJob(
        sessionId: document.sessionId,
        segment: segment,
        key: key,
      ));
      _results.upsertTranslation(TranscriptTranslation(
        segmentId: segment.id,
        targetLanguage: targetLanguage,
        text: '',
        status: TranscriptTranslationStatus.pending,
        sourceText: segment.text,
        sourceLanguage: segment.language,
        provider: status.provider,
      ));
    }
    _pump();
  }

  bool _hasCurrentTranslation(
    TranscriptDocument document,
    TranscriptSegment segment,
  ) =>
      document.translations.any((translation) =>
          translation.segmentId == segment.id &&
          translation.targetLanguage == targetLanguage &&
          translation.sourceText == segment.text);

  void _pump() {
    while (!_disposed && _active < maxConcurrent && _waiting.isNotEmpty) {
      final job = _waiting.removeAt(0);
      _active++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_TranslationJob job) async {
    final generation = _generation;
    _writeIfCurrent(
      job,
      TranscriptTranslation(
        segmentId: job.segment.id,
        targetLanguage: targetLanguage,
        text: '',
        status: TranscriptTranslationStatus.translating,
        sourceText: job.segment.text,
        sourceLanguage: job.segment.language,
        provider: serviceStatus.provider,
      ),
    );
    try {
      final result = await _service
          .translate(TranslationRequest(
            segmentId: job.segment.id,
            text: job.segment.text,
            sourceLanguage: job.segment.language,
            targetLanguage: targetLanguage,
          ))
          .timeout(timeout);
      if (generation != _generation) return;
      if (result.segmentId != job.segment.id) {
        throw StateError('翻译结果片段 ID 不匹配。');
      }
      _writeIfCurrent(
        job,
        TranscriptTranslation(
          segmentId: job.segment.id,
          targetLanguage: targetLanguage,
          text: result.text,
          status: TranscriptTranslationStatus.translated,
          sourceText: job.segment.text,
          sourceLanguage: job.segment.language,
          provider: result.provider,
        ),
      );
      _logs?.info('翻译', '字幕翻译完成', {
        '会话 ID': job.sessionId,
        '片段 ID': job.segment.id,
        '源语言': job.segment.language,
        '目标语言': targetLanguage,
        'Provider': result.provider,
      });
    } on Object catch (error) {
      if (generation == _generation) {
        _writeIfCurrent(
          job,
          TranscriptTranslation(
            segmentId: job.segment.id,
            targetLanguage: targetLanguage,
            text: '',
            status: TranscriptTranslationStatus.failed,
            sourceText: job.segment.text,
            sourceLanguage: job.segment.language,
            provider: serviceStatus.provider,
            error: error.runtimeType.toString(),
          ),
        );
        _logs?.warning('翻译', '字幕翻译失败', {
          '会话 ID': job.sessionId,
          '片段 ID': job.segment.id,
          '错误类型': error.runtimeType,
        });
      }
    } finally {
      if (generation == _generation) {
        _active--;
        if (!_disposed) sync();
      }
    }
  }

  void _writeIfCurrent(_TranslationJob job, TranscriptTranslation value) {
    if (_disposed || _sessionId != job.sessionId) return;
    final document = _results.document;
    if (document == null ||
        document.sessionId != job.sessionId ||
        !document.segments.any((segment) =>
            segment.id == job.segment.id && segment.text == job.segment.text)) {
      return;
    }
    _results.upsertTranslation(value);
  }

  String _jobKey(String sessionId, TranscriptSegment segment) =>
      '$sessionId\u0000${segment.id}\u0000${segment.text}\u0000'
      '${segment.language}\u0000$targetLanguage';

  bool _sameLanguage(String source, String target) {
    final sourceBase = source.toLowerCase().split(RegExp('[-_]')).first;
    final targetBase = target.toLowerCase().split(RegExp('[-_]')).first;
    return sourceBase == targetBase;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _waiting.clear();
    _results.removeListener(sync);
  }
}

class _TranslationJob {
  const _TranslationJob({
    required this.sessionId,
    required this.segment,
    required this.key,
  });

  final String sessionId;
  final TranscriptSegment segment;
  final String key;
}
