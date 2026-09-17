import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'assembler.dart';
import 'config.dart';
import 'contracts.dart';
import 'diagnostics.dart';
import 'engine.dart';
import 'gate.dart';
import 'native_bindings.dart';
import 'normalizer.dart';
import 'pcm.dart';
import 'segmenter.dart';
import 'text.dart';
import 'transcript.dart';
import 'vad.dart';

/// RMS-threshold fallback used when no VAD model is installed.
class EnergyVad implements SpeechProbabilityProvider {
  EnergyVad({this.frameSamples = 512, this.threshold = 0.012});

  @override
  final int frameSamples;
  final double threshold;

  @override
  Future<void> load() async {}

  @override
  Future<Float32List> probabilities(Float32List samples) async {
    final frames = samples.length ~/ frameSamples;
    final result = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      var energy = 0.0;
      for (var j = 0; j < frameSamples; j++) {
        final value = samples[i * frameSamples + j];
        energy += value * value;
      }
      final rms = math.sqrt(energy / frameSamples);
      result[i] = rms > threshold ? 1.0 : 0.0;
    }
    return result;
  }

  @override
  Future<void> dispose() async {}
}

/// Passes 16 kHz mono input straight through; used by tests and the
/// regression runner where the source already emits the target format.
class PassthroughConverter implements PcmConverter {
  @override
  PcmChunk? process(RawPcmChunk raw) {
    if (raw.sampleRate != speechSampleRate || raw.channels != 1) {
      throw ArgumentError('passthrough requires 16 kHz mono input');
    }
    return PcmChunk(samples: raw.samples, mediaStart: raw.mediaStart, isLast: raw.isLast);
  }

  @override
  void reset() {}

  @override
  void dispose() {}
}

/// Drives one media file through decode → VAD → windows → whisper → gate →
/// transcript, with bounded lead over playback and generation isolation so a
/// seek can never let stale results through.
class RecognitionSession {
  RecognitionSession({
    required this.source,
    required this.engine,
    required this.config,
    SpeechProbabilityProvider? vad,
    PcmConverter? converter,
    String? libraryPath,
    this.onLog,
    this.vadBatch = const Duration(milliseconds: 512),
  })  : vad = vad ?? EnergyVad(),
        _gate = SegmentGate(config.gate),
        _converter = converter ??
            PcmNormalizer(SpeechCoreBindings.open(
              libraryPath ?? (throw ArgumentError('libraryPath or converter required')),
            ));

  final PcmSource source;
  final RecognitionEngine engine;
  final RecognitionConfig config;
  final SpeechProbabilityProvider vad;
  final void Function(RecognitionLogEvent event)? onLog;
  final Duration vadBatch;

  final PcmConverter _converter;
  late final SpeechSegmenter _segmenter;
  late final VadStream _vadStream;
  final SegmentGate _gate;
  final TranscriptAssembler _assembler = TranscriptAssembler();
  final Queue<SpeechWindow> _pending = Queue<SpeechWindow>();
  final StreamController<Transcript> _transcripts = StreamController<Transcript>.broadcast();
  final StreamController<RecognitionDiagnostics> _diagnostics =
      StreamController<RecognitionDiagnostics>.broadcast();

  RecognitionDiagnostics _diag = const RecognitionDiagnostics();
  StreamSubscription<RawPcmChunk>? _chunkSubscription;
  StreamSubscription<PcmSourceStatus>? _statusSubscription;
  Future<void> _chain = Future<void>.value();
  Float32List _unaligned = Float32List(0);
  int _generation = 0;
  bool _prepared = false;
  bool _draining = false;
  bool _sawLast = false;
  bool _flushed = false;
  bool _disposed = false;
  bool _sourceShouldRun = false;
  String? _context;
  Duration _contextValidUntil = Duration.zero;
  Uri? _uri;

  Transcript get transcript => _assembler.transcript;
  Stream<Transcript> get transcripts => _transcripts.stream;
  RecognitionDiagnostics get diagnostics => _diag;
  Stream<RecognitionDiagnostics> get diagnosticsStream => _diagnostics.stream;
  int get generation => _generation;
  bool get isDisposed => _disposed;

  /// Loads the engine and VAD once. Safe to call repeatedly.
  Future<void> prepare() async {
    if (_prepared) return;
    await vad.load();
    _segmenter = SpeechSegmenter(frameSamples: vad.frameSamples, options: config.segmenter);
    _vadStream = VadStream(frameSamples: vad.frameSamples, probabilities: vad.probabilities);
    await engine.load();
    _prepared = true;
    _update(_diag.copyWith(engineState: engine.state, engineBackend: engine.backendInfo));
  }

