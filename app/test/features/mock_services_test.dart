import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/features/player/mock_services.dart';

void main() {
  test('mock player opens and advances playback snapshots', () async {
    final player = MockPlayerService();
    final snapshots = <PlaybackSnapshot>[];
    final subscription = player.snapshots.listen(snapshots.add);

    await player.open(MediaSource(
      uri: Uri.parse('mock://sample.mp4'),
      title: 'Sample',
      kind: MediaSourceKind.localFile,
    ));
    await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(snapshots.last.status, PlaybackStatus.playing);
    expect(snapshots.last.duration, const Duration(minutes: 12, seconds: 34));
    await player.setVolume(45);
    await player.setRate(1.5);
    expect(snapshots.last.volume, 45);
    expect(snapshots.last.rate, 1.5);
    await subscription.cancel();
    await player.dispose();
  });
}
