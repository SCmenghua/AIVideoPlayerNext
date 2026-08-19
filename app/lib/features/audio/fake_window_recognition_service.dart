import '../../domain/audio/audio_models.dart';
import '../../domain/speech/speech_models.dart';

class FakeWindowRecognitionService implements WindowRecognitionService {
  FakeWindowRecognitionService({this.delay = Duration.zero});

  final Duration delay;
  final List<RecognitionWindow> received = [];
  bool stopped = false;
  bool disposed = false;
  int _generation = 0;

  @override
  Future<WindowRecognitionResult> recognize(RecognitionWindow window) async {
    received.add(window);
    final generation = _generation;
    await Future<void>.delayed(delay);
    if (generation != _generation || disposed) {
      return WindowRecognitionResult(
          window: window, events: const [], error: 'cancelled');
    }
    return WindowRecognitionResult(
      window: window,
      events: [
        RecognitionEvent(
          sessionId: window.sessionId,
          segmentId: '${window.windowId}-segment-0',
          start: window.mediaStart,
          end: window.mediaEnd,
          text: 'window ${window.windowId}',
          language: 'en',
          kind: RecognitionKind.finalResult,
          source: RecognitionSource.whisperCpp,
          confidence: 1,
        ),
      ],
    );
  }

  @override
  Future<void> stop() async {
    stopped = true;
    _generation++;
    stopped = false;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    stopped = true;
    _generation++;
  }
}
