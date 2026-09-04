import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/translation/translation_text_normalizer.dart';

void main() {
  test('converts Japanese and half-width punctuation to Chinese typography',
      () {
    expect(
      normalizeChineseSubtitleText('大丈夫ですか?大丈夫です、ありがとう。'),
      '大丈夫ですか？大丈夫です，ありがとう。',
    );
  });

  test('maps Japanese corner brackets to Chinese quotes', () {
    expect(normalizeChineseSubtitleText('「はい」そうです'), '“はい”そうです');
  });

  test('keeps numeric separators intact', () {
    expect(normalizeChineseSubtitleText('1,000人が10:30に来た'), '1,000人が10:30に来た');
    expect(normalizeChineseSubtitleText('3.5時'), '3.5時');
  });

  test('collapses stray spaces between CJK characters but not Latin words',
      () {
    expect(normalizeChineseSubtitleText('こんにちは 世界 です'), 'こんにちは世界です');
    expect(normalizeChineseSubtitleText('hello world'), 'hello world');
    expect(normalizeChineseSubtitleText('hello world, 皆さん'), 'hello world，皆さん');
  });

  test('trims whitespace and full-width spaces', () {
    expect(normalizeChineseSubtitleText('\u3000はい \u3000'), 'はい');
  });

  test('strips markdown fences from model output', () {
    expect(
      normalizeChineseSubtitleText('```\nこんにちは、世界\n```'),
      'こんにちは，世界',
    );
  });

  test('passes clean text through unchanged', () {
    expect(normalizeChineseSubtitleText('これはペンです。'), 'これはペンです。');
  });

  test('returns empty text for empty input', () {
    expect(normalizeChineseSubtitleText(''), '');
    expect(normalizeChineseSubtitleText('   '), '');
    expect(normalizeChineseSubtitleText(null), '');
  });
}
