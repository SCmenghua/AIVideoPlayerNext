import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/core/diagnostics/recognition_result_store.dart';
import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/domain/subtitles/transcript_document.dart';
import 'package:ai_video_player_next/domain/translation/translation_service.dart';
import 'package:ai_video_player_next/features/translation/transcript_translation_queue.dart';

class _ControlledTranslationService
    implements TranslationService, TranslationServiceStatusProvider {
  _ControlledTranslationService({
    this.fail = false,
    this.empty = false,
    this.failuresBeforeSuccess = 0,
  });

  final bool fail;
  final bool empty;
  final int failuresBeforeSuccess;
  final List<TranslationRequest> requests = [];
  final List<Completer<TranslationResult>> pending = [];
  int active = 0;
  int maximumActive = 0;

  @override
  TranslationServiceStatus get status =>
      const TranslationServiceStatus.available(provider: 'test');

  @override
  Future<TranslationResult> translate(TranslationRequest request) {
    requests.add(request);
    active++;
    if (active > maximumActive) maximumActive = active;
    final completer = Completer<TranslationResult>();
    pending.add(completer);
    if (fail || requests.length <= failuresBeforeSuccess) {
      completer.completeError(StateError('test failure'));
    } else if (empty) {
      completer.complete(TranslationResult(
        segmentId: request.segmentId,
        text: '',
        provider: 'test',
      ));
    }
    return completer.future.whenComplete(() => active--);
  }

  void completeNext() {
    final completer = pending.removeAt(0);
    final request = requests.first;
    completer.complete(TranslationResult(
      segmentId: request.segmentId,
      text: 'translated',
      provider: 'test',
    ));
  }
}

class _UnavailableTranslationService
    implements TranslationService, TranslationServiceStatusProvider {
  int requestCount = 0;

  @override
  TranslationServiceStatus get status =>
      const TranslationServiceStatus.unavailable(
        provider: 'test',
        message: 'not configured',
      );

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    requestCount++;
    throw StateError('must not be called');
  }
}

class _ControlledBatchTranslationService
    implements
        TranslationService,
        BatchTranslationService,
        TranslationServiceStatusProvider {
  final List<List<TranslationRequest>> requests = [];
  final List<Completer<List<TranslationResult>>> pending = [];
  int active = 0;
  int maximumActive = 0;

  @override
  TranslationServiceStatus get status =>
      const TranslationServiceStatus.available(provider: 'batch-test');

  @override
  Future<TranslationResult> translate(TranslationRequest request) async =>
      (await translateBatch([request])).single;

  @override
  Future<List<TranslationResult>> translateBatch(
      List<TranslationRequest> batch) {
    requests.add(batch);
    active++;
    if (active > maximumActive) maximumActive = active;
    final completer = Completer<List<TranslationResult>>();
    pending.add(completer);
    return completer.future.whenComplete(() {
      active--;
      pending.remove(completer);
    });
  }
}

