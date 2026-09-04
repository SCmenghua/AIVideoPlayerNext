import 'dart:async';
import 'dart:io';

import '../../domain/audio/audio_models.dart';
import '../../domain/speech/recognition_window_context.dart';
import '../../domain/speech/speech_models.dart';
import '../../domain/speech/speech_core_status.dart';
import '../../domain/speech/whisper_model_catalog.dart';
import '../speech/whisper_cpp_speech_service.dart';
import '../../core/diagnostics/diagnostic_log_service.dart';

class UnavailableAudioDecoder implements AudioDecoder {
  UnavailableAudioDecoder({required this.message});

  final String message;
  final StreamController<AudioDecoderStatus> _statuses =
      StreamController<AudioDecoderStatus>.broadcast();
  final StreamController<AudioChunk> _chunks =
      StreamController<AudioChunk>.broadcast();
  AudioDecoderStatus _status = const AudioDecoderStatus.idle();
  bool _disposed = false;

  @override
  AudioDecoderStatus get status => _status;

  @override
  Stream<AudioDecoderStatus> get statuses => _statuses.stream;

  @override
  Stream<AudioChunk> get chunks => _chunks.stream;

  @override
  Future<void> open(AudioDecoderRequest request) async {
    if (_disposed) return;
    _status = AudioDecoderStatus(
      state: AudioDecoderState.error,
      sessionId: request.sessionId,
      message: message,
    );
    _statuses.add(_status);
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _statuses.close();
    await _chunks.close();
  }
}

