import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/domain/subtitles/transcript_document.dart';

void main() {
  const event = RecognitionEvent(
    sessionId: 'session-1',
    segmentId: 'session-1-window-0-segment-0',
    start: Duration(seconds: 4),
    end: Duration(seconds: 6),
    text: 'I love you.',
    language: 'en',
    kind: RecognitionKind.finalResult,
    source: RecognitionSource.whisperCpp,
    confidence: 0.94,
    sourceWindowId: 'session-1-window-0',
    sourceSegmentIndex: 0,
  );

  test('serializes stable segments with millisecond media time', () {
    final document = TranscriptDocument.empty(sessionId: 'session-1')
        .upsertSegment(TranscriptSegment.fromRecognitionEvent(event));

    expect(document.revision, 1);
    expect(document.segments.single.startMs, 4000);
    expect(document.segments.single.endMs, 6000);
    expect(document.segments.single.speaker, isNull);
    expect(document.segments.single.sourceWindows, ['session-1-window-0']);

    final restored = TranscriptDocument.fromJson(document.toJson());
    expect(restored.toJson(), document.toJson());
  });

  test('translation backfill retains the original segment and time range', () {
    final original = TranscriptDocument.empty(sessionId: 'session-1')
        .upsertSegment(TranscriptSegment.fromRecognitionEvent(event));
    final translated = original.upsertTranslation(const TranscriptTranslation(
      segmentId: 'session-1-window-0-segment-0',
      targetLanguage: 'zh-CN',
      text: '我喜欢你。',
      status: TranscriptTranslationStatus.translated,
    ));

    expect(translated.segments.single.text, 'I love you.');
    expect(translated.segments.single.startMs, 4000);
    expect(translated.translations.single.text, '我喜欢你。');
  });

  test('time lookup uses start inclusive and end exclusive media ranges', () {
    final document = TranscriptDocument.empty(sessionId: 'session-1')
        .upsertSegment(TranscriptSegment.fromRecognitionEvent(event));

    expect(document.at(const Duration(seconds: 4)), hasLength(1));
    expect(document.at(const Duration(seconds: 5, milliseconds: 999)),
        hasLength(1));
    expect(document.at(const Duration(seconds: 6)), isEmpty);
  });
}
