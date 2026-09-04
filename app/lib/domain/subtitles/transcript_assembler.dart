import '../speech/speech_models.dart';
import 'transcript_document.dart';

/// Converts window-local Whisper output into the stable timeline consumed by
/// diagnostics, translation and subtitle rendering. The raw events remain
/// available for diagnostics, but never become translation-facing IDs.
///
/// Adjacent timeline groups that whisper split mid-sentence at a recognition
/// window boundary are merged back into one sentence before they become
/// segments, so translation sees complete sentences instead of fragments.
class TranscriptAssembler {
  TranscriptAssembler({this.minimumConfidence = 0.0});

  /// Maximum media-time gap between two groups of the same sentence. Groups
  /// that overlap materially come from overlapping windows and must stay
  /// separate so their repeated text is never concatenated.
  static const int _maximumMergeGapMs = 1200;

  /// Upper bound for a merged sentence, in half-width display cells (one cell
  /// for Latin letters, two for full-width kana and kanji). 72 cells is about
  /// 36 Japanese characters, roughly one breath of speech; anything longer
  /// almost certainly spans several turns of dialogue.
  static const int _maximumMergedLength = 72;

  /// Maximum width of one displayed subtitle segment, again in half-width
  /// cells. A Japanese subtitle line is conventionally 13-16 full-width
  /// characters, so 36 cells fits a short sentence without forcing a second
  /// line, while leaving Latin text a full 36 characters.
  static const int _maximumSubtitleLength = 36;

  /// A comma cut is only taken when enough text precedes it, avoiding tiny
  /// fragments after a mid-phrase comma.
  static const int _minimumCommaCutLength = 12;

  /// Overlap length that makes a repeated prefix worth stripping. Shorter runs
  /// happen naturally in Japanese (a repeated 'はい' for example) and must
  /// survive, so the threshold sits above ordinary repetition.
  static const int _minimumRepeatedPrefixLength = 4;

  static const String _terminalPunctuation = '。．｡.！？!?…‥';
  static const String _closingBrackets = '」』”）)】》';
  static const String _phraseBreaks = '、，,';

  /// Japanese endings that cannot close a sentence, so a segment ending on
  /// one is a fragment its neighbour continues. Longest first.
  ///
  /// These are case and conjunctive particles: a line may end on the topic
  /// marker only because the window boundary fell there. The list is kept
  /// tight on purpose - the cost of missing one is two short subtitles where
  /// one would have read better, while the cost of a false match is the
  /// failure this rule exists to prevent.
  static final RegExp _japaneseContinuing = RegExp(
    r'(でも|ながら|ばかり|けれど|について|として|とか|など|まで|より|から'
    r'|だけ|しか|には|では|とは|への|への'
    r'|は|が|を|に|へ|の|も|と|で|て|し)$',
  );

  /// Kana range used to decide whether the Japanese terminal rules apply.
  static final RegExp _kanaPattern = RegExp(r'[぀-ヿ]');

  final double minimumConfidence;
  final Map<String, RecognitionEvent> _rawEvents = {};
  List<TranscriptSegment> _segments = const [];
  String? _sessionId;
  int _nextSegmentNumber = 1;

  List<RecognitionEvent> get rawEvents => List.unmodifiable(
        _rawEvents.values.toList()
          ..sort((left, right) => _compareEvents(left, right)),
      );

  List<TranscriptSegment> get segments => List.unmodifiable(_segments);

  void reset({required String sessionId}) {
    _sessionId = sessionId;
    _rawEvents.clear();
    _segments = const [];
    _nextSegmentNumber = 1;
  }

  /// Adds a final raw event and rebuilds the deterministic assembled timeline.
  /// Late or out-of-order arrivals are accepted; already matched timeline IDs
  /// stay stable so a later translation can remain attached.
  List<TranscriptSegment> add(RecognitionEvent event) {
    if (event.kind != RecognitionKind.finalResult ||
        event.text.trim().isEmpty ||
        (event.confidence != null && event.confidence! < minimumConfidence)) {
      return segments;
    }
    if (_sessionId != event.sessionId) reset(sessionId: event.sessionId);
    _rawEvents[event.segmentId] = event;
    _segments = _assemble();
    return segments;
  }

