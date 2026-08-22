import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../core/diagnostics/recognition_result_store.dart';
import '../../domain/subtitles/transcript_document.dart';
import '../../domain/translation/translation_service.dart';

/// Bounded, session-aware translation scheduler. A batch is one provider call;
/// every individual segment keeps its own stable ID and retry state.
class TranscriptTranslationQueue extends ChangeNotifier {
  TranscriptTranslationQueue({
    required RecognitionResultStore results,
    required TranslationService service,
    required String targetLanguage,
    this.maxConcurrent = 2,
    this.batchSize = 1,
    this.contextEnabled = true,
    this.maxQueued = 200,
    this.timeout = defaultTranslationRequestTimeout,
    this.maxAttempts = 3,
    this.retryDelay = const Duration(seconds: 1),
    this.batchWait = const Duration(milliseconds: 300),
    DiagnosticLogService? logs,
  })  : _results = results,
        _service = service,
        _targetLanguage = targetLanguage,
        _logs = logs {
    _validateLimits();
    _results.addListener(sync);
    sync();
  }

  final RecognitionResultStore _results;
  TranslationService _service;
  final DiagnosticLogService? _logs;
  String _targetLanguage;
  int maxConcurrent;
  int batchSize;
  bool contextEnabled;
  final int maxQueued;
  final Duration timeout;
  final int maxAttempts;
  final Duration retryDelay;
  final Duration batchWait;
  final List<_TranslationJob> _waiting = [];
  final Set<String> _knownKeys = {};
  final Map<String, Timer> _retryTimers = {};
  final List<Duration> _apiWaitSamples = [];
  Timer? _batchTimer;
  String? _sessionId;
  int _generation = 0;
  int _scheduleEpoch = 0;
  int _active = 0;
  bool _disposed = false;
  bool _unavailableLogged = false;
  int _completedApiRequests = 0;
  int _totalBatchSegments = 0;
  int _maxObservedActiveRequests = 0;
  int _startedSegments = 0;
  int _completedSegments = 0;
  int _failedAttempts = 0;
  int _timeoutAttempts = 0;
  int _terminalFailedSegments = 0;
  int _retriedSegments = 0;
  Duration _totalApiWait = Duration.zero;
  Duration _totalQueueWait = Duration.zero;
  Duration _totalEndToEndWait = Duration.zero;
  Duration? _lastApiWait;
  Duration? _lastQueueWait;
  Duration? _lastEndToEndWait;
  Duration? _priorityPosition;

  TranslationServiceStatus get serviceStatus =>
      _service is TranslationServiceStatusProvider
          ? (_service as TranslationServiceStatusProvider).status
          : const TranslationServiceStatus.available(provider: 'custom');

  String get targetLanguage => _targetLanguage;
  int get waitingCount => _waiting.length;
  int get activeCount => _active;

  TranslationQueueMetrics get metrics => TranslationQueueMetrics(
        configuredBatchSize: batchSize,
        configuredMaxConcurrent: maxConcurrent,
        waitingSegments: waitingCount,
        activeRequests: activeCount,
        completedApiRequests: _completedApiRequests,
        averageBatchSize: _averageBatchSize,
        maxObservedActiveRequests: _maxObservedActiveRequests,
        completedSegments: _completedSegments,
        failedAttempts: _failedAttempts,
        timeoutAttempts: _timeoutAttempts,
        terminalFailedSegments: _terminalFailedSegments,
        retriedSegments: _retriedSegments,
        averageApiWait: _average(_totalApiWait, _completedApiRequests),
        p95ApiWait: _percentile(_apiWaitSamples, 0.95),
        lastApiWait: _lastApiWait,
        averageQueueWait: _average(_totalQueueWait, _startedSegments),
        lastQueueWait: _lastQueueWait,
        averageEndToEndWait: _average(_totalEndToEndWait, _completedSegments),
        lastEndToEndWait: _lastEndToEndWait,
      );

  void updateConfiguration({
    required TranslationService service,
    required String targetLanguage,
  }) {
    if (_disposed ||
        (identical(_service, service) && _targetLanguage == targetLanguage)) {
      return;
    }
    final previousTargetLanguage = _targetLanguage;
    _cancelActiveRequests(_service);
    _service = service;
    _targetLanguage = targetLanguage;
    _restartScheduling(resetMetrics: true, cancelActiveRequests: false);
    _results.clearTranslationsForTargetLanguage(previousTargetLanguage);
    if (previousTargetLanguage != targetLanguage) {
      _results.clearTranslationsForTargetLanguage(targetLanguage);
    }
    sync();
  }

