import '../audio/audio_models.dart';
import 'speech_models.dart';

/// What one recognition window remembers about the window before it.
///
/// Two things are carried across a window boundary: the tail of the previous
/// transcript, handed to the decoder as a prompt so an utterance cut by the
/// boundary keeps its wording, and the previous window's text, used to catch
/// the decoder loop that carrying context can start.
///
/// Both are only meaningful inside one recognition session and only while the
/// windows stay contiguous. A session is a single media playthrough, so this
/// resets itself the moment a window from a different session arrives - the
/// recognition service outlives the media it was pointed at, and without that
/// guard the first window of a new video is compared against the last window
/// of the previous one.
class RecognitionWindowContext {
  RecognitionWindowContext({
    this.tailCharacters = 120,
    this.gapTolerance = const Duration(milliseconds: 1500),
    this.minimumRepeatCharacters = 6,
  });

  /// Whisper spends decoder context on the prompt, so only the tail of the
  /// previous window is worth passing.
  final int tailCharacters;

  /// A window that does not continue where the last one ended - after a seek,
  /// or across a long silence - gets no prompt, because stale context makes
  /// the decoder repeat text that is no longer on screen.
  final Duration gapTolerance;

  /// A speaker does occasionally repeat a short line, so only a repeat of
  /// something this long counts as a decoder loop.
  final int minimumRepeatCharacters;

  String? _sessionId;
  String? _tail;
  Duration? _end;
  String? _previousText;

  /// Drops everything carried so far. Called on seek and when recognition
  /// stops, where the next window will not continue the last one.
  void reset() {
    _sessionId = null;
    _tail = null;
    _end = null;
    _previousText = null;
  }

  /// Decoder prompt for [window], or null when nothing may be carried into it.
  String? promptFor(RecognitionWindow window) {
    _adopt(window.sessionId);
    final tail = _tail;
    final end = _end;
    if (tail == null || end == null) return null;
    final gap = window.mediaStart - end;
    if (gap < -gapTolerance || gap > gapTolerance) return null;
    return tail;
  }

  /// True when [events] say exactly what the previous window said.
  ///
  /// Measured on a 600-second Japanese track, large-v3 repeated one invented
  /// line for 415 of its 600 seconds and large-v3-turbo for 92, both at high
  /// confidence and with no repetition inside any single segment - no
  /// per-segment score rejects them. Noticing that a window said what the last
  /// one said is the only signal that does.
  bool repeatsPrevious(RecognitionWindow window, List<RecognitionEvent> events) {
    _adopt(window.sessionId);
    if (events.isEmpty) return false;
    final previous = _previousText;
    if (previous == null || previous.length < minimumRepeatCharacters) {
      return false;
    }
    return normalizeForComparison(_joined(events)) == previous;
  }

  /// Records what [window] produced, for the window that follows it.
  void remember(RecognitionWindow window, List<RecognitionEvent> events) {
    _adopt(window.sessionId);
    _previousText =
        events.isEmpty ? null : normalizeForComparison(_joined(events));
    final text = events.map((event) => event.text).join(' ').trim();
    if (text.isEmpty) {
      // Silence carries no context forward, but it also does not invalidate
      // what came before it; keep the previous tail anchored to this window so
      // a short pause does not drop the thread.
      _end = window.mediaEnd;
      return;
    }
    _tail = text.length <= tailCharacters
        ? text
        : text.substring(text.length - tailCharacters);
    _end = window.mediaEnd;
  }

  void _adopt(String sessionId) {
    if (_sessionId == sessionId) return;
    reset();
    _sessionId = sessionId;
  }

  static String _joined(List<RecognitionEvent> events) =>
      events.map((event) => event.text).join();

  /// Text stripped of the punctuation and spacing that recognition varies
  /// between windows, so two renderings of the same line compare equal.
  static String normalizeForComparison(String text) =>
      text.replaceAll(RegExp(r'[\s。、！？!?.,，．・]+'), '').trim();
}
