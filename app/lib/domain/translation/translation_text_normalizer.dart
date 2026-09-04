/// Normalizes provider output into Chinese subtitle typography for zh targets.
///
/// Whisper-era Japanese source text and some providers return half-width
/// punctuation, Japanese quote brackets or stray spaces between CJK
/// characters. The normalization is purely cosmetic: it never rewrites words,
/// and text that is already clean passes through unchanged.
library;

/// Applies the zh-target subtitle typography rules.
String normalizeChineseSubtitleText(Object? raw) {
  final text = raw is String ? raw : '';
  if (text.trim().isEmpty) return '';
  final converted = _convertPunctuation(_stripFences(text));
  return _collapseCjkSpaces(converted).trim();
}

String _stripFences(String raw) {
  var text = raw.trim();
  final fenced =
      RegExp(r'^```(?:[a-zA-Z]+)?\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (fenced != null) text = fenced.group(1)!.trim();
  return text;
}

String _convertPunctuation(String text) {
  final buffer = StringBuffer();
  for (var index = 0; index < text.length; index++) {
    final char = text[index];
    switch (char) {
      case '、':
      case '､':
        buffer.write('，');
      case '｡':
        buffer.write('。');
      case '「':
      case '『':
        buffer.write(_isClosingSide(text, index) ? '”' : '“');
      case '」':
      case '』':
        buffer.write('”');
      case ',':
        buffer.write(_betweenDigits(text, index) ? ',' : '，');
      case '!':
        buffer.write('！');
      case '?':
        buffer.write('？');
      case ':':
        buffer.write(_betweenDigits(text, index) ? ':' : '：');
      case ';':
        buffer.write('；');
      case '\u3000':
        buffer.write(' ');
      default:
        buffer.write(char);
    }
  }
  return buffer.toString();
}

/// Japanese corner brackets can appear nested; when the next visible
/// character already closes the bracket the opening one is treated as a
/// closing quote, which keeps 「…」…「 sequences from all becoming “.
bool _isClosingSide(String text, int index) {
  var cursor = index + 1;
  while (cursor < text.length && text[cursor] == ' ') {
    cursor++;
  }
  return cursor < text.length && (text[cursor] == '」' || text[cursor] == '』');
}

/// Keeps numeric separators such as `1,000` and `10:30` intact.
bool _betweenDigits(String text, int index) {
  if (index == 0 || index == text.length - 1) return false;
  bool isDigit(int code) => code >= 0x30 && code <= 0x39;
  final before = text.codeUnitAt(index - 1);
  final after = text.codeUnitAt(index + 1);
  return isDigit(before) && isDigit(after);
}

String _collapseCjkSpaces(String text) => text.replaceAll(
      RegExp(
        r'(?<=[\u3040-\u30ff\u3005\u3006\u3400-\u9fff\uff00-\uffef“”‘’，。：；！？])'
        r'\s+'
        r'(?=[\u3040-\u30ff\u3005\u3006\u3400-\u9fff\uff00-\uffef“”‘’，。：；！？])',
      ),
      '',
    );