  /// Applies settings without discarding completed translations. New batches
  /// start immediately under the new limits; old calls are allowed to finish.
  void updateScheduling({
    required int maxConcurrent,
    required int batchSize,
    bool? contextEnabled,
  }) {
    final nextContextEnabled = contextEnabled ?? this.contextEnabled;
    if (_disposed ||
        (this.maxConcurrent == maxConcurrent &&
            this.batchSize == batchSize &&
            this.contextEnabled == nextContextEnabled)) {
      return;
    }
    this.maxConcurrent = maxConcurrent;
    this.batchSize = batchSize;
    this.contextEnabled = nextContextEnabled;
    _validateLimits();
    _batchTimer?.cancel();
    _batchTimer = null;
    _logs?.info('翻译', '翻译调度设置已应用', {
      '每批字幕数': batchSize,
      '并发请求数': maxConcurrent,
      '携带上文': nextContextEnabled ? '开' : '关',
    });
    _pump();
    _notifyMetrics();
  }

  /// Drops queued work before [position] and schedules the current subtitle
  /// and later subtitles before any historical work. In-flight calls cannot be
  /// forcibly cancelled, but their results cannot enter this scheduling epoch.
  void prioritizeFrom(Duration position) {
    if (_disposed) return;
    final priorityPosition = position.isNegative ? Duration.zero : position;
    if (_priorityPosition == priorityPosition) return;
    _priorityPosition = priorityPosition;
    _restartScheduling(resetMetrics: false);
    sync();
  }

  void sync() {
    if (_disposed) return;
    final document = _results.document;
    final nextSessionId = document?.sessionId;
    if (nextSessionId != _sessionId) {
      _sessionId = nextSessionId;
      _priorityPosition = null;
      _restartScheduling(resetMetrics: true);
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
      if (_priorityPosition != null &&
          segment.endMs <= _priorityPosition!.inMilliseconds) {
        continue;
      }
      final key = _jobKey(document.sessionId, segment);
      if (_knownKeys.contains(key) ||
          _hasTranslatedTranslation(document, segment)) {
        continue;
      }
      if (_sameLanguage(segment.language, targetLanguage)) {
        _knownKeys.add(key);
        _results.upsertTranslation(_translationFor(
          segment: segment,
          text: segment.text,
          status: TranscriptTranslationStatus.translated,
          provider: 'identity',
        ));
        continue;
      }
      if (_waiting.length + _active * batchSize >= maxQueued) break;
      final now = DateTime.now();
      _knownKeys.add(key);
      _waiting.add(_TranslationJob(
        sessionId: document.sessionId,
        segment: segment,
        key: key,
        generation: _generation,
        scheduleEpoch: _scheduleEpoch,
        attempt: 1,
        enqueuedAt: now,
        firstEnqueuedAt: now,
      ));
      _results.upsertTranslation(_translationFor(
        segment: segment,
        text: '',
        status: TranscriptTranslationStatus.pending,
        provider: status.provider,
      ));
    }
    _pump();
  }

  void _pump() {
    final effectiveBatchSize = _supportsBatch ? batchSize : 1;
    while (!_disposed && _active < maxConcurrent && _waiting.isNotEmpty) {
      if (_waiting.length < effectiveBatchSize) {
        _scheduleBatchPump();
        return;
      }
      _startBatch(_takeBatch(effectiveBatchSize));
    }
    _notifyMetrics();
  }

  void _scheduleBatchPump() {
    if (_batchTimer != null || _disposed) return;
    _batchTimer = Timer(batchWait, () {
      _batchTimer = null;
      if (_disposed || _waiting.isEmpty || _active >= maxConcurrent) return;
      _startBatch(_takeBatch(_supportsBatch ? batchSize : 1));
      _pump();
    });
  }

  bool get _supportsBatch => _service is BatchTranslationService;

  List<_TranslationJob> _takeBatch(int configuredSize) {
    final first = _waiting.first;
    final limit = first.forceSingle ? 1 : configuredSize;
    var count = 0;
    while (count < _waiting.length && count < limit) {
      if (count > 0 && _waiting[count].forceSingle) break;
      count++;
    }
    final jobs = _waiting.sublist(0, count);
    _waiting.removeRange(0, count);
    return jobs;
  }

