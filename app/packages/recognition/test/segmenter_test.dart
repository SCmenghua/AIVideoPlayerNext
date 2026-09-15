import 'dart:typed_data';

import 'package:recognition/recognition.dart';
import 'package:test/test.dart';

const frame = 512;
final frameDuration = Duration(microseconds: frame * 1000000 ~/ 16000);

class Feeder {
  Feeder(this.segmenter);

  final SpeechSegmenter segmenter;
  final List<SegmenterEvent> events = [];
  Duration cursor = Duration.zero;

  void feed(Duration duration, double probability) {
    final frames = duration.inMicroseconds ~/ frameDuration.inMicroseconds;
    for (var i = 0; i < frames; i++) {
      final samples = Float32List(frame);
      if (probability >= 0.5) samples.fillRange(0, frame, 0.3);
      events.addAll(segmenter.addFrame(samples, probability, cursor));
      cursor += frameDuration;
    }
  }

  List<SpeechWindow> get windows =>
      events.whereType<WindowReady>().map((e) => e.window).toList();

  List<RangeSkipped> get skipped => events.whereType<RangeSkipped>().toList();
}

void main() {
  test('leading silence is skipped and a short window cuts after a long pause', () {
    final feeder = Feeder(SpeechSegmenter(frameSamples: frame))..segmenter.reset(sessionId: 's');
    feeder.feed(const Duration(seconds: 5), 0.05);
    expect(feeder.skipped, isNotEmpty);
    expect(feeder.windows, isEmpty);
    feeder.feed(const Duration(seconds: 2), 0.9);
    feeder.feed(const Duration(milliseconds: 1600), 0.05);
    expect(feeder.windows.length, 1);
    final window = feeder.windows.single;
    expect(window.cutReason, 'longSilence');
    expect(window.duration.inMilliseconds, inInclusiveRange(2100, 2500));
    expect(window.speechStart, greaterThanOrEqualTo(window.mediaStart));
    expect(window.speechEnd - window.speechStart, const Duration(milliseconds: 1984));
    expect(window.mediaStart.inMilliseconds, inInclusiveRange(4500, 5000));
  });

  test('medium windows cut at a normal pause, short pauses are ignored', () {
    final feeder = Feeder(SpeechSegmenter(frameSamples: frame));
    feeder.feed(const Duration(seconds: 3), 0.9);
    feeder.feed(const Duration(milliseconds: 600), 0.1);
    expect(feeder.windows, isEmpty, reason: 'window shorter than minCutWindow');
    feeder.feed(const Duration(seconds: 3), 0.9);
    feeder.feed(const Duration(milliseconds: 600), 0.1);
    expect(feeder.windows.length, 1);
    expect(feeder.windows.single.cutReason, 'pause');
    expect(feeder.windows.single.speechRatio, greaterThan(0.8));
  });

  test('a window that reaches the maximum is cut at the quietest frame', () {
    final feeder = Feeder(SpeechSegmenter(frameSamples: frame));
    feeder.feed(const Duration(seconds: 25), 0.9);
    feeder.feed(frameDuration * 3, 0.2);
    feeder.feed(const Duration(seconds: 4), 0.9);
    expect(feeder.windows.length, 1);
    final window = feeder.windows.single;
    expect(window.cutReason, 'forced');
    expect(window.duration.inMilliseconds, inInclusiveRange(24900, 25300));
    expect(feeder.segmenter.bufferedDuration.inMilliseconds, greaterThan(2500));
  });

  test('flush emits the remaining speech and nothing for silence', () {
    final segmenter = SpeechSegmenter(frameSamples: frame);
    final feeder = Feeder(segmenter);
    feeder.feed(const Duration(seconds: 1), 0.9);
    expect(feeder.windows, isEmpty);
    final events = segmenter.flush();
    expect(events.whereType<WindowReady>().length, 1);
    expect(events.single, isA<WindowReady>());
    expect((events.single as WindowReady).window.cutReason, 'flush');
    expect(segmenter.flush(), isEmpty);
  });

  test('window ids continue across a seek but restart for new media', () {
    final segmenter = SpeechSegmenter(frameSamples: frame)..reset(sessionId: 'a');
    final feeder = Feeder(segmenter);
    feeder.feed(const Duration(seconds: 2), 0.9);
    feeder.feed(const Duration(seconds: 2), 0.05);
    expect(feeder.windows.single.id, 'a-w00000');
    segmenter.reset(sessionId: 'b');
    final second = Feeder(segmenter);
    second.feed(const Duration(seconds: 2), 0.9);
    second.feed(const Duration(seconds: 2), 0.05);
    expect(second.windows.single.id, 'b-w00001');
    segmenter.reset(sessionId: 'c', preserveIndex: false);
    final third = Feeder(segmenter);
    third.feed(const Duration(seconds: 2), 0.9);
    third.feed(const Duration(seconds: 2), 0.05);
    expect(third.windows.single.id, 'c-w00000');
  });
}