  List<TranscriptSegment> _assemble() {
    final groups = <_RawGroup>[];
    for (final event in rawEvents) {
      final duplicate = _bestDuplicateGroup(groups, event);
      if (duplicate != null) {
        duplicate.add(event);
      } else {
        groups.add(_RawGroup(event));
      }
    }

    final clusters = <_RawCluster>[];
    for (final group in groups) {
      if (clusters.isNotEmpty && clusters.last.canMerge(group)) {
        clusters.last.add(group);
      } else {
        clusters.add(_RawCluster([group]));
      }
    }

    // Models with light punctuation (e.g. kotoba-whisper) emit whole runs of
    // sentences; split each cluster into subtitle-sized units before stable
    // ID matching so recognition and translation see sentence granularity.
    final units = <_SubtitleUnit>[];
    for (final cluster in clusters) {
      units.addAll(cluster.toSubtitleUnits());
    }

    final previous = List<TranscriptSegment>.of(_segments);
    final usedPreviousIds = <String>{};
    return List<TranscriptSegment>.unmodifiable(units.map((unit) {
      final matched = _bestPreviousMatch(unit, previous, usedPreviousIds);
      final id = matched?.id ??
          'seg-${(_nextSegmentNumber++).toString().padLeft(6, '0')}';
      if (matched != null) usedPreviousIds.add(matched.id);
      return unit.toSegment(id);
    }));
  }

  _RawGroup? _bestDuplicateGroup(
    List<_RawGroup> groups,
    RecognitionEvent event,
  ) {
    _RawGroup? best;
    var bestScore = 0.0;
    for (final group in groups.reversed) {
      final score = group.duplicateScore(event);
      if (score > bestScore) {
        best = group;
        bestScore = score;
      }
    }
    return bestScore >= 0.82 ? best : null;
  }

  TranscriptSegment? _bestPreviousMatch(
    _SubtitleUnit unit,
    List<TranscriptSegment> previous,
    Set<String> usedIds,
  ) {
    TranscriptSegment? best;
    var bestScore = 0.0;
    for (final segment in previous) {
      if (usedIds.contains(segment.id)) continue;
      final timeScore = _timeOverlapRatio(
        unit.startMs,
        unit.endMs,
        segment.startMs,
        segment.endMs,
      );
      final normalized = _normalizeText(segment.text);
      final textScore = _textSimilarity(unit.normalizedText, normalized);
      final score = timeScore * 0.6 + textScore * 0.4;
      // A fragment that grew into a full sentence shares its audio with the
      // previous segment; keeping the ID keeps its pending translation.
      final continues = timeScore >= 0.6 &&
          (unit.normalizedText.startsWith(normalized) ||
              normalized.startsWith(unit.normalizedText));
      if ((timeScore > 0 && textScore >= 0.82 && score > bestScore) ||
          (continues && score > bestScore)) {
        best = segment;
        bestScore = score;
      }
    }
    return best;
  }

  static bool _sameLanguage(String left, String right) {
    if (left.isEmpty || right.isEmpty) return true;
    return left == right;
  }

  /// True when [text] is a fragment that the following group continues.
  ///
  /// With punctuation the question is settled the other way round: text that
  /// ended a sentence takes nothing more, and anything else may be joined.
  /// Japanese recognition often carries no punctuation at all, and there that
  /// default is wrong. Measured over two minutes of real material, treating
  /// "no sentence-final marker found" as permission to merge chained two and
  /// three separate lines into single ten-second subtitles which stopped only
  /// at the width cap - and cut mid-word when they hit it, leaving orphans
  /// like the tail of a compound noun as a subtitle of its own.
  ///
  /// So for unpunctuated Japanese the merge needs positive evidence instead:
  /// the text has to end on something that cannot end a sentence.
  static bool _continuesIntoNext(String text, {String language = ''}) {
    var value = text.trim();
    while (value.isNotEmpty &&
        _closingBrackets.contains(value[value.length - 1])) {
      value = value.substring(0, value.length - 1).trim();
    }
    if (value.isEmpty) return false;
    if (_terminalPunctuation.contains(value[value.length - 1])) return false;
    if (language == 'ja' || _kanaPattern.hasMatch(value)) {
      return _japaneseContinuing.hasMatch(value);
    }
    return true;
  }