  void _startBatch(List<_TranslationJob> jobs) {
    _batchTimer?.cancel();
    _batchTimer = null;
    _active++;
    if (_active > _maxObservedActiveRequests) {
      _maxObservedActiveRequests = _active;
    }
    unawaited(_runBatch(jobs));
  }

  double? get _averageBatchSize => _completedApiRequests == 0
      ? null
      : _totalBatchSegments / _completedApiRequests;

  Future<void> _runBatch(List<_TranslationJob> jobs) async {
    final now = DateTime.now();
    final queueWaits = <_TranslationJob, Duration>{};
    for (final job in jobs) {
      _startedSegments++;
      final queueWait = now.difference(job.enqueuedAt);
      queueWaits[job] = queueWait;
      _writeIfCurrent(
          job,
          _translationFor(
            segment: job.segment,
            text: '',
            status: TranscriptTranslationStatus.translating,
            provider: serviceStatus.provider,
          ));
      _recordQueueWait(now.difference(job.enqueuedAt));
    }
    final requestTimer = Stopwatch()..start();
    var apiWaitRecorded = false;
    try {
      final requests = jobs
          .map((job) => TranslationRequest(
                segmentId: job.segment.id,
                text: job.segment.text,
                sourceLanguage: job.segment.language,
                targetLanguage: targetLanguage,
                context: contextEnabled
                    ? _contextLinesBefore(job.segment)
                    : const [],
              ))
          .toList(growable: false);
      final results = await _translate(requests);
      if (_isCurrentBatch(jobs)) {
        _recordApiWait(requestTimer.elapsed, jobs.length);
        apiWaitRecorded = true;
      }
      if (!_isCurrentBatch(jobs)) return;
      final byId = {for (final result in results) result.segmentId: result};
      if (byId.length != jobs.length ||
          jobs.any((job) =>
              !byId.containsKey(job.segment.id) ||
              byId[job.segment.id]!.text.trim().isEmpty)) {
        throw const FormatException('批量翻译结果与请求片段不匹配。');
      }
      final completedAt = DateTime.now();
      for (final job in jobs) {
        final result = byId[job.segment.id]!;
        _writeIfCurrent(
            job,
            _translationFor(
              segment: job.segment,
              text: result.text,
              status: TranscriptTranslationStatus.translated,
              provider: result.provider,
            ));
        _completedSegments++;
        _recordEndToEndWait(completedAt.difference(job.firstEnqueuedAt));
        _cancelRetryTimer(job.key);
      }
      _logs?.debug('翻译', '字幕批量翻译完成', {
        '会话 ID': jobs.first.sessionId,
        '片段数': jobs.length,
        '尝试次数': jobs.map((job) => job.attempt).reduce(_max),
        '请求耗时 ms': requestTimer.elapsedMilliseconds,
        '平均排队 ms': _averageMilliseconds(jobs, (job) => queueWaits[job]!),
        '平均端到端 ms': _averageMilliseconds(
            jobs, (job) => DateTime.now().difference(job.firstEnqueuedAt)),
        'Provider': results.first.provider,
      });
    } on Object catch (error) {
      if (_isCurrentBatch(jobs)) {
        if (!apiWaitRecorded) {
          _recordApiWait(requestTimer.elapsed, jobs.length);
        }
        final retryable = _isRetryable(error);
        final retryAfter = _retryAfterOf(error);
        for (final job in jobs) {
          _failedAttempts++;
          if (error is TimeoutException) _timeoutAttempts++;
          _writeIfCurrent(
              job,
              _translationFor(
                segment: job.segment,
                text: '',
                status: TranscriptTranslationStatus.failed,
                provider: serviceStatus.provider,
                error: _errorDescription(error),
              ));
          if (retryable) {
            _scheduleRetry(job,
                forceSingle: jobs.length > 1, retryAfter: retryAfter);
            if (job.attempt >= maxAttempts) {
              _terminalFailedSegments++;
            }
          } else {
            _terminalFailedSegments++;
          }
        }
        _logs?.warning('翻译', '字幕翻译失败', {
          '会话 ID': jobs.first.sessionId,
          '片段数': jobs.length,
          '错误类型': error.runtimeType,
          '错误分类': _errorCategory(error),
          '可重试': retryable,
          if (retryAfter != null) '建议重试延迟 ms': retryAfter.inMilliseconds,
          '错误信息': error.toString(),
          '批量请求': jobs.length,
          ..._serviceDiagnostics,
          '尝试次数': jobs.map((job) => job.attempt).reduce(_max),
          '请求耗时 ms': requestTimer.elapsedMilliseconds,
          '平均排队 ms': _averageMilliseconds(jobs, (job) => queueWaits[job]!),
        });
      }
    } finally {
      if (_isCurrentBatch(jobs)) {
        _active--;
        sync();
      }
    }
  }

