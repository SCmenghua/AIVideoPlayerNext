import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/audio_models.dart';
import 'package:ai_video_player_next/domain/audio/recognition_queue.dart';

RecognitionWindow _window(String id) => RecognitionWindow(
      windowId: id,
      sessionId: 's1',
      mediaStart: Duration.zero,
      sampleRate: 16000,
      samples: List<double>.filled(160, 0.1),
      sourceChunkCount: 1,
    );

void main() {
  test('queue keeps one active and one waiting window', () async {
    final queue = RecognitionQueue();
    final first = _window('first');
    final second = _window('second');
    final third = _window('third');
    expect(queue.offer(first), isTrue);
    expect(queue.offer(second), isTrue);
    expect(queue.offer(third), isFalse);

    final active = await queue.take();
    expect(active, same(first));
    expect(queue.depth, 2);
    queue.complete(active!);
    final next = await queue.take();
    expect(next, same(second));
  });

  test('clear removes waiting windows but leaves the active window owned',
      () async {
    final queue = RecognitionQueue();
    final first = _window('first');
    final second = _window('second');
    expect(queue.offer(first), isTrue);
    expect(queue.offer(second), isTrue);

    final active = await queue.take();
    expect(queue.clear(), contains(same(second)));
    expect(queue.active, same(first));
    expect(queue.depth, 1);

    queue.complete(active!);
    expect(queue.depth, 0);
  });
}
