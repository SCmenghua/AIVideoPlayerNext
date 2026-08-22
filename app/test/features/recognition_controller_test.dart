import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/audio_models.dart';
import 'package:ai_video_player_next/domain/audio/recognition_media_source.dart';
import 'package:ai_video_player_next/domain/audio/audio_window_planner.dart';
import 'package:ai_video_player_next/domain/audio/recognition_queue.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/features/audio/fake_audio_decoder.dart';
import 'package:ai_video_player_next/features/audio/fake_window_recognition_service.dart';
import 'package:ai_video_player_next/features/audio/recognition_controller.dart';
import 'package:ai_video_player_next/features/audio/recognition_media_cache_worker.dart';
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

  test('seek keeps the current recognition session and decoder open count',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(chunks: [_chunk(0, last: true)]);
    final recognizer = FakeWindowRecognitionService(
      delay: const Duration(milliseconds: 10),
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
    await _settle();
    final oldSession = controller.diagnostic.sessionId;
    final oldOpenCount = decoder.openCount;
    await controller.seek(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 15));

    expect(controller.diagnostic.sessionId, oldSession);
    expect(decoder.openCount, oldOpenCount);
    expect(events, hasLength(1));

    await subscription.cancel();
    await controller.dispose();
    await player.dispose();
  });

  test('reopening the same media starts a fresh recognition session', () async {
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
    final source = _source('reopened');

    await player.open(source);
    await player.play();
    await _settle();
    final firstSession = controller.diagnostic.sessionId;
    expect(decoder.openCount, 1);

    controller.prepareForMediaOpen();
    await player.open(source);
    await player.play();
    await _settle();

    expect(controller.diagnostic.sessionId, isNot(firstSession));
    expect(decoder.openCount, 2);
    expect(events.map((event) => event.sessionId).toSet(), hasLength(2));
    expect(controller.diagnostic.windowsRecognized, 1);

    await subscription.cancel();
    await controller.dispose();
    await player.dispose();
  });

  test('seek does not request recognizer cancellation', () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(chunks: [_chunk(0, last: true)]);
    final recognizer = _BlockingStopRecognizer();
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: recognizer,
      planner: _planner(),
    );

    await player.open(_source('nonblocking-seek'));
    await player.play();
    await _settle();
    final oldSession = controller.diagnostic.sessionId;

    final oldOpenCount = decoder.openCount;
    recognizer.blockStops = true;
    await controller
        .seek(const Duration(seconds: 5))
        .timeout(const Duration(milliseconds: 50));
    await _settle();

    expect(controller.diagnostic.sessionId, oldSession);
    expect(decoder.openCount, oldOpenCount);
    expect(recognizer.stopCalls, 1);

    recognizer.releaseStops();
    recognizer.blockStops = false;
    await controller.dispose();
    await player.dispose();
  });

  test('pause leaves the recognition decoder running', () async {
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
    final oldOpenCount = decoder.openCount;
    await player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(events, hasLength(1));
    expect(controller.diagnostic.windowsRecognized, 1);
    expect(decoder.openCount, oldOpenCount);
    expect(decoder.pauseCount, 0);

    await subscription.cancel();
    await controller.dispose();
    await player.dispose();
  });

  test('pause does not interrupt a buffered recognition window', () async {
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

    expect(recognizer.received, isEmpty);
    expect(events, isEmpty);
    expect(decoder.pauseCount, 0);

    await subscription.cancel();
    await controller.dispose();
    await player.dispose();
  });

  test('full-media prefetch reaches EOF without a watermark pause', () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(
      chunks: [_chunk(0), _chunk(1), _chunk(2, last: true)],
    );
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: FakeWindowRecognitionService(),
      planner: _planner(),
      queue: RecognitionQueue(maxWaiting: 4),
      lowWatermark: const Duration(milliseconds: 500),
      highWatermark: const Duration(seconds: 1),
    );

    await player.open(_source('full-media'));
    await player.play();
    await _settle();

    expect(controller.diagnostic.processedThrough,
        greaterThanOrEqualTo(const Duration(seconds: 3)));
    expect(decoder.pauseCount, 0);

    await controller.dispose();
    await player.dispose();
  });

  test('large forward seek schedules background recognition near target',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(
      chunks: List<AudioChunk>.generate(
        16,
        (index) => _chunk(index, last: index == 15),
      ),
    );
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: FakeWindowRecognitionService(
        delay: const Duration(milliseconds: 30),
      ),
      planner: _planner(),
      seekPriorityThreshold: const Duration(seconds: 5),
      seekPriorityContext: const Duration(seconds: 2),
      priorityLead: const Duration(seconds: 3),
    );

    await player.open(_source('seek-priority'));
    await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await controller.seek(const Duration(seconds: 11));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(decoder.seekCount, greaterThan(0));
    expect(decoder.seekPositions.first, const Duration(seconds: 9));
    expect(controller.diagnostic.sessionId, isNotNull);

    await controller.dispose();
    await player.dispose();
  });

  test('large network forward seek promotes the recognition cache target',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(
      chunks: List<AudioChunk>.generate(
        16,
        (index) => _chunk(index, last: index == 15),
      ),
    );
    _RecordingMediaCacheWorker? worker;
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: FakeWindowRecognitionService(
        delay: const Duration(milliseconds: 30),
      ),
      planner: _planner(),
      seekPriorityThreshold: const Duration(seconds: 5),
      seekPriorityContext: const Duration(seconds: 2),
      priorityLead: const Duration(seconds: 3),
      mediaCacheWorkerFactory: ({required source, required sessionId}) {
        return worker = _RecordingMediaCacheWorker(
          source: source,
          sessionId: sessionId,
        );
      },
    );

    await player.open(
      MediaSource(
        uri: Uri.parse('https://example.test/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
    );
    await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await controller.seek(const Duration(seconds: 11));
    await _settle();

    expect(worker, isNotNull);
    expect(worker!.priorityPositions, [const Duration(seconds: 11)]);

    await controller.dispose();
    await player.dispose();
  });

  test('iOS network recognition fully caches media before opening decoder',
      () async {
    final player = MockPlayerService();
    final decoder = _RecordingAudioDecoder(chunks: [_chunk(0, last: true)]);
    _IosCacheRecordingWorker? worker;
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: FakeWindowRecognitionService(),
      planner: _planner(),
      isIosPlatform: () => true,
      mediaCacheWorkerFactory: ({required source, required sessionId}) {
        return worker = _IosCacheRecordingWorker(
          source: source,
          sessionId: sessionId,
        );
      },
    );

    await player.open(
      MediaSource(
        uri: Uri.parse('https://example.test/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
    );
    await player.play();
    await _settle();

    expect(worker, isNotNull);
    expect(worker!.prepareCalls, 1);
    expect(worker!.proxyCalls, 0);
    expect(decoder.openRequest?.source.uri, Uri.file(r'C:\cache\media.mp4'));

    await controller.dispose();
    await player.dispose();
  });

  test('high watermark pauses and low watermark resumes the decoder', () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(
      chunks: [_chunk(0), _chunk(1), _chunk(2, last: true)],
    );
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: FakeWindowRecognitionService(),
      planner: _planner(),
      prefetchMode: RecognitionPrefetchMode.boundedAhead,
      lowWatermark: const Duration(milliseconds: 500),
      highWatermark: const Duration(seconds: 1),
    );

    await player.open(_source('watermark'));
    await player.play();
    await _settle();

    expect(decoder.pauseCount, greaterThanOrEqualTo(1));
    await player.seek(const Duration(seconds: 2));
    await _settle();

    expect(decoder.pauseCount, greaterThanOrEqualTo(1));
    expect(controller.diagnostic.processedThrough,
        greaterThanOrEqualTo(const Duration(seconds: 1)));

    await controller.dispose();
    await player.dispose();
  });

  test('switching to full-media prefetch resumes a watermark-paused decoder',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(
      chunks: [_chunk(0), _chunk(1), _chunk(2, last: true)],
    );
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: FakeWindowRecognitionService(),
      planner: _planner(),
      prefetchMode: RecognitionPrefetchMode.boundedAhead,
      lowWatermark: const Duration(milliseconds: 500),
      highWatermark: const Duration(seconds: 1),
    );

    await player.open(_source('runtime-prefetch-switch'));
    await player.play();
    await _settle();
    expect(decoder.pauseCount, greaterThanOrEqualTo(1));
    final opensBeforeSwitch = decoder.openCount;
    final startsBeforeSwitch = decoder.startCount;

    await controller.setPrefetchMode(RecognitionPrefetchMode.fullMedia);
    await _settle();

    expect(controller.prefetchMode, RecognitionPrefetchMode.fullMedia);
    expect(decoder.openCount, opensBeforeSwitch);
    expect(decoder.startCount, greaterThan(startsBeforeSwitch));

    await controller.dispose();
    await player.dispose();
  });

  test('backpressure hands a full prefetch lead to watermark recovery',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(
      chunks: [
        _chunk(0),
        _chunk(1),
        _chunk(2),
        _chunk(3),
        _chunk(4, last: true),
      ],
    );
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: FakeWindowRecognitionService(
        delay: const Duration(milliseconds: 5),
      ),
      planner: _planner(),
      prefetchMode: RecognitionPrefetchMode.boundedAhead,
      lowWatermark: const Duration(seconds: 1),
      highWatermark: const Duration(seconds: 2),
    );

    await player.open(_source('backpressure-watermark'));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(controller.diagnostic.processedThrough,
        greaterThanOrEqualTo(const Duration(seconds: 2)));
    expect(decoder.pauseCount, greaterThan(0));
    final startsBeforePlaybackAdvance = decoder.startCount;

    await player.seek(const Duration(seconds: 4));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(decoder.startCount, greaterThan(startsBeforePlaybackAdvance));
    expect(controller.diagnostic.processedThrough,
        greaterThanOrEqualTo(const Duration(seconds: 5)));

    await controller.dispose();
    await player.dispose();
  });

  test('silent windows advance processing but do not claim subtitle coverage',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(chunks: [
      AudioChunk(
        sessionId: 'decoder-session',
        mediaStart: Duration.zero,
        sampleRate: 16000,
        channels: 1,
        samples: List<double>.filled(16000, 0),
        isLast: true,
      ),
    ]);
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: FakeWindowRecognitionService(),
      planner: _planner(),
      prefetchMode: RecognitionPrefetchMode.boundedAhead,
      lowWatermark: const Duration(milliseconds: 500),
      highWatermark: const Duration(seconds: 1),
    );

    await player.open(_source('silent'));
    await player.play();
    await _settle();

    expect(controller.diagnostic.windowsSkipped, 1);
    expect(controller.diagnostic.processedThrough, const Duration(seconds: 1));
    expect(controller.diagnostic.recognizedThrough, Duration.zero);
    expect(decoder.pauseCount, 1);

    await controller.dispose();
    await player.dispose();
  });

  test('failed recognition advances processing but not subtitle coverage',
      () async {
    final player = MockPlayerService();
    final decoder = FakeAudioDecoder(chunks: [_chunk(0, last: true)]);
    final controller = RecognitionController(
      player: player,
      decoder: decoder,
      recognizer: _FailingRecognizer(),
      planner: _planner(),
    );

    await player.open(_source('failed'));
    await player.play();
    await _settle();

    expect(controller.diagnostic.windowsFailed, 1);
    expect(controller.diagnostic.processedThrough, const Duration(seconds: 1));
    expect(controller.diagnostic.recognizedThrough, Duration.zero);

    await controller.dispose();
    await player.dispose();
  });
}

