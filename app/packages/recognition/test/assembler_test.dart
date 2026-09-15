import 'dart:typed_data';

import 'package:recognition/recognition.dart';
import 'package:test/test.dart';

SpeechWindow window(int startMs, int durationMs, {String id = 'w'}) => SpeechWindow(
      id: id,
      index: 0,
      samples: Float32List(durationMs * 16),
      mediaStart: Duration(milliseconds: startMs),
      speechStart: Duration(milliseconds: startMs),
      speechEnd: Duration(milliseconds: startMs + durationMs),
      speechRatio: 1,
      cutReason: 'pause',
    );

AcceptedSegment accepted(int start, int end, String text) => AcceptedSegment(
      startMs: start,
      endMs: end,
      text: text,
      language: 'ja',
      avgLogprob: -0.1,
      noSpeechProb: 0.1,
      repetition: 0,
      windowId: 'w',
    );

void main() {
  test('fragments that continue a sentence are merged', () {
    final assembler = TranscriptAssembler();
    final transcript = assembler.addWindow(window(0, 6000), [
      accepted(0, 2000, '今日は天気が'),
      accepted(2100, 4000, 'いいですね。'),
      accepted(4200, 6000, '散歩しましょう'),
    ]);
    expect(transcript.segments.length, 2);
    expect(transcript.segments.first.text, '今日は天気がいいですね。');
    expect(transcript.segments.first.startMs, 0);
    expect(transcript.segments.first.endMs, 4000);
    expect(transcript.segments.last.text, '散歩しましょう');
  });

  test('a sentence-final form without punctuation is not merged', () {
    final assembler = TranscriptAssembler();
    final transcript = assembler.addWindow(window(0, 4000), [
      accepted(0, 2000, '行きます'),
      accepted(2100, 4000, '待ってて'),
    ]);
    expect(transcript.segments.length, 2);
  });

  test('run-on output is split at sentence ends with proportional timing', () {
    final assembler = TranscriptAssembler();
    final transcript = assembler.addWindow(window(0, 6000), [
      accepted(0, 6000, '一つ目の文です。二つ目の文です。'),
    ]);
    expect(transcript.segments.length, 2);
    expect(transcript.segments.first.startMs, 0);
    expect(transcript.segments.first.endMs, 3000);
    expect(transcript.segments.last.startMs, 3000);
    expect(transcript.segments.last.endMs, 6000);
  });

  test('long lines are wrapped to the display width', () {
    final assembler = TranscriptAssembler();
    final transcript = assembler.addWindow(window(0, 8000), [
      accepted(0, 8000, 'ただうちの家族はそんなこと、よく分からないから、聞いても無駄だと思う'),
    ]);
    expect(transcript.segments.length, greaterThan(1));
    for (final segment in transcript.segments) {
      expect(displayWidth(segment.text), lessThanOrEqualTo(36));
    }
  });

  test('a later window replaces segments it mostly covers', () {
    final assembler = TranscriptAssembler();
    assembler.addWindow(window(0, 4000, id: 'w0'), [accepted(0, 4000, '最初。')]);
    assembler.addWindow(window(4000, 4000, id: 'w1'), [accepted(4000, 8000, '二番目。')]);
    final transcript = assembler.addWindow(window(3000, 5000, id: 'w2'), [
      accepted(3500, 7500, '差し替え。'),
    ]);
    expect(transcript.segments.map((s) => s.text), ['最初。', '差し替え。']);
    expect(transcript.revision, 3);
  });

  test('ids are stable and unique across windows', () {
    final assembler = TranscriptAssembler();
    assembler.addWindow(window(0, 2000), [accepted(0, 2000, 'a。')]);
    final transcript = assembler.addWindow(window(2000, 2000), [accepted(2000, 4000, 'b。')]);
    expect(transcript.segments.map((s) => s.id).toSet().length, 2);
    expect(transcript.segments.first.id, 'seg-000001');
  });
}
