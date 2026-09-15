class TranscriptSegment {
  const TranscriptSegment({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.language,
    required this.windowId,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String text;
  final String language;
  final String windowId;

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);
  int get durationMs => endMs - startMs;

  TranscriptSegment copyWith({
    String? id,
    int? startMs,
    int? endMs,
    String? text,
    String? language,
    String? windowId,
  }) =>
      TranscriptSegment(
        id: id ?? this.id,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        text: text ?? this.text,
        language: language ?? this.language,
        windowId: windowId ?? this.windowId,
      );

  @override
  String toString() => 'TranscriptSegment($id $startMs-$endMs "$text")';
}

/// Immutable, time-ordered transcript of one media session.
class Transcript {
  Transcript(List<TranscriptSegment> segments, {required this.revision})
      : segments = List<TranscriptSegment>.unmodifiable(
          List<TranscriptSegment>.of(segments)
            ..sort((a, b) {
              final start = a.startMs.compareTo(b.startMs);
              return start != 0 ? start : a.endMs.compareTo(b.endMs);
            }),
        );

  static final Transcript empty = Transcript(const [], revision: 0);

  final List<TranscriptSegment> segments;
  final int revision;

  bool get isEmpty => segments.isEmpty;

  /// The segment to show at [position]. A finished segment keeps showing for
  /// [hold] unless a later one has started, so late-arriving or short lines
  /// are not lost.
  TranscriptSegment? at(
    Duration position, {
    Duration hold = const Duration(milliseconds: 2500),
  }) {
    final ms = position.inMilliseconds;
    TranscriptSegment? latest;
    for (final segment in segments) {
      if (segment.startMs > ms) break;
      latest = segment;
    }
    if (latest == null) return null;
    if (ms < latest.endMs) return latest;
    if (ms - latest.endMs < hold.inMilliseconds) return latest;
    return null;
  }

  List<TranscriptSegment> between(Duration from, Duration to) {
    final fromMs = from.inMilliseconds;
    final toMs = to.inMilliseconds;
    return segments
        .where((segment) => segment.endMs > fromMs && segment.startMs < toMs)
        .toList(growable: false);
  }

  TranscriptSegment? byId(String id) {
    for (final segment in segments) {
      if (segment.id == id) return segment;
    }
    return null;
  }
}
