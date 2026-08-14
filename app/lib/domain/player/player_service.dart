import 'dart:async';

class MediaSource {
  const MediaSource({required this.path, required this.title});

  final String path;
  final String title;
}

enum PlaybackStatus { idle, loading, playing, paused, ended, error }

class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.status,
    required this.position,
    required this.duration,
    required this.source,
    this.message,
  });

  const PlaybackSnapshot.idle()
      : status = PlaybackStatus.idle,
        position = Duration.zero,
        duration = Duration.zero,
        source = null,
        message = null;

  final PlaybackStatus status;
  final Duration position;
  final Duration duration;
  final MediaSource? source;
  final String? message;

  double get progress => duration.inMilliseconds == 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);
}

abstract interface class PlayerService {
  Future<void> open(MediaSource source);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Stream<PlaybackSnapshot> get snapshots;
  Future<void> dispose();
}
