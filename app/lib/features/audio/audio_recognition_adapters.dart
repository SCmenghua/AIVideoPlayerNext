import 'dart:async';
import 'dart:io';

import '../../domain/audio/audio_models.dart';
import '../../domain/speech/speech_models.dart';
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
  });

  final String libraryPath;
  final String modelPath;
  final int threads;
  final String language;
  final DiagnosticLogService? logs;
  final StreamController<WindowRecognitionStatus> _statuses =
      StreamController<WindowRecognitionStatus>.broadcast();
  late WindowRecognitionStatus _status = WindowRecognitionStatus.notLoaded(
    modelName: File(modelPath).uri.pathSegments.last,
  );
  late final WhisperCppPersistentRecognitionWorker _worker =
      WhisperCppPersistentRecognitionWorker(
    libraryPath: libraryPath,
    modelPath: modelPath,
    threads: threads,
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
      _setStatus(_status.copyWith(state: WindowRecognitionState.ready));
      logs?.info('识别音频', 'Whisper 模型加载成功', {'模型': _status.modelName});
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

  static const _knownHallucinations = <String>{
    'お疲れ様でした',
    'ご視聴ありがとうございました',
  };

  static String _normalizeForHallucinationCheck(String text) =>
      text.replaceAll(RegExp(r'[\s。、！？!?.,，．・]+'), '').trim();
}
