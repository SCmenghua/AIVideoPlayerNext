import 'dart:collection';

import '../player/player_service.dart';
import '../speech/speech_models.dart';

enum AudioDecoderState {
  idle,
  opening,
  ready,
  running,
  paused,
  seeking,
  ended,
  stopped,
  error,
  disposed,
}

class AudioDecoderStatus {
  const AudioDecoderStatus({
    required this.state,
    this.sessionId,
    this.message,
    this.sampleRate,
    this.channels,
    this.emittedChunks = 0,
  });

  const AudioDecoderStatus.idle() : this(state: AudioDecoderState.idle);

  final AudioDecoderState state;
  final String? sessionId;
  final String? message;
  final int? sampleRate;
  final int? channels;
  final int emittedChunks;

  AudioDecoderStatus copyWith({
    AudioDecoderState? state,
    String? sessionId,
    String? message,
    int? sampleRate,
    int? channels,
    int? emittedChunks,
    bool clearMessage = false,
  }) =>
      AudioDecoderStatus(
        state: state ?? this.state,
        sessionId: sessionId ?? this.sessionId,
        message: clearMessage ? null : message ?? this.message,
        sampleRate: sampleRate ?? this.sampleRate,
        channels: channels ?? this.channels,
        emittedChunks: emittedChunks ?? this.emittedChunks,
      );
}

class AudioDecoderRequest {
  const AudioDecoderRequest({
    required this.sessionId,
    required this.source,
    this.start = Duration.zero,
  });

  final String sessionId;
  final MediaSource source;
  final Duration start;
}

class AudioChunk {
  AudioChunk({
    required this.sessionId,
    required this.mediaStart,
    required this.sampleRate,
    required this.channels,
    required List<double> samples,
    this.isLast = false,
  }) : samples = UnmodifiableListView(List<double>.from(samples)) {
    if (sessionId.isEmpty) throw ArgumentError.value(sessionId, 'sessionId');
    if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
    if (channels <= 0) throw ArgumentError.value(channels, 'channels');
    if (this.samples.length % channels != 0) {
      throw ArgumentError(
          'Audio samples must contain complete interleaved frames');
    }
  }

  final String sessionId;
  final Duration mediaStart;
  final int sampleRate;
  final int channels;
  final List<double> samples;
  final bool isLast;

  int get sampleCount => samples.length ~/ channels;

  Duration get duration => Duration(
        microseconds:
            (sampleCount * Duration.microsecondsPerSecond / sampleRate).round(),
      );

  AudioChunk copyWith({
    String? sessionId,
    Duration? mediaStart,
    int? sampleRate,
    int? channels,
    List<double>? samples,
    bool? isLast,
  }) =>
      AudioChunk(
        sessionId: sessionId ?? this.sessionId,
        mediaStart: mediaStart ?? this.mediaStart,
        sampleRate: sampleRate ?? this.sampleRate,
        channels: channels ?? this.channels,
        samples: samples ?? this.samples,
        isLast: isLast ?? this.isLast,
      );
}

class NormalizedPcm {
  NormalizedPcm({
    required this.sessionId,
    required this.mediaStart,
    required this.sampleRate,
    required List<double> samples,
  }) : samples = UnmodifiableListView(List<double>.from(samples));

  final String sessionId;
  final Duration mediaStart;
  final int sampleRate;
  final List<double> samples;

  Duration get duration => Duration(
        microseconds:
            (samples.length * Duration.microsecondsPerSecond / sampleRate)
                .round(),
      );
}

/// Matches speech_core's downmix and linear resampling contract.
class PcmStandardizer {
  const PcmStandardizer({this.outputSampleRate = 16000});

  final int outputSampleRate;

