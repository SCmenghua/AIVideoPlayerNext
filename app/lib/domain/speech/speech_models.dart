enum RecognitionKind { partial, finalResult }

enum RecognitionSource {
  whisperCpp,
  appleSpeech,
  windowsLiveCaptions,
  playerPcm,
  microphone
}

class RecognitionRequest {
  const RecognitionRequest({
    required this.sessionId,
    required this.from,
    this.language = 'auto',
    this.sourceWindowId,
    this.initialPrompt,
  });

  final String sessionId;
  final Duration from;
  final String language;
  final String? sourceWindowId;

  /// Text the decoder reads as preceding context, so an utterance split across
  /// two windows keeps its wording and punctuation. This is the tail of the
  /// previous window's transcript, not the whole transcript: the prompt
  /// competes with the audio for the decoder's context.
  final String? initialPrompt;
}

class RecognitionEvent {
  const RecognitionEvent({
    required this.sessionId,
    required this.segmentId,
    required this.start,
    required this.end,
    required this.text,
    required this.language,
    required this.kind,
    required this.source,
    this.confidence,
    this.avgLogprob,
    this.noSpeechProbability,
    this.repetition,
    this.sourceWindowId,
    this.sourceSegmentIndex,
  });

  final String sessionId;
  final String segmentId;
  final Duration start;
  final Duration end;
  final String text;
  final String language;
  final RecognitionKind kind;
  final RecognitionSource source;
  final double? confidence;

  /// Mean per-token log probability on Whisper's own scale, where roughly -1.0
  /// is where its decoder stops trusting a candidate. Null when the backend
  /// does not report it.
  final double? avgLogprob;

  /// The backend's probability that the window carried no speech at all.
  final double? noSpeechProbability;

  /// Repeated 4-gram share of the text, rising towards 1 in a decoder loop.
  final double? repetition;

  final String? sourceWindowId;
  final int? sourceSegmentIndex;
}

abstract interface class SpeechRecognitionService {
  Future<void> start(RecognitionRequest request);
  Future<void> stop();
  Future<void> reset({required Duration position});
  Stream<RecognitionEvent> get events;
}
