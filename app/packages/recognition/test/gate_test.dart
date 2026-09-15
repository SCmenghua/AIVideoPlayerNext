import 'dart:typed_data';

import 'package:recognition/recognition.dart';
import 'package:test/test.dart';

SpeechWindow window({
  int startMs = 10000,
  int durationMs = 8000,
  int speechStartMs = 10400,
  int speechEndMs = 17600,
}) =>
    SpeechWindow(
      id: 'w',
      index: 0,
      samples: Float32List(durationMs * 16),
      mediaStart: Duration(milliseconds: startMs),
      speechStart: Duration(milliseconds: speechStartMs),
      speechEnd: Duration(milliseconds: speechEndMs),
      speechRatio: 0.9,
      cutReason: 'pause',
    );

RawSegment raw(
  String text, {
  int start = 500,
  int end = 3000,
  double repetition = 0,
  double noSpeech = 0.1,
  String language = 'ja',
}) =>
    RawSegment(
      index: 0,
      startMs: start,
      endMs: end,
      text: text,
      language: language,
      avgLogprob: -0.2,
      noSpeechProb: noSpeech,
      repetition: repetition,
      tokenCount: 5,
    );

void main() {
  test('accepts ordinary segments on the media timeline', () {
    final gate = SegmentGate(const GateOptions());
    final result = gate.apply(window(), [raw('こんにちは')], pinnedLanguage: 'ja');
    expect(result.accepted.single.startMs, 10500);
    expect(result.accepted.single.endMs, 13000);
    expect(result.dropped, isEmpty);
  });

  test('drops loops, blocked phrases, no-speech and wrong language', () {
    final gate = SegmentGate(const GateOptions());
    final result = gate.apply(
      window(),
      [
        raw('ご視聴ありがとうございました'),
        raw('あああああああああああああ', repetition: 0.9),
        raw('静か', noSpeech: 0.95),
        raw('hello', language: 'en'),
        raw('   '),
      ],
      pinnedLanguage: 'ja',
    );
    expect(result.accepted, isEmpty);
    expect(result.dropped.map((d) => d.reason),
        containsAll(['blocked', 'repetition', 'noSpeech', 'language', 'empty']));
  });

  test('clamps into the padded speech range and drops segments outside it', () {
    final gate = SegmentGate(const GateOptions());
    final result = gate.apply(
      window(),
      [raw('先頭', start: 0, end: 300), raw('末尾', start: 7900, end: 8000)],
    );
    expect(result.accepted.length, 2);
    expect(result.accepted.first.startMs, 10200);
    expect(result.accepted.first.endMs, 10300);
    expect(result.accepted.last.startMs, 17800);
    expect(result.accepted.last.endMs, 18000);
  });

  test('a window repeating the previous window verbatim is dropped', () {
    final gate = SegmentGate(const GateOptions());
    final first = gate.apply(window(), [raw('同じ文です')]);
    expect(first.accepted.length, 1);
    final second = gate.apply(window(startMs: 20000), [raw('同じ 文です。')]);
    expect(second.accepted, isEmpty);
    expect(second.dropped.single.reason, 'repeatedWindow');
    final third = gate.apply(window(startMs: 30000), [raw('同じ文です')]);
    expect(third.accepted.length, 1, reason: 'context is cleared after a drop');
  });
}
