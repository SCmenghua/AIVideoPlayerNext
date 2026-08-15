import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/player/browser_media_handoff.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';

void main() {
  test('browser handoff retains source context without persisting credentials',
      () {
    final headers = <String, String>{
      'Referer': 'https://example.com/watch',
      'Cookie': 'session=transient',
    };
    final handoff = BrowserMediaHandoff(
      mediaUri: Uri.parse('https://cdn.example.com/video.mp4'),
      title: '网页视频',
      originPage: Uri.parse('https://example.com/watch'),
      browserSessionId: 'browser-session-1',
      requestHeaders: headers,
    );
    headers['Cookie'] = 'session=changed';

    final source = handoff.toMediaSource();

    expect(source.kind, MediaSourceKind.browserHandoff);
    expect(source.uri, Uri.parse('https://cdn.example.com/video.mp4'));
    expect(source.originPage, Uri.parse('https://example.com/watch'));
    expect(source.browserSessionId, 'browser-session-1');
    expect(source.requestHeaders['Cookie'], 'session=transient');
    expect(
      () => source.requestHeaders['Cookie'] = 'session=written',
      throwsUnsupportedError,
    );
  });
}
