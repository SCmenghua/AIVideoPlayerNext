import 'dart:async';

import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../domain/audio/audio_models.dart';
import '../../domain/audio/audio_window_planner.dart';
import '../../domain/audio/recognition_queue.dart';
import '../../domain/player/player_service.dart';
import '../../domain/speech/speech_models.dart';

class RecognitionController {
  RecognitionController({
    required PlayerService player,
    required AudioDecoder decoder,
    required WindowRecognitionService recognizer,
    AudioWindowPlanner? planner,
    RecognitionQueue? queue,
    DiagnosticLogService? logs,
  })  : _player = player,
        _decoder = decoder,
        _recognizer = recognizer,
        _planner = planner ?? AudioWindowPlanner(),
        _queue = queue ?? RecognitionQueue(),
        _logs = logs {
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
  final StreamController<RecognitionEvent> _events =
      StreamController<RecognitionEvent>.broadcast();
  final StreamController<RecognitionDiagnostics> _diagnostics =
      StreamController<RecognitionDiagnostics>.broadcast();
  StreamSubscription<PlaybackSnapshot>? _playerSubscription;
  StreamSubscription<AudioChunk>? _decoderChunkSubscription;
  StreamSubscription<AudioDecoderStatus>? _decoderStatusSubscription;
  StreamSubscription<WindowRecognitionStatus>? _recognizerStatusSubscription;
  RecognitionDiagnostics _diagnostic = const RecognitionDiagnostics.idle();
  Future<void> _pump = Future<void>.value();
  bool _queueDrainScheduled = false;
  Future<void> _operations = Future<void>.value();
  String? _sessionId;
  MediaSource? _source;
  Duration? _lastPlaybackPosition;
  Duration? _explicitSeekPosition;
  bool _disposed = false;
  bool _playing = false;
  bool _backpressurePaused = false;
  RecognitionWindow? _deferredWindow;
  int _generation = 0;
  DateTime? _lastDecoderLogAt;
  AudioDecoderState? _lastLoggedDecoderState;
  int _lastLoggedDecoderChunks = -1;
  bool _hasLoggedAudioChunk = false;

  Stream<RecognitionEvent> get events => _events.stream;
  Stream<RecognitionDiagnostics> get diagnostics => _diagnostics.stream;
  RecognitionDiagnostics get diagnostic => _diagnostic;

  Future<void> seek(Duration position) async {
    if (_disposed || _sessionId == null) return;
    _explicitSeekPosition = position;
    await _player.seek(position);
    await _operations;
  }

  Future<void> stop() async {
    if (_disposed) return;
    await _enqueue(() async {
      ++_generation;
      _playing = false;
      _backpressurePaused = false;
      _planner.reset(sessionId: _sessionId ?? 'stopped');
      _queue.clear();
      _deferredWindow = null;
      await _decoder.stop();
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
    _explicitSeekPosition = null;
    await _playerSubscription?.cancel();
    await _decoderChunkSubscription?.cancel();
    await _decoderStatusSubscription?.cancel();
    await _recognizerStatusSubscription?.cancel();
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
    unawaited(_enqueue(() => _applyPlayback(snapshot)));
  }

  Future<void> _applyPlayback(PlaybackSnapshot snapshot) async {
    final source = snapshot.source;
    if (source == null) return;
    final sourceChanged = !_sameSource(source, _source) || _sessionId == null;
    final explicitSeek = _explicitSeekPosition;
    final positionJump = _lastPlaybackPosition != null &&
        (snapshot.position - _lastPlaybackPosition!).abs() >
            const Duration(seconds: 2);
    _lastPlaybackPosition = snapshot.position;

    if (sourceChanged) {
      await _newSession(
        source,
        position: snapshot.position,
        startDecoder: snapshot.status == PlaybackStatus.playing,
      );
      return;
    }
    if (explicitSeek != null || positionJump) {
      _explicitSeekPosition = null;
      await _newSession(
        source,
        position: explicitSeek ?? snapshot.position,
        startDecoder: snapshot.status == PlaybackStatus.playing,
      );
      return;
    }
    if (snapshot.status == PlaybackStatus.playing && !_playing) {
      _playing = true;
      await _decoder.start();
    } else if (snapshot.status != PlaybackStatus.playing && _playing) {
      _playing = false;
      await _pauseRecognition();
    }
  }

  bool _sameSource(MediaSource left, MediaSource? right) =>
      right != null &&
      left.uri == right.uri &&
      left.kind == right.kind &&
      left.browserSessionId == right.browserSessionId;

  Future<void> _newSession(
    MediaSource source, {
    required Duration position,
    required bool startDecoder,
  }) async {
    final generation = ++_generation;
    _playing = startDecoder;
    _backpressurePaused = false;
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
    await _recognizer.stop();
    try {
      await _decoder.open(AudioDecoderRequest(
        sessionId: sessionId,
        source: source,
        start: position,
      ));
    } on Object catch (error) {
      if (generation != _generation || _disposed) return;
      _playing = false;
      _setDiagnostic(_diagnostic.copyWith(
        decoder: _decoder.status,
        queueDepth: _queue.depth,
        lastReason: 'decoder_open_failed',
      ));
      _logs?.error('识别音频', '音频解码打开失败', {
        '错误类型': error.runtimeType,
        '错误信息': error.toString(),
      });
      return;
    }
    if (generation != _generation || _disposed) return;
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
      recognizer: _recognizer is WindowRecognitionStatusProvider
          ? (_recognizer as WindowRecognitionStatusProvider).status
          : _diagnostic.recognizer,
    ));
    if (startDecoder) await _decoder.start();
  }

  Future<void> _pauseRecognition() async {
    _backpressurePaused = false;
    await _decoder.pause();
    // Let an already-submitted bounded window finish. Cancelling it on every
    // pause made a user miss a valid transcription simply by stopping playback.
    _setDiagnostic(_diagnostic.copyWith(
      decoder: _decoder.status,
      queueDepth: _queue.depth,
      lastReason: 'paused',
    ));
  }

  void _onDecoderStatus(AudioDecoderStatus status) {
    _setDiagnostic(_diagnostic.copyWith(decoder: status));
    final now = DateTime.now();
    final stateChanged = status.state != _lastLoggedDecoderState;
    final periodic = _lastDecoderLogAt == null ||
        now.difference(_lastDecoderLogAt!) >= const Duration(seconds: 1);
    final chunkMilestone = status.emittedChunks >= 0 &&
        status.emittedChunks ~/ 100 > _lastLoggedDecoderChunks ~/ 100;
    if (stateChanged || periodic || chunkMilestone ||
        status.state == AudioDecoderState.error) {
      _lastDecoderLogAt = now;
      _lastLoggedDecoderState = status.state;
      _lastLoggedDecoderChunks = status.emittedChunks;
      _logs?.info('识别音频', '解码器状态汇总', {
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
    // A decoder pause emits a final marker for the buffered tail. Keep that
    // marker even after playback flips to paused so the partial window is not
    // silently discarded.
    if (_disposed || chunk.sessionId != _sessionId) return;
    if (!_playing && !chunk.isLast) return;
    final now = DateTime.now();
    final periodic = _lastDecoderLogAt == null ||
        now.difference(_lastDecoderLogAt!) >= const Duration(seconds: 1);
    if (!_hasLoggedAudioChunk || periodic || chunk.isLast) {
      _hasLoggedAudioChunk = true;
      _lastDecoderLogAt = now;
      _logs?.info('识别音频', '解码音频进度', {
        '媒体起点': chunk.mediaStart,
        '持续时间': chunk.duration,
        '采样率': chunk.sampleRate,
        '声道': chunk.channels,
        '样本帧数': chunk.sampleCount,
        '尾部标记': chunk.isLast,
        '说明': chunk.isLast ? '音频流结束' : '高频音频块已合并记录',
      });
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
      _logs?.info('识别音频', '生成识别窗口', {
        '窗口 ID': window.windowId,
        '媒体起点': window.mediaStart,
        '媒体终点': window.mediaEnd,
        '持续时间': window.duration,
        '样本数': window.samples.length,
        '源音频块数': window.sourceChunkCount,
      });
      if (!_queue.offer(window)) {
        if (_deferredWindow == null) {
          _deferredWindow = window;
          _logs?.info('识别音频', '窗口等待背压恢复', {
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
    if (_backpressurePaused || !_playing || _disposed) return;
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
    if (!_backpressurePaused || !_playing || _disposed || _queue.isFull) {
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

  void _offerDeferredWindow() {
    final deferred = _deferredWindow;
    if (deferred == null || _disposed || !_queue.offer(deferred)) return;
    _deferredWindow = null;
    _setDiagnostic(_diagnostic.copyWith(queueDepth: _queue.depth));
    _logs?.info('识别音频', '等待窗口已重新入队', {
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
    try {
      if (_disposed || window.sessionId != _sessionId) return;
      final result = await _recognizer.recognize(window);
      if (generation != _generation ||
          _disposed ||
          window.sessionId != _sessionId) {
        return;
      }
      if (!result.succeeded) {
        _setDiagnostic(_diagnostic.copyWith(
          windowsFailed: _diagnostic.windowsFailed + 1,
          lastReason: result.error,
          lastWindow: window,
          lastInference: result.inference,
          lastRealtimeFactor: result.realtimeFactor,
          lastResultCount: result.events.length,
          recognitionLag: _recognitionLag(window),
        ));
        _logs?.error('识别音频', '窗口识别失败', {
          '原因': result.error,
          '窗口时长': window.duration,
          '推理耗时': result.inference,
        });
        return;
      }
      for (final event in result.events) {
        if (event.sessionId == _sessionId && event.text.trim().isNotEmpty) {
          _logs?.info('识别音频', '字幕输出', {
            '窗口 ID': window.windowId,
            '片段起点': event.start,
            '片段终点': event.end,
            '文字': event.text,
            '语言': event.language,
          });
          _events.add(event);
        }
      }
      _setDiagnostic(_diagnostic.copyWith(
        queueDepth: _queue.depth,
        lastWindow: window,
        windowsRecognized: _diagnostic.windowsRecognized + 1,
        lastInference: result.inference,
        lastRealtimeFactor: result.realtimeFactor,
        lastResultCount: result.events.length,
        recognitionLag: _recognitionLag(window),
        clearReason: true,
      ));
    } catch (error) {
      _setDiagnostic(_diagnostic.copyWith(
        windowsFailed: _diagnostic.windowsFailed + 1,
        lastReason: 'recognition_error',
      ));
      _logs?.error('识别音频', '窗口识别失败', {'错误类型': error.runtimeType});
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
    _setDiagnostic(_diagnostic.copyWith(
      windowsSkipped: _diagnostic.windowsSkipped + 1,
      lastReason: reason,
    ));
    _logs?.info('识别音频', '窗口已跳过', {
      '原因': reason,
      '媒体起点': mediaStart,
      '媒体终点': mediaEnd,
      '队列深度': _queue.depth,
    });
  }

  Duration _recognitionLag(RecognitionWindow window) {
    final position = _diagnostic.playbackPosition;
    final lag = position - window.mediaEnd;
    return lag.isNegative ? Duration.zero : lag;
  }

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
