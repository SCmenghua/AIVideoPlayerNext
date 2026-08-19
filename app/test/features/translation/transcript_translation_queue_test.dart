import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/core/diagnostics/recognition_result_store.dart';
import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/domain/subtitles/transcript_document.dart';
import 'package:ai_video_player_next/domain/translation/translation_service.dart';
import 'package:ai_video_player_next/features/translation/transcript_translation_queue.dart';

class _ControlledTranslationService
    implements TranslationService, TranslationServiceStatusProvider {
  _ControlledTranslationService({this.fail = false});

  final bool fail;
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
    if (fail) {
      completer.completeError(StateError('test failure'));
    }
    return completer.future.whenComplete(() => active--);
  }

  void completeNext() {
    final completer = pending.removeAt(0);
    completer.complete(TranslationResult(
      segmentId: requests.first.segmentId,
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
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
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

  test('marks provider failures without affecting recognition', () async {
    final store = RecognitionResultStore();
    final service = _ControlledTranslationService(fail: true);
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

    expect(store.recognitions.single.text, 'hello');
    expect(store.translationResults.single.translation.status,
        TranscriptTranslationStatus.failed);
  });
}
