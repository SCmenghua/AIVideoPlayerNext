import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/domain/subtitles/transcript_assembler.dart';

RecognitionEvent _event({
  required String id,
  required int startMs,
  required int endMs,
  required String text,
  String window = 'window-0',
  double confidence = 0.8,
}) =>
    RecognitionEvent(
      sessionId: 'session-1',
      segmentId: id,
      start: Duration(milliseconds: startMs),
      end: Duration(milliseconds: endMs),
      text: text,
      language: 'en',
      kind: RecognitionKind.finalResult,
      source: RecognitionSource.whisperCpp,
      confidence: confidence,
      sourceWindowId: window,
    );

void main() {
  test('collapses overlapping duplicate windows and keeps provenance', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'window-0-segment-0',
      startMs: 1000,
      endMs: 3000,
      text: 'Hello, world.',
      window: 'window-0',
      confidence: 0.7,
    ));
    assembler.add(_event(
      id: 'window-1-segment-0',
      startMs: 1100,
      endMs: 3100,
      text: 'hello world',
      window: 'window-1',
      confidence: 0.9,
    ));

    expect(assembler.segments, hasLength(1));
    expect(assembler.segments.single.id, 'seg-000001');
    expect(assembler.segments.single.text, 'hello world');
    expect(assembler.segments.single.sourceWindows, ['window-0', 'window-1']);
  });

  test('keeps identical words at materially different media times', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'first',
      startMs: 0,
      endMs: 1000,
      text: 'Yes.',
    ));
    assembler.add(_event(
      id: 'second',
      startMs: 10000,
      endMs: 11000,
      text: 'Yes.',
      window: 'window-2',
    ));

    expect(assembler.segments.map((segment) => segment.id), [
      'seg-000001',
      'seg-000002',
    ]);
  });

  test('keeps uncertain cross-window partial phrases separate', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'first',
      startMs: 1000,
      endMs: 3000,
      text: 'I love you and',
    ));
    assembler.add(_event(
      id: 'second',
      startMs: 2000,
      endMs: 4000,
      text: 'you and me',
      window: 'window-1',
    ));

    expect(assembler.segments, hasLength(2));
  });

  test('deduplicates an overlapping result even when another phrase intervenes',
      () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'first-hello',
      startMs: 0,
      endMs: 3000,
      text: 'hello world',
      window: 'window-0',
    ));
    assembler.add(_event(
      id: 'intervening',
      startMs: 1000,
      endMs: 2500,
      text: 'a different sentence',
      window: 'window-1',
    ));
    assembler.add(_event(
      id: 'duplicate-hello',
      startMs: 1500,
      endMs: 3200,
      text: 'Hello, world.',
      window: 'window-2',
    ));

    expect(assembler.segments, hasLength(2));
    expect(
      assembler.segments
          .firstWhere((segment) => segment.text == 'hello world')
          .sourceWindows,
      ['window-0', 'window-2'],
    );
  });

  test('out-of-order arrivals sort by media time and retain stable IDs', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'later',
      startMs: 5000,
      endMs: 6000,
      text: 'later',
    ));
    assembler.add(_event(
      id: 'earlier',
      startMs: 1000,
      endMs: 2000,
      text: 'earlier',
      window: 'window-1',
    ));

    expect(assembler.segments.map((segment) => segment.text),
        ['earlier', 'later']);
    expect(assembler.segments.map((segment) => segment.id), [
      'seg-000002',
      'seg-000001',
    ]);
  });
}
