import 'dart:collection';

import '../player/player_service.dart';

/// Describes the media input owned by the background recognition pipeline.
///
/// The player and recognizer may share a transient browser authorization
/// context, but they do not share a reader, playback clock, or seek operation.
class RecognitionMediaSource {
  RecognitionMediaSource({
    required this.uri,
    required this.title,
    required this.kind,
    this.originPage,
    Map<String, String> requestHeaders = const {},
    this.browserSessionId,
  }) : requestHeaders = UnmodifiableMapView(Map.of(requestHeaders));

  factory RecognitionMediaSource.fromPlayerSource(MediaSource source) =>
      RecognitionMediaSource(
        uri: source.uri,
        title: source.title,
        kind: source.kind,
        originPage: source.originPage,
        requestHeaders: source.requestHeaders,
        browserSessionId: source.browserSessionId,
      );

  final Uri uri;
  final String title;
  final MediaSourceKind kind;
  final Uri? originPage;
  final Map<String, String> requestHeaders;
  final String? browserSessionId;

  bool get isNetwork => uri.scheme == 'http' || uri.scheme == 'https';
  bool get isLocalFile => uri.scheme == 'file';
}

enum RecognitionMediaReadMode {
  localFile,
  directNetworkFallback,
  progressiveSegmentCache,
}

/// The bounded ledger shared by a recognition downloader and decoder.
///
/// Actual file/network workers publish state here. It deliberately contains no
/// socket, file handle, or player object, keeping those consumers isolated.
class RecognitionMediaCursor {
  RecognitionMediaCursor({
    required this.sessionId,
    required this.mode,
    this.maxBytes = 256 * 1024 * 1024,
    this.maxSegments = 128,
  }) : _segments = Queue<RecognitionMediaSegment>();

  final String sessionId;
  final RecognitionMediaReadMode mode;
  final int maxBytes;
  final int maxSegments;
  final Queue<RecognitionMediaSegment> _segments;
  int _downloadedBytes = 0;
  int _downloadedThrough = 0;
  int _decodedThrough = 0;

  UnmodifiableListView<RecognitionMediaSegment> get segments =>
      UnmodifiableListView(_segments);
  int get downloadedBytes => _downloadedBytes;
  int get downloadedThrough => _downloadedThrough;
  int get decodedThrough => _decodedThrough;

  /// Adds a persisted byte segment and advances only the contiguous range.
  void recordDownloadedSegment({
    required int start,
    required int endExclusive,
  }) {
    if (start < 0 || endExclusive <= start) {
      throw ArgumentError('segment must have a positive non-negative range');
    }
    var merged = RecognitionMediaSegment(start, endExclusive);
    final neighbors = _segments
        .where((existing) => existing.overlapsOrTouches(merged))
        .toList(growable: false);
    for (final neighbor in neighbors) {
      _segments.remove(neighbor);
      merged = RecognitionMediaSegment(
        merged.start < neighbor.start ? merged.start : neighbor.start,
        merged.endExclusive > neighbor.endExclusive
            ? merged.endExclusive
            : neighbor.endExclusive,
      );
    }
    _segments.add(merged);
    _sortSegments();
    _recalculate();
    _trimToLimits();
  }

  void recordDecodedThrough(int endExclusive) {
    if (endExclusive < _decodedThrough) return;
    if (endExclusive > _downloadedThrough &&
        mode != RecognitionMediaReadMode.directNetworkFallback) {
      throw StateError('decoder cannot pass the contiguous downloaded range');
    }
    _decodedThrough = endExclusive;
  }

  bool containsRange({
    required int start,
    required int endExclusive,
  }) =>
      _segments.any(
        (segment) =>
            segment.start <= start && segment.endExclusive >= endExclusive,
      );

  void _sortSegments() {
    final sorted = _segments.toList()
      ..sort((left, right) => left.start.compareTo(right.start));
    _segments
      ..clear()
      ..addAll(sorted);
  }

  void _recalculate() {
    _downloadedBytes = _segments.fold<int>(
      0,
      (sum, value) => sum + value.length,
    );
    _downloadedThrough = 0;
    for (final segment in _segments) {
      if (segment.start > _downloadedThrough) break;
      if (segment.endExclusive > _downloadedThrough) {
        _downloadedThrough = segment.endExclusive;
      }
    }
  }

  void _trimToLimits() {
    while (_segments.length > maxSegments || _downloadedBytes > maxBytes) {
      _segments.removeFirst();
      _recalculate();
    }
  }
}

class RecognitionMediaSegment {
  const RecognitionMediaSegment(this.start, this.endExclusive);

  final int start;
  final int endExclusive;

  int get length => endExclusive - start;

  bool overlapsOrTouches(RecognitionMediaSegment other) =>
      start <= other.endExclusive && other.start <= endExclusive;
}
