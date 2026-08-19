import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/recognition_media_source.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';

void main() {
  test('copies player handoff into an independent recognition source', () {
    final playerSource = MediaSource(
      uri: Uri.parse('https://media.example/video.mp4'),
      title: 'video',
      kind: MediaSourceKind.browserHandoff,
      originPage: Uri.parse('https://example/watch'),
      requestHeaders: const {'Referer': 'https://example/watch'},
      browserSessionId: 'browser-1',
    );

    final source = RecognitionMediaSource.fromPlayerSource(playerSource);

    expect(source.uri, playerSource.uri);
    expect(source.isNetwork, isTrue);
    expect(source.requestHeaders['Referer'], 'https://example/watch');
    expect(
        identical(source.requestHeaders, playerSource.requestHeaders), isFalse);
  });

  test('cursor merges ranges and advances only through contiguous bytes', () {
    final cursor = RecognitionMediaCursor(
      sessionId: 'session-1',
      mode: RecognitionMediaReadMode.progressiveSegmentCache,
    );

    cursor.recordDownloadedSegment(start: 100, endExclusive: 200);
    expect(cursor.downloadedThrough, 0);
    cursor.recordDownloadedSegment(start: 0, endExclusive: 100);
    expect(cursor.downloadedThrough, 200);
    cursor.recordDownloadedSegment(start: 200, endExclusive: 250);
    expect(cursor.segments, hasLength(1));
    expect(cursor.downloadedBytes, 250);
  });

  test('cursor enforces byte and segment bounds', () {
    final cursor = RecognitionMediaCursor(
      sessionId: 'session-1',
      mode: RecognitionMediaReadMode.progressiveSegmentCache,
      maxBytes: 10,
      maxSegments: 2,
    );

    cursor.recordDownloadedSegment(start: 0, endExclusive: 6);
    cursor.recordDownloadedSegment(start: 20, endExclusive: 26);
    expect(cursor.downloadedBytes, lessThanOrEqualTo(10));
    expect(cursor.segments.length, lessThanOrEqualTo(2));
  });

  test('cached decoder cannot report beyond the downloaded high water mark',
      () {
    final cursor = RecognitionMediaCursor(
      sessionId: 'session-1',
      mode: RecognitionMediaReadMode.progressiveSegmentCache,
    );
    cursor.recordDownloadedSegment(start: 0, endExclusive: 100);

    expect(() => cursor.recordDecodedThrough(101), throwsStateError);
    cursor.recordDecodedThrough(100);
    expect(cursor.decodedThrough, 100);
  });
}
