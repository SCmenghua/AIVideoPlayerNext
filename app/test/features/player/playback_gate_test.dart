import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/domain/subtitles/transcript_document.dart';
import 'package:ai_video_player_next/features/player/playback_gate.dart';
import 'package:ai_video_player_next/features/settings/app_settings.dart';

class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  void advance(Duration by) => now = now.add(by);
}

TranscriptDocument _document(List<(int, int, String)> segments) {
  var document = TranscriptDocument.empty(sessionId: 's');
  for (final (start, end, text) in segments) {
    document = document.upsertSegment(TranscriptSegment(
      id: text,
      startMs: start,
      endMs: end,
      text: text,
      language: 'ja',
      status: TranscriptSegmentStatus.timelineFinal,
      sourceWindows: const ['w'],
    ));
  }
  return document;
}

void main() {
  test('startup waits for the first subtitle, then releases with play', () {
    final clock = _Clock();
    final gate = PlaybackGate(now: () => clock.now)..beginMedia();
    expect(gate.waitingForStart, isTrue);

    var evaluation = gate.evaluate(
      status: PlaybackStatus.paused,
      position: Duration.zero,
      document: TranscriptDocument.empty(sessionId: 's'),
      targetLanguage: 'zh-CN',
      translationExpected: false,
      recognitionAlive: true,
    );
    expect(evaluation.action, GateAction.none);
    expect(evaluation.waitingForStart, isTrue);

    evaluation = gate.evaluate(
      status: PlaybackStatus.paused,
      position: Duration.zero,
      document: _document([(500, 2500, 'こんにちは')]),
      targetLanguage: 'zh-CN',
      translationExpected: false,
      recognitionAlive: true,
    );
    expect(evaluation.action, GateAction.play);
    expect(gate.waitingForStart, isFalse);
  });

  test('startup releases on timeout and when recognition is dead', () {
    final clock = _Clock();
    final gate = PlaybackGate(now: () => clock.now)..beginMedia();
    clock.advance(const Duration(seconds: 11));
    final timedOut = gate.evaluate(
      status: PlaybackStatus.paused,
      position: Duration.zero,
      document: null,
      targetLanguage: 'zh-CN',
      translationExpected: true,
      recognitionAlive: true,
    );
    expect(timedOut.action, GateAction.play);

    final dead = PlaybackGate(now: () => clock.now)..beginMedia();
    final released = dead.evaluate(
      status: PlaybackStatus.paused,
      position: Duration.zero,
      document: null,
      targetLanguage: 'zh-CN',
      translationExpected: true,
      recognitionAlive: false,
    );
    expect(released.action, GateAction.play);
  });

  test('playback priority never waits', () {
    final clock = _Clock();
    final gate = PlaybackGate(
      now: () => clock.now,
      strategy: PlaybackStartStrategy.playbackPriority,
    )..beginMedia();
    expect(gate.waitingForStart, isFalse);
    final evaluation = gate.evaluate(
      status: PlaybackStatus.playing,
      position: const Duration(seconds: 30),
      document: null,
      targetLanguage: 'zh-CN',
      translationExpected: true,
      recognitionAlive: true,
    );
    expect(evaluation.action, GateAction.none);
  });

  test('subtitle priority pauses during a gap, resumes on content or after the bounded wait', () {
    final clock = _Clock();
    final gate = PlaybackGate(now: () => clock.now, waitForPreparation: false)..beginMedia();
    final empty = TranscriptDocument.empty(sessionId: 's');

    var evaluation = gate.evaluate(
      status: PlaybackStatus.playing,
      position: const Duration(seconds: 10),
      document: empty,
      targetLanguage: 'zh-CN',
      translationExpected: false,
      recognitionAlive: true,
    );
    expect(evaluation.action, GateAction.pause);
    expect(gate.policyPaused, isTrue);

    evaluation = gate.evaluate(
      status: PlaybackStatus.paused,
      position: const Duration(seconds: 10),
      document: _document([(11000, 13000, '次')]),
      targetLanguage: 'zh-CN',
      translationExpected: false,
      recognitionAlive: true,
    );
    expect(evaluation.action, GateAction.play);
    expect(gate.policyPaused, isFalse);

    evaluation = gate.evaluate(
      status: PlaybackStatus.playing,
      position: const Duration(seconds: 20),
      document: empty,
      targetLanguage: 'zh-CN',
      translationExpected: false,
      recognitionAlive: true,
    );
    expect(evaluation.action, GateAction.pause);
    clock.advance(const Duration(seconds: 9));
    evaluation = gate.evaluate(
      status: PlaybackStatus.paused,
      position: const Duration(seconds: 20),
      document: empty,
      targetLanguage: 'zh-CN',
      translationExpected: false,
      recognitionAlive: true,
    );
    expect(evaluation.action, GateAction.play, reason: 'bounded wait expired');
  });

  test('a user play during a wait suppresses the gate until content returns', () {
    final clock = _Clock();
    final gate = PlaybackGate(now: () => clock.now, waitForPreparation: false)..beginMedia();
    final empty = TranscriptDocument.empty(sessionId: 's');
    gate.evaluate(
      status: PlaybackStatus.playing,
      position: const Duration(seconds: 10),
      document: empty,
      targetLanguage: 'zh-CN',
      translationExpected: false,
      recognitionAlive: true,
    );
    expect(gate.policyPaused, isTrue);
    gate.userPlay();
    final evaluation = gate.evaluate(
      status: PlaybackStatus.playing,
      position: const Duration(seconds: 11),
      document: empty,
      targetLanguage: 'zh-CN',
      translationExpected: false,
      recognitionAlive: true,
    );
    expect(evaluation.action, GateAction.none);
    expect(gate.policyPaused, isFalse);
  });
}