  /// Splits transcript text into subtitle-sized parts: sentence-final
  /// punctuation always ends a part; phrase commas break runs beyond
  /// [_maximumSubtitleLength] when enough text precedes the comma; a word
  /// boundary is preferred over a mid-word hard cut. Returns only non-empty
  /// parts. Separating whitespace absorbed at a cut is dropped, so joining the
  /// parts reproduces the source text minus its spacing.
  static List<String> splitSubtitleText(String text) {
    final parts = <String>[];
    final buffer = <String>[];
    var width = 0;
    var lastBreakAfter = -1;
    var widthAtBreak = 0;
    var lastSpaceAfter = -1;
    var widthAtSpace = 0;
    void flush(int end) {
      final part = buffer.take(end).join().trim();
      if (part.isNotEmpty) parts.add(part);
    }

    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      buffer.add(char);
      width += _runeWidth(rune);
      final length = buffer.length;
      if (_terminalPunctuation.contains(char)) {
        flush(length);
        buffer.clear();
        width = 0;
        lastBreakAfter = -1;
        widthAtBreak = 0;
        lastSpaceAfter = -1;
        widthAtSpace = 0;
        continue;
      }
      if (_phraseBreaks.contains(char)) {
        lastBreakAfter = length;
        widthAtBreak = width;
      }
      if (_isWhitespace(rune)) {
        lastSpaceAfter = length;
        widthAtSpace = width;
      }
      if (width >= _maximumSubtitleLength) {
        // Prefer a phrase comma, then a word boundary, so a hard cut never
        // lands inside a Latin word and splits 'such a' across two subtitles.
        // Both candidates are measured in display cells like the cap itself.
        final commaCut =
            widthAtBreak >= _minimumCommaCutLength ? lastBreakAfter : 0;
        final spaceCut =
            widthAtSpace >= _minimumCommaCutLength ? lastSpaceAfter : 0;
        final cut =
            commaCut > 0 ? commaCut : (spaceCut > 0 ? spaceCut : length);
        final remainder = buffer.sublist(cut);
        flush(cut);
        buffer
          ..clear()
          ..addAll(remainder);
        width = _displayWidth(buffer.join());
        lastBreakAfter = -1;
        widthAtBreak = 0;
        lastSpaceAfter = -1;
        widthAtSpace = 0;
      }
    }
    flush(buffer.length);
    return parts;
  }

  /// Joins sentence fragments without injecting noise: CJK fragments are
  /// concatenated directly, fragments that both touch an ASCII letter or
  /// digit get a single space.
  ///
  /// A fragment that restates the tail of what precedes it is trimmed first.
  /// Whisper repeats a few characters across adjacent segments (measured on
  /// 7.9% of adjacent pairs, roughly a tenth of all characters); joining them
  /// verbatim produces text like '自慢やわ自慢やわ自慢'.
  static String _joinSentenceParts(Iterable<String> parts) {
    var result = '';
    for (final raw in parts) {
      var part = raw.trim();
      if (part.isEmpty) continue;
      if (result.isEmpty) {
        result = part;
        continue;
      }
      part = _stripRepeatedPrefix(result, part);
      if (part.isEmpty) continue;
      final last = result.codeUnitAt(result.length - 1);
      final first = part.codeUnitAt(0);
      final joinsWithSpace = _isAsciiWord(last) && _isAsciiWord(first);
      result = joinsWithSpace ? '$result $part' : result + part;
    }
    return result;
  }

  /// Removes a leading run of [next] that already appears at the end of
  /// [previous]. Whisper spaces Japanese inconsistently, so the comparison
  /// ignores whitespace while the cut is mapped back onto the original text.
  /// A fragment may collapse entirely: adjacent segments sharing a long run of
  /// identical text are Whisper restating itself, not a second speaker. Short
  /// utterances stay below [_minimumRepeatedPrefixLength] and are kept.
  static String _stripRepeatedPrefix(String previous, String next) {
    final packed = previous.replaceAll(RegExp(r'\s+'), '');
    final candidate = next.trim();
    final packedNext = candidate.replaceAll(RegExp(r'\s+'), '');
    if (packed.isEmpty || packedNext.isEmpty) return candidate;
    final maximum = _min(packed.length, packedNext.length);
    for (var length = maximum;
        length >= _minimumRepeatedPrefixLength;
        length--) {
      if (packed.endsWith(packedNext.substring(0, length))) {
        return _dropLeadingCharacters(candidate, length);
      }
    }
    return candidate;
  }

  /// Drops the first [count] non-whitespace characters of [text].
  static String _dropLeadingCharacters(String text, int count) {
    var remaining = count;
    var index = 0;
    while (index < text.length && remaining > 0) {
      if (!_isWhitespace(text.codeUnitAt(index))) remaining--;
      index++;
    }
    return text.substring(index).trimLeft();
  }

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0a ||
      codeUnit == 0x0d;

  /// Display width in half-width cells. Full-width kana, kanji and their
  /// punctuation occupy two cells, so a cap expressed in cells yields lines of
  /// comparable visual length for Japanese and Latin text.
  static int _displayWidth(String text) {
    var width = 0;
    for (final rune in text.runes) {
      width += _runeWidth(rune);
    }
    return width;
  }

  static int _runeWidth(int rune) => _isFullWidth(rune) ? 2 : 1;

  static bool _isFullWidth(int rune) =>
      (rune >= 0x1100 && rune <= 0x115F) ||
      (rune >= 0x2E80 && rune <= 0xA4CF) ||
      (rune >= 0xAC00 && rune <= 0xD7A3) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0xFE30 && rune <= 0xFE6F) ||
      (rune >= 0xFF00 && rune <= 0xFF60) ||
      (rune >= 0xFFE0 && rune <= 0xFFE6) ||
      (rune >= 0x20000 && rune <= 0x3FFFD);

  static bool _isAsciiWord(int codeUnit) =>
      (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7A);
}