  /// Returns false when the source could not be opened; the session is then
  /// in [RecognitionState.error] and may be reopened with another URI.
  Future<bool> open(Uri uri, {Duration start = Duration.zero}) async {
    _ensureUsable();
    await prepare();
    final generation = ++_generation;
    _uri = uri;
    _resetPipeline(sessionId: 'g$generation', start: start, newMedia: true);
    _update(_diag.copyWith(
      state: RecognitionState.opening,
      generation: generation,
      playbackPosition: start,
      clearMessage: true,
    ));
    _subscribe();
    try {
      await source.open(uri, start: start);
      if (generation != _generation) return false;
      _sourceShouldRun = true;
      await source.start();
      if (generation != _generation) return false;
      _update(_diag.copyWith(state: RecognitionState.running));
      _log(RecognitionLogLevel.info, '识别会话已开始', {'媒体': uri.toString(), '起点': start});
      return true;
    } on Object catch (error) {
      if (generation != _generation) return false;
      _update(_diag.copyWith(state: RecognitionState.error, message: error.toString()));
      _log(RecognitionLogLevel.error, '识别会话打开失败', {'错误': error.toString()});
      return false;
    }
  }

  Future<void> seek(Duration position) async {
    _ensureUsable();
    if (_uri == null) return;
    final generation = ++_generation;
    engine.cancel();
    _resetPipeline(sessionId: 'g$generation', start: position, newMedia: false);
    _update(_diag.copyWith(
      generation: generation,
      state: RecognitionState.running,
      playbackPosition: position,
      clearMessage: true,
    ));
    try {
      await source.seek(position);
      if (generation != _generation) return;
      if (_sourceShouldRun) await source.start();
      _log(RecognitionLogLevel.info, '识别已跳转', {'位置': position});
    } on Object catch (error) {
      if (generation != _generation) return;
      _update(_diag.copyWith(state: RecognitionState.error, message: error.toString()));
    }
  }

  void updatePlaybackPosition(Duration position) {
    if (_disposed) return;
    _update(_diag.copyWith(playbackPosition: position));
    _checkLead();
  }

  Future<void> stop() async {
    if (_disposed) return;
    ++_generation;
    engine.cancel();
    _pending.clear();
    _sourceShouldRun = false;
    await _chunkSubscription?.cancel();
    _chunkSubscription = null;
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    try {
      await source.stop();
    } on Object catch (error) {
      _log(RecognitionLogLevel.warning, '解码器停止失败', {'错误': error.toString()});
    }
    _update(_diag.copyWith(state: RecognitionState.stopped, pendingWindows: 0));
  }

