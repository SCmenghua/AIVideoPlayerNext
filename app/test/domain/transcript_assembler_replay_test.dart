@Tags(['replay'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/domain/subtitles/transcript_assembler.dart';

/// Replays recognition events captured from real media through the real
/// assembler and prints the subtitles a viewer would see.
///
/// This is a harness, not an assertion: it exists so subtitle length and
/// timing can be judged against actual output instead of guessed at. Point
/// [ASSEMBLER_REPLAY] at a jsonl file of events to use it:
///
///   flutter test --tags replay --dart-define=ASSEMBLER_REPLAY=<path> \
///     test/domain/transcript_assembler_replay_test.dart
const replayPath = String.fromEnvironment('ASSEMBLER_REPLAY');

int displayWidth(String text) {
  var width = 0;
  for (final rune in text.runes) {
    final wide = rune >= 0x1100 &&
        (rune <= 0x115F ||
            (rune >= 0x2E80 && rune <= 0xA4CF) ||
            (rune >= 0xAC00 && rune <= 0xD7A3) ||
            (rune >= 0xF900 && rune <= 0xFAFF) ||
            (rune >= 0xFE30 && rune <= 0xFE6F) ||
            (rune >= 0xFF00 && rune <= 0xFF60) ||
            (rune >= 0xFFE0 && rune <= 0xFFE6) ||
            (rune >= 0x20000 && rune <= 0x3FFFD));
    width += wide ? 2 : 1;
  }
  return width;
}

void main() {
  test('replays captured recognition events through the assembler', () {
    if (replayPath.isEmpty) {
      markTestSkipped('set --dart-define=ASSEMBLER_REPLAY=<events.jsonl>');
      return;
    }
    final assembler = TranscriptAssembler();
    for (final line in File(replayPath).readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final row = jsonDecode(line) as Map<String, dynamic>;
      assembler.add(RecognitionEvent(
        sessionId: 'replay',
        segmentId: row['segmentId'] as String,
        start: Duration(milliseconds: row['startMs'] as int),
        end: Duration(milliseconds: row['endMs'] as int),
        text: row['text'] as String,
        language: row['language'] as String,
        kind: RecognitionKind.finalResult,
        source: RecognitionSource.whisperCpp,
        confidence: (row['confidence'] as num?)?.toDouble(),
        sourceWindowId: row['window'] as String?,
      ));
    }

    final segments = assembler.segments;
    stdout.writeln('  时长   宽度  字幕');
    var overLong = 0;
    var overWide = 0;
    for (final segment in segments) {
      final seconds = (segment.endMs - segment.startMs) / 1000.0;
      final width = displayWidth(segment.text);
      if (seconds > 6) overLong++;
      if (width > 36) overWide++;
      stdout.writeln('  ${seconds.toStringAsFixed(2).padLeft(5)}s '
          '${width.toString().padLeft(4)}  '
          '[${(segment.startMs / 1000).toStringAsFixed(2)}-'
          '${(segment.endMs / 1000).toStringAsFixed(2)}] ${segment.text}');
    }
    stdout.writeln('  共 ${segments.length} 条；>6 秒 $overLong 条；>36 格 $overWide 条');
  });
}
