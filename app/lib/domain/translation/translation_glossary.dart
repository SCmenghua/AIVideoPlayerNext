/// Parses the user-defined translation glossary used to keep names, honorifics
/// and recurring terms consistent across one media session.
///
/// One entry per line in `原文=译文` form; full-width `＝` is accepted as the
/// separator. Lines that are empty, start with `#`, or lack a separator are
/// ignored so users can keep notes in the same text block.
library;

const int maxTranslationGlossaryEntries = 50;

Map<String, String> parseTranslationGlossary(Object? raw) {
  final text = raw is String ? raw : '';
  if (text.trim().isEmpty) return const {};
  final entries = <String, String>{};
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final separator = trimmed.indexOf('=');
    final fullWidth = trimmed.indexOf('＝');
    final splitAt = separator == -1
        ? fullWidth
        : fullWidth == -1
            ? separator
            : (separator < fullWidth ? separator : fullWidth);
    if (splitAt <= 0 || splitAt >= trimmed.length - 1) continue;
    final term = trimmed.substring(0, splitAt).trim();
    final translation = trimmed.substring(splitAt + 1).trim();
    if (term.isEmpty || translation.isEmpty) continue;
    entries.putIfAbsent(term, () => translation);
    if (entries.length >= maxTranslationGlossaryEntries) break;
  }
  return Map.unmodifiable(entries);
}