RecognitionEvent _event({
  required String sessionId,
  required String segmentId,
  required String text,
  String language = 'en',
  int startSeconds = 0,
}) =>
    RecognitionEvent(
      sessionId: sessionId,
      segmentId: segmentId,
      start: Duration(seconds: startSeconds),
      end: Duration(seconds: startSeconds + 2),
      text: text,
      language: language,
      kind: RecognitionKind.finalResult,
      source: RecognitionSource.whisperCpp,
    );

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('uses a forty-second default request timeout', () {
    final store = RecognitionResultStore();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: _ControlledTranslationService(),
      targetLanguage: 'zh-CN',
    );

    expect(queue.timeout, const Duration(seconds: 40));
    queue.dispose();
  });

  test('queues stable final segments and writes translated text by ID',
      () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      maxConcurrent: 1,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'seg-1',
      text: 'hello',
    ));
    await _settle();

    expect(service.requests.single.text, 'hello');
    expect(service.requests.single.sourceLanguage, 'en');
    expect(service.requests.single.targetLanguage, 'zh-CN');
    expect(store.translationResults.single.translation.status,
        TranscriptTranslationStatus.translating);

    service.pending.single.complete(const TranslationResult(
      segmentId: 'seg-000001',
      text: '你好',
      provider: 'test',
    ));
    await _settle();

    final result = store.translationResults.single.translation;
    expect(result.status, TranscriptTranslationStatus.translated,
        reason: result.error);
    expect(result.text, '你好');
    expect(result.segmentId, 'seg-000001');
  });

  test('keeps translation concurrency bounded', () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      maxConcurrent: 2,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    for (var index = 0; index < 4; index++) {
      store.addRecognition(_event(
        sessionId: 'session-1',
        segmentId: 'seg-$index',
        text: 'line $index',
        startSeconds: index * 2,
      ));
    }
    await _settle();

    expect(service.requests, hasLength(2));
    expect(service.maximumActive, 2);
    expect(queue.waitingCount, 2);
  });

  test('keeps non-batch providers at one request per concurrency slot',
      () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      batchSize: 4,
      maxConcurrent: 2,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    for (var index = 0; index < 4; index++) {
      store.addRecognition(_event(
        sessionId: 'session-single',
        segmentId: 'single-$index',
        text: 'line $index',
        startSeconds: index * 2,
      ));
    }
    await _settle();

    expect(service.requests, hasLength(2));
    expect(service.maximumActive, 2);
    expect(queue.metrics.configuredBatchSize, 4);
  });

  test('prioritizes the current and future segments after a seek', () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      maxConcurrent: 1,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    for (final entry in [
      (id: 'old-1', seconds: 60),
      (id: 'old-2', seconds: 120),
      (id: 'current', seconds: 300),
      (id: 'future', seconds: 310),
    ]) {
      store.addRecognition(_event(
        sessionId: 'session-1',
        segmentId: entry.id,
        text: entry.id,
        startSeconds: entry.seconds,
      ));
    }
    await _settle();

    expect(service.requests.single.segmentId, 'seg-000001');
    expect(queue.waitingCount, 3);

    queue.prioritizeFrom(const Duration(minutes: 5));
    await _settle();

    expect(service.requests, hasLength(2));
    expect(service.requests.last.text, 'current');
    expect(queue.waitingCount, 1);
  });

  test('ignores an in-flight request from before a seek', () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      maxConcurrent: 1,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'old',
      text: 'old text',
      startSeconds: 60,
    ));
    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'current',
      text: 'current text',
      startSeconds: 300,
    ));
    await _settle();

    queue.prioritizeFrom(const Duration(minutes: 5));
    await _settle();
    expect(service.requests.last.text, 'current text');

    final staleCompleter = service.pending.removeAt(0);
    staleCompleter.complete(const TranslationResult(
      segmentId: 'seg-000001',
      text: 'stale translation',
      provider: 'test',
    ));
    await _settle();

    expect(
      store.translationResults
          .where((result) => result.translation.text == 'stale translation'),
      isEmpty,
    );
    expect(
      store.translationResults
          .where((result) => result.translation.text == 'current text'),
      isEmpty,
    );

    service.pending.single.complete(const TranslationResult(
      segmentId: 'seg-000002',
      text: 'current translation',
      provider: 'test',
    ));
    await _settle();
    expect(
      store.translationResults
          .where((result) => result.translation.text == 'current translation'),
      hasLength(1),
    );
  });

  test('drops late results after switching sessions', () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      maxConcurrent: 1,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'old',
      segmentId: 'old-seg',
      text: 'old text',
    ));
    await _settle();
    final oldRequest = service.requests.single;

    store.addRecognition(_event(
      sessionId: 'new',
      segmentId: 'new-seg',
      text: 'new text',
    ));
    await _settle();
    expect(store.sessionId, 'new');
    expect(store.translationResults.single.translation.status,
        TranscriptTranslationStatus.translating);

    service.pending.first.complete(const TranslationResult(
      segmentId: 'old-seg',
      text: 'stale translation',
      provider: 'test',
    ));
    await _settle();

    expect(oldRequest.segmentId, 'seg-000001');
    expect(
      store.translationResults
          .where((result) => result.translation.text == 'stale translation'),
      isEmpty,
    );
  });

  test('does not call an unavailable provider', () async {
    final store = RecognitionResultStore();
    final service = _UnavailableTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'seg-1',
      text: 'hello',
    ));
    await _settle();

    expect(service.requestCount, 0);
    expect(store.translationResults, isEmpty);
  });

  test('switching providers drops stale work and retranslates the session',
      () async {
    final store = RecognitionResultStore();
    final oldService = _ControlledTranslationService();
    final newService = _ControlledTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: oldService,
      targetLanguage: 'zh-CN',
      maxConcurrent: 1,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'seg-1',
      text: 'hello',
    ));
    await _settle();
    expect(oldService.requests, hasLength(1));

    queue.updateConfiguration(service: newService, targetLanguage: 'zh-CN');
    await _settle();
    expect(newService.requests, hasLength(1));

    oldService.pending.single.complete(const TranslationResult(
      segmentId: 'seg-000001',
      text: 'stale',
      provider: 'old',
    ));
    await _settle();
    expect(
      store.translationResults
          .where((result) => result.translation.text == 'stale'),
      isEmpty,
    );

    newService.pending.single.complete(const TranslationResult(
      segmentId: 'seg-000001',
      text: 'new translation',
      provider: 'new',
    ));
    await _settle();
    expect(store.translationResults.single.translation.text, 'new translation');
    expect(store.translationResults.single.translation.provider, 'new');
  });

  test('retries provider failures and stops at the attempt limit', () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService(fail: true);
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      retryDelay: Duration.zero,
      maxAttempts: 3,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'seg-1',
      text: 'hello',
    ));
    await _settle();

    expect(store.recognitions.single.text, 'hello');
    await _settle();
    expect(service.requests, hasLength(3));
    expect(store.translationResults.single.translation.status,
        TranscriptTranslationStatus.failed);
    expect(queue.waitingCount, 0);
    expect(queue.metrics.failedAttempts, 3);
    expect(queue.metrics.terminalFailedSegments, 1);
    expect(queue.metrics.retriedSegments, 2);
  });

  test('retries a transient provider failure and writes the later result',
      () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService(failuresBeforeSuccess: 1);
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      retryDelay: Duration.zero,
      maxAttempts: 3,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'seg-1',
      text: 'hello',
    ));
    await _settle();

    expect(service.requests, hasLength(2));
    expect(store.translationResults.single.translation.status,
        TranscriptTranslationStatus.translating);
    service.pending.last.complete(const TranslationResult(
      segmentId: 'seg-000001',
      text: '你好',
      provider: 'test',
    ));
    await _settle();
    expect(store.translationResults.single.translation.status,
        TranscriptTranslationStatus.translated);
    expect(store.translationResults.single.translation.text, '你好');
  });

  test('retries empty provider results as failures', () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService(empty: true);
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      retryDelay: Duration.zero,
      maxAttempts: 2,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'seg-1',
      text: 'hello',
    ));
    await _settle();
    expect(service.requests, hasLength(2));
    expect(store.translationResults.single.translation.status,
        TranscriptTranslationStatus.failed);
  });

  test('cancels pending retries after seek', () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService(fail: true);
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      retryDelay: const Duration(milliseconds: 20),
      maxAttempts: 3,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'old',
      text: 'old text',
      startSeconds: 60,
    ));
    await _settle();
    expect(service.requests, hasLength(1));

    queue.prioritizeFrom(const Duration(minutes: 5));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(service.requests, hasLength(1));
  });

  test('records API round-trip waits and resets them for a new session',
      () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      maxConcurrent: 1,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'seg-1',
      text: 'hello',
    ));
    await _settle();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    service.pending.single.complete(const TranslationResult(
      segmentId: 'seg-000001',
      text: '你好',
      provider: 'test',
    ));
    await _settle();

    expect(queue.metrics.completedApiRequests, 1);
    expect(queue.metrics.averageApiWait, isNotNull);
    expect(queue.metrics.averageApiWait,
        greaterThanOrEqualTo(const Duration(milliseconds: 1)));

    store.addRecognition(_event(
      sessionId: 'session-2',
      segmentId: 'seg-2',
      text: 'new text',
    ));
    await _settle();

    expect(queue.metrics.completedApiRequests, 0);
    expect(queue.metrics.averageApiWait, isNull);
  });

  test('uses configured batch size and request concurrency', () async {
    final store = RecognitionResultStore();
    final service = _ControlledBatchTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      batchSize: 2,
      maxConcurrent: 2,
      batchWait: Duration.zero,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    for (var index = 0; index < 6; index++) {
      store.addRecognition(_event(
        sessionId: 'session-batch',
        segmentId: 'batch-$index',
        text: 'line $index',
        startSeconds: index * 2,
      ));
    }
    await _settle();

    expect(service.requests, hasLength(2));
    expect(service.requests[0], hasLength(2));
    expect(service.requests[1], hasLength(2));
    expect(service.maximumActive, 2);
    expect(queue.waitingCount, 2);
    expect(queue.metrics.maxObservedActiveRequests, 2);

    queue.updateScheduling(maxConcurrent: 1, batchSize: 3);
    expect(queue.metrics.configuredBatchSize, 3);
    expect(queue.metrics.configuredMaxConcurrent, 1);
  });

  test('retries a failed batch as individual requests', () async {
    final store = RecognitionResultStore();
    final service = _ControlledBatchTranslationService();
    final queue = TranscriptTranslationQueue(
      results: store,
      service: service,
      targetLanguage: 'zh-CN',
      batchSize: 2,
      maxConcurrent: 1,
      batchWait: Duration.zero,
      retryDelay: Duration.zero,
    );
    addTearDown(() {
      queue.dispose();
      store.dispose();
    });

    store.addRecognition(_event(
      sessionId: 'batch-fallback',
      segmentId: 'first',
      text: 'first',
    ));
    store.addRecognition(_event(
      sessionId: 'batch-fallback',
      segmentId: 'second',
      text: 'second',
      startSeconds: 2,
    ));
    await _settle();
    expect(service.requests, hasLength(1));
    expect(service.requests.single, hasLength(2));

    service.pending.single.completeError(const FormatException('batch response'));
    await _settle();
    expect(service.requests, hasLength(2));
    expect(service.requests[1], hasLength(1));

    service.pending.single.complete([
      TranslationResult(
        segmentId: service.requests[1].single.segmentId,
        text: 'one',
        provider: 'batch-test',
      ),
    ]);
    await _settle();
    expect(service.requests, hasLength(3));
    expect(service.requests[2], hasLength(1));

    service.pending.single.complete([
      TranslationResult(
        segmentId: service.requests[2].single.segmentId,
        text: 'two',
        provider: 'batch-test',
      ),
    ]);
    await _settle();
    expect(
      store.translationResults
          .where((result) =>
              result.translation.status == TranscriptTranslationStatus.translated)
          .map((result) => result.translation.text),
      containsAll(<String>['one', 'two']),
    );
  });
}
