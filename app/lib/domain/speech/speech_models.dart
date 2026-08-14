enum RecognitionKind { partial, finalResult }

enum RecognitionSource { whisperCpp, appleSpeech, windowsLiveCaptions, playerPcm, microphone }

class RecognitionRequest {
  const RecognitionRequest({required this.sessionId, required this.from});

  final String sessionId;
  final Duration from;
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
}

abstract interface class SpeechRecognitionService {
  Future<void> start(RecognitionRequest request);
  Future<void> stop();
  Future<void> reset({required Duration position});
  Stream<RecognitionEvent> get events;
}