class _RawGroup {
  _RawGroup(RecognitionEvent event) : _events = [event];

  final List<RecognitionEvent> _events;

  Iterable<RecognitionEvent> get events => _events;

  String get text => _best.text;

  int get startMs =>
      _events.map((event) => event.start.inMilliseconds).reduce(_min);
  int get endMs =>
      _events.map((event) => event.end.inMilliseconds).reduce(_max);
  String get normalizedText => _normalizeText(_best.text);

  /// True when another event in the group says everything this one says and
  /// more. Overlapping windows produce exactly this pair - one window heard
  /// the whole utterance, its neighbour only the part on its side of the
  /// boundary - and the fuller text is the one to keep even when the fragment
  /// scored higher, because confidence rises on short decodes.
  bool _isFragmentOf(RecognitionEvent event, Map<String, String> normalized) {
    final own = normalized[event.segmentId] ?? '';
    if (own.isEmpty) return true;
    return _events.any((other) {
      if (identical(other, event)) return false;
      final text = normalized[other.segmentId] ?? '';
      return text.length > own.length && text.contains(own);
    });
  }

  RecognitionEvent get _best {
    final normalized = <String, String>{
      for (final event in _events) event.segmentId: _normalizeText(event.text),
    };
    final ordered = List<RecognitionEvent>.of(_events)
      ..sort((left, right) {
        final fragment = (_isFragmentOf(left, normalized) ? 1 : 0)
            .compareTo(_isFragmentOf(right, normalized) ? 1 : 0);
        if (fragment != 0) return fragment;
        final confidence =
            (right.confidence ?? 0).compareTo(left.confidence ?? 0);
        if (confidence != 0) return confidence;
        final start = left.start.compareTo(right.start);
        if (start != 0) return start;
        final end = left.end.compareTo(right.end);
        if (end != 0) return end;
        return left.segmentId.compareTo(right.segmentId);
      });
    return ordered.first;
  }