  int _max(int left, int right) => left > right ? left : right;

  String _errorCategory(Object error) => switch (error) {
        TimeoutException() => 'timeout',
        TranslationProviderException() =>
          error.retryable ? 'provider_retryable' : 'provider_fatal',
        FormatException() => 'response_format',
        _ => 'provider_error',
      };

  bool _isRetryable(Object error) =>
      error is! TranslationProviderException || error.retryable;

  Duration? _retryAfterOf(Object error) =>
      error is TranslationProviderException ? error.retryAfter : null;

  String _errorDescription(Object error) {
    if (error is TranslationProviderException) {
      return error.retryable ? error.message : '${error.message}（不会自动重试）';
    }
    if (error is TimeoutException) return '翻译请求超时';
    if (error is FormatException) return '翻译响应格式错误';
    return error.runtimeType.toString();
  }

  Map<String, Object?> get _serviceDiagnostics =>
      _service is TranslationServiceDiagnosticsProvider
          ? (_service as TranslationServiceDiagnosticsProvider).diagnostics
          : {'Provider': serviceStatus.provider};

  Future<List<TranslationResult>> _translate(
    List<TranslationRequest> requests,
  ) {
    final service = _service;
    if (service is TimedBatchTranslationService) {
      return service.translateBatchWithTimeout(requests, timeout);
    }
    if (service is BatchTranslationService) {
      return (service as BatchTranslationService)
          .translateBatch(requests)
          .timeout(timeout);
    }
    if (service is TimedTranslationService) {
      return service
          .translateWithTimeout(requests.single, timeout)
          .then((result) => [result]);
    }
    return Future.wait(requests.map(service.translate)).timeout(timeout);
  }

  static const _maximumContextLines = 3;

  /// Preceding timeline lines by media time for pronoun and terminology
  /// context. Translations are attached opportunistically when already done;
  /// no request ever waits for another one to finish.
  List<TranslationContextLine> _contextLinesBefore(TranscriptSegment segment) {
    final document = _results.document;
    if (document == null) return const [];
    final preceding = <TranslationContextLine>[];
    for (final candidate in document.orderedSegments) {
      if (candidate.id == segment.id && candidate.text == segment.text) break;
      if (candidate.endMs > segment.startMs) continue;
      preceding.add(TranslationContextLine(
        text: candidate.text,
        translation: _translatedTextFor(document, candidate),
      ));
      if (preceding.length > _maximumContextLines) {
        preceding.removeAt(0);
      }
    }
    return List.unmodifiable(preceding);
  }

  String? _translatedTextFor(
    TranscriptDocument document,
    TranscriptSegment segment,
  ) {
    for (final translation in document.translations) {
      if (translation.segmentId == segment.id &&
          translation.targetLanguage == targetLanguage &&
          translation.sourceText == segment.text &&
          translation.status == TranscriptTranslationStatus.translated) {
        return translation.text;
      }
    }
    return null;
  }

  bool _hasTranslatedTranslation(
    TranscriptDocument document,
    TranscriptSegment segment,
  ) =>
      document.translations.any((translation) =>
          translation.segmentId == segment.id &&
          translation.targetLanguage == targetLanguage &&
          translation.sourceText == segment.text &&
          translation.status == TranscriptTranslationStatus.translated);

  TranscriptTranslation _translationFor({
    required TranscriptSegment segment,
    required String text,
    required TranscriptTranslationStatus status,
    required String provider,
    String? error,
  }) =>
      TranscriptTranslation(
        segmentId: segment.id,
        targetLanguage: targetLanguage,
        text: text,
        status: status,
        sourceText: segment.text,
        sourceLanguage: segment.language,
        provider: provider,
        error: error,
      );

