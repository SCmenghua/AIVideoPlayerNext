import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/audio/audio_models.dart';
import '../../domain/speech/speech_models.dart';
import '../../domain/speech/speech_core_status.dart';
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
    implements WindowRecognitionService, WindowRecognitionStatusProvider {
  WhisperWindowRecognitionService({
    required this.libraryPath,
    required this.modelPath,
    this.logs,
    this.threads = 16,
    this.language = 'ja',
    this.requestedBackend = WhisperRequestedBackend.vulkan,
  });

  final String libraryPath;
  final String modelPath;
  final int threads;
  final String language;
  final DiagnosticLogService? logs;
  final WhisperRequestedBackend requestedBackend;
  final StreamController<WindowRecognitionStatus> _statuses =
      StreamController<WindowRecognitionStatus>.broadcast();
  late WindowRecognitionStatus _status = WindowRecognitionStatus.notLoaded(
    modelName: File(modelPath).uri.pathSegments.last,
    backendStatus: WhisperBackendStatus.initial(requested: requestedBackend),
  );
  late final WhisperCppPersistentRecognitionWorker _worker =
      WhisperCppPersistentRecognitionWorker(
    libraryPath: libraryPath,
    modelPath: modelPath,
    threads: threads,
    requestedBackend: requestedBackend,
  );
  bool _disposed = false;

  @override
  WindowRecognitionStatus get status => _status;

  @override
  Stream<WindowRecognitionStatus> get statuses => _statuses.stream;

  Future<void> prepare() async {
    if (_disposed || _status.state == WindowRecognitionState.ready) return;
    _setStatus(_status.copyWith(state: WindowRecognitionState.loading));
    logs?.info('识别音频', 'Whisper 开始加载模型', {'模型': _status.modelName});
    try {
      await _worker.warmUp();
      _setStatus(_status.copyWith(
        state: WindowRecognitionState.ready,
        backendStatus: _worker.backendStatus,
      ));
      logs?.info('识别音频', 'Whisper 模型加载成功', {'模型': _status.modelName});
      _logBackendStatus(_worker.backendStatus);
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
    logs?.info('识别音频', 'Whisper 开始识别', {'窗口 ID': window.windowId});
    logs?.info('识别音频', 'Whisper 输入窗口', {
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
      events = await _worker.recognize(
        request: RecognitionRequest(
          sessionId: window.sessionId,
          from: window.mediaStart,
          language: language,
        ),
        samples: window.samples,
      );
      _setStatus(_status.copyWith(backendStatus: _worker.backendStatus));
      final filteredEvents = <RecognitionEvent>[];
      for (final event in events) {
        final text = event.text.trim();
        final normalizedText = _normalizeForHallucinationCheck(text);
        String? discardReason;
        if (text.isEmpty) {
          discardReason = 'emptyText';
        } else if (event.language != language) {
          discardReason = 'unexpectedLanguage';
        } else if (_knownHallucinations.contains(normalizedText)) {
          discardReason = 'knownHallucination';
        }
        if (discardReason != null) {
          logs?.info('识别音频', 'Whisper 候选已丢弃', {
            '窗口 ID': window.windowId,
            '片段起点': event.start,
            '片段终点': event.end,
            '文字': text,
            '语言': event.language,
            '置信度': event.confidence,
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
        ));
      }
      events = List<RecognitionEvent>.unmodifiable(filteredEvents);
      stopwatch.stop();
      _setStatus(_status.copyWith(
        state: WindowRecognitionState.ready,
        lastWindow: window,
        lastResultCount: events.length,
        lastOutput: events.map((event) => event.text).toList(growable: false),
        lastInference: stopwatch.elapsed,
      ));
      logs?.info('识别音频', 'Whisper 输出窗口', {
        '窗口 ID': window.windowId,
        '结果数': events.length,
        '输出文字': events.map((event) => event.text).join(' | '),
        '推理耗时': stopwatch.elapsed,
        '实时倍率':
            stopwatch.elapsed.inMicroseconds / window.duration.inMicroseconds,
        '语言参数': language,
        '请求后端': _worker.backendStatus.requestedLabel,
        '实际后端': _worker.backendStatus.actualLabel,
        'GPU 已启用': _worker.backendStatus.gpuEnabled,
        '设备': _worker.backendStatus.deviceName.isEmpty
            ? '未报告'
            : _worker.backendStatus.deviceName,
        '回退原因': _worker.backendStatus.fallbackLabel,
      });
      if (events.isEmpty) {
        logs?.info('识别音频', 'Whisper 输出为空', {'窗口 ID': window.windowId});
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
  Future<void> stop() => _worker.stop();

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _worker.dispose();
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

  static const _knownHallucinations = <String>{
    'お疲れ様でした',
    'ご視聴ありがとうございました',
  };

  static String _normalizeForHallucinationCheck(String text) =>
      text.replaceAll(RegExp(r'[\s。、！？!?.,，．・]+'), '').trim();
}

/// iOS adapter which resolves the sandbox model path before constructing the
/// shared persistent FFI worker. This keeps platform path policy out of the
/// recognition controller and lets the native process expose speech_core.
class IosWhisperWindowRecognitionService
    implements WindowRecognitionService, WindowRecognitionStatusProvider {
  IosWhisperWindowRecognitionService({
    this.logs,
    this.threads = 4,
    this.language = 'ja',
    this.requestedBackend = WhisperRequestedBackend.metal,
  });

  static const _channel = MethodChannel('ai_video_player/ios_speech_core');
  static const modelFileName = 'ggml-large-v3-turbo-q5_0.bin';
  final DiagnosticLogService? logs;
  final int threads;
  final String language;
  final WhisperRequestedBackend requestedBackend;
  final StreamController<WindowRecognitionStatus> _statuses =
      StreamController<WindowRecognitionStatus>.broadcast();
  late WindowRecognitionStatus _status = WindowRecognitionStatus.notLoaded(
    modelName: modelFileName,
    backendStatus: WhisperBackendStatus.initial(
      requested: requestedBackend,
    ),
  );
  WhisperWindowRecognitionService? _delegate;
  bool _disposed = false;

  @override
  WindowRecognitionStatus get status => _delegate?.status ?? _status;

  @override
  Stream<WindowRecognitionStatus> get statuses => _statuses.stream;

  /// Installs a user-provided model into the app sandbox. The binary remains
  /// outside Git and can be supplied by a future import/settings workflow.
  static Future<String?> installModel(Uint8List bytes) =>
      _channel.invokeMethod<String>('installModel', bytes);

  Future<void> prepare() async {
    if (_disposed || _delegate != null) return;
    _setStatus(_status.copyWith(state: WindowRecognitionState.loading));
    try {
      final path = await _channel.invokeMethod<String>('modelPath');
      if (path == null || !File(path).existsSync()) {
        throw StateError('iOS Application Support 中未找到 Whisper 模型。');
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
      logs?.error('识别音频', 'iOS Whisper 模型不可用', {
        '错误类型': error.runtimeType,
        '错误信息': error,
      });
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
