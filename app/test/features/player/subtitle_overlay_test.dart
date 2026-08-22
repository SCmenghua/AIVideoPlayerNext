import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/subtitles/transcript_document.dart';
import 'package:ai_video_player_next/features/player/subtitle_overlay.dart';
import 'package:ai_video_player_next/features/settings/app_settings.dart';

void main() {
  const segment = TranscriptSegment(
    id: 'segment-1',
    startMs: 1000,
    endMs: 3000,
    text: 'The source subtitle.',
    language: 'en',
    status: TranscriptSegmentStatus.timelineFinal,
    sourceWindows: ['window-1'],
  );

  test('selects translated text for the active media segment', () {
    final document = TranscriptDocument.empty(sessionId: 'session-1')
        .upsertSegment(segment)
        .upsertTranslation(const TranscriptTranslation(
          segmentId: 'segment-1',
          targetLanguage: 'zh-CN',
          text: '这是一条翻译字幕。',
          status: TranscriptTranslationStatus.translated,
        ));

    final subtitle = subtitleAt(document, const Duration(seconds: 2));

    expect(subtitle?.translationText, '这是一条翻译字幕。');
    expect(subtitle?.sourceText, 'The source subtitle.');
  });

  test('falls back to source text while translation is unavailable', () {
    final document = TranscriptDocument.empty(sessionId: 'session-1')
        .upsertSegment(segment)
        .upsertTranslation(const TranscriptTranslation(
          segmentId: 'segment-1',
          targetLanguage: 'zh-CN',
          text: '',
          status: TranscriptTranslationStatus.translating,
        ));

    final subtitle = subtitleAt(document, const Duration(seconds: 2));

    expect(subtitle?.translationText, isNull);
    expect(subtitle?.sourceText, 'The source subtitle.');
  });

  testWidgets('renders translation and source text as an overlay',
      (tester) async {
    final document = TranscriptDocument.empty(sessionId: 'session-1')
        .upsertSegment(segment)
        .upsertTranslation(const TranscriptTranslation(
          segmentId: 'segment-1',
          targetLanguage: 'zh-CN',
          text: '这是一条翻译字幕。',
          status: TranscriptTranslationStatus.translated,
        ));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SubtitleOverlay(
          document: document,
          position: const Duration(seconds: 2),
        ),
      ),
    ));

    expect(find.byKey(const Key('subtitle-primary')), findsOneWidget);
    expect(find.text('这是一条翻译字幕。'), findsOneWidget);
    expect(find.byKey(const Key('subtitle-source')), findsOneWidget);
    expect(find.text('The source subtitle.'), findsOneWidget);
  });

  testWidgets('renders only the original in original mode', (tester) async {
    final document = TranscriptDocument.empty(sessionId: 'session-1')
        .upsertSegment(segment)
        .upsertTranslation(const TranscriptTranslation(
          segmentId: 'segment-1',
          targetLanguage: 'zh-CN',
          text: '这是一条翻译字幕。',
          status: TranscriptTranslationStatus.translated,
        ));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SubtitleOverlay(
          document: document,
          position: const Duration(seconds: 2),
          displayMode: SubtitleDisplayMode.original,
        ),
      ),
    ));

    expect(find.text('The source subtitle.'), findsOneWidget);
    expect(find.text('这是一条翻译字幕。'), findsNothing);
    expect(find.byKey(const Key('subtitle-source')), findsNothing);
  });

  testWidgets('shows a pending state in translation mode', (tester) async {
    final document =
        TranscriptDocument.empty(sessionId: 'session-1').upsertSegment(segment);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SubtitleOverlay(
          document: document,
          position: const Duration(seconds: 2),
          displayMode: SubtitleDisplayMode.translation,
        ),
      ),
    ));

    expect(find.text('翻译准备中...'), findsOneWidget);
    expect(find.text('The source subtitle.'), findsNothing);
  });
}
