import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/browser/browser_media_classifier.dart';

void main() {
  const classifier = BrowserMediaClassifier();
  final page = Uri.parse('https://example.com/watch/42');

  test('hands off ordinary MP4 with transient referrer context', () {
    final decision = classifier.classify(
      candidate: Uri.parse('https://cdn.example.com/video.mp4?token=temporary'),
      originPage: page,
      browserSessionId: 'session-1',
      title: '示例视频',
      requestHeaders: {'Referer': page.toString()},
    );

    expect(decision.disposition, BrowserMediaDisposition.handoff);
    expect(decision.handoff!.mediaUri.path, '/video.mp4');
    expect(decision.handoff!.originPage, page);
    expect(decision.handoff!.requestHeaders['Referer'], page.toString());
  });

  test('hands off HLS manifests', () {
    final decision = classifier.classify(
      candidate: Uri.parse('https://cdn.example.com/master.m3u8'),
      originPage: page,
      browserSessionId: 'session-1',
      title: '',
    );

    expect(decision.disposition, BrowserMediaDisposition.handoff);
    expect(decision.handoff!.title, '网页视频');
  });

  test('reports blob media as unsupported without attempting extraction', () {
    final decision = classifier.classify(
      candidate: Uri.parse('blob:https://example.com/asset'),
      originPage: page,
      browserSessionId: 'session-1',
      title: '受保护视频',
    );

    expect(decision.disposition, BrowserMediaDisposition.unsupported);
    expect(decision.reason, contains('无法由内置播放器接管'));
  });

  test('keeps ordinary webpages in the browser', () {
    final decision = classifier.classify(
      candidate: Uri.parse('https://example.com/article'),
      originPage: page,
      browserSessionId: 'session-1',
      title: '文章',
    );

    expect(decision.disposition, BrowserMediaDisposition.ignore);
  });
}
