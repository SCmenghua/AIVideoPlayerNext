import 'dart:async';
import 'dart:io';

import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../domain/audio/audio_models.dart';
import '../../domain/audio/audio_window_planner.dart';
import '../../domain/audio/recognition_queue.dart';
import '../../domain/audio/recognition_media_source.dart';
import '../../domain/player/player_service.dart';
import '../../domain/speech/speech_models.dart';
import 'recognition_media_cache_worker.dart';

enum RecognitionPrefetchMode {
  /// Continuously transcribe from the current cursor to media EOF.
  fullMedia,

  /// Keep a bounded recognition lead around the player clock.
  boundedAhead,
}

class RecognitionController {
  RecognitionController({
    required PlayerService player,
    required AudioDecoder decoder,
    required WindowRecognitionService recognizer,
    AudioWindowPlanner? planner,
    RecognitionQueue? queue,
    DiagnosticLogService? logs,
    RecognitionMediaCacheWorker Function({
      required RecognitionMediaSource source,
      required String sessionId,
    })? mediaCacheWorkerFactory,
    bool Function()? isIosPlatform,
    bool Function()? iosStreamingProxyEnabled,
    RecognitionPrefetchMode prefetchMode = RecognitionPrefetchMode.fullMedia,
    this.lowWatermark = const Duration(seconds: 20),
    this.highWatermark = const Duration(seconds: 45),
    this.seekPriorityThreshold = const Duration(seconds: 10),
    this.seekPriorityContext = const Duration(seconds: 2),
    Duration? priorityLead,
  })  : _player = player,
        _decoder = decoder,
        _recognizer = recognizer,
        _planner = planner ?? AudioWindowPlanner(),
        _queue = queue ?? RecognitionQueue(),
        _logs = logs,
        _mediaCacheWorkerFactory =
            mediaCacheWorkerFactory ?? _defaultMediaCacheWorker,
        _isIosPlatform = isIosPlatform ?? _defaultIsIosPlatform,
        _iosStreamingProxyEnabled =
            iosStreamingProxyEnabled ?? _defaultIosStreamingProxyEnabled,
        _prefetchMode = prefetchMode,
        seekPriorityLead = priorityLead ?? highWatermark {
    if (lowWatermark.isNegative || highWatermark <= lowWatermark) {
      throw ArgumentError('watermarks must be non-negative and increasing');
    }
    if (seekPriorityThreshold <= Duration.zero ||
        seekPriorityContext.isNegative ||
        seekPriorityLead <= Duration.zero) {
      throw ArgumentError('seek priority durations must be valid');
    }
    _playerSubscription = player.snapshots.listen(_onPlayback);
    _decoderChunkSubscription = decoder.chunks.listen(_onChunk);
    _decoderStatusSubscription = decoder.statuses.listen(_onDecoderStatus);
    final statusProvider = recognizer is WindowRecognitionStatusProvider
        ? recognizer as WindowRecognitionStatusProvider
        : null;
    if (statusProvider != null) {
      _setDiagnostic(_diagnostic.copyWith(recognizer: statusProvider.status));
      _recognizerStatusSubscription = statusProvider.statuses.listen(
        (status) => _setDiagnostic(_diagnostic.copyWith(recognizer: status)),
      );
    }
  }

  final PlayerService _player;
  final AudioDecoder _decoder;
  final WindowRecognitionService _recognizer;
  final AudioWindowPlanner _planner;
  final RecognitionQueue _queue;
  final DiagnosticLogService? _logs;
  final RecognitionMediaCacheWorker Function({
    required RecognitionMediaSource source,
    required String sessionId,
  }) _mediaCacheWorkerFactory;
  final bool Function() _isIosPlatform;

  /// Experimental: when true, iOS network recognition first streams through
  /// the loopback proxy and falls back to the full cache on any failure.
  final bool Function() _iosStreamingProxyEnabled;
  RecognitionPrefetchMode _prefetchMode;
  final Duration lowWatermark;
  final Duration highWatermark;
  final Duration seekPriorityThreshold;
  final Duration seekPriorityContext;
  final Duration seekPriorityLead;
  final StreamController<RecognitionEvent> _events =
      StreamController<RecognitionEvent>.broadcast();
  final StreamController<RecognitionDiagnostics> _diagnostics =
      StreamController<RecognitionDiagnostics>.broadcast();
  StreamSubscription<PlaybackSnapshot>? _playerSubscription;
  StreamSubscription<AudioChunk>? _decoderChunkSubscription;
  StreamSubscription<AudioDecoderStatus>? _decoderStatusSubscription;
  StreamSubscription<WindowRecognitionStatus>? _recognizerStatusSubscription;
  StreamSubscription<RecognitionMediaCacheSnapshot>? _mediaCacheSubscription;
  StreamSubscription<RecognitionMediaCacheRequestEvent>?
      _mediaCacheRequestSubscription;
  RecognitionDiagnostics _diagnostic = const RecognitionDiagnostics.idle();
  Future<void> _pump = Future<void>.value();
  Future<void> _recognizerReady = Future<void>.value();
  bool _queueDrainScheduled = false;
  Future<void> _operations = Future<void>.value();
  String? _sessionId;
  MediaSource? _source;
  bool _disposed = false;
  // This flag describes the recognition decoder, not the player clock.
  bool _playing = false;
  bool _backpressurePaused = false;
  bool _watermarkPaused = false;
  RecognitionWindow? _deferredWindow;
  int _generation = 0;
  int _workEpoch = 0;
  DateTime? _lastDecoderLogAt;
  AudioDecoderState? _lastLoggedDecoderState;
  int _lastLoggedDecoderChunks = -1;
  bool _hasLoggedAudioChunk = false;
  bool _hasLoggedRecognition = false;

  /// True while the current iOS session reads through the experimental
  /// streaming proxy; a decoder-open failure then retries via the full cache.
  bool _iosProxySourceActive = false;
  DateTime? _decoderOpenRequestedAt;
  DateTime? _prioritySeekRequestedAt;
  Duration? _prioritySeekStart;
  bool _priorityFirstPcmPending = false;
  bool _priorityFirstWindowPending = false;
  bool _priorityFirstSubtitlePending = false;
  RecognitionMediaCacheWorker? _mediaCacheWorker;
  DateTime? _lastMediaCacheLogAt;