/// Adapter for the model-resident Phase 6 worker.
class WhisperWindowRecognitionService
    implements
        WindowRecognitionService,
        WindowRecognitionStatusProvider,
        WindowRecognitionLanguageController,
        WindowRecognitionModelController {
  WhisperWindowRecognitionService({
    required this.libraryPath,
    required String modelPath,
    this.logs,
    this.threads = 16,
    this.language = 'ja',
    this.requestedBackend = WhisperRequestedBackend.vulkan,
  }) : _modelPath = modelPath;

  final String libraryPath;

  /// Currently selected GGML model file. Mutable so the user can switch
  /// models in settings; the new model is loaded lazily.
  String _modelPath;
  String get modelPath => _modelPath;
  final int threads;
  final DiagnosticLogService? logs;
  final WhisperRequestedBackend requestedBackend;
  final StreamController<WindowRecognitionStatus> _statuses =
      StreamController<WindowRecognitionStatus>.broadcast();
  WhisperCppPersistentRecognitionWorker? _worker;
  Future<void> _modelSwap = Future<void>.value();
  late WindowRecognitionStatus _status = WindowRecognitionStatus.notLoaded(
    modelName: File(_modelPath).uri.pathSegments.last,
    backendStatus: WhisperBackendStatus.initial(requested: requestedBackend),
  );
  bool _disposed = false;

  /// What each window carries over from the one before it. This service
  /// outlives the media it is pointed at, so the context has to be keyed on
  /// the recognition session rather than on this object's lifetime.
  final RecognitionWindowContext _context = RecognitionWindowContext();

  WhisperCppPersistentRecognitionWorker _ensureWorker() =>
      _worker ??= WhisperCppPersistentRecognitionWorker(
        libraryPath: libraryPath,
        modelPath: _modelPath,
        threads: threads,
        requestedBackend: requestedBackend,
      );

  /// Whisper language hint applied to every window. Mutable so the user can
  /// change the recognition source language in settings without rebuilding
  /// the model; `auto` keeps Whisper's language detection.
  String language;

  @override
  WindowRecognitionStatus get status => _status;

  @override
  void setLanguage(String value) => language = value;

  /// Swaps the Whisper model. Before the first [prepare] this only records
  /// the path; afterwards the new model is loaded in the background and the
  /// old worker is disposed once the replacement is ready.
  @override
  void setModel(String modelPath) {
    if (_disposed || modelPath == _modelPath) return;
    _modelPath = modelPath;
    final worker = _worker;
    if (worker == null) {
      _setStatus(WindowRecognitionStatus.notLoaded(
        modelName: File(modelPath).uri.pathSegments.last,
        backendStatus: WhisperBackendStatus.initial(
          requested: requestedBackend,
        ),
      ));
      return;
    }
    _modelSwap = _modelSwap.then((_) => _swapWorker(modelPath));
  }

  Future<void> _swapWorker(String modelPath) async {
    if (_disposed || _modelPath != modelPath || _worker == null) return;
    final modelName = File(modelPath).uri.pathSegments.last;
    _setStatus(_status.copyWith(
      state: WindowRecognitionState.loading,
      modelName: modelName,
    ));
    logs?.info('识别音频', 'Whisper 开始切换模型', {'模型': modelName});
    final previous = _worker!;
    final next = WhisperCppPersistentRecognitionWorker(
      libraryPath: libraryPath,
      modelPath: modelPath,
      threads: threads,
      requestedBackend: requestedBackend,
    );
    try {
      await next.warmUp();
    } on Object catch (error) {
      await next.dispose();
      _setStatus(_status.copyWith(
        state: WindowRecognitionState.ready,
        message: '模型切换失败，继续使用当前模型：$error',
      ));
      logs?.error('识别音频', 'Whisper 模型切换失败', {
        '模型': modelName,
        '错误类型': error.runtimeType,
      });
      return;
    }
    _worker = next;
    await previous.dispose();
    _setStatus(_status.copyWith(
      state: WindowRecognitionState.ready,
      message: null,
      modelName: modelName,
      backendStatus: next.backendStatus,
    ));
    logs?.info('识别音频', 'Whisper 模型切换完成', {'模型': modelName});
    _logBackendStatus(next.backendStatus);
  }

  @override
  Stream<WindowRecognitionStatus> get statuses => _statuses.stream;

  Future<void> prepare() async {
    if (_disposed || _status.state == WindowRecognitionState.ready) return;
    _setStatus(_status.copyWith(state: WindowRecognitionState.loading));
    logs?.info('识别音频', 'Whisper 开始加载模型', {'模型': _status.modelName});
    try {
      await _ensureWorker().warmUp();
      final worker = _worker!;
      _setStatus(_status.copyWith(
        state: WindowRecognitionState.ready,
        backendStatus: worker.backendStatus,
      ));
      logs?.info('识别音频', 'Whisper 模型加载成功', {'模型': _status.modelName});
      _logBackendStatus(worker.backendStatus);
    } on Object catch (error) {
      _setStatus(_status.copyWith(
        state: WindowRecognitionState.error,
        message: error.toString(),
      ));
      logs?.error('识别音频', 'Whisper 模型加载失败', {
        '模型': _status.modelName,
        '错误类型': error.runtimeType,
        '错误信息': error,
      });
    }
  }

  @override
  Future<WindowRecognitionResult> recognize(RecognitionWindow window) async {
    if (_disposed) {
      return WindowRecognitionResult(
        window: window,
        events: const [],
        error: 'disposed',
      );
    }
    final stopwatch = Stopwatch()..start();
    List<RecognitionEvent> events = const [];
    _setStatus(_status.copyWith(
      state: WindowRecognitionState.recognizing,
      lastWindow: window,
    ));
    logs?.debug('识别音频', 'Whisper 开始识别', {'窗口 ID': window.windowId});
    logs?.debug('识别音频', 'Whisper 输入窗口', {
      '窗口 ID': window.windowId,
      '媒体起点': window.mediaStart,
      '媒体终点': window.mediaEnd,
      '持续时间': window.duration,
      '采样率': window.sampleRate,
      '输入样本数': window.samples.length,
      '源音频块数': window.sourceChunkCount,
      '模型': _status.modelName,
    });
    try {
      events = await _ensureWorker().recognize(
        request: RecognitionRequest(
          sessionId: window.sessionId,
          from: window.mediaStart,
          language: language,
          sourceWindowId: window.windowId,
          initialPrompt: _context.promptFor(window),
        ),
        samples: window.samples,
      );
      _setStatus(
          _status.copyWith(backendStatus: _ensureWorker().backendStatus));
      // With `auto` the detected language is per-window; there is no fixed
      // expectation to validate events against.
      final expectedLanguage = language == 'auto' ? null : language;
      final filteredEvents = <RecognitionEvent>[];
      for (final event in events) {
        final text = event.text.trim();
        final normalizedText = _normalizeForHallucinationCheck(text);
        String? discardReason;
        if (text.isEmpty) {
          discardReason = 'emptyText';
        } else if (expectedLanguage != null && event.language != expectedLanguage) {
          discardReason = 'unexpectedLanguage';
        } else if (_knownHallucinations.contains(normalizedText)) {
          discardReason = 'knownHallucination';
        } else if (event.repetition != null &&
            event.repetition! > _repetitionCeiling) {
          discardReason = 'repetitionLoop';
        } else if (event.avgLogprob != null &&
            event.avgLogprob! < _logprobFloor) {
          discardReason = 'lowConfidence';
        }
        if (discardReason != null) {
          logs?.debug('识别音频', 'Whisper 候选已丢弃', {
            '窗口 ID': window.windowId,
            '片段起点': event.start,
            '片段终点': event.end,
            '文字': text,
            '语言': event.language,
            '置信度': event.confidence,
            '平均对数概率': event.avgLogprob,
            '无语音概率': event.noSpeechProbability,
            '重复率': event.repetition,
            '原因': discardReason,
          });
          continue;
        }
        filteredEvents.add(RecognitionEvent(
          sessionId: event.sessionId,
          segmentId: event.segmentId,
          start: event.start,
          end: event.end,
          text: text,
          language: event.language,
          kind: event.kind,
          source: event.source,
          confidence: event.confidence,
          avgLogprob: event.avgLogprob,
          noSpeechProbability: event.noSpeechProbability,
          repetition: event.repetition,
          sourceWindowId: event.sourceWindowId,
          sourceSegmentIndex: event.sourceSegmentIndex,
        ));
      }
      if (_context.repeatsPrevious(window, filteredEvents)) {
        logs?.debug('识别音频', 'Whisper 窗口重复上一窗口，已丢弃', {
          '窗口 ID': window.windowId,
          '文字': filteredEvents.map((event) => event.text).join(' | '),
        });
        filteredEvents.clear();
        _context.reset();
      }
      events = List<RecognitionEvent>.unmodifiable(
          _boundWindowEdges(window, filteredEvents));
      _context.remember(window, events);
      stopwatch.stop();
      _setStatus(_status.copyWith(
        state: WindowRecognitionState.ready,
        lastWindow: window,
        lastResultCount: events.length,
        lastOutput: events.map((event) => event.text).toList(growable: false),
        lastInference: stopwatch.elapsed,
      ));
      logs?.debug('识别音频', 'Whisper 输出窗口', {
        '窗口 ID': window.windowId,
        '结果数': events.length,
        '输出文字': events.map((event) => event.text).join(' | '),
        '推理耗时': stopwatch.elapsed,
        '实时倍率':
            stopwatch.elapsed.inMicroseconds / window.duration.inMicroseconds,
        '语言参数': language,
        '请求后端': _ensureWorker().backendStatus.requestedLabel,
        '实际后端': _worker?.backendStatus.actualLabel ?? '未知',
        'GPU 已启用': _worker?.backendStatus.gpuEnabled ?? false,
        '设备': (_worker?.backendStatus.deviceName.isEmpty ?? true)
            ? '未报告'
            : _worker!.backendStatus.deviceName,
        '回退原因': _worker?.backendStatus.fallbackLabel ?? 'unknown',
      });
      if (events.isEmpty) {
        logs?.debug('识别音频', 'Whisper 输出为空', {'窗口 ID': window.windowId});
      }
      return WindowRecognitionResult(
        window: window,
        events: events,
        inference: stopwatch.elapsed,
        // Empty output is a normal result for silence or filtered candidates.
        // Native/FFI failures are reported through the catch branch below.
        error: null,
      );
    } on Object catch (error) {
      stopwatch.stop();
      _setStatus(_status.copyWith(
        state: WindowRecognitionState.error,
        message: error.toString(),
        lastWindow: window,
        lastInference: stopwatch.elapsed,
      ));
      logs?.error('识别音频', 'Whisper 识别失败', {
        '窗口 ID': window.windowId,
        '错误类型': error.runtimeType,
        '错误信息': error,
        '耗时': stopwatch.elapsed,
      });
      return WindowRecognitionResult(
        window: window,
        events: events,
        inference: stopwatch.elapsed,
        error: error.toString(),
      );
    }
  }

  @override
  Future<void> stop() {
    // The next window will not continue the last one: this is called on seek
    // and when the media is replaced.
    _context.reset();
    return _worker?.stop() ?? Future<void>.value();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _worker?.dispose();
    _setStatus(_status.copyWith(state: WindowRecognitionState.stopped));
    await _statuses.close();
  }

  void _setStatus(WindowRecognitionStatus value) {
    if (_disposed && value.state != WindowRecognitionState.stopped) return;
    _status = value;
    if (!_statuses.isClosed) _statuses.add(value);
  }

  void _logBackendStatus(WhisperBackendStatus status) {
    logs?.info('识别音频', 'Whisper 后端状态', {
      '请求后端': status.requestedLabel,
      '实际后端': status.actualLabel,
      'GPU 已启用': status.gpuEnabled,
      '设备': status.deviceName.isEmpty ? '未报告' : status.deviceName,
      '回退原因': status.fallbackLabel,
      '后端说明': status.message,
    });
  }

  /// Whisper partitions a window into spans that touch end to end, so the
  /// boundaries *between* segments follow the speech - measured against
  /// long-form decoding of the same audio they land within 0.3s - while the
  /// first segment's start and the last one's end are pinned to the window
  /// edges and absorb whatever silence or music sits there.
  ///
  /// Only the trailing edge is corrected, and only by shortening it. The
  /// leading edge was tried too and had to be abandoned: pulling a first
  /// segment's start towards its end moved a line that genuinely ran 3.9
  /// seconds (a drawn-out shout) 1.9 seconds late, because speech does exceed
  /// any per-character estimate. Shortening the tail has no such failure -
  /// there is nothing after the last segment for the extra time to belong to.
  /// The case this exists for is a window holding one short line: the sample
  /// had a 2.1-second line reported as filling all nine seconds.
  List<RecognitionEvent> _boundWindowEdges(
    RecognitionWindow window,
    List<RecognitionEvent> events,
  ) {
    if (events.isEmpty) return events;
    final bounded = <RecognitionEvent>[];
    for (var index = 0; index < events.length; index++) {
      final event = events[index];
      var start = event.start;
      var end = event.end;
      if (index == events.length - 1 &&
          end - start >= window.duration * _windowShare) {
        final spoken = _spokenDuration(event.text);
        if (end - start > spoken) end = start + spoken;
      }
      if (end <= start) {
        start = event.start;
        end = event.end;
      }
      bounded.add(RecognitionEvent(
        sessionId: event.sessionId,
        segmentId: event.segmentId,
        start: start,
        end: end,
        text: event.text,
        language: event.language,
        kind: event.kind,
        source: event.source,
        confidence: event.confidence,
        avgLogprob: event.avgLogprob,
        noSpeechProbability: event.noSpeechProbability,
        repetition: event.repetition,
        sourceWindowId: event.sourceWindowId,
        sourceSegmentIndex: event.sourceSegmentIndex,
      ));
    }
    return bounded;
  }

  /// Share of the window a last segment has to cover before its end is treated
  /// as the window's edge rather than the speech's. A last segment that ends
  /// well inside the window ended where the decoder heard it end.
  static const _windowShare = 0.6;

  /// Upper bound on how long [text] takes to say, deliberately far above
  /// conversational pace.
  ///
  /// The rate has to survive drawn-out delivery, because a line that runs long
  /// is speech, not silence: the sample's opening exclamation runs 7.19
  /// seconds for ten full-width characters, or 0.72s each, against the roughly
  /// 0.14s each that ordinary Japanese takes. At 0.75s the estimate leaves
  /// that line untouched and still catches what this exists for - a window
  /// whose only line was six characters long reported as filling all nine
  /// seconds. Latin script is counted at a fifth of the rate. The result is
  /// never below [_minimumSubtitle], which keeps a one-word answer on screen
  /// long enough to read.
  static Duration _spokenDuration(String text) {
    var micros = 0;
    for (final rune in text.runes) {
      final wide = rune >= 0x1100 &&
          (rune <= 0x115F ||
              (rune >= 0x2E80 && rune <= 0xA4CF) ||
              (rune >= 0xAC00 && rune <= 0xD7A3) ||
              (rune >= 0xF900 && rune <= 0xFAFF) ||
              (rune >= 0xFE30 && rune <= 0xFE6F) ||
              (rune >= 0xFF00 && rune <= 0xFF60) ||
              (rune >= 0xFFE0 && rune <= 0xFFE6) ||
              (rune >= 0x20000 && rune <= 0x3FFFD));
      micros += wide ? 750000 : 150000;
    }
    final estimate = Duration(microseconds: micros);
    return estimate < _minimumSubtitle ? _minimumSubtitle : estimate;
  }

  static const _minimumSubtitle = Duration(milliseconds: 1200);

  /// Whisper's own decoder abandons a candidate below roughly this mean token
  /// log probability; segments that reach the caller under it are the ones its
  /// temperature fallback ran out of retries on.
  static const _logprobFloor = -1.0;

  /// A repeated 4-gram share above this is a decoder loop, not speech.
  static const _repetitionCeiling = 0.5;

  static const _knownHallucinations = <String>{
    'お疲れ様でした',
    'ご視聴ありがとうございました',
  };

  static String _normalizeForHallucinationCheck(String text) =>
      RecognitionWindowContext.normalizeForComparison(text);
}

