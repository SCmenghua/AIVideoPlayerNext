import 'dart:async';
import 'dart:typed_data';

import 'package:recognition/recognition.dart';
import 'package:test/test.dart';

/// Emits a scripted 16 kHz mono signal: speech is a 0.3 amplitude square-ish
/// wave, silence is zero. Chunks are 0.5 s.
class ScriptedSource implements PcmSource {
  ScriptedSource(this.script);

  final List<(Duration, bool)> script;
  final StreamController<RawPcmChunk> _chunks = StreamController.broadcast();
  final StreamController<PcmSourceStatus> _statuses = StreamController.broadcast();
  PcmSourceStatus _status = const PcmSourceStatus.idle();
  int pauseCalls = 0;
  int startCalls = 0;
  Duration? lastSeek;
  bool _running = false;
  Duration _position = Duration.zero;
  Timer? _timer;

  @override
  Stream<RawPcmChunk> get chunks => _chunks.stream;
  @override
  Stream<PcmSourceStatus> get statuses => _statuses.stream;
  @override
  PcmSourceStatus get status => _status;

  Duration get total => script.fold(Duration.zero, (sum, item) => sum + item.$1);

  @override
  Future<void> open(Uri uri, {Duration start = Duration.zero}) async {
    _position = start;
    _set(const PcmSourceStatus(state: PcmSourceState.ready, sampleRate: 16000, channels: 1));
  }

  @override
  Future<void> start() async {
    startCalls++;
    _running = true;
    _set(_status.copyWith(state: PcmSourceState.running));
    _timer ??= Timer.periodic(const Duration(milliseconds: 2), (_) => _tick());
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _running = false;
    _set(_status.copyWith(state: PcmSourceState.paused));
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    _position = position;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _set(_status.copyWith(state: PcmSourceState.stopped));
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _chunks.close();
    await _statuses.close();
  }

  bool _isSpeechAt(Duration position) {
    var offset = Duration.zero;
    for (final (duration, speech) in script) {
      if (position < offset + duration) return speech;
      offset += duration;
    }
    return false;
  }

  void _tick() {
    if (!_running) return;
    const chunk = Duration(milliseconds: 500);
    if (_position >= total) {
      _chunks.add(RawPcmChunk(
        samples: Float32List(0),
        sampleRate: 16000,
        channels: 1,
        mediaStart: _position,
        isLast: true,
      ));
      _running = false;
      _timer?.cancel();
      _timer = null;
      _set(_status.copyWith(state: PcmSourceState.ended));
      return;
    }
    final samples = Float32List(8000);
    for (var i = 0; i < samples.length; i++) {
      final t = _position + Duration(microseconds: i * 1000000 ~/ 16000);
      samples[i] = _isSpeechAt(t) ? ((i ~/ 20) % 2 == 0 ? 0.3 : -0.3) : 0.0;
    }
    _chunks.add(RawPcmChunk(
      samples: samples,
      sampleRate: 16000,
      channels: 1,
      mediaStart: _position,
    ));
    _position += chunk;
  }

  void _set(PcmSourceStatus status) {
    _status = status;
    _statuses.add(status);
  }
}

class FakeEngine implements RecognitionEngine {
  FakeEngine({this.delay = const Duration(milliseconds: 5)});

  final Duration delay;
  final List<EngineRequest> requests = [];
  int cancels = 0;
  Completer<void>? gate;

  @override
  EngineState get state => EngineState.ready;
  @override
  EngineBackendInfo? get backendInfo => const EngineBackendInfo(
        requested: 'cpu',
        actual: 'cpu',
        gpuEnabled: false,
        deviceName: '',
        fallbackReason: 0,
        message: 'fake',
      );

  @override
  Future<void> load() async {}

  @override
  Future<EngineResult> recognize(EngineRequest request) async {
    requests.add(request);
    final pending = gate;
    if (pending != null) await pending.future;
    await Future<void>.delayed(delay);
    final durationMs = request.samples.length ~/ 16;
    return EngineResult(
      segments: [
        RawSegment(
          index: 0,
          startMs: 100,
          endMs: durationMs - 100,
          text: '窓${requests.length}の文です。',
          language: 'ja',
          avgLogprob: -0.1,
          noSpeechProb: 0.05,
          repetition: 0,
          tokenCount: 6,
        ),
      ],
      inference: const Duration(milliseconds: 5),
      droppedSegments: 0,
      backend: backendInfo!,
    );
  }