  void _writeIfCurrent(_TranslationJob job, TranscriptTranslation value) {
    if (!_isCurrent(job)) return;
    final document = _results.document;
    if (document == null ||
        document.sessionId != job.sessionId ||
        !document.segments.any((segment) =>
            segment.id == job.segment.id && segment.text == job.segment.text)) {
      return;
    }
    _results.upsertTranslation(value);
  }

  bool _isCurrent(_TranslationJob job) =>
      !_disposed &&
      _sessionId == job.sessionId &&
      _generation == job.generation &&
      _scheduleEpoch == job.scheduleEpoch;

  bool _isCurrentBatch(List<_TranslationJob> jobs) =>
      jobs.isNotEmpty && jobs.every(_isCurrent);

  void _scheduleRetry(
    _TranslationJob job, {
    required bool forceSingle,
    Duration? retryAfter,
  }) {
    if (job.attempt >= maxAttempts || _disposed) return;
    _retriedSegments++;
    final delay = retryAfter == null
        ? retryDelay * job.attempt
        : (retryDelay * job.attempt > retryAfter
            ? retryDelay * job.attempt
            : retryAfter);
    _cancelRetryTimer(job.key);
    _retryTimers[job.key] = Timer(delay, () {
      _retryTimers.remove(job.key);
      if (!_isCurrent(job)) return;
      _tryEnqueueRetry(job, forceSingle: forceSingle);
    });
  }

  void _tryEnqueueRetry(
    _TranslationJob job, {
    required bool forceSingle,
  }) {
    if (!_isCurrent(job)) return;
    final document = _results.document;
    TranscriptSegment? segment;
    if (document != null) {
      for (final candidate in document.segments) {
        if (candidate.id == job.segment.id &&
            candidate.text == job.segment.text) {
          segment = candidate;
          break;
        }
      }
    }
    if (document == null ||
        segment == null ||
        _hasTranslatedTranslation(document, segment)) {
      return;
    }
    if (_waiting.length + _active * batchSize >= maxQueued) {
      _retryTimers[job.key] = Timer(batchWait, () {
        _retryTimers.remove(job.key);
        _tryEnqueueRetry(job, forceSingle: forceSingle);
      });
      return;
    }
    _waiting.add(_TranslationJob(
      sessionId: job.sessionId,
      segment: segment,
      key: job.key,
      generation: job.generation,
      scheduleEpoch: job.scheduleEpoch,
      attempt: job.attempt + 1,
      enqueuedAt: DateTime.now(),
      firstEnqueuedAt: job.firstEnqueuedAt,
      forceSingle: forceSingle,
    ));
    _results.upsertTranslation(_translationFor(
      segment: segment,
      text: '',
      status: TranscriptTranslationStatus.pending,
      provider: serviceStatus.provider,
    ));
    _pump();
  }

  void _restartScheduling({
    required bool resetMetrics,
    bool cancelActiveRequests = true,
  }) {
    if (cancelActiveRequests) _cancelActiveRequests(_service);
    ++_generation;
    ++_scheduleEpoch;
    _active = 0;
    _waiting.clear();
    _knownKeys.clear();
    _batchTimer?.cancel();
    _batchTimer = null;
    _cancelRetryTimers();
    _unavailableLogged = false;
    if (resetMetrics) _resetMetrics();
  }

  void _cancelActiveRequests(TranslationService service) {
    if (service is TranslationServiceRequestCanceller) {
      (service as TranslationServiceRequestCanceller).cancelActiveRequests();
    }
  }

  void _cancelRetryTimer(String key) => _retryTimers.remove(key)?.cancel();

  void _cancelRetryTimers() {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
  }

  String _jobKey(String sessionId, TranscriptSegment segment) =>
      '$sessionId\u0000${segment.id}\u0000${segment.text}\u0000'
      '${segment.language}\u0000$targetLanguage';

  bool _sameLanguage(String source, String target) =>
      source.toLowerCase().split(RegExp('[-_]')).first ==
      target.toLowerCase().split(RegExp('[-_]')).first;

  void _validateLimits() {
    if (maxConcurrent < 1 ||
        batchSize < 1 ||
        maxQueued < maxConcurrent ||
        maxAttempts < 1 ||
        retryDelay.isNegative ||
        batchWait.isNegative) {
      throw ArgumentError('translation queue limits are invalid');
    }
  }