class _FailingRecognizer implements WindowRecognitionService {
  @override
  Future<WindowRecognitionResult> recognize(RecognitionWindow window) async =>
      WindowRecognitionResult(
        window: window,
        events: const [],
        error: 'model_error',
      );

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _BlockingStopRecognizer implements WindowRecognitionService {
  bool blockStops = false;
  Completer<void>? _stopCompleter;
  int stopCalls = 0;

  @override
  Future<WindowRecognitionResult> recognize(RecognitionWindow window) async =>
      WindowRecognitionResult(window: window, events: const []);

  @override
  Future<void> stop() {
    ++stopCalls;
    if (!blockStops) return Future<void>.value();
    return (_stopCompleter ??= Completer<void>()).future;
  }

  void releaseStops() {
    final completer = _stopCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  Future<void> dispose() async => releaseStops();
}

class _RecordingMediaCacheWorker extends RecognitionMediaCacheWorker {
  _RecordingMediaCacheWorker({
    required super.source,
    required super.sessionId,
  });

  final List<Duration> priorityPositions = [];

  @override
  void prioritizePlaybackRange({
    required Duration playbackPosition,
    required Duration context,
    required Duration lead,
    required int epoch,
  }) {
    priorityPositions.add(playbackPosition);
  }
}

class _IosCacheRecordingWorker extends RecognitionMediaCacheWorker {
  _IosCacheRecordingWorker({
    required super.source,
    required super.sessionId,
  });

  int prepareCalls = 0;
  int proxyCalls = 0;

  @override
  Future<RecognitionMediaCacheSnapshot> prepare() async {
    ++prepareCalls;
    return RecognitionMediaCacheSnapshot(
      sessionId: sessionId,
      mode: RecognitionMediaReadMode.localFile,
      state: RecognitionMediaCacheState.complete,
      cursor: RecognitionMediaCursor(
        sessionId: sessionId,
        mode: RecognitionMediaReadMode.localFile,
      ),
      path: r'C:\cache\media.mp4',
      contentLength: 1234,
    );
  }

  @override
  Future<RecognitionMediaCacheSnapshot> startProxy() async {
    ++proxyCalls;
    throw StateError('iOS must not start the recognition proxy');
  }
}

class _RecordingAudioDecoder extends FakeAudioDecoder {
  _RecordingAudioDecoder({required super.chunks});

  AudioDecoderRequest? openRequest;

  @override
  Future<void> open(AudioDecoderRequest request) async {
    openRequest = request;
    await super.open(request);
  }
}
