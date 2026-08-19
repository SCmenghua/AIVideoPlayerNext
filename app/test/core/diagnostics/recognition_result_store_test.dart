import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/core/diagnostics/recognition_result_store.dart';
import 'package:ai_video_player_next/domain/speech/speech_models.dart';

RecognitionEvent _event({
  required String sessionId,
  required String segmentId,
  required String text,
  Duration start = const Duration(seconds: 4),
  Duration end = const Duration(seconds: 6),
}) =>
    RecognitionEvent(
      sessionId: sessionId,
      segmentId: segmentId,
      start: start,
      end: end,
      text: text,
      language: 'ja',
      kind: RecognitionKind.finalResult,
      source: RecognitionSource.whisperCpp,
    );

void main() {
  test('keeps final recognition results independent from player position', () {
    final store = RecognitionResultStore();
    store.reset(sessionId: 'session-1');

    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'segment-1',
      text: 'first recognition result',
    ));
    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'segment-2',
      text: 'second recognition result',
    ));

    expect(store.recognitions.map((event) => event.text), [
      'first recognition result',
      'second recognition result',
    ]);
    expect(
      store.formatForExport(RecognitionResultKind.recognition),
      contains('[00:04.000 - 00:06.000] first recognition result'),
    );

    store.dispose();
  });

  test('switching sessions drops previous recognition and translation results',
      () {
    final store = RecognitionResultStore();
    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'segment-1',
      text: 'old result',
    ));
    store.addTranslation('segment-1', 'old translation');

    store.addRecognition(_event(
      sessionId: 'session-2',
      segmentId: 'segment-2',
      text: 'new result',
    ));

    expect(store.sessionId, 'session-2');
    expect(store.recognitions.single.text, 'new result');
    expect(store.translationResults, isEmpty);

    store.dispose();
  });

  test(
      'orders background results by media time and ignores unknown translations',
      () {
    final store = RecognitionResultStore();
    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'later',
      text: 'later result',
      start: const Duration(seconds: 8),
      end: const Duration(seconds: 9),
    ));
    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'earlier',
      text: 'earlier result',
      start: const Duration(seconds: 2),
      end: const Duration(seconds: 3),
    ));
    store.addTranslation('old-session-segment', 'must be ignored');

    expect(store.recognitions.map((event) => event.text), [
      'earlier result',
      'later result',
    ]);
    expect(store.translationResults, isEmpty);

    store.dispose();
  });

  test('retains segments with the same native index from separate windows', () {
    final store = RecognitionResultStore();
    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'session-1-window-0-segment-0',
      text: 'first window',
      start: Duration.zero,
      end: const Duration(seconds: 2),
    ));
    store.addRecognition(_event(
      sessionId: 'session-1',
      segmentId: 'session-1-window-1-segment-0',
      text: 'second window',
      start: const Duration(seconds: 4),
      end: const Duration(seconds: 6),
    ));

    expect(store.recognitions.map((event) => event.text), [
      'first window',
      'second window',
    ]);

    store.dispose();
  });
}
