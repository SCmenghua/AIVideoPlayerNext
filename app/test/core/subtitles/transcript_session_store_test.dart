import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/core/subtitles/transcript_session_store.dart';
import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/domain/subtitles/transcript_document.dart';

TranscriptSegment _segment(String id) => TranscriptSegment(
      id: id,
      startMs: 0,
      endMs: 1000,
      text: 'hello',
      language: 'en',
      status: TranscriptSegmentStatus.timelineFinal,
      sourceWindows: const ['session-1-window-0'],
    );

RecognitionEvent _rawEvent() => const RecognitionEvent(
      sessionId: 'session-1',
      segmentId: 'session-1-window-0-segment-0',
      start: Duration(seconds: 2),
      end: Duration(seconds: 4),
      text: 'raw whisper output',
      language: 'en',
      kind: RecognitionKind.finalResult,
      source: RecognitionSource.whisperCpp,
      confidence: 0.91,
      sourceWindowId: 'session-1-window-0',
      sourceSegmentIndex: 0,
    );

void main() {
  test('writes a temporary session snapshot after memory updates', () async {
    final root = await Directory.systemTemp.createTemp('transcript-store-test');
    final store = TranscriptSessionStore(
      rootDirectory: root,
      writeDebounce: Duration.zero,
    );
    addTearDown(() async {
      await store.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await store.beginSession('session-1');
    expect(store.upsertSegment(_segment('seg-1')), isTrue);
    await store.flush();

    final snapshot = store.snapshotFile!;
    final content =
        jsonDecode(await snapshot.readAsString()) as Map<String, dynamic>;
    expect(content['sessionId'], 'session-1');
    expect((content['segments'] as List).single['id'], 'seg-1');
  });

  test('deletes an old session and does not let it affect a new session',
      () async {
    final root = await Directory.systemTemp.createTemp('transcript-store-test');
    final store = TranscriptSessionStore(
      rootDirectory: root,
      writeDebounce: Duration.zero,
    );
    addTearDown(() async {
      await store.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await store.beginSession('old-session');
    store.upsertSegment(_segment('old-segment'));
    await store.beginSession('new-session');
    store.upsertSegment(_segment('new-segment'));
    await store.flush();

    expect(
        await Directory('${root.path}${Platform.pathSeparator}old-session')
            .exists(),
        isFalse);
    final content = jsonDecode(await store.snapshotFile!.readAsString())
        as Map<String, dynamic>;
    expect(content['sessionId'], 'new-session');
    expect((content['segments'] as List).single['id'], 'new-segment');
  });

  test('records test-build raw Whisper evidence separately from the timeline',
      () async {
    final root = await Directory.systemTemp.createTemp('transcript-store-test');
    final store = TranscriptSessionStore(
      rootDirectory: root,
      writeDebounce: Duration.zero,
      retainRawEvidence: true,
    );
    addTearDown(() async {
      await store.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await store.beginSession('session-1');
    expect(store.recordRawRecognition(_rawEvent()), isTrue);
    await store.flush();

    final raw = jsonDecode(await store.rawSnapshotFile!.readAsString())
        as Map<String, dynamic>;
    final event = (raw['events'] as List).single as Map<String, dynamic>;
    expect(raw['sessionId'], 'session-1');
    expect(event['rawId'], 'session-1-window-0-segment-0');
    expect(event['sourceWindowId'], 'session-1-window-0');
    expect(event['sourceSegmentIndex'], 0);
    expect(event['startMs'], 2000);
    expect(event['endMs'], 4000);
  });

  test('can disable raw evidence retention for release builds', () async {
    final root = await Directory.systemTemp.createTemp('transcript-store-test');
    final store = TranscriptSessionStore(
      rootDirectory: root,
      writeDebounce: Duration.zero,
      retainRawEvidence: false,
    );
    addTearDown(() async {
      await store.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await store.beginSession('session-1');
    expect(store.recordRawRecognition(_rawEvent()), isFalse);
    await store.flush();

    expect(store.rawSnapshotFile, isNull);
    expect(
      await File('${root.path}${Platform.pathSeparator}session-1'
              '${Platform.pathSeparator}transcript.raw.json')
          .exists(),
      isFalse,
    );
  });
}
