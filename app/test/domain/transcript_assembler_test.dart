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
  String language = 'en',
}) =>
    RecognitionEvent(
      sessionId: 'session-1',
      segmentId: id,
      start: Duration(milliseconds: startMs),
      end: Duration(milliseconds: endMs),
      text: text,
      language: language,
      kind: RecognitionKind.finalResult,
      source: RecognitionSource.whisperCpp,
      confidence: confidence,
      sourceWindowId: window,
    );

void main() {
  test('unpunctuated Japanese lines are not glued to each other', () {
    // kotoba-whisper omits terminal punctuation on nearly every segment. When
    // "no sentence-final marker" counted as permission to merge, adjacent
    // windows chained into ten-second subtitles that stopped only at the
    // width cap. Two finished lines must stay two subtitles.
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'window-0-segment-0',
      startMs: 550,
      endMs: 7740,
      text: 'わあいいなあブレザー',
      window: 'window-0',
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'window-1-segment-0',
      startMs: 8000,
      endMs: 10560,
      text: 'ドラマみたいなね',
      window: 'window-1',
      language: 'ja',
    ));

    expect(assembler.segments.map((segment) => segment.text),
        ['わあいいなあブレザー', 'ドラマみたいなね']);
  });

  test('a line cut on a case particle is joined to its continuation', () {
    // The window boundary fell after the genitive, so this one really is a
    // fragment: nothing in Japanese can end a sentence on の here.
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'window-1-segment-3',
      startMs: 14400,
      endMs: 16050,
      text: '三つみちゃんはうちらの',
      window: 'window-1',
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'window-2-segment-0',
      startMs: 16050,
      endMs: 17550,
      text: '自慢',
      window: 'window-2',
      language: 'ja',
    ));

    expect(assembler.segments.single.text, '三つみちゃんはうちらの自慢');
  });

  test('scripts that punctuate reliably still merge on absence of a stop', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'window-0-segment-0',
      startMs: 1000,
      endMs: 2000,
      text: 'the quick brown',
      window: 'window-0',
    ));
    assembler.add(_event(
      id: 'window-1-segment-0',
      startMs: 2000,
      endMs: 3000,
      text: 'fox jumps',
      window: 'window-1',
    ));

    expect(assembler.segments.single.text, 'the quick brown fox jumps');
  });

  test('keeps the whole utterance when a neighbouring window cut it short', () {
    final assembler = TranscriptAssembler();
    // The window boundary fell mid-sentence, so one window heard a fragment
    // and the overlapping one heard all of it. The fragment scores higher -
    // short decodes usually do - and must still lose to the full line.
    assembler.add(_event(
      id: 'window-0-segment-1',
      startMs: 7000,
      endMs: 8000,
      text: 'the quick brown',
      window: 'window-0',
      confidence: 0.95,
    ));
    assembler.add(_event(
      id: 'window-1-segment-0',
      startMs: 7000,
      endMs: 9200,
      text: 'the quick brown fox jumps',
      window: 'window-1',
      confidence: 0.8,
    ));

    expect(assembler.segments, hasLength(1));
    expect(assembler.segments.single.text, 'the quick brown fox jumps');
  });

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

  test('keeps kana so overlapping Japanese windows deduplicate', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'window-0-segment-0',
      startMs: 1000,
      endMs: 3000,
      text: 'ありがとう ございます',
      window: 'window-0',
      confidence: 0.7,
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'window-1-segment-0',
      startMs: 1100,
      endMs: 3100,
      text: 'ありがとうございます',
      window: 'window-1',
      confidence: 0.9,
      language: 'ja',
    ));

    expect(assembler.segments, hasLength(1));
    expect(assembler.segments.single.text, 'ありがとうございます');
    expect(assembler.segments.single.sourceWindows, ['window-0', 'window-1']);
  });

  test('merges a Japanese sentence fragment split at a window boundary', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'fragment-1',
      startMs: 0,
      endMs: 2000,
      text: '今日は',
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'fragment-2',
      startMs: 2000,
      endMs: 4500,
      text: 'いい天気です',
      window: 'window-1',
      language: 'ja',
    ));

    expect(assembler.segments, hasLength(1));
    expect(assembler.segments.single.id, 'seg-000001');
    expect(assembler.segments.single.text, '今日はいい天気です');
    expect(assembler.segments.single.startMs, 0);
    expect(assembler.segments.single.endMs, 4500);
    expect(assembler.segments.single.sourceWindows, ['window-0', 'window-1']);
  });

  test('keeps sentence-final Japanese segments separate', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'first',
      startMs: 0,
      endMs: 2000,
      text: 'いい天気です。',
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'second',
      startMs: 2000,
      endMs: 4000,
      text: 'はい',
      window: 'window-1',
      language: 'ja',
    ));

    expect(assembler.segments.map((segment) => segment.text),
        ['いい天気です。', 'はい']);
  });

  test('does not merge fragments across a long silence', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'first',
      startMs: 0,
      endMs: 2000,
      text: 'えっと',
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'second',
      startMs: 5000,
      endMs: 7000,
      text: 'そうですね',
      window: 'window-1',
      language: 'ja',
    ));

    expect(assembler.segments, hasLength(2));
  });

  test('does not merge fragments of different languages', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'first',
      startMs: 0,
      endMs: 2000,
      text: 'and then',
      language: 'en',
    ));
    assembler.add(_event(
      id: 'second',
      startMs: 2000,
      endMs: 4000,
      text: 'そうです',
      window: 'window-1',
      language: 'ja',
    ));

    expect(assembler.segments, hasLength(2));
  });

  test('a grown merged sentence keeps its stable ID', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'fragment-1',
      startMs: 0,
      endMs: 2000,
      text: '今日は',
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'fragment-2',
      startMs: 2000,
      endMs: 4500,
      text: 'いい天気です',
      window: 'window-1',
      language: 'ja',
    ));

    expect(assembler.segments, hasLength(1));
    expect(assembler.segments.single.id, 'seg-000001',
        reason: 'the translation attached to the fragment must follow');
  });

  test('splits a multi-sentence segment at terminal punctuation', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'run',
      startMs: 0,
      endMs: 9000,
      text: 'はい。わかりました。ありがとうございます。',
      language: 'ja',
    ));

    expect(assembler.segments.map((segment) => segment.text),
        ['はい。', 'わかりました。', 'ありがとうございます。']);
    expect(assembler.segments.first.startMs, 0);
    expect(assembler.segments.last.endMs, 9000);
    for (final segment in assembler.segments) {
      expect(segment.endMs, greaterThan(segment.startMs));
      expect(segment.sourceWindows, ['window-0']);
    }
  });

  test('splits a long unpunctuated run at phrase commas', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'run',
      startMs: 0,
      endMs: 10000,
      text: '今日は朝からとてもいい天気で、どこか遠くへ出かけたくなる such a、素敵な一日ですね',
      language: 'ja',
    ));

    expect(assembler.segments.length, greaterThan(1));
    for (final segment in assembler.segments) {
      expect(segment.text.length, lessThan(60),
          reason: 'displayed subtitles must not be one long run');
      expect(segment.endMs, greaterThan(segment.startMs));
    }
    const source =
        '今日は朝からとてもいい天気で、どこか遠くへ出かけたくなる such a、素敵な一日ですね';
    final concatenated = assembler.segments.map((s) => s.text).join();
    // A cut absorbs the whitespace that separated the two parts, so the round
    // trip is compared without spacing; no substantive character may be lost.
    expect(concatenated.replaceAll(RegExp(r'\s+'), ''),
        source.replaceAll(RegExp(r'\s+'), ''));
  });

  test('short unpunctuated sentences stay in one segment', () {
    final assembler = TranscriptAssembler();
    assembler.add(_event(
      id: 'run',
      startMs: 0,
      endMs: 4000,
      text: '今日から東京の高校生です',
      language: 'ja',
    ));

    expect(assembler.segments, hasLength(1));
    expect(assembler.segments.single.text, '今日から東京の高校生です');
  });

  test('separates unpunctuated Japanese sentences by final morphology', () {
    final assembler = TranscriptAssembler();
    // kotoba-whisper drops the terminal '。' on about 93% of segments, so the
    // boundary has to come from sentence-final morphology. Without it these two
    // lines merge and one subtitle ends up carrying both speakers.
    assembler.add(_event(
      id: 'first',
      startMs: 0,
      endMs: 2000,
      text: '今日はいい天気ですね',
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'second',
      startMs: 2000,
      endMs: 4000,
      text: '散歩に行きましょう',
      window: 'window-1',
      language: 'ja',
    ));

    expect(assembler.segments.map((segment) => segment.text),
        ['今日はいい天気ですね', '散歩に行きましょう']);
  });

  test('strips a repeated prefix across adjacent segments', () {
    final assembler = TranscriptAssembler();
    // Whisper restates a few characters across adjacent segments, which joins
    // into '私は行くから行くから待って'. The duplicate detection only covers
    // materially overlapping windows, so the join has to trim the restatement.
    assembler.add(_event(
      id: 'first',
      startMs: 0,
      endMs: 2000,
      text: '私は行くから',
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'second',
      startMs: 2000,
      endMs: 4000,
      text: '行くから待って',
      window: 'window-1',
      language: 'ja',
    ));

    expect(assembler.segments, hasLength(1));
    expect(assembler.segments.single.text, '私は行くから待って');
  });

  test('caps a merged Japanese run at one subtitle line', () {
    final assembler = TranscriptAssembler();
    // Two turns that carry no terminal punctuation and no comma: the length cap
    // is the only remaining guard, so it has to stay close to one spoken line.
    assembler.add(_event(
      id: 'first',
      startMs: 0,
      endMs: 3000,
      text: 'えっとそれはちょっと',
      language: 'ja',
    ));
    assembler.add(_event(
      id: 'second',
      startMs: 3000,
      endMs: 6000,
      text: 'そういうわけにはいかないので',
      window: 'window-1',
      language: 'ja',
    ));

    final segments = assembler.segments;
    expect(segments.length, greaterThan(1));
    for (final segment in segments) {
      expect(_cells(segment.text), lessThanOrEqualTo(36));
    }
  });
}

/// Display width in half-width cells, matching the assembler's own measure.
int _cells(String text) {
  var cells = 0;
  for (final rune in text.runes) {
    cells += (rune >= 0x2E80 && rune <= 0xA4CF) ||
            (rune >= 0xF900 && rune <= 0xFAFF) ||
            (rune >= 0xFF00 && rune <= 0xFF60)
        ? 2
        : 1;
  }
  return cells;
}
