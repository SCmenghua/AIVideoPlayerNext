import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/audio_models.dart';
import 'package:ai_video_player_next/domain/audio/audio_window_planner.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/features/audio/fake_audio_decoder.dart';
import 'package:ai_video_player_next/features/audio/fake_window_recognition_service.dart';
import 'package:ai_video_player_next/features/audio/recognition_controller.dart';
import 'package:ai_video_player_next/features/player/mock_services.dart';

MediaSource _source(String title) => MediaSource.localFile(
      path: 'C:\\test\\$title.mp4',
      title: '$title.mp4',
    );

AudioChunk _chunk(int seconds, {bool last = false}) => AudioChunk(
      sessionId: 'decoder-session',
      mediaStart: Duration(seconds: seconds),
      sampleRate: 16000,
      channels: 1,
      samples: List<double>.filled(16000, 0.1),
      isLast: last,
    );

AudioChunk _partialChunk(int milliseconds) => AudioChunk(
      sessionId: 'decoder-session',
      mediaStart: Duration.zero,
      sampleRate: 16000,
      channels: 1,
      samples: List<double>.filled(milliseconds * 16, 0.1),
    );

AudioWindowPlanner _planner() => AudioWindowPlanner(
      targetWindow: const Duration(seconds: 1),
      minimumSpeechWindow: const Duration(milliseconds: 100),
      maximumWindow: const Duration(seconds: 2),
    );

Future<void> _settle() async {
  for (var index = 0; index < 12; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('controller turns playing decoder chunks into recognition events',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(chunks: [_chunk(0, last: true)]);
    final recognizer = FakeWindowRecognitionService();
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: recognizer,
      planner: _planner(),
    );
    final events = <RecognitionEvent>[];
    final subscription = controller.events.listen(events.add);

    await player.open(_source('first'));
    await player.play();
    await _settle();

    expect(recognizer.received, hasLength(1));
    expect(events, hasLength(1));
    expect(events.single.start, Duration.zero);
    expect(controller.diagnostic.windowsRecognized, 1);

    await subscription.cancel();
    await controller.dispose();
    await player.dispose();
  });

  test('slow recognition pauses decoding and preserves one deferred window',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(
      chunks: [_chunk(0), _chunk(1), _chunk(2, last: true)],
    );
    final recognizer = FakeWindowRecognitionService(
      delay: const Duration(milliseconds: 30),
    );
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: recognizer,
      planner: _planner(),
    );

    await player.open(_source('slow'));
    await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(recognizer.received, hasLength(3));
    expect(controller.diagnostic.windowsSkipped, 0);
    expect(controller.diagnostic.queueDepth, lessThanOrEqualTo(2));

    await controller.dispose();
    await player.dispose();
  });

  test('seek creates a new session and rejects old recognition results',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(chunks: [_chunk(0, last: true)]);
    final recognizer = FakeWindowRecognitionService(
      delay: const Duration(milliseconds: 30),
    );
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: recognizer,
      planner: _planner(),
    );
    final events = <RecognitionEvent>[];
    final subscription = controller.events.listen(events.add);

    await player.open(_source('seek'));
    await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final oldSession = controller.diagnostic.sessionId;
    await controller.seek(const Duration(seconds: 5));
    await _settle();

    expect(controller.diagnostic.sessionId, isNot(oldSession));
    expect(events, isEmpty);

    await subscription.cancel();
    await controller.dispose();
    await player.dispose();
  });

  test('pause lets an in-flight window finish', () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(chunks: [_chunk(0, last: true)]);
    final recognizer = FakeWindowRecognitionService(
      delay: const Duration(milliseconds: 30),
    );
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: recognizer,
      planner: _planner(),
    );
    final events = <RecognitionEvent>[];
    final subscription = controller.events.listen(events.add);

    await player.open(_source('pause'));
    await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(events, hasLength(1));
    expect(controller.diagnostic.windowsRecognized, 1);

    await subscription.cancel();
    await controller.dispose();
    await player.dispose();
  });

  test('pause flushes a buffered partial window', () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(chunks: [_partialChunk(500)]);
    final recognizer = FakeWindowRecognitionService();
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: recognizer,
      planner: _planner(),
    );
    final events = <RecognitionEvent>[];
    final subscription = controller.events.listen(events.add);

    await player.open(_source('partial'));
    await player.play();
    await _settle();
    await player.pause();
    await _settle();

    expect(recognizer.received, hasLength(1));
    expect(events, hasLength(1));
    expect(events.single.end, const Duration(milliseconds: 500));

    await subscription.cancel();
    await controller.dispose();
    await player.dispose();
  });
}