/// iOS adapter which wraps the shared persistent FFI worker around a weight
/// installed in the app sandbox.
///
/// iOS builds carry no model: the user installs the ones they want, so this
/// starts with nothing loaded and reports that plainly rather than failing
/// like a broken install would.
class IosWhisperWindowRecognitionService
    implements
        WindowRecognitionService,
        WindowRecognitionStatusProvider,
        WindowRecognitionLanguageController,
        WindowRecognitionModelController {
  IosWhisperWindowRecognitionService({
    this.logs,
    this.threads = 4,
    this.language = 'ja',
    this.requestedBackend = WhisperRequestedBackend.metal,
    String? modelPath,
  }) : _modelPath = modelPath;

  final DiagnosticLogService? logs;
  final int threads;
  String language;
  final WhisperRequestedBackend requestedBackend;
  String? _modelPath;
  final StreamController<WindowRecognitionStatus> _statuses =
      StreamController<WindowRecognitionStatus>.broadcast();
  late WindowRecognitionStatus _status = WindowRecognitionStatus.notLoaded(
    modelName: _modelPath == null
        ? '未安装'
        : File(_modelPath!).uri.pathSegments.last,
    backendStatus: WhisperBackendStatus.initial(
      requested: requestedBackend,
    ),
  );
  WhisperWindowRecognitionService? _delegate;
  bool _disposed = false;

  @override
  WindowRecognitionStatus get status => _delegate?.status ?? _status;

  @override
  void setLanguage(String value) {
    language = value;
    final delegate = _delegate;
    if (delegate != null) delegate.setLanguage(value);
  }

  @override
  Stream<WindowRecognitionStatus> get statuses => _statuses.stream;

  /// Points the recognizer at a weight the user has installed. Loading happens
  /// on the next [prepare]; a model that arrives while the app is running is
  /// picked up by calling this and then preparing again.
  @override
  void setModel(String modelPath) {
    if (_disposed || modelPath == _modelPath) return;
    _modelPath = modelPath;
    final previous = _delegate;
    _delegate = null;
    _setStatus(WindowRecognitionStatus.notLoaded(
      modelName: File(modelPath).uri.pathSegments.last,
      backendStatus: WhisperBackendStatus.initial(requested: requestedBackend),
    ));
    if (previous != null) unawaited(previous.dispose());
  }

  Future<void> prepare() async {
    if (_disposed || _delegate != null) return;
    _setStatus(_status.copyWith(state: WindowRecognitionState.loading));
    try {
      final path = _modelPath;
      if (path == null || !File(path).existsSync()) {
        throw const WhisperModelMissingException();
      }
      final delegate = WhisperWindowRecognitionService(
        libraryPath: '@process',
        modelPath: path,
        logs: logs,
        threads: threads,
        language: language,
        requestedBackend: requestedBackend,
      );
      _delegate = delegate;
      delegate.statuses.listen(_setStatus);
      await delegate.prepare();
      _setStatus(delegate.status);
    } on Object catch (error) {
      _setStatus(_status.copyWith(
        state: WindowRecognitionState.unavailable,
        message: error.toString(),
      ));
      if (error is WhisperModelMissingException) {
        logs?.info('识别音频', 'iOS 尚未安装识别模型', {'说明': error.toString()});
      } else {
        logs?.error('识别音频', 'iOS Whisper 模型不可用', {
          '错误类型': error.runtimeType,
          '错误信息': error,
        });
      }
    }
  }

  @override
  Future<WindowRecognitionResult> recognize(RecognitionWindow window) {
    final delegate = _delegate;
    if (delegate == null) {
      return Future.value(WindowRecognitionResult(
        window: window,
        events: const [],
        error: _status.message ?? 'iOS Whisper 尚未加载。',
      ));
    }
    return delegate.recognize(window);
  }

  @override
  Future<void> stop() => _delegate?.stop() ?? Future<void>.value();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _delegate?.dispose();
    await _statuses.close();
  }

  void _setStatus(WindowRecognitionStatus value) {
    if (_disposed) return;
    _status = value;
    if (!_statuses.isClosed) _statuses.add(value);
  }
}
