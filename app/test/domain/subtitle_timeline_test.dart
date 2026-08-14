import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/domain/subtitles/subtitle_timeline.dart';

void main() {
  test('partial is previewed and final replaces it in history', () {
    final timeline = SubtitleTimeline();
    timeline.apply(const RecognitionEvent(
      sessionId: 's1', segmentId: 'seg1', start: Duration(seconds: 1), end: Duration(seconds: 3),
      text: 'hel', language: 'en', kind: RecognitionKind.partial, source: RecognitionSource.whisperCpp,
    ));
    expect(timeline.partial?.original, 'hel');
    expect(timeline.finals, isEmpty);

    timeline.apply(const RecognitionEvent(
      sessionId: 's1', segmentId: 'seg1', start: Duration(seconds: 1), end: Duration(seconds: 3),
      text: 'hello', language: 'en', kind: RecognitionKind.finalResult, source: RecognitionSource.whisperCpp,
    ));
    expect(timeline.partial, isNull);
    expect(timeline.finals.single.original, 'hello');
  });

  test('position lookup and translation backfill use media time and segment id', () {
    final timeline = SubtitleTimeline();
    timeline.apply(const RecognitionEvent(
      sessionId: 's1', segmentId: 'seg1', start: Duration(seconds: 1), end: Duration(seconds: 3),
      text: 'hello', language: 'en', kind: RecognitionKind.finalResult, source: RecognitionSource.whisperCpp,
    ));
    timeline.applyTranslation('seg1', '你好');
    expect(timeline.at(const Duration(seconds: 2)).single.translation, '你好');
    expect(timeline.at(const Duration(seconds: 4)), isEmpty);
  });

  test('reset isolates sessions', () {
    final timeline = SubtitleTimeline();
    timeline.apply(const RecognitionEvent(
      sessionId: 'old', segmentId: 'old-1', start: Duration.zero, end: Duration(seconds: 1),
      text: 'old', language: 'en', kind: RecognitionKind.finalResult, source: RecognitionSource.whisperCpp,
    ));
    timeline.apply(const RecognitionEvent(
      sessionId: 'new', segmentId: 'new-1', start: Duration.zero, end: Duration(seconds: 1),
      text: 'new', language: 'en', kind: RecognitionKind.finalResult, source: RecognitionSource.whisperCpp,
    ));
    timeline.reset(sessionId: 'new');
    expect(timeline.finals.single.original, 'new');
  });
}