  /// Releases the session's own resources. The source, engine and VAD are
  /// owned by the caller.
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    _converter.dispose();
    await _transcripts.close();
    await _diagnostics.close();
  }

  // ---------------------------------------------------------------------------

  void _resetPipeline({required String sessionId, required Duration start, required bool newMedia}) {
    _pending.clear();
    _unaligned = Float32List(0);
    _converter.reset();
    _vadStream.reset();
    _segmenter.reset(sessionId: sessionId, preserveIndex: !newMedia);
    _gate.reset();
    if (newMedia) {
      _assembler.reset();
      _emitTranscript();
    }
    _context = null;
    _contextValidUntil = Duration.zero;
    _sawLast = false;
    _flushed = false;
    _chain = Future<void>.value();
    _update(_diag.copyWith(
      decodedThrough: start,
      processedThrough: start,
      recognizedThrough: newMedia ? Duration.zero : _diag.recognizedThrough,
      pendingWindows: 0,
      sourcePausedForLead: false,
      sourcePausedForQueue: false,
    ));
  }

  void _subscribe() {
    _chunkSubscription ??= source.chunks.listen(_onChunk);
    _statusSubscription ??= source.statuses.listen(_onSourceStatus);
  }

  void _onSourceStatus(PcmSourceStatus status) {
    _update(_diag.copyWith(source: status));
    if (status.state == PcmSourceState.error) {
      _update(_diag.copyWith(state: RecognitionState.error, message: status.message));
      _log(RecognitionLogLevel.error, '解码器错误', {'错误': status.message});
    } else if (status.state == PcmSourceState.ended && !_sawLast) {
      final generation = _generation;
      _chain = _chain.then((_) => _finish(generation));
    }
  }

  void _onChunk(RawPcmChunk raw) {
    final generation = _generation;
    _chain = _chain.then((_) => _handleChunk(raw, generation)).catchError((Object error) {
      if (generation != _generation || _disposed) return;
      _update(_diag.copyWith(state: RecognitionState.error, message: error.toString()));
      _log(RecognitionLogLevel.error, '识别管线错误', {'错误': error.toString()});
    });
  }

  Future<void> _handleChunk(RawPcmChunk raw, int generation) async {
    if (generation != _generation || _disposed) return;
    final chunk = _converter.process(raw);
    if (chunk == null) return;
    if (chunk.isLast) _sawLast = true;
    _update(_diag.copyWith(decodedThrough: chunk.mediaEnd));
    await _feed(chunk, generation);
    if (generation != _generation) return;
    if (chunk.isLast) await _finish(generation);
    _checkLead();
  }

  Future<void> _feed(PcmChunk chunk, int generation) async {
    final frame = vad.frameSamples;
    final combined = Float32List(_unaligned.length + chunk.samples.length)
      ..setAll(0, _unaligned)
      ..setAll(_unaligned.length, chunk.samples);
    final combinedStart = chunk.mediaStart -
        Duration(microseconds: _unaligned.length * Duration.microsecondsPerSecond ~/ speechSampleRate);
    var aligned = combined.length ~/ frame * frame;
    final minimum = chunk.isLast ? 1 : vadBatch.inMicroseconds * speechSampleRate ~/ 1000000;
    if (aligned < minimum && !chunk.isLast) {
      _unaligned = combined;
      return;
    }
    Float32List batch;
    if (chunk.isLast && combined.length % frame != 0) {
      aligned = (combined.length ~/ frame + 1) * frame;
      batch = Float32List(aligned)..setAll(0, combined);
      _unaligned = Float32List(0);
    } else {
      batch = Float32List.sublistView(combined, 0, aligned);
      _unaligned = Float32List.fromList(combined.sublist(aligned));
    }
    if (batch.isEmpty) return;
    final probabilities = await _vadStream.process(batch);
    if (generation != _generation) return;
    final frames = batch.length ~/ frame;
    for (var i = 0; i < frames; i++) {
      final samples = Float32List.sublistView(batch, i * frame, (i + 1) * frame);
      final start = combinedStart +
          Duration(microseconds: i * frame * Duration.microsecondsPerSecond ~/ speechSampleRate);
      _handleEvents(_segmenter.addFrame(samples, probabilities[i], start));
    }
  }

  Future<void> _finish(int generation) async {
    if (_flushed || generation != _generation) return;
    _flushed = true;
    if (_unaligned.isNotEmpty) {
      await _feed(PcmChunk(samples: Float32List(0), mediaStart: _diag.decodedThrough, isLast: true), generation);
      if (generation != _generation) return;
    }
    _handleEvents(_segmenter.flush());
    _sourceShouldRun = false;
    if (!_draining && _pending.isEmpty) {
      _update(_diag.copyWith(state: RecognitionState.ended));
      _log(RecognitionLogLevel.info, '识别会话已到达媒体结尾');
    }
  }

  void _handleEvents(List<SegmenterEvent> events) {
    for (final event in events) {
      switch (event) {
        case WindowReady(:final window):
          _pending.add(window);
          _update(_diag.copyWith(pendingWindows: _pending.length));
          _log(RecognitionLogLevel.debug, '识别窗口已切出', {
            '窗口': window.id,
            '起点': window.mediaStart,
            '时长': window.duration,
            '语音占比': window.speechRatio.toStringAsFixed(2),
            '切分原因': window.cutReason,
          });
          _checkQueue();
          _drain();
        case RangeSkipped(:final start, :final end):
          _advanceProcessed(end);
          _update(_diag.copyWith(windowsSkipped: _diag.windowsSkipped + 1));
          _log(RecognitionLogLevel.debug, '静音区间已跳过', {'起点': start, '终点': end});
      }
    }
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    _drainLoop().whenComplete(() {
      _draining = false;
      if (_pending.isNotEmpty) {
        _drain();
      } else if (_flushed &&
          !_disposed &&
          (_diag.state == RecognitionState.running ||
              _diag.state == RecognitionState.paused)) {
        _update(_diag.copyWith(state: RecognitionState.ended));
        _log(RecognitionLogLevel.info, '识别会话已到达媒体结尾');
      }
    });
  }

  Future<void> _drainLoop() async {
    while (_pending.isNotEmpty && !_disposed) {
      final window = _pending.removeFirst();
      final generation = _generation;
      _update(_diag.copyWith(pendingWindows: _pending.length));
      _checkQueue();
      final prompt = config.contextEnabled && window.mediaStart <= _contextValidUntil
          ? _context
          : null;
      final stopwatch = Stopwatch()..start();
      EngineResult result;
      try {
        result = await engine.recognize(EngineRequest(
          samples: window.samples,
          language: config.language,
          threads: config.threads,
          decoder: config.decoder,
          prompt: prompt,
        ));
      } on Object catch (error) {
        if (generation != _generation) continue;
        final cancelled = error is SpeechCoreException && error.status == SpeechCoreStatus.cancelled;
        if (!cancelled) {
          _update(_diag.copyWith(
            windowsFailed: _diag.windowsFailed + 1,
            engineState: engine.state,
          ));
          _log(RecognitionLogLevel.error, '识别窗口失败', {
            '窗口': window.id,
            '错误': error.toString(),
          });
        }
        _advanceProcessed(window.mediaEnd);
        continue;
      }
      if (generation != _generation) continue;
      stopwatch.stop();
      final gated = _gate.apply(
        window,
        result.segments,
        pinnedLanguage: config.autoDetectLanguage ? null : config.language,
      );
      if (gated.accepted.isNotEmpty) {
        _assembler.addWindow(window, gated.accepted);
        _emitTranscript();
        _context = contextTail(gated.text, config.contextMaxCharacters);
        _contextValidUntil = window.mediaEnd + const Duration(milliseconds: 1500);
      } else {
        _context = null;
      }
      final recognizedThrough = gated.accepted.isEmpty
          ? _diag.recognizedThrough
          : Duration(milliseconds: gated.accepted.last.endMs);
      _advanceProcessed(window.mediaEnd);
      _update(_diag.copyWith(
        windowsRecognized: _diag.windowsRecognized + 1,
        segmentsAccepted: _diag.segmentsAccepted + gated.accepted.length,
        segmentsDropped: _diag.segmentsDropped + gated.dropped.length + result.droppedSegments,
        recognizedThrough: recognizedThrough > _diag.recognizedThrough
            ? recognizedThrough
            : _diag.recognizedThrough,
        lastWindowDuration: window.duration,
        lastInference: result.inference,
        lastRealtimeFactor: window.duration.inMicroseconds == 0
            ? 0
            : result.inference.inMicroseconds / window.duration.inMicroseconds,
        engineState: engine.state,
        engineBackend: result.backend,
      ));
      final base = window.mediaStart.inMilliseconds;
      _log(RecognitionLogLevel.debug, '识别窗口完成', {
        '窗口': window.id,
        '窗口起点': base,
        '窗口终点': window.mediaEnd.inMilliseconds,
        '切分原因': window.cutReason,
        '推理耗时': result.inference,
        '排队加推理': stopwatch.elapsed,
        '接受': gated.accepted.length,
        '丢弃': gated.dropped
            .map((d) => '${d.reason}@${base + d.segment.startMs}-'
                '${base + d.segment.endMs}ms:${d.segment.text}')
            .toList(),
        '输出': gated.accepted.map((s) => s.text).toList(),
        '后端': result.backend.actual,
      });
    }
  }

  void _advanceProcessed(Duration through) {
    if (through > _diag.processedThrough) {
      _update(_diag.copyWith(processedThrough: through));
    }
  }

  void _checkQueue() {
    final shouldPause = _pending.length >= config.maxPendingWindows;
    if (shouldPause && !_diag.sourcePausedForQueue) {
      _update(_diag.copyWith(sourcePausedForQueue: true));
      _applySourceRun();
    } else if (!shouldPause && _diag.sourcePausedForQueue) {
      _update(_diag.copyWith(sourcePausedForQueue: false));
      _applySourceRun();
    }
  }

  void _checkLead() {
    final leadPause = config.leadPause;
    if (leadPause == null) return;
    final lead = _diag.decodedThrough - _diag.playbackPosition;
    if (!_diag.sourcePausedForLead && lead > leadPause) {
      _update(_diag.copyWith(sourcePausedForLead: true));
      _applySourceRun();
    } else if (_diag.sourcePausedForLead && lead < config.leadResume) {
      _update(_diag.copyWith(sourcePausedForLead: false));
      _applySourceRun();
    }
  }

  void _applySourceRun() {
    if (!_sourceShouldRun || _sawLast) return;
    final paused = _diag.sourcePausedForLead || _diag.sourcePausedForQueue;
    final generation = _generation;
    final action = paused ? source.pause() : source.start();
    action.catchError((Object error) {
      if (generation != _generation) return;
      _log(RecognitionLogLevel.warning, '解码器暂停/恢复失败', {'错误': error.toString()});
    });
    _update(_diag.copyWith(
      state: paused ? RecognitionState.paused : RecognitionState.running,
    ));
  }

  void _emitTranscript() {
    if (!_transcripts.isClosed) _transcripts.add(_assembler.transcript);
  }

  void _update(RecognitionDiagnostics value) {
    _diag = value;
    if (!_diagnostics.isClosed) _diagnostics.add(value);
  }

  void _log(RecognitionLogLevel level, String message, [Map<String, Object?> details = const {}]) {
    onLog?.call(RecognitionLogEvent(level, message, details));
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('session disposed');
  }
}
