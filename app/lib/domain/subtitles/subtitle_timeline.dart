import '../speech/speech_models.dart';

class SubtitleEntry {
  SubtitleEntry({
    required this.sessionId,
    required this.segmentId,
    required this.start,
    required this.end,
    required this.original,
    required this.language,
    this.translation,
    this.isFinal = true,
  });

  final String sessionId;
  final String segmentId;
  final Duration start;
  final Duration end;
  final String original;
  final String language;
  String? translation;
  bool isFinal;
}

class SubtitleTimeline {
  final Map<String, SubtitleEntry> _entries = {};
  SubtitleEntry? _partial;

  List<SubtitleEntry> get finals => _entries.values.toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  SubtitleEntry? get partial => _partial;

  void apply(RecognitionEvent event) {
    if (event.kind == RecognitionKind.partial) {
      _partial = SubtitleEntry(
        sessionId: event.sessionId,
        segmentId: event.segmentId,
        start: event.start,
        end: event.end,
        original: event.text,
        language: event.language,
        isFinal: false,
      );
      return;
    }

    _entries[event.segmentId] = SubtitleEntry(
      sessionId: event.sessionId,
      segmentId: event.segmentId,
      start: event.start,
      end: event.end,
      original: event.text,
      language: event.language,
    );
    if (_partial?.segmentId == event.segmentId) _partial = null;
  }

  void applyTranslation(String segmentId, String text) {
    final entry = _entries[segmentId];
    if (entry != null) entry.translation = text;
  }

  List<SubtitleEntry> at(Duration position) => finals
      .where((entry) => position >= entry.start && position <= entry.end)
      .toList();

  void reset({required String sessionId}) {
    _entries.removeWhere((_, entry) => entry.sessionId != sessionId);
    if (_partial?.sessionId != sessionId) _partial = null;
  }
}
