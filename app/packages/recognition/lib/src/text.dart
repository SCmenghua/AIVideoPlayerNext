/// Text helpers shared by the gate, the assembler and the regression runner.
library;

const _sentenceTerminators = '。．｡.！？!?…‥';
const _clauseBreaks = '、，,';

bool isKana(int rune) =>
    (rune >= 0x3040 && rune <= 0x30FF) || (rune >= 0x31F0 && rune <= 0x31FF);

bool isCjkIdeograph(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    rune == 0x3005 ||
    rune == 0x3006;

bool isHangul(int rune) =>
    (rune >= 0xAC00 && rune <= 0xD7AF) || (rune >= 0x1100 && rune <= 0x11FF);

/// Whether the rune occupies two columns in a subtitle line.
bool isWide(int rune) =>
    isKana(rune) ||
    isCjkIdeograph(rune) ||
    isHangul(rune) ||
    (rune >= 0x3000 && rune <= 0x303F) ||
    (rune >= 0xFF00 && rune <= 0xFF60) ||
    (rune >= 0xFFE0 && rune <= 0xFFE6);

int displayWidth(String text) {
  var width = 0;
  for (final rune in text.runes) {
    width += isWide(rune) ? 2 : 1;
  }
  return width;
}

bool containsKana(String text) => text.runes.any(isKana);

bool containsCjk(String text) =>
    text.runes.any((rune) => isKana(rune) || isCjkIdeograph(rune) || isHangul(rune));

/// Lower-cased text with whitespace and punctuation removed; kana and
/// ideographs are kept so CJK strings can be compared.
String normalizeForComparison(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final isLatin = (rune >= 0x30 && rune <= 0x39) || (rune >= 0x61 && rune <= 0x7A);
    if (isLatin || isKana(rune) || isCjkIdeograph(rune) || isHangul(rune) ||
        (rune >= 0x00C0 && rune <= 0x024F) || (rune >= 0x0400 && rune <= 0x04FF)) {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

const _japaneseSentenceEndings = [
  'でした',
  'ました',
  'ません',
  'ですね',
  'ですよ',
  'ですか',
  'ますね',
  'ますよ',
  'ますか',
  'ない',
  'なかった',
  'です',
  'ます',
  'だ',
  'だよ',
  'だね',
  'かな',
  'よね',
  'のよ',
  'わ',
  'ね',
  'よ',
  'か',
  'な',
  'の',
  'ぞ',
  'ぜ',
  'さ',
];

/// Whether the text reads as a complete sentence: it ends with terminal
/// punctuation, or, for Japanese output without punctuation, with a
/// sentence-final form.
bool endsSentence(String text) {
  final trimmed = text.trimRight();
  if (trimmed.isEmpty) return false;
  final last = String.fromCharCode(trimmed.runes.last);
  if (_sentenceTerminators.contains(last)) return true;
  if (!containsKana(trimmed)) return false;
  for (final ending in _japaneseSentenceEndings) {
    if (trimmed.endsWith(ending)) return true;
  }
  return false;
}

/// Splits on terminal punctuation, keeping the punctuation attached.
List<String> splitSentences(String text) {
  final result = <String>[];
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    buffer.writeCharCode(rune);
    if (_sentenceTerminators.contains(String.fromCharCode(rune))) {
      final sentence = buffer.toString().trim();
      if (sentence.isNotEmpty) result.add(sentence);
      buffer.clear();
    }
  }
  final tail = buffer.toString().trim();
  if (tail.isNotEmpty) result.add(tail);
  return result;
}

/// Breaks [text] into pieces no wider than [maxWidth] columns, preferring
/// clause punctuation, then spaces, then a hard cut.
List<String> wrapByWidth(String text, int maxWidth, {int minPieceWidth = 8}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  if (displayWidth(trimmed) <= maxWidth) return [trimmed];
  final runes = trimmed.runes.toList(growable: false);
  final pieces = <String>[];
  var start = 0;
  while (start < runes.length) {
    var width = 0;
    var end = start;
    var lastClause = -1;
    var lastSpace = -1;
    while (end < runes.length) {
      final w = isWide(runes[end]) ? 2 : 1;
      if (width + w > maxWidth) break;
      width += w;
      end++;
      final char = String.fromCharCode(runes[end - 1]);
      final pieceWidth = _widthOf(runes, start, end);
      if (_clauseBreaks.contains(char) && pieceWidth >= minPieceWidth) {
        lastClause = end;
      } else if (char == ' ' && pieceWidth >= minPieceWidth) {
        lastSpace = end;
      }
    }
    if (end >= runes.length) {
      pieces.add(String.fromCharCodes(runes, start).trim());
      break;
    }
    if (end == start) end = start + 1;
    final cut = lastClause > start
        ? lastClause
        : lastSpace > start
            ? lastSpace
            : end;
    final piece = String.fromCharCodes(runes, start, cut).trim();
    if (piece.isNotEmpty) pieces.add(piece);
    start = cut;
    while (start < runes.length && runes[start] == 0x20) {
      start++;
    }
  }
  return pieces;
}

int _widthOf(List<int> runes, int start, int end) {
  var width = 0;
  for (var i = start; i < end; i++) {
    width += isWide(runes[i]) ? 2 : 1;
  }
  return width;
}

/// Character error rate of [hypothesis] against [reference] after
/// normalisation, as used by the regression runner.
double characterErrorRate(String reference, String hypothesis) {
  final ref = normalizeForComparison(reference).runes.toList(growable: false);
  final hyp = normalizeForComparison(hypothesis).runes.toList(growable: false);
  if (ref.isEmpty) return hyp.isEmpty ? 0 : 1;
  return levenshtein(ref, hyp) / ref.length;
}

int levenshtein(List<int> a, List<int> b) {
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var best = previous[j] + 1;
      if (current[j - 1] + 1 < best) best = current[j - 1] + 1;
      if (previous[j - 1] + cost < best) best = previous[j - 1] + cost;
      current[j] = best;
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}

/// The last [maxCharacters] characters of [text], cut at a sentence or clause
/// boundary when one is available.
String contextTail(String text, int maxCharacters) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || maxCharacters <= 0) return '';
  final runes = trimmed.runes.toList(growable: false);
  if (runes.length <= maxCharacters) return trimmed;
  var start = runes.length - maxCharacters;
  for (var i = start; i < runes.length - 4; i++) {
    final char = String.fromCharCode(runes[i]);
    if (_sentenceTerminators.contains(char) || _clauseBreaks.contains(char) || char == ' ') {
      start = i + 1;
      break;
    }
  }
  return String.fromCharCodes(runes, start).trim();
}
