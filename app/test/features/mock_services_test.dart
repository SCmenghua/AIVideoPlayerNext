import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/features/player/mock_services.dart';

void main() {
  test('mock player opens and advances playback snapshots', () async {
    final player = MockPlayerService();
    final snapshots = <PlaybackSnapshot>[];
    final subscription = player.snapshots.listen(snapshots.add);

    await player.open(const MediaSource(path: 'mock://sample.mp4', title: 'Sample'));
    await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(snapshots.last.status, PlaybackStatus.playing);
    expect(snapshots.last.duration, const Duration(minutes: 12, seconds: 34));
    await subscription.cancel();
    await player.dispose();
  });

  test('mock speech emits partial then final for the same segment', () async {
    final speech = MockSpeechRecognitionService();
    final events = <RecognitionEvent>[];
    final subscription = speech.events.listen(events.add);

    await speech.start(const RecognitionRequest(sessionId: 's1', from: Duration.zero));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(events.map((event) => event.kind), [RecognitionKind.partial, RecognitionKind.finalResult]);
    expect(events[0].segmentId, events[1].segmentId);
    await subscription.cancel();
  });
}
