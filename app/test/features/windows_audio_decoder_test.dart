import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/features/audio/windows_audio_decoder.dart';

void main() {
  test('uses a Windows path for local media', () {
    final source = MediaSource.localFile(
      path: r'C:\media\local video.mp4',
      title: 'local video.mp4',
    );

    expect(
      windowsAudioDecoderInputFor(source),
      r'C:\media\local video.mp4',
    );
  });

  test('preserves an HTTPS browser-handoff URL for Media Foundation', () {
    final source = MediaSource(
      uri: Uri.parse('https://media.example.com/video.mp4?session=temporary'),
      title: '网页视频',
      kind: MediaSourceKind.browserHandoff,
      requestHeaders: const {'Referer': 'https://example.com/watch'},
    );

    expect(
      windowsAudioDecoderInputFor(source),
      'https://media.example.com/video.mp4?session=temporary',
    );
  });

  test('rejects unsupported audio-decoder schemes before native open', () {
    final source = MediaSource(
      uri: Uri.parse('blob:https://example.com/video'),
      title: '不支持媒体',
      kind: MediaSourceKind.browserHandoff,
    );

    expect(
      () => windowsAudioDecoderInputFor(source),
      throwsA(isA<AudioDecoderException>()),
    );
  });
}