  void _recordApiWait(Duration elapsed, int segmentCount) {
    _completedApiRequests++;
    _totalBatchSegments += segmentCount;
    _totalApiWait += elapsed;
    _lastApiWait = elapsed;
    _apiWaitSamples.add(elapsed);
    if (_apiWaitSamples.length > 128) _apiWaitSamples.removeAt(0);
    _notifyMetrics();
  }

  void _recordQueueWait(Duration elapsed) {
    _totalQueueWait += elapsed;
    _lastQueueWait = elapsed;
  }

  void _recordEndToEndWait(Duration elapsed) {
    _totalEndToEndWait += elapsed;
    _lastEndToEndWait = elapsed;
  }

  Duration? _average(Duration total, int count) =>
      count == 0 ? null : total ~/ count;

  Duration? _percentile(List<Duration> values, double percentile) {
    if (values.isEmpty) return null;
    final ordered = [...values]..sort();
    final index = ((ordered.length - 1) * percentile).ceil();
    return ordered[index];
  }

  void _resetMetrics() {
    _completedApiRequests = 0;
    _totalBatchSegments = 0;
    _maxObservedActiveRequests = 0;
    _startedSegments = 0;
    _completedSegments = 0;
    _failedAttempts = 0;
    _timeoutAttempts = 0;
    _terminalFailedSegments = 0;
    _retriedSegments = 0;
    _totalApiWait = Duration.zero;
    _totalQueueWait = Duration.zero;
    _totalEndToEndWait = Duration.zero;
    _lastApiWait = null;
    _lastQueueWait = null;
    _lastEndToEndWait = null;
    _apiWaitSamples.clear();
    _notifyMetrics();
  }

  int _averageMilliseconds(
    List<_TranslationJob> jobs,
    Duration Function(_TranslationJob job) elapsed,
  ) {
    if (jobs.isEmpty) return 0;
    final total = jobs.map((job) => elapsed(job).inMilliseconds).fold<int>(
          0,
          (sum, value) => sum + value,
        );
    return total ~/ jobs.length;
  }

  void _notifyMetrics() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    ++_scheduleEpoch;
    _waiting.clear();
    _batchTimer?.cancel();
    _cancelRetryTimers();
    _results.removeListener(sync);
    super.dispose();
  }
}

class TranslationQueueMetrics {
  const TranslationQueueMetrics({
    required this.configuredBatchSize,
    required this.configuredMaxConcurrent,
    required this.waitingSegments,
    required this.activeRequests,
    required this.completedApiRequests,
    required this.averageBatchSize,
    required this.maxObservedActiveRequests,
    required this.completedSegments,
    required this.failedAttempts,
    required this.timeoutAttempts,
    required this.terminalFailedSegments,
    required this.retriedSegments,
    required this.averageApiWait,
    required this.p95ApiWait,
    required this.lastApiWait,
    required this.averageQueueWait,
    required this.lastQueueWait,
    required this.averageEndToEndWait,
    required this.lastEndToEndWait,
  });

  final int configuredBatchSize;
  final int configuredMaxConcurrent;
  final int waitingSegments;
  final int activeRequests;
  final int completedApiRequests;
  final double? averageBatchSize;
  final int maxObservedActiveRequests;
  final int completedSegments;

  /// Number of segment attempts that ended in an error, including retries.
  final int failedAttempts;
  final int timeoutAttempts;

  /// Number of segments that exhausted [TranscriptTranslationQueue.maxAttempts].
  final int terminalFailedSegments;
  final int retriedSegments;
  final Duration? averageApiWait;
  final Duration? p95ApiWait;
  final Duration? lastApiWait;
  final Duration? averageQueueWait;
  final Duration? lastQueueWait;
  final Duration? averageEndToEndWait;
  final Duration? lastEndToEndWait;
}

class _TranslationJob {
  const _TranslationJob({
    required this.sessionId,
    required this.segment,
    required this.key,
    required this.generation,
    required this.scheduleEpoch,
    required this.attempt,
    required this.enqueuedAt,
    required this.firstEnqueuedAt,
    this.forceSingle = false,
  });

  final String sessionId;
  final TranscriptSegment segment;
  final String key;
  final int generation;
  final int scheduleEpoch;
  final int attempt;
  final DateTime enqueuedAt;
  final DateTime firstEnqueuedAt;
  final bool forceSingle;
}