  double duplicateScore(RecognitionEvent event) {
    final overlap = _timeOverlapRatio(
      startMs,
      endMs,
      event.start.inMilliseconds,
      event.end.inMilliseconds,
    );
    if (overlap < 0.5) return 0;
    final incoming = _normalizeText(event.text);
    final similarity = _textSimilarity(normalizedText, incoming);
    return similarity > 0 && _containsSubstantially(normalizedText, incoming)
        ? 1
        : similarity;
  }

  /// True when one text is contained in the other and long enough to be the
  /// same utterance rather than a short word that happens to appear inside it.
  static bool _containsSubstantially(String left, String right) {
    if (left.isEmpty || right.isEmpty) return false;
    final longer = left.length >= right.length ? left : right;
    final shorter = left.length >= right.length ? right : left;
    if (shorter.length < 3) return false;
    if (shorter.length * 2 < longer.length) return false;
    return longer.contains(shorter);
  }

  void add(RecognitionEvent event) => _events.add(event);
}

/// A chain of raw groups that belongs to one sentence. A single-group cluster
/// behaves exactly like the pre-merge group; a merged cluster spans the whole
/// sentence and joins each group's best text.
class _RawCluster {
  _RawCluster(List<_RawGroup> groups) : _groups = List.of(groups);

  final List<_RawGroup> _groups;

  void add(_RawGroup group) => _groups.add(group);

  int get startMs => _groups.first.startMs;

  int get endMs => _groups.map((group) => group.endMs).reduce(_max);

  String get text =>
      TranscriptAssembler._joinSentenceParts(_groups.map((g) => g._best.text));

  String get normalizedText => _normalizeText(text);

  String get language => _groups.first._best.language;

  double? get confidence {
    double? best;
    for (final event in events) {
      final value = event.confidence;
      if (value != null && (best == null || value > best)) best = value;
    }
    return best;
  }

  Iterable<RecognitionEvent> get events => _groups.expand((g) => g.events);

  bool canMerge(_RawGroup next) {
    final last = _groups.last;
    final gap = next.startMs - last.endMs;
    if (gap < -50 || gap > TranscriptAssembler._maximumMergeGapMs) return false;
    if (!TranscriptAssembler._continuesIntoNext(text, language: language)) {
      return false;
    }
    if (next.text.trim().isEmpty) return false;
    // Width, not character count: a cap in display cells keeps Japanese and
    // Latin segments to lines of comparable length on screen.
    if (TranscriptAssembler._displayWidth(text) +
            TranscriptAssembler._displayWidth(next.text.trim()) >
        TranscriptAssembler._maximumMergedLength) {
      return false;
    }
    return TranscriptAssembler._sameLanguage(language, next._best.language);
  }

  /// Splits the cluster text into subtitle-sized units: sentence-final
  /// punctuation always starts a new unit, phrase commas break runs that
  /// exceed [_maximumSubtitleLength], and anything still longer is cut at
  /// the character cap. Unit times are interpolated proportionally by text
  /// length across the cluster window.
  List<_SubtitleUnit> toSubtitleUnits() {
    final parts = TranscriptAssembler.splitSubtitleText(text);
    final sourceWindows = events
        .map((event) => event.sourceWindowId ?? event.segmentId)
        .toSet()
        .toList()
      ..sort();
    if (parts.length <= 1) {
      return [
        _SubtitleUnit(
          startMs,
          endMs,
          text,
          language,
          confidence,
          sourceWindows,
        ),
      ];
    }
    final totalLength =
        parts.fold<int>(0, (sum, part) => sum + part.length);
    final units = <_SubtitleUnit>[];
    var consumed = 0;
    var unitStart = startMs;
    for (var index = 0; index < parts.length; index++) {
      consumed += parts[index].length;
      var unitEnd = index == parts.length - 1
          ? endMs
          : startMs +
              ((endMs - startMs) * consumed / totalLength).round();
      if (unitEnd <= unitStart) unitEnd = unitStart + 1;
      units.add(_SubtitleUnit(
        unitStart,
        unitEnd,
        parts[index],
        language,
        confidence,
        sourceWindows,
      ));
      unitStart = unitEnd;
    }
    return units;
  }

