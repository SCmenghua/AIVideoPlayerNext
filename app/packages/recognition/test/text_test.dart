import 'package:recognition/recognition.dart';
import 'package:test/test.dart';

void main() {
  test('display width counts CJK as two columns', () {
    expect(displayWidth('abc'), 3);
    expect(displayWidth('日本語'), 6);
    expect(displayWidth('カタカナ!'), 9);
  });

  test('normalisation keeps kana and ideographs', () {
    expect(normalizeForComparison('こんにちは、世界！'), 'こんにちは世界');
    expect(normalizeForComparison('Hello, World 123'), 'helloworld123');
    expect(normalizeForComparison(' わあ いいなあ ブレザー '), 'わあいいなあブレザー');
  });

  test('sentence end detection handles punctuation and Japanese forms', () {
    expect(endsSentence('今日は暑いですね。'), isTrue);
    expect(endsSentence('今日は暑いです'), isTrue);
    expect(endsSentence('行きました'), isTrue);
    expect(endsSentence('分からない'), isTrue);
    expect(endsSentence('それで'), isFalse);
    expect(endsSentence('a different sentence'), isFalse);
    expect(endsSentence('Done.'), isTrue);
  });

  test('sentence splitting keeps terminators attached', () {
    expect(splitSentences('一つ目。二つ目！三つ目'), ['一つ目。', '二つ目！', '三つ目']);
  });

  test('width wrapping prefers clause breaks and does not split short text', () {
    expect(wrapByWidth('短い', 36), ['短い']);
    final long = 'ただうちの家族はそんなこと、よく分からないから、聞いても無駄だと思う';
    final pieces = wrapByWidth(long, 36);
    expect(pieces.length, greaterThan(1));
    for (final piece in pieces) {
      expect(displayWidth(piece), lessThanOrEqualTo(36));
    }
    expect(pieces.first, endsWith('、'));
    expect(wrapByWidth('a different sentence', 36), ['a different sentence']);
  });

  test('character error rate', () {
    expect(characterErrorRate('こんにちは', 'こんにちは'), 0);
    expect(characterErrorRate('こんにちは', 'こんばんは'), closeTo(0.4, 1e-9));
    expect(characterErrorRate('abc', ''), 1);
  });

  test('context tail cuts at a boundary', () {
    expect(contextTail('短い文', 120), '短い文');
    final tail = contextTail('最初の文です。次の文はここで終わる。最後の文', 12);
    expect(tail, '最後の文');
  });
}