  /// Per-session budget of proxy request events recorded at info level. The
  /// default log level is "info", so promoting the first requests of each
  /// session keeps the streaming handshake visible in user exports while
  /// steady-state traffic stays at debug.
  int _mediaCacheRequestInfoBudget = 0;
  static const _mediaCacheRequestInfoBudgetReset = 12;
  Duration? _lastPlaybackPosition;
  Duration _sequentialStart = Duration.zero;
  final _RecognitionCoverage _coverage = _RecognitionCoverage();
  _RecognitionTraversal _traversal = _RecognitionTraversal.sequential;
  Duration? _priorityEnd;
  Duration? _gapEnd;
  Duration? _resumeAfterGap;
  bool _cursorTransitionPending = false;
  bool _acceptChunks = true;

  Stream<RecognitionEvent> get events => _events.stream;
  Stream<RecognitionDiagnostics> get diagnostics => _diagnostics.stream;
  RecognitionDiagnostics get diagnostic => _diagnostic;
  RecognitionPrefetchMode get prefetchMode => _prefetchMode;

  /// Invalidates the current recognition session before the player opens a
  /// media source. This is required even when the URI is unchanged: reopening
  /// the same file is a new transcript session, not a seek in the old one.
  void prepareForMediaOpen() {
    if (_disposed) return;
    ++_generation;
    ++_workEpoch;
    _playing = false;
    _acceptChunks = false;
    _backpressurePaused = false;
    _watermarkPaused = false;
    _cursorTransitionPending = false;
    _traversal = _RecognitionTraversal.sequential;
    _priorityEnd = null;
    _gapEnd = null;
    _resumeAfterGap = null;
    _coverage.clear();
    _sequentialStart = Duration.zero;
    _lastPlaybackPosition = Duration.zero;
    _source = null;
    _sessionId = null;
    _queue.clear();
    _deferredWindow = null;
    _planner.reset(sessionId: 'media-pending');
    _requestRecognizerStop();
    _setDiagnostic(const RecognitionDiagnostics.idle());
  }

  static RecognitionMediaCacheWorker _defaultMediaCacheWorker({
    required RecognitionMediaSource source,
    required String sessionId,
  }) =>
      RecognitionMediaCacheWorker(source: source, sessionId: sessionId);

  static bool _defaultIsIosPlatform() => Platform.isIOS;

  static bool _defaultIosStreamingProxyEnabled() => false;

  Future<void> seek(Duration position) async {
    if (_disposed || _sessionId == null) return;
    final elapsed = Stopwatch()..start();
    final previousPosition = _lastPlaybackPosition;
    await _player.seek(position);
    _considerSeekPriority(position, previousPosition: previousPosition);
    _lastPlaybackPosition = position;
    _logs?.debug('识别音频', 'seek 交给播放器完成', {
      '目标位置': position,
      'UI 调用耗时': elapsed.elapsed,
      '会话 ID': _sessionId,
    });
  }

  Future<void> setPrefetchMode(RecognitionPrefetchMode mode) async {
    if (_disposed || _prefetchMode == mode) return;
    final previous = _prefetchMode;
    _prefetchMode = mode;
    _logs?.info('识别音频', '识别预取策略已切换', {
      '从': previous.name,
      '到': mode.name,
      '当前位置优先': '已启用',
    });
    if (mode == RecognitionPrefetchMode.boundedAhead) {
      _pauseDecoderForWatermark();
      return;
    }
    if (!_watermarkPaused ||
        !_playing ||
        _backpressurePaused ||
        _cursorTransitionPending) {
      _watermarkPaused = false;
      return;
    }
    _watermarkPaused = false;
    final generation = _generation;
    await _enqueue(() async {
      if (_disposed ||
          !_playing ||
          generation != _generation ||
          _backpressurePaused ||
          _cursorTransitionPending) {
        return;
      }
      await _decoder.start();
      _setDiagnostic(_diagnostic.copyWith(
        decoder: _decoder.status,
        queueDepth: _queue.depth,
        lastReason: 'full_media_prefetch_resumed',
      ));
    });
  }

