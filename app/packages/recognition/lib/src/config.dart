enum SpeechBackend { auto, cpu, vulkan, metal }

/// whisper.cpp decoder parameters. Defaults follow OpenAI's reference
/// transcription pipeline.
class DecoderOptions {
  const DecoderOptions({
    this.beamSize = 5,
    this.temperature = 0.0,
    this.temperatureIncrement = 0.2,
    this.entropyThreshold = 2.4,
    this.logprobThreshold = -1.0,
    this.noSpeechThreshold = 0.6,
    this.tokenTimestamps = true,
    this.audioContext = 0,
  });

  final int beamSize;
  final double temperature;
  final double temperatureIncrement;
  final double entropyThreshold;
  final double logprobThreshold;
  final double noSpeechThreshold;
  final bool tokenTimestamps;
  final int audioContext;

  DecoderOptions copyWith({
    int? beamSize,
    double? temperature,
    double? temperatureIncrement,
    double? entropyThreshold,
    double? logprobThreshold,
    double? noSpeechThreshold,
    bool? tokenTimestamps,
    int? audioContext,
  }) =>
      DecoderOptions(
        beamSize: beamSize ?? this.beamSize,
        temperature: temperature ?? this.temperature,
        temperatureIncrement: temperatureIncrement ?? this.temperatureIncrement,
        entropyThreshold: entropyThreshold ?? this.entropyThreshold,
        logprobThreshold: logprobThreshold ?? this.logprobThreshold,
        noSpeechThreshold: noSpeechThreshold ?? this.noSpeechThreshold,
        tokenTimestamps: tokenTimestamps ?? this.tokenTimestamps,
        audioContext: audioContext ?? this.audioContext,
      );

  Map<String, Object?> toMap() => {
        'beamSize': beamSize,
        'temperature': temperature,
        'temperatureIncrement': temperatureIncrement,
        'entropyThreshold': entropyThreshold,
        'logprobThreshold': logprobThreshold,
        'noSpeechThreshold': noSpeechThreshold,
        'tokenTimestamps': tokenTimestamps,
        'audioContext': audioContext,
      };

  static DecoderOptions fromMap(Map<Object?, Object?> map) => DecoderOptions(
        beamSize: map['beamSize'] as int,
        temperature: map['temperature'] as double,
        temperatureIncrement: map['temperatureIncrement'] as double,
        entropyThreshold: map['entropyThreshold'] as double,
        logprobThreshold: map['logprobThreshold'] as double,
        noSpeechThreshold: map['noSpeechThreshold'] as double,
        tokenTimestamps: map['tokenTimestamps'] as bool,
        audioContext: map['audioContext'] as int,
      );
}

/// How speech is cut into recognition windows. Every boundary lands inside a
/// pause; the tiers trade latency for context as the buffered window grows.
class SegmenterOptions {
  const SegmenterOptions({
    this.speechThreshold = 0.5,
    this.shortSilence = const Duration(milliseconds: 250),
    this.minSilence = const Duration(milliseconds: 500),
    this.longSilence = const Duration(milliseconds: 1500),
    this.minWindow = const Duration(seconds: 1),
    this.minCutWindow = const Duration(seconds: 6),
    this.targetWindow = const Duration(seconds: 20),
    this.maxWindow = const Duration(seconds: 28),
    this.pad = const Duration(milliseconds: 200),
    this.silenceFlush = const Duration(seconds: 2),
  });

  final double speechThreshold;

  /// Pause accepted once the window is longer than [targetWindow].
  final Duration shortSilence;

  /// Pause accepted once the window is longer than [minCutWindow].
  final Duration minSilence;

  /// Pause accepted once the window is longer than [minWindow].
  final Duration longSilence;
  final Duration minWindow;
  final Duration minCutWindow;
  final Duration targetWindow;
  final Duration maxWindow;

  /// Audio kept before the first and after the last speech frame.
  final Duration pad;

  /// Silence without any speech after which the buffer is dropped.
  final Duration silenceFlush;
}

class GateOptions {
  const GateOptions({
    this.maxRepetition = 0.5,
    this.maxNoSpeechProbability = 0.9,
    this.blockedPhrases = const {
      'ご視聴ありがとうございました',
      'お疲れ様でした',
      'チャンネル登録お願いします',
    },
  });

  final double maxRepetition;
  final double maxNoSpeechProbability;
  final Set<String> blockedPhrases;
}

class RecognitionConfig {
  const RecognitionConfig({
    required this.modelPath,
    this.vadModelPath,
    this.language = 'ja',
    this.backend = SpeechBackend.auto,
    this.threads = 4,
    this.decoder = const DecoderOptions(),
    this.segmenter = const SegmenterOptions(),
    this.gate = const GateOptions(),
    this.contextEnabled = true,
    this.contextMaxCharacters = 120,
    this.leadPause = const Duration(seconds: 30),
    this.leadResume = const Duration(seconds: 15),
    this.maxPendingWindows = 3,
  });

  final String modelPath;
  final String? vadModelPath;

  /// ISO 639-1 code, or `auto` for detection.
  final String language;
  final SpeechBackend backend;
  final int threads;
  final DecoderOptions decoder;
  final SegmenterOptions segmenter;
  final GateOptions gate;

  /// Feed the tail of the previous window's text as the next initial prompt.
  final bool contextEnabled;
  final int contextMaxCharacters;

  /// Pause decoding when recognition is this far ahead of playback; `null`
  /// disables the watermark (used by offline regression).
  final Duration? leadPause;
  final Duration leadResume;
  final int maxPendingWindows;

  bool get autoDetectLanguage => language == 'auto';

  RecognitionConfig copyWith({
    String? modelPath,
    String? vadModelPath,
    String? language,
    SpeechBackend? backend,
    int? threads,
    DecoderOptions? decoder,
    SegmenterOptions? segmenter,
    GateOptions? gate,
    bool? contextEnabled,
    int? contextMaxCharacters,
    Duration? leadPause,
    bool clearLeadPause = false,
    Duration? leadResume,
    int? maxPendingWindows,
  }) =>
      RecognitionConfig(
        modelPath: modelPath ?? this.modelPath,
        vadModelPath: vadModelPath ?? this.vadModelPath,
        language: language ?? this.language,
        backend: backend ?? this.backend,
        threads: threads ?? this.threads,
        decoder: decoder ?? this.decoder,
        segmenter: segmenter ?? this.segmenter,
        gate: gate ?? this.gate,
        contextEnabled: contextEnabled ?? this.contextEnabled,
        contextMaxCharacters: contextMaxCharacters ?? this.contextMaxCharacters,
        leadPause: clearLeadPause ? null : leadPause ?? this.leadPause,
        leadResume: leadResume ?? this.leadResume,
        maxPendingWindows: maxPendingWindows ?? this.maxPendingWindows,
      );
}