  @override
  void cancel() => cancels++;

  @override
  Future<void> dispose() async {}
}

RecognitionSession makeSession(ScriptedSource source, FakeEngine engine, {RecognitionConfig? config}) =>
    RecognitionSession(
      source: source,
      engine: engine,
      config: config ??
          const RecognitionConfig(
            modelPath: 'fake',
            leadPause: null,
            segmenter: SegmenterOptions(minCutWindow: Duration(seconds: 2)),
          ),
      converter: PassthroughConverter(),
    );

Future<void> waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('speech separated by pauses becomes windows and transcript segments', () async {
    final source = ScriptedSource([
      (const Duration(seconds: 1), false),
      (const Duration(seconds: 3), true),
      (const Duration(seconds: 1), false),
      (const Duration(seconds: 3), true),
      (const Duration(seconds: 1), false),
    ]);
    final engine = FakeEngine();
    final session = makeSession(source, engine);
    await session.open(Uri.parse('test://media'));
    await waitFor(() => session.diagnostics.state == RecognitionState.ended);
    expect(engine.requests.length, 2);
    expect(session.transcript.segments.length, 2);
    expect(session.transcript.segments.first.startMs, inInclusiveRange(800, 1400));
    expect(session.diagnostics.processedThrough, greaterThanOrEqualTo(const Duration(seconds: 8)));
    expect(session.diagnostics.windowsSkipped, greaterThan(0));
    expect(engine.requests.last.prompt, isNotNull, reason: 'previous window text is the prompt');
    await session.dispose();
    await source.dispose();
  });

  test('a seek discards the in-flight result and restarts from the target', () async {
    final source = ScriptedSource([
      (const Duration(seconds: 3), true),
      (const Duration(seconds: 1), false),
      (const Duration(seconds: 3), true),
      (const Duration(seconds: 1), false),
    ]);
    final engine = FakeEngine()..gate = Completer<void>();
    final session = makeSession(source, engine);
    await session.open(Uri.parse('test://media'));
    await waitFor(() => engine.requests.isNotEmpty);
    await session.seek(const Duration(seconds: 6));
    expect(engine.cancels, 1);
    expect(source.lastSeek, const Duration(seconds: 6));
    engine.gate!.complete();
    await waitFor(() => session.diagnostics.state == RecognitionState.ended);
    expect(session.transcript.segments.where((s) => s.startMs < 6000), isEmpty,
        reason: 'the pre-seek result must not land');
    await session.dispose();
    await source.dispose();
  });

  test('the source is paused while too many windows wait for the engine', () async {
    final source = ScriptedSource([
      for (var i = 0; i < 6; i++) ...[
        (const Duration(seconds: 3), true),
        (const Duration(seconds: 1), false),
      ],
    ]);
    final engine = FakeEngine()..gate = Completer<void>();
    final session = makeSession(
      source,
      engine,
      config: const RecognitionConfig(
        modelPath: 'fake',
        leadPause: null,
        maxPendingWindows: 2,
        segmenter: SegmenterOptions(minCutWindow: Duration(seconds: 2)),
      ),
    );
    await session.open(Uri.parse('test://media'));
    await waitFor(() => source.pauseCalls > 0);
    expect(session.diagnostics.sourcePausedForQueue, isTrue);
    engine.gate!.complete();
    await waitFor(() => session.diagnostics.state == RecognitionState.ended);
    expect(session.transcript.segments.length, 6);
    await session.dispose();
    await source.dispose();
  });

  test('the lead watermark pauses and resumes the source', () async {
    final source = ScriptedSource([(const Duration(seconds: 40), true)]);
    final engine = FakeEngine();
    final session = makeSession(
      source,
      engine,
      config: const RecognitionConfig(
        modelPath: 'fake',
        leadPause: Duration(seconds: 5),
        leadResume: Duration(seconds: 2),
      ),
    );
    await session.open(Uri.parse('test://media'));
    await waitFor(() => session.diagnostics.sourcePausedForLead);
    expect(source.pauseCalls, greaterThan(0));
    session.updatePlaybackPosition(session.diagnostics.decodedThrough - const Duration(seconds: 1));
    await waitFor(() => !session.diagnostics.sourcePausedForLead);
    await session.stop();
    await session.dispose();
    await source.dispose();
  });
}
