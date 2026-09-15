import 'package:recognition/recognition.dart';
import 'package:test/test.dart';

TranscriptSegment segment(String id, int start, int end) => TranscriptSegment(
      id: id,
      startMs: start,
      endMs: end,
      text: id,
      language: 'ja',
      windowId: 'w',
    );

void main() {
  test('segments are sorted and looked up by position with hold', () {
    final transcript = Transcript(
      [segment('b', 5000, 7000), segment('a', 1000, 3000)],
      revision: 1,
    );
    expect(transcript.segments.map((s) => s.id), ['a', 'b']);
    expect(transcript.at(const Duration(milliseconds: 500)), isNull);
    expect(transcript.at(const Duration(milliseconds: 1500))?.id, 'a');
    expect(transcript.at(const Duration(milliseconds: 3500))?.id, 'a', reason: 'held after end');
    expect(transcript.at(const Duration(milliseconds: 3500), hold: Duration.zero), isNull);
    expect(transcript.at(const Duration(milliseconds: 5600))?.id, 'b',
        reason: 'a later segment takes over immediately');
    expect(transcript.at(const Duration(milliseconds: 6000))?.id, 'b');
    expect(transcript.at(const Duration(milliseconds: 9600)), isNull);
  });

  test('between returns overlapping segments', () {
    final transcript = Transcript(
      [segment('a', 1000, 3000), segment('b', 5000, 7000)],
      revision: 1,
    );
    final hits = transcript.between(
      const Duration(milliseconds: 2500),
      const Duration(milliseconds: 5500),
    );
    expect(hits.map((s) => s.id), ['a', 'b']);
  });
}