  Future<void> stop() async {
    if (_disposed) return;
    await _enqueue(() async {
      ++_generation;
      ++_workEpoch;
      _playing = false;
      _backpressurePaused = false;
      _watermarkPaused = false;
      _acceptChunks = false;
      _cursorTransitionPending = false;
      _traversal = _RecognitionTraversal.sequential;
      _priorityEnd = null;
      _gapEnd = null;
      _resumeAfterGap = null;
      _coverage.clear();
      _planner.reset(sessionId: _sessionId ?? 'stopped');
      _queue.clear();
      _deferredWindow = null;
      await _decoder.stop();
      await _releaseMediaCacheWorker();
      await _recognizer.stop();
      _setDiagnostic(_diagnostic.copyWith(
        decoder: _decoder.status,
        queueDepth: _queue.depth,
        lastReason: 'stopped',
      ));
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    ++_workEpoch;
    await _playerSubscription?.cancel();
    await _decoderChunkSubscription?.cancel();
    await _decoderStatusSubscription?.cancel();
    await _recognizerStatusSubscription?.cancel();
    await _releaseMediaCacheWorker();
    await _operations;
    await _decoder.stop();
    await _recognizer.stop();
    _queue.close();
    await _decoder.dispose();
    await _recognizer.dispose();
    await _events.close();
    await _diagnostics.close();
  }

  void _onPlayback(PlaybackSnapshot snapshot) {
    if (_disposed) return;
    _setDiagnostic(_diagnostic.copyWith(playbackPosition: snapshot.position));
    _resumeDecoderAfterWatermarkIfNeeded();
    unawaited(_applyPlayback(snapshot).catchError((Object error, StackTrace _) {
      _logs?.error('识别音频', '播放生命周期操作失败', {
        '错误类型': error.runtimeType,
      });
    }));
  }

  Future<void> _applyPlayback(PlaybackSnapshot snapshot) async {
    final source = snapshot.source;
    if (source == null) return;
    final sourceChanged = !_sameSource(source, _source) || _sessionId == null;

    if (sourceChanged) {
      await _newSession(
        source,
        position: snapshot.position,
      );
      return;
    }
    _lastPlaybackPosition = snapshot.position;
    // Playback pause and short seeks only change the authoritative player
    // clock. A long forward jump into uncovered media schedules a separate
    // background cursor move; it never blocks this player update.
  }

  void _considerSeekPriority(
    Duration position, {
    Duration? previousPosition,
  }) {
    final previous = previousPosition ?? _lastPlaybackPosition;
    if (previous == null || _cursorTransitionPending || !_playing) return;
    final jump = position - previous;
    if (jump < seekPriorityThreshold || _coverage.contains(position)) return;
    final sequentialThrough = _coverage.contiguousThrough(_sequentialStart);
    if (position - sequentialThrough < seekPriorityThreshold) return;

    final start = _earlierOf(
      position > seekPriorityContext
          ? position - seekPriorityContext
          : Duration.zero,
      position,
    );
    final end = position + seekPriorityLead;
    final worker = _mediaCacheWorker;
    final nextWorkEpoch = _workEpoch + 1;
    worker?.prioritizePlaybackRange(
      playbackPosition: position,
      context: seekPriorityContext,
      lead: seekPriorityLead,
      epoch: nextWorkEpoch,
    );
    _prioritySeekRequestedAt = DateTime.now();
    _prioritySeekStart = start;
    _priorityFirstPcmPending = true;
    _priorityFirstWindowPending = true;
    _priorityFirstSubtitlePending = true;
    _logs?.debug('识别媒体缓存', '识别网络目标区域已提升优先级', {
      '会话 ID': _sessionId,
      '工作序号': nextWorkEpoch,
      '播放器目标位置': position,
      '识别起点': start,
      '目标领先': seekPriorityLead,
    });
    _scheduleCursorMove(
      position: start,
      traversal: _RecognitionTraversal.priority,
      priorityEnd: end,
      gapEnd: start > sequentialThrough ? start : null,
      resumeAfterGap: end,
      reason: 'forward_seek_priority',
    );
  }

  bool _sameSource(MediaSource left, MediaSource? right) =>
      right != null &&
      left.uri == right.uri &&
      left.kind == right.kind &&
      left.browserSessionId == right.browserSessionId;

  void _scheduleCursorMove({
    required Duration position,
    required _RecognitionTraversal traversal,
    required Duration? priorityEnd,
    required Duration? gapEnd,
    required Duration? resumeAfterGap,
    required String reason,
  }) {
    if (_disposed || !_playing || _cursorTransitionPending) return;
    _cursorTransitionPending = true;
    _acceptChunks = false;
    final generation = _generation;
    final workEpoch = ++_workEpoch;
    _queue.clear();
    _deferredWindow = null;
    _requestRecognizerStop();
    unawaited(_enqueue(() async {
      if (_disposed || !_playing || generation != _generation) return;
      try {
        _planner.reset(
          sessionId: _sessionId ?? 'cursor-transition',
          preserveWindowIndex: true,
        );
        final decoderSeek = _decoder.seek(position);
        if (traversal == _RecognitionTraversal.priority) {
          _mediaCacheWorker?.activatePlaybackPriority(epoch: workEpoch);
        }
        await decoderSeek;
        if (_disposed || !_playing || generation != _generation) return;
        _traversal = traversal;
        _priorityEnd = priorityEnd;
        _gapEnd = gapEnd;
        _resumeAfterGap = resumeAfterGap;
        _acceptChunks = true;
        _backpressurePaused = false;
        _watermarkPaused = false;
        await _decoder.start();
        _setDiagnostic(_diagnostic.copyWith(
          decoder: _decoder.status,
          queueDepth: _queue.depth,
          lastReason: reason,
        ));
        _logs?.info('识别音频', '后台识别游标已切换', {
          '会话 ID': _sessionId,
          '工作序号': workEpoch,
          '原因': reason,
          '目标位置': position,
          '遍历阶段': traversal.name,
          '优先结束': priorityEnd,
          '缺口结束': gapEnd,
          '后续恢复': resumeAfterGap,
          '目标优先至 decoder 就绪耗时': traversal == _RecognitionTraversal.priority
              ? _elapsedSince(_prioritySeekRequestedAt)
              : null,
        });
      } on Object catch (error) {
        if (generation == _generation && !_disposed) {
          _acceptChunks = true;
          _logs?.error('识别音频', '后台识别游标切换失败', {
            '原因': reason,
            '错误类型': error.runtimeType,
          });
        }
      } finally {
        if (generation == _generation && !_disposed) {
          _cursorTransitionPending = false;
        }
      }
    }));
  }

  void _advanceTraversalAfter(Duration mediaEnd) {
    if (_cursorTransitionPending || !_playing) return;
    switch (_traversal) {
      case _RecognitionTraversal.sequential:
        return;
      case _RecognitionTraversal.priority:
        final priorityEnd = _priorityEnd;
        if (priorityEnd == null || mediaEnd < priorityEnd) return;
        final gapEnd = _gapEnd;
        if (gapEnd != null) {
          final gapStart = _coverage.contiguousThrough(_sequentialStart);
          if (gapStart < gapEnd) {
            _scheduleCursorMove(
              position: gapStart,
              traversal: _RecognitionTraversal.gapFill,
              priorityEnd: null,
              gapEnd: gapEnd,
              resumeAfterGap: _resumeAfterGap,
              reason: 'forward_seek_fill_gap',
            );
            return;
          }
        }
        _resumeSequentialAfterPriority();
      case _RecognitionTraversal.gapFill:
        final gapEnd = _gapEnd;
        if (gapEnd == null || mediaEnd < gapEnd) return;
        _resumeSequentialAfterPriority();
    }
  }

  void _resumeSequentialAfterPriority() {
    final resumeAt = _resumeAfterGap;
    if (resumeAt == null) {
      _traversal = _RecognitionTraversal.sequential;
      return;
    }
    _scheduleCursorMove(
      position: resumeAt,
      traversal: _RecognitionTraversal.sequential,
      priorityEnd: null,
      gapEnd: null,
      resumeAfterGap: null,
      reason: 'forward_seek_resume_sequential',
    );
  }

  Future<void> _newSession(
    MediaSource source, {
    required Duration position,
  }) async {
    final generation = ++_generation;
    _playing = true;
    _acceptChunks = true;
    _backpressurePaused = false;
    _watermarkPaused = false;
    _cursorTransitionPending = false;
    _traversal = _RecognitionTraversal.sequential;
    _priorityEnd = null;
    _gapEnd = null;
    _resumeAfterGap = null;
    _coverage.clear();
    _sequentialStart = position;
    _lastPlaybackPosition = position;
    _source = source;
    _sessionId = 'audio-${DateTime.now().microsecondsSinceEpoch}';
    final sessionId = _sessionId!;
    _planner.reset(sessionId: sessionId);
    _queue.clear();
    _deferredWindow = null;
    _lastDecoderLogAt = null;
    _lastLoggedDecoderState = null;
    _lastLoggedDecoderChunks = -1;
    _hasLoggedAudioChunk = false;
    _hasLoggedRecognition = false;
    _iosProxySourceActive = false;
    _decoderOpenRequestedAt = DateTime.now();
    _setDiagnostic(RecognitionDiagnostics(
      sessionId: sessionId,
      decoder: _decoder.status,
      queueDepth: 0,
      lastWindow: null,
      windowsRecognized: 0,
      windowsSkipped: 0,
      windowsFailed: 0,
      lastReason: null,
      playbackPosition: position,
      lastInference: Duration.zero,
      lastRealtimeFactor: 0,
      lastResultCount: 0,
      recognitionLag: Duration.zero,
      decodedThrough: Duration.zero,
      processedThrough: Duration.zero,
      recognizedThrough: Duration.zero,
      recognizer: _recognizer is WindowRecognitionStatusProvider
          ? (_recognizer as WindowRecognitionStatusProvider).status
          : _diagnostic.recognizer,
    ));
    _logs?.info('识别音频', '请求打开识别解码器', {
      '会话 ID': sessionId,
      '起始位置': position,
      '媒体地址': source.uri,
    });
    // Cancellation is requested immediately, but waiting for a native model to
    // leave its current inference must not hold a newer seek or media change.
    // New windows wait for this barrier before calling the shared model again.
    _requestRecognizerStop();
    Object? openError;
    try {
      final decoderSource = await _prepareDecoderSource(
        source: source,
        sessionId: sessionId,
        generation: generation,
      );
      if (generation != _generation || _disposed) return;
      await _decoder.open(AudioDecoderRequest(
        sessionId: sessionId,
        source: decoderSource,
        start: position,
      ));
    } on Object catch (error) {
      openError = error;
    }
    if (generation != _generation || _disposed) return;
    if (openError != null && _iosProxySourceActive) {
      // The experimental iOS streaming proxy could not be opened by
      // AVFoundation; one retry through the full cache keeps the session
      // alive instead of dropping recognition for the whole media.
      _iosProxySourceActive = false;
      _logs?.warning('识别音频', 'iOS 流式识别解码打开失败，回退完整缓存', {
        '会话 ID': sessionId,
        '错误类型': openError.runtimeType,
        '错误信息': openError.toString(),
      });
      try {
        final fallbackSource = await _prepareIosFullCacheSource(
          source: source,
          sessionId: sessionId,
          generation: generation,
        );
        if (generation != _generation || _disposed) return;
        await _decoder.open(AudioDecoderRequest(
          sessionId: sessionId,
          source: fallbackSource,
          start: position,
        ));
        openError = null;
      } on Object catch (error) {
        openError = error;
      }
      if (generation != _generation || _disposed) return;
    }
    if (openError != null) {
      _playing = false;
      _setDiagnostic(_diagnostic.copyWith(
        decoder: _decoder.status,
        queueDepth: _queue.depth,
        lastReason: 'decoder_open_failed',
      ));
      _logs?.error('识别音频', '音频解码打开失败', {
        '错误类型': openError.runtimeType,
        '错误信息': openError.toString(),
      });
      return;
    }
    if (generation != _generation || _disposed) return;
    _logs?.info('识别音频', '识别解码器打开完成', {
      '会话 ID': sessionId,
      '耗时': _elapsedSince(_decoderOpenRequestedAt),
      '采样率': _decoder.status.sampleRate,
      '声道': _decoder.status.channels,
    });
    _setDiagnostic(RecognitionDiagnostics(
      sessionId: sessionId,
      decoder: _decoder.status,
      queueDepth: 0,
      lastWindow: null,
      windowsRecognized: 0,
      windowsSkipped: 0,
      windowsFailed: 0,
      lastReason: null,
      playbackPosition: position,
      lastInference: Duration.zero,
      lastRealtimeFactor: 0,
      lastResultCount: 0,
      recognitionLag: Duration.zero,
      decodedThrough: Duration.zero,
      processedThrough: Duration.zero,
      recognizedThrough: Duration.zero,
      recognizer: _recognizer is WindowRecognitionStatusProvider
          ? (_recognizer as WindowRecognitionStatusProvider).status
          : _diagnostic.recognizer,
      mediaPreparationState: _diagnostic.mediaPreparationState,
      mediaPreparationMessage: _diagnostic.mediaPreparationMessage,
    ));
    await _decoder.start();
  }

  Future<MediaSource> _prepareDecoderSource({
    required MediaSource source,
    required String sessionId,
    required int generation,
  }) async {
    await _releaseMediaCacheWorker();
    final recognitionSource = RecognitionMediaSource.fromPlayerSource(source);
    if (!recognitionSource.isNetwork) return source;

    if (_isIosPlatform()) {
      if (_iosStreamingProxyEnabled()) {
        final proxySource = await _tryIosStreamingProxySource(
          source: source,
          recognitionSource: recognitionSource,
          sessionId: sessionId,
          generation: generation,
        );
        if (proxySource != null) return proxySource;
      }
      return _prepareIosFullCacheSource(
        source: source,
        sessionId: sessionId,
        generation: generation,
      );
    }

    final worker = _attachMediaCacheWorker(
      recognitionSource: recognitionSource,
      sessionId: sessionId,
    );
    final snapshot = await worker.startProxy();
    if (generation != _generation ||
        _disposed ||
        !identical(worker, _mediaCacheWorker)) {
      return source;
    }
    final proxyUri = snapshot.proxyUri;
    if (proxyUri == null) {
      throw StateError(snapshot.message ?? '识别媒体代理未能启动。');
    }
    _logs?.info('识别媒体缓存', '识别网络媒体代理已启动', {
      '会话 ID': sessionId,
      '原始地址': source.uri,
      '代理地址': proxyUri,
      '缓存上限字节': worker.policy.maxBytes,
      '分段上限': worker.policy.maxSegments,
    });
    return MediaSource(
      uri: proxyUri,
      title: source.title,
      kind: source.kind,
      originPage: source.originPage,
      browserSessionId: source.browserSessionId,
    );
  }

  RecognitionMediaCacheWorker _attachMediaCacheWorker({
    required RecognitionMediaSource recognitionSource,
    required String sessionId,
  }) {
    final worker = _mediaCacheWorkerFactory(
      source: recognitionSource,
      sessionId: sessionId,
    );
    _mediaCacheWorker = worker;
    _lastMediaCacheLogAt = null;
    _mediaCacheRequestInfoBudget = _mediaCacheRequestInfoBudgetReset;
    _mediaCacheSubscription = worker.snapshots.listen(_onMediaCacheSnapshot);
    _mediaCacheRequestSubscription = worker.requestEvents.listen(
      _onMediaCacheRequestEvent,
    );
    return worker;
  }

  /// Experimental iOS streaming path. Returns null when the proxy fails to
  /// start so the caller falls back to the full cache; returns [source] only
  /// for a session that was already superseded.
  Future<MediaSource?> _tryIosStreamingProxySource({
    required MediaSource source,
    required RecognitionMediaSource recognitionSource,
    required String sessionId,
    required int generation,
  }) async {
    final worker = _attachMediaCacheWorker(
      recognitionSource: recognitionSource,
      sessionId: sessionId,
    );
    worker.proxyPathCarriesExtension = true;
    final snapshot = await worker.startProxy();
    if (generation != _generation ||
        _disposed ||
        !identical(worker, _mediaCacheWorker)) {
      return source;
    }
    final proxyUri = snapshot.proxyUri;
    if (snapshot.state == RecognitionMediaCacheState.failed ||
        proxyUri == null) {
      _logs?.warning('识别媒体缓存', 'iOS 流式识别代理启动失败，回退完整缓存', {
        '会话 ID': sessionId,
        '原始地址': source.uri,
        '说明': snapshot.message,
      });
      await _releaseMediaCacheWorker();
      return null;
    }
    _iosProxySourceActive = true;
    final decoderUri = RecognitionMediaCacheWorker.customSchemeProxyUri(proxyUri);
    _logs?.info('识别媒体缓存', 'iOS 流式识别代理已启动（实验）', {
      '会话 ID': sessionId,
      '原始地址': source.uri,
      '代理地址': proxyUri,
      '解码地址': decoderUri,
      '缓存上限字节': worker.policy.maxBytes,
    });
    return MediaSource(
      uri: decoderUri,
      title: source.title,
      kind: source.kind,
      originPage: source.originPage,
      browserSessionId: source.browserSessionId,
    );
  }

  Future<MediaSource> _prepareIosFullCacheSource({
    required MediaSource source,
    required String sessionId,
    required int generation,
  }) async {
    await _releaseMediaCacheWorker();
    final worker = _attachMediaCacheWorker(
      recognitionSource: RecognitionMediaSource.fromPlayerSource(source),
      sessionId: sessionId,
    );
    _logs?.info('识别媒体缓存', 'iOS 网络媒体开始完整缓存', {
      '会话 ID': sessionId,
      '原始地址': source.uri,
      '缓存上限字节': worker.policy.maxBytes,
    });
    final snapshot = await worker.prepare();
    if (generation != _generation ||
        _disposed ||
        !identical(worker, _mediaCacheWorker)) {
      return source;
    }
    if (snapshot.state != RecognitionMediaCacheState.complete ||
        snapshot.path == null) {
      throw StateError(snapshot.message ?? 'iOS 识别媒体缓存未完成。');
    }
    final localUri = Uri.file(snapshot.path!);
    _logs?.info('识别媒体缓存', 'iOS 识别媒体缓存完成', {
      '会话 ID': sessionId,
      '本地地址': localUri,
      '媒体总字节': snapshot.contentLength,
      '顺序下载回退': snapshot.usedSequentialDownload,
    });
    return MediaSource(
      uri: localUri,
      title: source.title,
      kind: source.kind,
      originPage: source.originPage,
      browserSessionId: source.browserSessionId,
    );
  }

  Future<void> _releaseMediaCacheWorker() async {
    final requestSubscription = _mediaCacheRequestSubscription;
    _mediaCacheRequestSubscription = null;
    await requestSubscription?.cancel();
    final subscription = _mediaCacheSubscription;
    _mediaCacheSubscription = null;
    await subscription?.cancel();
    final worker = _mediaCacheWorker;
    _mediaCacheWorker = null;
    _lastMediaCacheLogAt = null;
    await worker?.dispose();
  }

  void _onMediaCacheRequestEvent(RecognitionMediaCacheRequestEvent event) {
    final details = <String, Object?>{
      '会话 ID': _sessionId,
      '请求 ID': event.requestId,
      'Range': event.range,
      '实际上游 Range': event.upstreamRange,
      '请求角色': event.requestRole,
      '优先序号': event.priorityEpoch,
      '播放器目标位置': event.playbackPosition,
      '传输字节': event.bytesTransferred,
      '耗时': event.elapsed,
      '首字节耗时': event.timeToFirstByte,
      '平均字节每秒': event.averageBytesPerSecond,
      '响应状态': event.responseStatusCode,
      '响应 Content-Range': event.responseContentRange,
      '说明': event.message,
    };
    switch (event.kind) {
      case RecognitionMediaCacheRequestEventKind.priorityIntent:
        _logs?.debug('识别媒体缓存', '网络目标区域优先意图已登记', details);
        return;
      case RecognitionMediaCacheRequestEventKind.cacheHit:
        _logRequestEvent('代理 Range 命中识别缓存', details);
        return;
      case RecognitionMediaCacheRequestEventKind.upstreamStarted:
        _logRequestEvent('上游 Range 请求已开始', details);
        return;
      case RecognitionMediaCacheRequestEventKind.upstreamResponse:
        _logRequestEvent('上游实际 Range 已响应', details);
        return;
      case RecognitionMediaCacheRequestEventKind.upstreamFirstByte:
        _logRequestEvent('上游 Range 首字节已到达', details);
        return;
      case RecognitionMediaCacheRequestEventKind.upstreamCompleted:
        _logRequestEvent('上游 Range 请求已完成', details);
        return;
      case RecognitionMediaCacheRequestEventKind.upstreamCancelled:
        _logs?.debug('识别媒体缓存', '旧上游 Range 已为新位置取消', details);
        return;
      case RecognitionMediaCacheRequestEventKind.upstreamFailed:
        _logs?.error('识别媒体缓存', '上游 Range 请求失败', details);
        return;
    }
  }

  /// Records proxy request traffic at info level until the per-session
  /// budget is spent, then falls back to debug so steady-state streaming
  /// does not flood the default "info" log.
  void _logRequestEvent(String action, Map<String, Object?> details) {
    if (_mediaCacheRequestInfoBudget > 0) {
      _mediaCacheRequestInfoBudget--;
      _logs?.info('识别媒体缓存', action, details);
    } else {
      _logs?.debug('识别媒体缓存', action, details);
    }
  }

  void _onMediaCacheSnapshot(RecognitionMediaCacheSnapshot snapshot) {
    if (snapshot.sessionId == _sessionId) {
      _setDiagnostic(_diagnostic.copyWith(
        mediaPreparationState: snapshot.state.name,
        mediaPreparationMessage: snapshot.message,
      ));
    }
    final now = DateTime.now();
    final shouldLog =
        snapshot.state != RecognitionMediaCacheState.downloading ||
            _lastMediaCacheLogAt == null ||
            now.difference(_lastMediaCacheLogAt!) >= const Duration(seconds: 1);
    if (!shouldLog) return;
    _lastMediaCacheLogAt = now;
    _logs?.debug('识别媒体缓存', '识别缓存状态', {
      '会话 ID': snapshot.sessionId,
      '状态': snapshot.state.name,
      '模式': snapshot.mode.name,
      '连续可用字节': snapshot.cursor.downloadedThrough,
      '已缓存字节': snapshot.cursor.downloadedBytes,
      '缓存段数': snapshot.cursor.segments.length,
      '媒体总字节': snapshot.contentLength,
      '顺序下载回退': snapshot.usedSequentialDownload,
      '说明': snapshot.message,
    });
  }

  void _requestRecognizerStop() {
    final previous = _recognizerReady;
    _recognizerReady = previous.then((_) => _recognizer.stop()).catchError(
      (Object error, StackTrace _) {
        _logs?.error('识别音频', '请求停止旧识别会话失败', {
          '错误类型': error.runtimeType,
        });
      },
    );
  }

  void _onDecoderStatus(AudioDecoderStatus status) {
    _setDiagnostic(_diagnostic.copyWith(decoder: status));
    final now = DateTime.now();
    final stateChanged = status.state != _lastLoggedDecoderState;
    final periodic = _lastDecoderLogAt == null ||
        now.difference(_lastDecoderLogAt!) >= const Duration(seconds: 1);
    final chunkMilestone = status.emittedChunks >= 0 &&
        status.emittedChunks ~/ 100 > _lastLoggedDecoderChunks ~/ 100;
    if (stateChanged ||
        periodic ||
        chunkMilestone ||
        status.state == AudioDecoderState.error) {
      _lastDecoderLogAt = now;
      _lastLoggedDecoderState = status.state;
      _lastLoggedDecoderChunks = status.emittedChunks;
      _logs?.debug('识别音频', '解码器状态汇总', {
        '状态': status.state.name,
        '采样率': status.sampleRate,
        '声道': status.channels,
        '已输出块数': status.emittedChunks,
        '说明': status.message,
      });
    }
    if (status.state == AudioDecoderState.error) {
      _logs?.error('识别音频', '音频解码失败', {'原因': status.message});
    }
  }

  void _onChunk(AudioChunk chunk) {
    if (_disposed || !_acceptChunks || chunk.sessionId != _sessionId) return;
    if (!_playing && !chunk.isLast) return;
    if (!chunk.isLast) {
      _setDiagnostic(_diagnostic.copyWith(
        decodedThrough: _laterOf(
          _diagnostic.decodedThrough,
          chunk.mediaStart + chunk.duration,
        ),
      ));
    }
    final now = DateTime.now();
    final periodic = _lastDecoderLogAt == null ||
        now.difference(_lastDecoderLogAt!) >= const Duration(seconds: 1);
    if (!_hasLoggedAudioChunk || periodic || chunk.isLast) {
      final isFirstChunk = !_hasLoggedAudioChunk;
      _hasLoggedAudioChunk = true;
      _lastDecoderLogAt = now;
      _logs?.debug('识别音频', '解码音频进度', {
        '媒体起点': chunk.mediaStart,
        '持续时间': chunk.duration,
        '采样率': chunk.sampleRate,
        '声道': chunk.channels,
        '样本帧数': chunk.sampleCount,
        '尾部标记': chunk.isLast,
        // Windows uses this marker both at real EOF and after an asynchronous
        // pause request, so the player must not infer media EOF from it.
        '说明': chunk.isLast ? '解码 worker 本轮结束' : '高频音频块已合并记录',
      });
      if (isFirstChunk) {
        _logs?.info('识别音频', '首个 PCM 已到达', {
          '会话 ID': chunk.sessionId,
          '打开至首 PCM 耗时': _elapsedSince(_decoderOpenRequestedAt),
          '媒体起点': chunk.mediaStart,
        });
      }
      if (_priorityFirstPcmPending && _isInPriorityRegion(chunk.mediaStart)) {
        _priorityFirstPcmPending = false;
        _logs?.info('识别音频', '目标位置首个 PCM 已到达', {
          '会话 ID': chunk.sessionId,
          '识别起点': _prioritySeekStart,
          '首 PCM 媒体起点': chunk.mediaStart,
          'seek 至首 PCM 耗时': _elapsedSince(_prioritySeekRequestedAt),
        });
      }
      if (chunk.isLast) {
        _logs?.debug('识别音频', 'decoder worker 已退出', {
          '会话 ID': chunk.sessionId,
          '状态': _decoder.status.state.name,
        });
      }
    }
    for (final result in _planner.add(chunk)) {
      final window = result.window;
      if (window == null) {
        _recordSkip(
          result.skipReason!.name,
          mediaStart: result.mediaStart,
          mediaEnd: result.mediaEnd,
        );
        continue;
      }
      _logs?.debug('识别音频', '生成识别窗口', {
        '窗口 ID': window.windowId,
        '媒体起点': window.mediaStart,
        '媒体终点': window.mediaEnd,
        '持续时间': window.duration,
        '样本数': window.samples.length,
        '源音频块数': window.sourceChunkCount,
      });
      if (_priorityFirstWindowPending &&
          _isInPriorityRegion(window.mediaStart)) {
        _priorityFirstWindowPending = false;
        _logs?.info('识别音频', '目标位置首个识别窗口已生成', {
          '窗口 ID': window.windowId,
          '媒体起点': window.mediaStart,
          'seek 至首窗口耗时': _elapsedSince(_prioritySeekRequestedAt),
        });
      }
      if (!_queue.offer(window)) {
        if (_deferredWindow == null) {
          _deferredWindow = window;
          _logs?.debug('识别音频', '窗口等待背压恢复', {
            '窗口 ID': window.windowId,
            '媒体起点': window.mediaStart,
            '媒体终点': window.mediaEnd,
            '队列深度': _queue.depth,
          });
        } else {
          _recordSkip(
            WindowSkipReason.queueFull.name,
            mediaStart: window.mediaStart,
            mediaEnd: window.mediaEnd,
          );
        }
        _pauseDecoderForBackpressure();
        continue;
      }
      _setDiagnostic(_diagnostic.copyWith(queueDepth: _queue.depth));
      _scheduleQueueDrain();
      if (_queue.isFull) _pauseDecoderForBackpressure();
    }
  }

  void _pauseDecoderForBackpressure() {
    if (_backpressurePaused ||
        _cursorTransitionPending ||
        !_playing ||
        _disposed) {
      return;
    }
    _backpressurePaused = true;
    final generation = _generation;
    unawaited(_enqueue(() async {
      if (_disposed || !_playing || generation != _generation) return;
      try {
        await _decoder.pause();
        _setDiagnostic(_diagnostic.copyWith(
          decoder: _decoder.status,
          queueDepth: _queue.depth,
          lastReason: 'recognition_lag',
        ));
      } catch (error) {
        _backpressurePaused = false;
        _setDiagnostic(_diagnostic.copyWith(
          lastReason: 'backpressure_pause_failed',
        ));
        _logs?.error('识别音频', '背压暂停解码失败', {'错误类型': error.runtimeType});
      }
    }));
  }

  void _resumeDecoderAfterBackpressure() {
    _offerDeferredWindow();
    if (!_backpressurePaused ||
        _cursorTransitionPending ||
        !_playing ||
        _disposed ||
        _queue.isFull) {
      return;
    }
    if (_usesWatermarks && _isAtHighWatermark) {
      // The decoder has already been asked to stop for queue backpressure.
      // Keep that stop in effect, but hand ownership to the watermark state so
      // advancing player time can restart it at the low watermark.
      _backpressurePaused = false;
      _watermarkPaused = true;
      _setDiagnostic(_diagnostic.copyWith(
        decoder: _decoder.status,
        queueDepth: _queue.depth,
        lastReason: 'high_watermark',
      ));
      _logs?.debug('识别音频', '背压恢复转为连续预取高水位暂停', {
        '处理至': _diagnostic.processedThrough,
        '播放位置': _diagnostic.playbackPosition,
        '领先量': _recognitionLead,
        '高水位': highWatermark,
      });
      return;
    }
    final generation = _generation;
    unawaited(_enqueue(() async {
      if (_disposed ||
          !_playing ||
          generation != _generation ||
          _queue.isFull) {
        return;
      }
      try {
        await _decoder.start();
        _backpressurePaused = false;
        _setDiagnostic(_diagnostic.copyWith(
          decoder: _decoder.status,
          queueDepth: _queue.depth,
          lastReason: 'backpressure_recovered',
        ));
      } catch (error) {
        _setDiagnostic(_diagnostic.copyWith(
          lastReason: 'backpressure_resume_failed',
        ));
        _logs?.error('识别音频', '背压恢复解码失败', {'错误类型': error.runtimeType});
      }
    }));
  }

  bool get _usesWatermarks =>
      _prefetchMode == RecognitionPrefetchMode.boundedAhead;

  bool get _isAtHighWatermark =>
      _usesWatermarks && _recognitionLead >= highWatermark;

  bool get _isBelowLowWatermark =>
      _usesWatermarks && _recognitionLead <= lowWatermark;

  Duration get _recognitionLead {
    final lead = _diagnostic.processedThrough - _diagnostic.playbackPosition;
    return lead.isNegative ? Duration.zero : lead;
  }

  void _pauseDecoderForWatermark() {
    if (!_usesWatermarks ||
        _watermarkPaused ||
        _backpressurePaused ||
        _cursorTransitionPending ||
        !_playing ||
        _disposed) {
      return;
    }
    _watermarkPaused = true;
    final generation = _generation;
    unawaited(_enqueue(() async {
      if (_disposed ||
          !_playing ||
          generation != _generation ||
          !_isAtHighWatermark) {
        _watermarkPaused = false;
        return;
      }
      try {
        await _decoder.pause();
        _setDiagnostic(_diagnostic.copyWith(
          decoder: _decoder.status,
          queueDepth: _queue.depth,
          lastReason: 'high_watermark',
        ));
        _logs?.debug('识别音频', '达到连续预取高水位，暂停解码', {
          '处理至': _diagnostic.processedThrough,
          '播放位置': _diagnostic.playbackPosition,
          '领先量': _recognitionLead,
          '高水位': highWatermark,
        });
      } catch (error) {
        _watermarkPaused = false;
        _logs?.error('识别音频', '高水位暂停解码失败', {
          '错误类型': error.runtimeType,
        });
      }
    }));
  }

  void _resumeDecoderAfterWatermarkIfNeeded() {
    if (!_usesWatermarks ||
        !_watermarkPaused ||
        _backpressurePaused ||
        _cursorTransitionPending ||
        !_playing ||
        _disposed ||
        _queue.isFull ||
        !_isBelowLowWatermark) {
      return;
    }
    final generation = _generation;
    unawaited(_enqueue(() async {
      if (_disposed ||
          !_watermarkPaused ||
          _backpressurePaused ||
          _cursorTransitionPending ||
          !_playing ||
          generation != _generation ||
          !_isBelowLowWatermark) {
        return;
      }
      try {
        await _decoder.start();
        _watermarkPaused = false;
        _setDiagnostic(_diagnostic.copyWith(
          decoder: _decoder.status,
          queueDepth: _queue.depth,
          lastReason: 'low_watermark_recovered',
        ));
        _logs?.debug('识别音频', '低于连续预取低水位，恢复解码', {
          '处理至': _diagnostic.processedThrough,
          '播放位置': _diagnostic.playbackPosition,
          '领先量': _recognitionLead,
          '低水位': lowWatermark,
        });
      } catch (error) {
        _logs?.error('识别音频', '低水位恢复解码失败', {
          '错误类型': error.runtimeType,
        });
      }
    }));
  }

  void _offerDeferredWindow() {
    final deferred = _deferredWindow;
    if (deferred == null || _disposed || !_queue.offer(deferred)) return;
    _deferredWindow = null;
    _setDiagnostic(_diagnostic.copyWith(queueDepth: _queue.depth));
    _logs?.debug('识别音频', '等待窗口已重新入队', {
      '窗口 ID': deferred.windowId,
      '媒体起点': deferred.mediaStart,
      '媒体终点': deferred.mediaEnd,
      '队列深度': _queue.depth,
    });
    _scheduleQueueDrain();
  }

  void _scheduleQueueDrain() {
    if (_queueDrainScheduled || _disposed) return;
    _queueDrainScheduled = true;
    _pump = _pump.then<void>((_) async {
      try {
        await _drainQueue();
      } catch (error) {
        _logs?.error('识别音频', '识别队列处理失败', {
          '错误类型': error.runtimeType,
        });
      } finally {
        _queueDrainScheduled = false;
        if (!_disposed && _queue.waiting.isNotEmpty) _scheduleQueueDrain();
      }
    });
  }

  Future<void> _drainQueue() async {
    while (!_disposed) {
      final window = _queue.takeNow();
      if (window == null) return;
      await _processWindow(window);
    }
  }

  Future<void> _processWindow(RecognitionWindow window) async {
    final generation = _generation;
    final workEpoch = _workEpoch;
    try {
      if (_disposed || window.sessionId != _sessionId) return;
      await _recognizerReady;
      if (generation != _generation ||
          workEpoch != _workEpoch ||
          _disposed ||
          window.sessionId != _sessionId) {
        return;
      }
      final result = await _recognizer.recognize(window);
      if (generation != _generation ||
          workEpoch != _workEpoch ||
          _disposed ||
          window.sessionId != _sessionId) {
        return;
      }
      if (!result.succeeded) {
        _recordCoverage(window.mediaStart, window.mediaEnd);
        _setDiagnostic(_diagnostic.copyWith(
          windowsFailed: _diagnostic.windowsFailed + 1,
          lastReason: result.error,
          lastWindow: window,
          lastInference: result.inference,
          lastRealtimeFactor: result.realtimeFactor,
          lastResultCount: result.events.length,
          recognitionLag: _recognitionLag(window),
          processedThrough:
              _laterOf(_diagnostic.processedThrough, window.mediaEnd),
        ));
        _logs?.error('识别音频', '窗口识别失败', {
          '原因': result.error,
          '窗口时长': window.duration,
          '推理耗时': result.inference,
        });
        _pauseDecoderForWatermark();
        return;
      }
      var recognizedThrough = _diagnostic.recognizedThrough;
      for (final event in result.events) {
        if (event.sessionId == _sessionId &&
            event.kind == RecognitionKind.finalResult &&
            event.text.trim().isNotEmpty) {
          recognizedThrough = _laterOf(recognizedThrough, event.end);
          final isFirstRecognition = !_hasLoggedRecognition;
          _hasLoggedRecognition = true;
          _logs?.debug('识别音频', '字幕输出', {
            '窗口 ID': window.windowId,
            '片段起点': event.start,
            '片段终点': event.end,
            '文字': event.text,
            '语言': event.language,
          });
          _events.add(event);
          if (isFirstRecognition) {
            _logs?.info('识别音频', '首条字幕已识别', {
              '会话 ID': event.sessionId,
              '打开至首条字幕耗时': _elapsedSince(_decoderOpenRequestedAt),
              '媒体起点': event.start,
            });
          }
          if (_priorityFirstSubtitlePending &&
              _isInPriorityRegion(event.start)) {
            _priorityFirstSubtitlePending = false;
            _logs?.info('识别音频', '目标位置首条字幕已识别', {
              '会话 ID': event.sessionId,
              '片段起点': event.start,
              'seek 至首目标字幕耗时': _elapsedSince(_prioritySeekRequestedAt),
            });
          }
        }
      }
      _recordCoverage(window.mediaStart, window.mediaEnd);
      _setDiagnostic(_diagnostic.copyWith(
        queueDepth: _queue.depth,
        lastWindow: window,
        windowsRecognized: _diagnostic.windowsRecognized + 1,
        lastInference: result.inference,
        lastRealtimeFactor: result.realtimeFactor,
        lastResultCount: result.events.length,
        recognitionLag: _recognitionLag(window),
        processedThrough: _laterOf(
          _diagnostic.processedThrough,
          window.mediaEnd,
        ),
        recognizedThrough: recognizedThrough,
        clearReason: true,
      ));
      _pauseDecoderForWatermark();
    } catch (error) {
      if (generation != _generation ||
          workEpoch != _workEpoch ||
          _disposed ||
          window.sessionId != _sessionId) {
        return;
      }
      _recordCoverage(window.mediaStart, window.mediaEnd);
      _setDiagnostic(_diagnostic.copyWith(
        windowsFailed: _diagnostic.windowsFailed + 1,
        lastReason: 'recognition_error',
        lastWindow: window,
        recognitionLag: _recognitionLag(window),
        processedThrough: _laterOf(
          _diagnostic.processedThrough,
          window.mediaEnd,
        ),
      ));
      _logs?.error('识别音频', '窗口识别失败', {'错误类型': error.runtimeType});
      _pauseDecoderForWatermark();
    } finally {
      _queue.complete(window);
      _setDiagnostic(_diagnostic.copyWith(queueDepth: _queue.depth));
      _resumeDecoderAfterBackpressure();
    }
  }

  void _recordSkip(
    String reason, {
    Duration? mediaStart,
    Duration? mediaEnd,
  }) {
    if (mediaStart != null &&
        mediaEnd != null &&
        reason != WindowSkipReason.queueFull.name) {
      _recordCoverage(mediaStart, mediaEnd);
    }
    _setDiagnostic(_diagnostic.copyWith(
      windowsSkipped: _diagnostic.windowsSkipped + 1,
      lastReason: reason,
      processedThrough: mediaEnd == null
          ? _diagnostic.processedThrough
          : _laterOf(_diagnostic.processedThrough, mediaEnd),
    ));
    _logs?.debug('识别音频', '窗口已跳过', {
      '原因': reason,
      '媒体起点': mediaStart,
      '媒体终点': mediaEnd,
      '队列深度': _queue.depth,
    });
    _pauseDecoderForWatermark();
  }

  Duration _recognitionLag(RecognitionWindow window) {
    final position = _diagnostic.playbackPosition;
    final lag = position - window.mediaEnd;
    return lag.isNegative ? Duration.zero : lag;
  }

  Duration _laterOf(Duration left, Duration right) =>
      left >= right ? left : right;

  Duration _earlierOf(Duration left, Duration right) =>
      left <= right ? left : right;

  bool _isInPriorityRegion(Duration position) {
    final start = _prioritySeekStart;
    return start != null && position >= start;
  }

  void _recordCoverage(Duration start, Duration end) {
    _coverage.add(start, end);
    _advanceTraversalAfter(end);
  }

  Duration? _elapsedSince(DateTime? startedAt) =>
      startedAt == null ? null : DateTime.now().difference(startedAt);

  void _setDiagnostic(RecognitionDiagnostics value) {
    if (_disposed) return;
    _diagnostic = value;
    _diagnostics.add(value);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    final safe = next.catchError((error) {
      _logs?.error('识别音频', '生命周期操作失败', {
        '错误类型': error.runtimeType,
      });
    });
    _operations = safe;
    return safe;
  }
}

enum _RecognitionTraversal { sequential, priority, gapFill }

class _RecognitionCoverage {
  final List<({Duration start, Duration end})> _ranges = [];

  void clear() => _ranges.clear();

  bool contains(Duration position) =>
      _ranges.any((range) => range.start <= position && position < range.end);

  Duration contiguousThrough(Duration start) {
    var cursor = start;
    for (final range in _ranges) {
      if (range.end <= cursor) continue;
      if (range.start > cursor) break;
      cursor = range.end;
    }
    return cursor;
  }

  void add(Duration start, Duration end) {
    if (end <= start) return;
    var mergedStart = start;
    var mergedEnd = end;
    final next = <({Duration start, Duration end})>[];
    for (final range in _ranges) {
      if (range.end < mergedStart || range.start > mergedEnd) {
        next.add(range);
        continue;
      }
      if (range.start < mergedStart) mergedStart = range.start;
      if (range.end > mergedEnd) mergedEnd = range.end;
    }
    next.add((start: mergedStart, end: mergedEnd));
    next.sort((left, right) => left.start.compareTo(right.start));
    _ranges
      ..clear()
      ..addAll(next);
  }
}
