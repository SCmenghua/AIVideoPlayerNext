import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/translation/translation_glossary.dart';

void main() {
  test('parses one entry per line with half-width separator', () {
    expect(
      parseTranslationGlossary('ハルヒ=春日\n団長=团长'),
      {'ハルヒ': '春日', '団長': '团长'},
    );
  });

  test('accepts full-width separator and surrounding spaces', () {
    expect(
      parseTranslationGlossary('セバスチャン ＝ 赛巴斯蒂安'),
      {'セバスチャン': '赛巴斯蒂安'},
    );
  });

  test('ignores empty lines, comments and malformed lines', () {
    expect(
      parseTranslationGlossary('# 注释\n\nなし\n===\n先輩=前辈\n=空\n前輩= '),
      {'先輩': '前辈'},
    );
  });

  test('keeps the first translation for a duplicated term', () {
    expect(
      parseTranslationGlossary('先生=老师\n先生=博士'),
      {'先生': '老师'},
    );
  });

  test('caps the number of entries', () {
    final buffer = StringBuffer();
    for (var index = 0; index < 80; index++) {
      buffer.writeln(' term$index = 译$index');
    }
    expect(parseTranslationGlossary(buffer.toString()).length,
        maxTranslationGlossaryEntries);
  });

  test('returns empty for empty input', () {
    expect(parseTranslationGlossary(''), isEmpty);
    expect(parseTranslationGlossary(null), isEmpty);
    expect(parseTranslationGlossary('   \n  '), isEmpty);
  });
}
