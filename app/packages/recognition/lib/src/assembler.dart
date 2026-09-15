import 'gate.dart';
import 'segmenter.dart';
import 'text.dart';
import 'transcript.dart';

/// Turns accepted segments into subtitle lines: joins fragments that read as
/// one sentence, splits run-on output at sentence ends, wraps to a readable
/// width, and replaces whatever an earlier pass produced for the same span.
class TranscriptAssembler {
  TranscriptAssembler({
    this.maxMergedWidth = 72,
    this.maxLineWidth = 36,
    this.mergeGap = const Duration(milliseconds: 300),
    this.minLineMs = 400,
  });

  final int maxMergedWidth;
  final int maxLineWidth;
  final Duration mergeGap;
  final int minLineMs;

  Transcript _transcript = Transcript.empty;
  int _nextId = 1;

  Transcript get transcript => _transcript;

  void reset() {
    _transcript = Transcript.empty;
    _nextId = 1;
  }

  Transcript addWindow(SpeechWindow window, List<AcceptedSegment> accepted) {
    final merged = _merge(accepted);
    final lines = <_Line>[];
    for (final fragment in merged) {
      lines.addAll(_split(fragment));
    }
    final kept = _transcript.segments.where((segment) {
      final overlap = _overlapMs(segment.startMs, segment.endMs,
          window.mediaStart.inMilliseconds, window.mediaEnd.inMilliseconds);
      return overlap * 2 < segment.durationMs || segment.durationMs == 0 && overlap == 0;
    }).toList();
    for (final line in lines) {
      kept.add(TranscriptSegment(
        id: 'seg-${(_nextId++).toString().padLeft(6, '0')}',
        startMs: line.startMs,
        endMs: line.endMs,
        text: line.text,
        language: line.language,
        windowId: window.id,
      ));
    }
    _transcript = Transcript(kept, revision: _transcript.revision + 1);
    return _transcript;
  }

  List<_Line> _merge(List<AcceptedSegment> accepted) {
    final result = <_Line>[];
    for (final segment in accepted) {
      final line = _Line(segment.startMs, segment.endMs, segment.text, segment.language);
      if (result.isEmpty) {
        result.add(line);
        continue;
      }
      final previous = result.last;
      final gap = line.startMs - previous.endMs;
      final separator = containsCjk(previous.text) || containsCjk(line.text) ? '' : ' ';
      final joined = '${previous.text}$separator${line.text}';
      final continues = !endsSentence(previous.text) &&
          gap <= mergeGap.inMilliseconds &&
          previous.language == line.language &&
          displayWidth(joined) <= maxMergedWidth;
      if (continues) {
        result[result.length - 1] = _Line(previous.startMs, line.endMs, joined, previous.language);
      } else {
        result.add(line);
      }
    }
    return result;
  }

  List<_Line> _split(_Line fragment) {
    final units = <String>[];
    for (final sentence in splitSentences(fragment.text)) {
      units.addAll(wrapByWidth(sentence, maxLineWidth));
    }
    if (units.length <= 1) {
      return [fragment.copyWith(text: units.isEmpty ? fragment.text : units.single)];
    }
    final widths = units.map(displayWidth).toList(growable: false);
    final totalWidth = widths.fold<int>(0, (sum, width) => sum + width);
    final span = fragment.endMs - fragment.startMs;
    final result = <_Line>[];
    var cursor = fragment.startMs;
    for (var i = 0; i < units.length; i++) {
      final isLast = i == units.length - 1;
      var end = isLast
          ? fragment.endMs
          : cursor + (span * widths[i] / totalWidth).round();
      if (end - cursor < minLineMs) end = cursor + minLineMs;
      if (end > fragment.endMs) end = fragment.endMs;
      if (end <= cursor) end = cursor + 1;
      result.add(_Line(cursor, end, units[i], fragment.language));
      cursor = end;
    }
    return result;
  }
}

class _Line {
  const _Line(this.startMs, this.endMs, this.text, this.language);

  final int startMs;
  final int endMs;
  final String text;
  final String language;

  _Line copyWith({String? text}) => _Line(startMs, endMs, text ?? this.text, language);
}

int _overlapMs(int aStart, int aEnd, int bStart, int bEnd) {
  final start = aStart > bStart ? aStart : bStart;
  final end = aEnd < bEnd ? aEnd : bEnd;
  return end > start ? end - start : 0;
}
