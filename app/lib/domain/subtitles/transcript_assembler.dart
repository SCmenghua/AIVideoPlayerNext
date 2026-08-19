import '../speech/speech_models.dart';
import 'transcript_document.dart';

/// Converts window-local Whisper output into the stable timeline consumed by
/// diagnostics, translation and subtitle rendering. The raw events remain
/// available for diagnostics, but never become translation-facing IDs.
class TranscriptAssembler {
  TranscriptAssembler({this.minimumConfidence = 0.0});

  final double minimumConfidence;
  final Map<String, RecognitionEvent> _rawEvents = {};
  List<TranscriptSegment> _segments = const [];
  String? _sessionId;
  int _nextSegmentNumber = 1;

  List<RecognitionEvent> get rawEvents => List.unmodifiable(
        _rawEvents.values.toList()
          ..sort((left, right) => _compareEvents(left, right)),
      );

  List<TranscriptSegment> get segments => List.unmodifiable(_segments);

  void reset({required String sessionId}) {
    _sessionId = sessionId;
    _rawEvents.clear();
    _segments = const [];
    _nextSegmentNumber = 1;
  }

  /// Adds a final raw event and rebuilds the deterministic assembled timeline.
  /// Late or out-of-order arrivals are accepted; already matched timeline IDs
  /// stay stable so a later translation can remain attached.
  List<TranscriptSegment> add(RecognitionEvent event) {
    if (event.kind != RecognitionKind.finalResult ||
        event.text.trim().isEmpty ||
        (event.confidence != null && event.confidence! < minimumConfidence)) {
      return segments;
    }
    if (_sessionId != event.sessionId) reset(sessionId: event.sessionId);
    _rawEvents[event.segmentId] = event;
    _segments = _assemble();
    return segments;
  }

  List<TranscriptSegment> _assemble() {
    final groups = <_RawGroup>[];
    for (final event in rawEvents) {
      final duplicate = _bestDuplicateGroup(groups, event);
      if (duplicate != null) {
        duplicate.add(event);
      } else {
        groups.add(_RawGroup(event));
      }
    }

    final previous = List<TranscriptSegment>.of(_segments);
    final usedPreviousIds = <String>{};
    return List<TranscriptSegment>.unmodifiable(groups.map((group) {
      final matched = _bestPreviousMatch(group, previous, usedPreviousIds);
      final id = matched?.id ??
          'seg-${(_nextSegmentNumber++).toString().padLeft(6, '0')}';
      if (matched != null) usedPreviousIds.add(matched.id);
      return group.toSegment(id);
    }));
  }

  _RawGroup? _bestDuplicateGroup(
    List<_RawGroup> groups,
    RecognitionEvent event,
  ) {
    _RawGroup? best;
    var bestScore = 0.0;
    for (final group in groups.reversed) {
      final score = group.duplicateScore(event);
      if (score > bestScore) {
        best = group;
        bestScore = score;
      }
    }
    return bestScore >= 0.82 ? best : null;
  }

  TranscriptSegment? _bestPreviousMatch(
    _RawGroup group,
    List<TranscriptSegment> previous,
    Set<String> usedIds,
  ) {
    TranscriptSegment? best;
    var bestScore = 0.0;
    for (final segment in previous) {
      if (usedIds.contains(segment.id)) continue;
      final timeScore = _timeOverlapRatio(
        group.startMs,
        group.endMs,
        segment.startMs,
        segment.endMs,
      );
      final textScore =
          _textSimilarity(group.normalizedText, _normalizeText(segment.text));
      final score = timeScore * 0.6 + textScore * 0.4;
      if (timeScore > 0 && textScore >= 0.82 && score > bestScore) {
        best = segment;
        bestScore = score;
      }
    }
    return best;
  }
}

class _RawGroup {
  _RawGroup(RecognitionEvent event) : _events = [event];

  final List<RecognitionEvent> _events;

  int get startMs =>
      _events.map((event) => event.start.inMilliseconds).reduce(_min);
  int get endMs =>
      _events.map((event) => event.end.inMilliseconds).reduce(_max);
  String get normalizedText => _normalizeText(_best.text);

  RecognitionEvent get _best {
    final ordered = List<RecognitionEvent>.of(_events)
      ..sort((left, right) {
        final confidence =
            (right.confidence ?? 0).compareTo(left.confidence ?? 0);
        if (confidence != 0) return confidence;
        final start = left.start.compareTo(right.start);
        if (start != 0) return start;
        final end = left.end.compareTo(right.end);
        if (end != 0) return end;
        return left.segmentId.compareTo(right.segmentId);
      });
    return ordered.first;
  }

  double duplicateScore(RecognitionEvent event) {
    final overlap = _timeOverlapRatio(
      startMs,
      endMs,
      event.start.inMilliseconds,
      event.end.inMilliseconds,
    );
    if (overlap < 0.5) return 0;
    return _textSimilarity(normalizedText, _normalizeText(event.text));
  }

  void add(RecognitionEvent event) => _events.add(event);

  TranscriptSegment toSegment(String id) {
    final best = _best;
    return TranscriptSegment(
      id: id,
      startMs: startMs,
      endMs: endMs,
      text: best.text,
      language: best.language,
      confidence: best.confidence,
      status: TranscriptSegmentStatus.timelineFinal,
      sourceWindows: _events
          .map((event) => event.sourceWindowId ?? event.segmentId)
          .toSet()
          .toList()
        ..sort(),
    );
  }
}

int _min(int left, int right) => left < right ? left : right;
int _max(int left, int right) => left > right ? left : right;

int _compareEvents(RecognitionEvent left, RecognitionEvent right) {
  final start = left.start.compareTo(right.start);
  if (start != 0) return start;
  final end = left.end.compareTo(right.end);
  return end != 0 ? end : left.segmentId.compareTo(right.segmentId);
}

double _timeOverlapRatio(
    int leftStart, int leftEnd, int rightStart, int rightEnd) {
  final overlap = _min(leftEnd, rightEnd) - _max(leftStart, rightStart);
  if (overlap <= 0) return 0;
  final shorter = _min(leftEnd - leftStart, rightEnd - rightStart);
  return shorter <= 0 ? 0 : overlap / shorter;
}

String _normalizeText(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

double _textSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  if (left.contains(right) || right.contains(left)) {
    return _min(left.length, right.length) / _max(left.length, right.length);
  }
  final leftTokens = left.split(' ').toSet();
  final rightTokens = right.split(' ').toSet();
  final union = leftTokens.union(rightTokens).length;
  return union == 0 ? 0 : leftTokens.intersection(rightTokens).length / union;
}