  TranscriptSegment toSegment(String id) {
    final events = List<RecognitionEvent>.of(this.events);
    return TranscriptSegment(
      id: id,
      startMs: startMs,
      endMs: endMs,
      text: text,
      language: language,
      confidence: confidence,
      status: TranscriptSegmentStatus.timelineFinal,
      sourceWindows: events
          .map((event) => event.sourceWindowId ?? event.segmentId)
          .toSet()
          .toList()
        ..sort(),
    );
  }
}

/// One display-sized subtitle unit carved out of an assembled cluster.
class _SubtitleUnit {
  const _SubtitleUnit(
    this.startMs,
    this.endMs,
    this.text,
    this.language,
    this.confidence,
    this.sourceWindows,
  );

  final int startMs;
  final int endMs;
  final String text;
  final String language;
  final double? confidence;
  final List<String> sourceWindows;

  String get normalizedText => _normalizeText(text);

  TranscriptSegment toSegment(String id) => TranscriptSegment(
        id: id,
        startMs: startMs,
        endMs: endMs,
        text: text,
        language: language,
        confidence: confidence,
        status: TranscriptSegmentStatus.timelineFinal,
        sourceWindows: sourceWindows,
      );
}

int _min(int left, int right) => left < right ? left : right;
int _max(int left, int right) => left > right ? left : right;

int _compareEvents(RecognitionEvent left, RecognitionEvent right) {
  final start = left.start.compareTo(right.start);
  if (start != 0) return start;
  final end = left.end.compareTo(right.end);
  return end != 0 ? end : left.segmentId.compareTo(right.segmentId);
}

double _timeOverlapRatio(
    int leftStart, int leftEnd, int rightStart, int rightEnd) {
  final overlap = _min(leftEnd, rightEnd) - _max(leftStart, rightStart);
  if (overlap <= 0) return 0;
  final shorter = _min(leftEnd - leftStart, rightEnd - rightStart);
  return shorter <= 0 ? 0 : overlap / shorter;
}

/// Keeps kana in the normalized form. Japanese text normalized without kana
/// collapses to almost nothing, which silently broke duplicate detection and
/// stable timeline IDs for ja transcripts.
String _normalizeText(String text) => text
    .toLowerCase()
    .replaceAll(
      RegExp(r'[^a-z0-9\u3040-\u309f\u30a0-\u30ff\u3005\u3006\u4e00-\u9fff]+'),
      ' ',
    )
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

double _textSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  if (left.contains(right) || right.contains(left)) {
    return _min(left.length, right.length) / _max(left.length, right.length);
  }
  // Whisper Japanese output spaces CJK text inconsistently; compare the
  // space-stripped forms before falling back to whitespace tokens, which
  // never match for languages without word separators.
  if (_containsCjk(left) && _containsCjk(right)) {
    final packedLeft = left.replaceAll(' ', '');
    final packedRight = right.replaceAll(' ', '');
    if (packedLeft == packedRight) return 1;
    if (packedLeft.contains(packedRight) ||
        packedRight.contains(packedLeft)) {
      return _min(packedLeft.length, packedRight.length) /
          _max(packedLeft.length, packedRight.length);
    }
  }
  final leftTokens = left.split(' ').toSet();
  final rightTokens = right.split(' ').toSet();
  final union = leftTokens.union(rightTokens).length;
  return union == 0 ? 0 : leftTokens.intersection(rightTokens).length / union;
}

final RegExp _cjkPattern = RegExp(r'[\u3040-\u30ff\u3005\u3006\u3400-\u9fff]');

bool _containsCjk(String text) => _cjkPattern.hasMatch(text);
