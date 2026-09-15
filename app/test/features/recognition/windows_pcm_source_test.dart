import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/features/recognition/windows_pcm_source.dart';

void main() {
  test('uses a Windows path for local media', () {
    // Uri.file only yields a file scheme when the input matches the host
    // path style; a backslash literal is a relative POSIX path on macOS.
    final path = Platform.isWindows ? r'C:\media\local video.mp4' : '/media/local video.mp4';
    final uri = Uri.file(path);

    expect(windowsAudioDecoderInputFor(uri), uri.toFilePath(windows: true));
  });

  test('preserves an HTTP loopback URL for Media Foundation', () {
    final uri = Uri.parse('http://127.0.0.1:55402/media.mp4');

    expect(windowsAudioDecoderInputFor(uri), 'http://127.0.0.1:55402/media.mp4');
  });

  test('rejects unsupported schemes before native open', () {
    expect(
      () => windowsAudioDecoderInputFor(Uri.parse('blob:https://example.com/video')),
      throwsA(isA<AudioDecoderException>()),
    );
  });
}