  NormalizedPcm normalize(AudioChunk chunk) {
    final mono = List<double>.filled(chunk.sampleCount, 0);
    for (var frame = 0; frame < chunk.sampleCount; frame++) {
      var sum = 0.0;
      for (var channel = 0; channel < chunk.channels; channel++) {
        sum += chunk.samples[frame * chunk.channels + channel];
      }
      mono[frame] = (sum / chunk.channels).clamp(-1.0, 1.0).toDouble();
    }

    if (chunk.sampleRate == outputSampleRate) {
      return NormalizedPcm(
        sessionId: chunk.sessionId,
        mediaStart: chunk.mediaStart,
        sampleRate: outputSampleRate,
        samples: mono,
      );
    }
    if (mono.isEmpty) {
      return NormalizedPcm(
        sessionId: chunk.sessionId,
        mediaStart: chunk.mediaStart,
        sampleRate: outputSampleRate,
        samples: const [],
      );
    }

    final outputCount =
        (mono.length * outputSampleRate / chunk.sampleRate).ceil();
    final output = List<double>.filled(outputCount, 0);
    if (mono.length == 1) {
      output.fillRange(0, output.length, mono.single);
    } else if (output.length == 1) {
      output[0] = mono.first;
    } else {
      final scale = (mono.length - 1) / (output.length - 1);
      for (var index = 0; index < output.length; index++) {
        final source = index * scale;
        final left = source.floor();
        final right = (left + 1).clamp(0, mono.length - 1);
        final weight = source - left;
        output[index] = mono[left] * (1 - weight) + mono[right] * weight;
      }
    }
    return NormalizedPcm(
      sessionId: chunk.sessionId,
      mediaStart: chunk.mediaStart,
      sampleRate: outputSampleRate,
      samples: output,
    );
  }
}

class RecognitionWindow {
  RecognitionWindow({
    required this.windowId,
    required this.sessionId,
    required this.mediaStart,
    required this.sampleRate,
    required List<double> samples,
    required this.sourceChunkCount,
  }) : samples = UnmodifiableListView(List<double>.from(samples));

  final String windowId;
  final String sessionId;
  final Duration mediaStart;
  final int sampleRate;
  final List<double> samples;
  final int sourceChunkCount;

  Duration get duration => Duration(
        microseconds:
            (samples.length * Duration.microsecondsPerSecond / sampleRate)
                .round(),
      );

  Duration get mediaEnd => mediaStart + duration;
}

enum WindowSkipReason { silence, tooShort, queueFull, cancelled, decoderError }

class WindowPlanResult {
  WindowPlanResult.window(RecognitionWindow value)
      : window = value,
        skipReason = null,
        mediaStart = value.mediaStart,
        mediaEnd = value.mediaEnd;

  const WindowPlanResult.skipped({
    required this.mediaStart,
    required this.mediaEnd,
    required WindowSkipReason reason,
  })  : window = null,
        skipReason = reason;

  final RecognitionWindow? window;
  final WindowSkipReason? skipReason;
  final Duration mediaStart;
  final Duration mediaEnd;
}

class WindowRecognitionResult {
  const WindowRecognitionResult({
    required this.window,
    required this.events,
    this.inference = Duration.zero,
    this.error,
  });

  final RecognitionWindow window;
  final List<RecognitionEvent> events;
  final Duration inference;
  final String? error;

  bool get succeeded => error == null;

  double get realtimeFactor => window.duration.inMicroseconds == 0
      ? 0
      : inference.inMicroseconds / window.duration.inMicroseconds;
}

enum WindowRecognitionState {
  unavailable,
  notLoaded,
  loading,
  ready,
  recognizing,
  error,
  stopped,
}

class WindowRecognitionStatus {
  const WindowRecognitionStatus({
    required this.state,
    this.message,
    this.modelName,
    this.lastWindow,
    this.lastResultCount = 0,
    this.lastOutput = const [],
    this.lastInference = Duration.zero,
  });

  const WindowRecognitionStatus.notLoaded({this.modelName})
      : state = WindowRecognitionState.notLoaded,
        message = null,
        lastWindow = null,
        lastResultCount = 0,
        lastOutput = const [],
        lastInference = Duration.zero;

  const WindowRecognitionStatus.unavailable({
    this.message,
    this.modelName,
  })  : state = WindowRecognitionState.unavailable,
        lastWindow = null,
        lastResultCount = 0,
        lastOutput = const [],
        lastInference = Duration.zero;

  final WindowRecognitionState state;
  final String? message;
  final String? modelName;
  final RecognitionWindow? lastWindow;
  final int lastResultCount;
  final List<String> lastOutput;
  final Duration lastInference;

