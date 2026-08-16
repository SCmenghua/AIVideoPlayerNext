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

  test('planner skips pure silence but keeps speech with a silent tail', () {
    final planner = AudioWindowPlanner(
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
}
