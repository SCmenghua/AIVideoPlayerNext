import 'engine.dart';
import 'pcm.dart';

enum RecognitionState { idle, opening, running, paused, ended, stopped, error }

enum RecognitionLogLevel { debug, info, warning, error }

class RecognitionLogEvent {
  const RecognitionLogEvent(this.level, this.message, [this.details = const {}]);

  final RecognitionLogLevel level;
  final String message;
  final Map<String, Object?> details;
}

class RecognitionDiagnostics {
  const RecognitionDiagnostics({
    this.state = RecognitionState.idle,
    this.generation = 0,
    this.playbackPosition = Duration.zero,
    this.decodedThrough = Duration.zero,
    this.processedThrough = Duration.zero,
    this.recognizedThrough = Duration.zero,
    this.pendingWindows = 0,
    this.windowsRecognized = 0,
    this.windowsSkipped = 0,
    this.windowsFailed = 0,
    this.segmentsAccepted = 0,
    this.segmentsDropped = 0,
    this.lastWindowDuration = Duration.zero,
    this.lastInference = Duration.zero,
    this.lastRealtimeFactor = 0,
    this.sourcePausedForLead = false,
    this.sourcePausedForQueue = false,
    this.engineState = EngineState.unloaded,
    this.engineBackend,
    this.source = const PcmSourceStatus.idle(),
    this.message,
  });

  final RecognitionState state;
  final int generation;
  final Duration playbackPosition;

  /// Media time up to which audio has been decoded.
  final Duration decodedThrough;

  /// Media time up to which windows (recognised or skipped) are complete.
  final Duration processedThrough;

  /// End of the last accepted subtitle segment.
  final Duration recognizedThrough;
  final int pendingWindows;
  final int windowsRecognized;
  final int windowsSkipped;
  final int windowsFailed;
  final int segmentsAccepted;
  final int segmentsDropped;
  final Duration lastWindowDuration;
  final Duration lastInference;
  final double lastRealtimeFactor;
  final bool sourcePausedForLead;
  final bool sourcePausedForQueue;
  final EngineState engineState;
  final EngineBackendInfo? engineBackend;
  final PcmSourceStatus source;
  final String? message;

  Duration get lead => decodedThrough - playbackPosition;

  RecognitionDiagnostics copyWith({
    RecognitionState? state,
    int? generation,
    Duration? playbackPosition,
    Duration? decodedThrough,
    Duration? processedThrough,
    Duration? recognizedThrough,
    int? pendingWindows,
    int? windowsRecognized,
    int? windowsSkipped,
    int? windowsFailed,
    int? segmentsAccepted,
    int? segmentsDropped,
    Duration? lastWindowDuration,
    Duration? lastInference,
    double? lastRealtimeFactor,
    bool? sourcePausedForLead,
    bool? sourcePausedForQueue,
    EngineState? engineState,
    EngineBackendInfo? engineBackend,
    PcmSourceStatus? source,
    String? message,
    bool clearMessage = false,
  }) =>
      RecognitionDiagnostics(
        state: state ?? this.state,
        generation: generation ?? this.generation,
        playbackPosition: playbackPosition ?? this.playbackPosition,
        decodedThrough: decodedThrough ?? this.decodedThrough,
        processedThrough: processedThrough ?? this.processedThrough,
        recognizedThrough: recognizedThrough ?? this.recognizedThrough,
        pendingWindows: pendingWindows ?? this.pendingWindows,
        windowsRecognized: windowsRecognized ?? this.windowsRecognized,
        windowsSkipped: windowsSkipped ?? this.windowsSkipped,
        windowsFailed: windowsFailed ?? this.windowsFailed,
        segmentsAccepted: segmentsAccepted ?? this.segmentsAccepted,
        segmentsDropped: segmentsDropped ?? this.segmentsDropped,
        lastWindowDuration: lastWindowDuration ?? this.lastWindowDuration,
        lastInference: lastInference ?? this.lastInference,
        lastRealtimeFactor: lastRealtimeFactor ?? this.lastRealtimeFactor,
        sourcePausedForLead: sourcePausedForLead ?? this.sourcePausedForLead,
        sourcePausedForQueue: sourcePausedForQueue ?? this.sourcePausedForQueue,
        engineState: engineState ?? this.engineState,
        engineBackend: engineBackend ?? this.engineBackend,
        source: source ?? this.source,
        message: clearMessage ? null : message ?? this.message,
      );
}
