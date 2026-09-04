import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/audio_models.dart';
import 'package:ai_video_player_next/domain/speech/recognition_window_context.dart';
import 'package:ai_video_player_next/domain/speech/speech_models.dart';

RecognitionWindow _window({
  required String session,
  required int startMs,
  int durationMs = 8000,
}) =>
    RecognitionWindow(
      windowId: '$session-window-$startMs',
      sessionId: session,
      mediaStart: Duration(milliseconds: startMs),
      sampleRate: 16000,
      samples: List<double>.filled(durationMs * 16, 0.1),
      sourceChunkCount: 1,
    );

RecognitionEvent _event(String text, {String session = 'session-1'}) =>
    RecognitionEvent(
      sessionId: session,
      segmentId: '$session-$text',
      start: Duration.zero,
      end: const Duration(seconds: 3),
      text: text,
      language: 'ja',
      kind: RecognitionKind.finalResult,
      source: RecognitionSource.whisperCpp,
    );

void main() {
  test('carries the previous transcript into a contiguous window', () {
    final context = RecognitionWindowContext();
    final first = _window(session: 'session-1', startMs: 0);

    expect(context.promptFor(first), isNull);
    context.remember(first, [_event('わあいいなあブレザー')]);

    expect(context.promptFor(_window(session: 'session-1', startMs: 8000)),
        'わあいいなあブレザー');
  });

  test('drops the context when the next window does not continue', () {
    final context = RecognitionWindowContext();
    final first = _window(session: 'session-1', startMs: 0);
    context.remember(first, [_event('わあいいなあブレザー')]);

    // A seek lands far from where the last window ended.
    expect(context.promptFor(_window(session: 'session-1', startMs: 120000)),
        isNull);
  });

  test('a repeated window is recognised as a decoder loop', () {
    final context = RecognitionWindowContext();
    context.remember(
        _window(session: 'session-1', startMs: 0), [_event('親友だなんて素敵です')]);

    final next = _window(session: 'session-1', startMs: 8000);
    expect(context.repeatsPrevious(next, [_event('親友だなんて素敵です!')]), isTrue);
    expect(context.repeatsPrevious(next, [_event('ドラマみたいなね')]), isFalse);
  });

  test('a new session starts with no context at all', () {
    // The recognition service outlives the media it is pointed at. Without a
    // session guard the first window of a new video is compared against the
    // last window of the previous one, and a video whose opening line matches
    // is discarded before it reaches the timeline.
    final context = RecognitionWindowContext();
    context.remember(
        _window(session: 'session-1', startMs: 0), [_event('わあいいなあブレザー')]);

    final reopened = _window(session: 'session-2', startMs: 0);
    expect(context.promptFor(reopened), isNull);
    expect(
      context.repeatsPrevious(
          reopened, [_event('わあいいなあブレザー', session: 'session-2')]),
      isFalse,
    );
  });

  test('reset drops the context within a session', () {
    final context = RecognitionWindowContext();
    context.remember(
        _window(session: 'session-1', startMs: 0), [_event('わあいいなあブレザー')]);
    context.reset();

    expect(context.promptFor(_window(session: 'session-1', startMs: 8000)),
        isNull);
  });

  test('a silent window keeps the thread instead of breaking it', () {
    final context = RecognitionWindowContext();
    context.remember(
        _window(session: 'session-1', startMs: 0), [_event('わあいいなあブレザー')]);
    context.remember(
        _window(session: 'session-1', startMs: 8000), const <RecognitionEvent>[]);

    expect(context.promptFor(_window(session: 'session-1', startMs: 16000)),
        'わあいいなあブレザー');
  });
}
