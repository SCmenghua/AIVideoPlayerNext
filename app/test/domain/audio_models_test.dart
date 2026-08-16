import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/audio_models.dart';

void main() {
  test('standardizer downmixes and resamples with media timestamp intact', () {
    final chunk = AudioChunk(
      sessionId: 's1',
      mediaStart: const Duration(seconds: 3),
      sampleRate: 8000,
      channels: 2,
      samples: const [1, -1, 0.5, 0.5, 0, 0],
    );

    final normalized = const PcmStandardizer().normalize(chunk);

    expect(normalized.sessionId, 's1');
    expect(normalized.mediaStart, const Duration(seconds: 3));
    expect(normalized.sampleRate, 16000);
    expect(normalized.samples.length, 6);
    expect(normalized.samples.first, closeTo(0, 0.0001));
    expect(normalized.samples.last, closeTo(0, 0.0001));
  });

  test('audio chunk rejects incomplete interleaved frames', () {
    expect(
      () => AudioChunk(
        sessionId: 's1',
        mediaStart: Duration.zero,
        sampleRate: 16000,
        channels: 2,
        samples: const [0.1],
      ),
      throwsArgumentError,
    );
  });
}