  WindowRecognitionStatus copyWith({
    WindowRecognitionState? state,
    String? message,
    String? modelName,
    RecognitionWindow? lastWindow,
    int? lastResultCount,
    List<String>? lastOutput,
    Duration? lastInference,
  }) =>
      WindowRecognitionStatus(
        state: state ?? this.state,
        message: message ?? this.message,
        modelName: modelName ?? this.modelName,
        lastWindow: lastWindow ?? this.lastWindow,
        lastResultCount: lastResultCount ?? this.lastResultCount,
        lastOutput: lastOutput ?? this.lastOutput,
        lastInference: lastInference ?? this.lastInference,
      );
}

class RecognitionDiagnostics {
  const RecognitionDiagnostics({
    required this.sessionId,
    required this.decoder,
    required this.queueDepth,
    required this.lastWindow,
    required this.windowsRecognized,
    required this.windowsSkipped,
    required this.windowsFailed,
    required this.lastReason,
    required this.playbackPosition,
    required this.lastInference,
    required this.lastRealtimeFactor,
    required this.lastResultCount,
    required this.recognitionLag,
    required this.recognizer,
  });

  const RecognitionDiagnostics.idle()
      : sessionId = null,
        decoder = const AudioDecoderStatus.idle(),
        queueDepth = 0,
        lastWindow = null,
        windowsRecognized = 0,
        windowsSkipped = 0,
        windowsFailed = 0,
        lastReason = null,
        playbackPosition = Duration.zero,
        lastInference = Duration.zero,
        lastRealtimeFactor = 0,
        lastResultCount = 0,
        recognitionLag = Duration.zero,
        recognizer = const WindowRecognitionStatus.notLoaded();

  final String? sessionId;
  final AudioDecoderStatus decoder;
  final int queueDepth;
  final RecognitionWindow? lastWindow;
  final int windowsRecognized;
  final int windowsSkipped;
  final int windowsFailed;
  final String? lastReason;
  final Duration playbackPosition;
  final Duration lastInference;
  final double lastRealtimeFactor;
  final int lastResultCount;
  final Duration recognitionLag;
  final WindowRecognitionStatus recognizer;

  RecognitionDiagnostics copyWith({
    String? sessionId,
    AudioDecoderStatus? decoder,
    int? queueDepth,
    RecognitionWindow? lastWindow,
    int? windowsRecognized,
    int? windowsSkipped,
    int? windowsFailed,
    String? lastReason,
    Duration? playbackPosition,
    Duration? lastInference,
    double? lastRealtimeFactor,
    int? lastResultCount,
    Duration? recognitionLag,
    WindowRecognitionStatus? recognizer,
    bool clearReason = false,
  }) =>
      RecognitionDiagnostics(
        sessionId: sessionId ?? this.sessionId,
        decoder: decoder ?? this.decoder,
        queueDepth: queueDepth ?? this.queueDepth,
        lastWindow: lastWindow ?? this.lastWindow,
        windowsRecognized: windowsRecognized ?? this.windowsRecognized,
        windowsSkipped: windowsSkipped ?? this.windowsSkipped,
        windowsFailed: windowsFailed ?? this.windowsFailed,
        lastReason: clearReason ? null : lastReason ?? this.lastReason,
        playbackPosition: playbackPosition ?? this.playbackPosition,
        lastInference: lastInference ?? this.lastInference,
        lastRealtimeFactor: lastRealtimeFactor ?? this.lastRealtimeFactor,
        lastResultCount: lastResultCount ?? this.lastResultCount,
        recognitionLag: recognitionLag ?? this.recognitionLag,
        recognizer: recognizer ?? this.recognizer,
      );
}

abstract interface class AudioDecoder {
  AudioDecoderStatus get status;
  Stream<AudioDecoderStatus> get statuses;
  Stream<AudioChunk> get chunks;
  Future<void> open(AudioDecoderRequest request);
  Future<void> start();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> dispose();
}

abstract interface class WindowRecognitionService {
  Future<WindowRecognitionResult> recognize(RecognitionWindow window);
  Future<void> stop();
  Future<void> dispose();
}

abstract interface class WindowRecognitionStatusProvider {
  WindowRecognitionStatus get status;
  Stream<WindowRecognitionStatus> get statuses;
}
