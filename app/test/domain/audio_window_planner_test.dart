import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/audio_models.dart';
import 'package:ai_video_player_next/domain/audio/audio_window_planner.dart';

AudioChunk _chunk(String session, int startSeconds, List<double> samples,
        {bool last = false}) =>
    AudioChunk(
      sessionId: session,
      mediaStart: Duration(seconds: startSeconds),
      sampleRate: 16000,
      channels: 1,
      samples: samples,
      isLast: last,
    );

void main() {
  test('planner emits deterministic non-overlapping windows', () {
    final planner = AudioWindowPlanner(
      windowOverlap: Duration.zero,
      targetWindow: const Duration(seconds: 1),
      maximumWindow: const Duration(seconds: 2),
      tailSilence: Duration.zero,
    );
    final samples = List<double>.filled(16000, 0.1);

    final first = planner.add(_chunk('s1', 0, samples));
    final second = planner.add(_chunk('s1', 1, samples, last: true));

    final windows = [...first, ...second]
        .where((result) => result.window != null)
        .map((result) => result.window!)
        .toList();
    expect(windows, hasLength(2));
    expect(windows[0].mediaStart, Duration.zero);
    expect(windows[0].mediaEnd, const Duration(seconds: 1));
    expect(windows[1].mediaStart, const Duration(seconds: 1));
    expect(windows[1].mediaEnd, const Duration(seconds: 2));
  });

  test('planner replays the overlap at the head of the next window', () {
    final planner = AudioWindowPlanner(
      targetWindow: const Duration(seconds: 1),
      maximumWindow: const Duration(seconds: 2),
      windowOverlap: const Duration(milliseconds: 250),
      tailSilence: Duration.zero,
    );
    final samples = List<double>.filled(16000, 0.1);

    final first = planner.add(_chunk('s1', 0, samples));
    final second = planner.add(_chunk('s1', 1, samples, last: true));

    final windows = [...first, ...second]
        .where((result) => result.window != null)
        .map((result) => result.window!)
        .toList();
    expect(windows, hasLength(2));
    expect(windows[0].mediaStart, Duration.zero);
    expect(windows[0].samples, hasLength(16000));
    // The second window starts a quarter second earlier than it otherwise
    // would and carries that audio again, so a line cut by the boundary is
    // heard whole at least once.
    expect(windows[1].mediaStart, const Duration(milliseconds: 750));
    expect(windows[1].samples, hasLength(20000));
  });

  test('planner skips pure silence but keeps speech with a silent tail', () {
    final planner = AudioWindowPlanner(
      windowOverlap: Duration.zero,
      targetWindow: const Duration(seconds: 1),
      maximumWindow: const Duration(seconds: 2),
      tailSilence: const Duration(milliseconds: 200),
    );
    final result = planner.add(_chunk(
      's1',
      0,
      [
        ...List<double>.filled(12800, 0.1),
        ...List<double>.filled(3200, 0),
      ],
      last: true,
    ));
    expect(result.single.window, isNotNull);

    final silentPlanner = AudioWindowPlanner(
      windowOverlap: Duration.zero,
      targetWindow: const Duration(seconds: 1),
      maximumWindow: const Duration(seconds: 2),
    );
    final silent = silentPlanner.add(
      _chunk('s2', 0, List<double>.filled(16000, 0), last: true),
    );
    expect(silent.single.skipReason, WindowSkipReason.silence);
  });

  test('planner keeps a short spoken line inside a mostly quiet window', () {
    final planner = AudioWindowPlanner(
      windowOverlap: Duration.zero,
      targetWindow: const Duration(seconds: 1),
      maximumWindow: const Duration(seconds: 2),
    );
    final result = planner.add(_chunk(
      's1',
      0,
      [
        ...List<double>.filled(9600, 0),
        ...List<double>.filled(6400, 0.04),
        ...List<double>.filled(3200, 0),
      ],
      last: true,
    ));

    expect(result.single.window, isNotNull);
  });

  test('planner skips a single short noise burst', () {
    final planner = AudioWindowPlanner(
      windowOverlap: Duration.zero,
      targetWindow: const Duration(seconds: 1),
      maximumWindow: const Duration(seconds: 2),
    );
    final result = planner.add(_chunk(
      's1',
      0,
      [
        ...List<double>.filled(6400, 0),
        ...List<double>.filled(3200, 0.04),
        ...List<double>.filled(6400, 0),
      ],
      last: true,
    ));

    expect(result.single.skipReason, WindowSkipReason.silence);
  });

  test('planner trims a sufficiently long trailing pause at EOF', () {
    final planner = AudioWindowPlanner(
      windowOverlap: Duration.zero,
      targetWindow: const Duration(seconds: 1),
      maximumWindow: const Duration(seconds: 2),
      minimumSpeechWindow: const Duration(milliseconds: 100),
      tailSilence: const Duration(milliseconds: 200),
    );
    final result = planner.add(_chunk(
      's1',
      0,
      [
        ...List<double>.filled(12800, 0.1),
        ...List<double>.filled(3200, 0),
      ],
      last: true,
    ));

    expect(result.single.window, isNotNull);
    expect(result.single.window!.duration, const Duration(milliseconds: 800));
    expect(result.single.mediaEnd, const Duration(milliseconds: 800));
  });

  test('planner moves the window boundary onto a nearby pause', () {
    final planner = AudioWindowPlanner(
      windowOverlap: Duration.zero,
      targetWindow: const Duration(seconds: 1),
      maximumWindow: const Duration(seconds: 2),
      tailSilence: Duration.zero,
    );
    // 1.1s of speech, a 0.2s pause, then more speech. The nominal boundary at
    // 1.0s lands mid-utterance, so the planner extends to the pause at 1.1s
    // rather than cutting the line in half.
    final results = planner.add(_chunk('s1', 0, [
      ...List<double>.filled(17600, 0.2),
      ...List<double>.filled(3200, 0),
      ...List<double>.filled(6400, 0.2),
    ]));

    final windows = results
        .where((result) => result.window != null)
        .map((result) => result.window!)
        .toList();
    expect(windows, hasLength(1));
    expect(windows.single.duration, const Duration(milliseconds: 1100));
  });

  test('planner keeps the nominal length when no pause is nearby', () {
    final planner = AudioWindowPlanner(
      windowOverlap: Duration.zero,
      targetWindow: const Duration(seconds: 1),
      maximumWindow: const Duration(seconds: 2),
      tailSilence: Duration.zero,
    );
    // Continuous speech: with nothing to align to the cadence must stay exactly
    // on target, otherwise window timing and the watermarks drift.
    final results =
        planner.add(_chunk('s1', 0, List<double>.filled(24000, 0.2)));

    final windows = results
        .where((result) => result.window != null)
        .map((result) => result.window!)
        .toList();
    expect(windows, hasLength(1));
    expect(windows.single.duration, const Duration(seconds: 1));
  });
}
