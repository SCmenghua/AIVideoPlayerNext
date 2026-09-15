import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/subtitles/transcript_document.dart';

void main() {
  const segment = TranscriptSegment(
    id: 'seg-000001',
    startMs: 4000,
    endMs: 6000,
    text: 'I love you.',
    language: 'en',
    status: TranscriptSegmentStatus.timelineFinal,
    sourceWindows: ['g1-w00000'],
  );

  test('serializes stable segments with millisecond media time', () {
    final document = TranscriptDocument.empty(sessionId: 'session-1').upsertSegment(segment);

    expect(document.revision, 1);
    expect(document.segments.single.startMs, 4000);
    expect(document.segments.single.endMs, 6000);
    expect(document.segments.single.speaker, isNull);
    expect(document.segments.single.sourceWindows, ['g1-w00000']);

    final restored = TranscriptDocument.fromJson(document.toJson());
    expect(restored.toJson(), document.toJson());
  });

  test('translation backfill retains the original segment and time range', () {
    final original = TranscriptDocument.empty(sessionId: 'session-1').upsertSegment(segment);
    final translated = original.upsertTranslation(const TranscriptTranslation(
      segmentId: 'seg-000001',
      targetLanguage: 'zh-CN',
      text: '我喜欢你。',
      status: TranscriptTranslationStatus.translated,
    ));

    expect(translated.segments.single.text, 'I love you.');
    expect(translated.segments.single.startMs, 4000);
    expect(translated.translations.single.text, '我喜欢你。');
  });

  test('replacing segments drops translations whose text changed', () {
    final document = TranscriptDocument.empty(sessionId: 'session-1')
        .upsertSegment(segment)
        .upsertTranslation(const TranscriptTranslation(
          segmentId: 'seg-000001',
          targetLanguage: 'zh-CN',
          text: '我喜欢你。',
          status: TranscriptTranslationStatus.translated,
          sourceText: 'I love you.',
        ));
    final same = document.replaceSegments([segment]);
    expect(same.translations, hasLength(1));
    final changed = document.replaceSegments([
      TranscriptSegment(
        id: segment.id,
        startMs: segment.startMs,
        endMs: segment.endMs,
        text: 'I love you too.',
        language: segment.language,
        status: segment.status,
        sourceWindows: segment.sourceWindows,
      ),
    ]);
    expect(changed.translations, isEmpty);
  });

  test('time lookup uses start inclusive and end exclusive media ranges', () {
    final document = TranscriptDocument.empty(sessionId: 'session-1').upsertSegment(segment);

    expect(document.at(const Duration(seconds: 4)), hasLength(1));
    expect(document.at(const Duration(seconds: 5, milliseconds: 999)), hasLength(1));
    expect(document.at(const Duration(seconds: 6)), isEmpty);
  });
}
