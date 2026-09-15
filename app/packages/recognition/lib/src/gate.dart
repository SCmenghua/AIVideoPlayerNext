import 'config.dart';
import 'engine.dart';
import 'segmenter.dart';
import 'text.dart';

/// A raw segment that passed the gate, placed on the media timeline.
class AcceptedSegment {
  const AcceptedSegment({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.language,
    required this.avgLogprob,
    required this.noSpeechProb,
    required this.repetition,
    required this.windowId,
  });

  final int startMs;
  final int endMs;
  final String text;
  final String language;
  final double avgLogprob;
  final double noSpeechProb;
  final double repetition;
  final String windowId;
}

class DroppedSegment {
  const DroppedSegment(this.segment, this.reason);

  final RawSegment segment;
  final String reason;
}

class GateResult {
  const GateResult({required this.accepted, required this.dropped});

  final List<AcceptedSegment> accepted;
  final List<DroppedSegment> dropped;

  String get text => accepted.map((segment) => segment.text).join(' ');
}

/// Quality gate between the decoder and the transcript. Whisper's own
/// thresholds run natively; this layer catches what they let through:
/// degenerate loops, stock hallucinated phrases, and a whole window that
/// merely repeats the previous one.
class SegmentGate {
  SegmentGate(this.options);

  final GateOptions options;
  String? _previousWindowText;
  late final Set<String> _blocked =
      options.blockedPhrases.map(normalizeForComparison).toSet();

  void reset() => _previousWindowText = null;

  GateResult apply(
    SpeechWindow window,
    List<RawSegment> segments, {
    String? pinnedLanguage,
  }) {
    final accepted = <AcceptedSegment>[];
    final dropped = <DroppedSegment>[];
    final base = window.mediaStart.inMilliseconds;
    final pad = const Duration(milliseconds: 200).inMilliseconds;
    final endMsLimit = window.mediaEnd.inMilliseconds;
    final lowMs = (window.speechStart.inMilliseconds - pad).clamp(base, endMsLimit).toInt();
    final highMs = (window.speechEnd.inMilliseconds + pad).clamp(base, endMsLimit).toInt();

    final ordered = List<RawSegment>.of(segments)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    for (final segment in ordered) {
      final text = segment.text.trim();
      final normalized = normalizeForComparison(text);
      String? reason;
      if (text.isEmpty || normalized.isEmpty) {
        reason = 'empty';
      } else if (_blocked.contains(normalized)) {
        reason = 'blocked';
      } else if (segment.repetition > options.maxRepetition) {
        reason = 'repetition';
      } else if (segment.noSpeechProb >= options.maxNoSpeechProbability) {
        reason = 'noSpeech';
      } else if (pinnedLanguage != null &&
          pinnedLanguage != 'auto' &&
          segment.language.isNotEmpty &&
          segment.language != pinnedLanguage) {
        reason = 'language';
      }
      if (reason != null) {
        dropped.add(DroppedSegment(segment, reason));
        continue;
      }
      var startMs = (base + segment.startMs).clamp(lowMs, highMs).toInt();
      var endMs = (base + segment.endMs).clamp(lowMs, highMs).toInt();
      if (endMs <= startMs) {
        // Whisper anchored the segment entirely in padding; keep it only if
        // it has some plausible span inside the window.
        endMs = (startMs + 300).clamp(lowMs, endMsLimit).toInt();
        if (endMs <= startMs) {
          dropped.add(DroppedSegment(segment, 'outsideSpeech'));
          continue;
        }
      }
      if (accepted.isNotEmpty && startMs < accepted.last.endMs) {
        startMs = accepted.last.endMs;
        if (endMs <= startMs) {
          dropped.add(DroppedSegment(segment, 'overlap'));
          continue;
        }
      }
      accepted.add(AcceptedSegment(
        startMs: startMs,
        endMs: endMs,
        text: text,
        language: segment.language,
        avgLogprob: segment.avgLogprob,
        noSpeechProb: segment.noSpeechProb,
        repetition: segment.repetition,
        windowId: window.id,
      ));
    }

    final windowText = accepted.map((segment) => normalizeForComparison(segment.text)).join();
    if (windowText.isNotEmpty && windowText == _previousWindowText) {
      for (final segment in accepted) {
        dropped.add(DroppedSegment(
          RawSegment(
            index: -1,
            startMs: segment.startMs - base,
            endMs: segment.endMs - base,
            text: segment.text,
            language: segment.language,
            avgLogprob: segment.avgLogprob,
            noSpeechProb: segment.noSpeechProb,
            repetition: segment.repetition,
            tokenCount: 0,
          ),
          'repeatedWindow',
        ));
      }
      _previousWindowText = null;
      return GateResult(accepted: const [], dropped: dropped);
    }
    _previousWindowText = windowText.isEmpty ? null : windowText;
    return GateResult(accepted: accepted, dropped: dropped);
  }
}
