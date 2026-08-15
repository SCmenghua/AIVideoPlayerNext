import 'dart:async';
import 'dart:collection';

enum MediaSourceKind { localFile, browserHandoff }

class MediaSource {
  MediaSource({
    required this.uri,
    required this.title,
    required this.kind,
    this.originPage,
    Map<String, String> requestHeaders = const {},
    this.browserSessionId,
  }) : requestHeaders = UnmodifiableMapView(Map.of(requestHeaders));

  factory MediaSource.localFile(
          {required String path, required String title}) =>
      MediaSource(
        uri: Uri.file(path),
        title: title,
        kind: MediaSourceKind.localFile,
      );

  final Uri uri;
  final String title;
  final MediaSourceKind kind;
  final Uri? originPage;
  final Map<String, String> requestHeaders;
  final String? browserSessionId;
}

enum PlaybackStatus { idle, loading, playing, paused, ended, error }

class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.status,
    required this.position,
    required this.duration,
    required this.source,
    this.volume = 100,
    this.rate = 1,
    this.isBuffering = false,
    this.message,
  });

  const PlaybackSnapshot.idle()
      : status = PlaybackStatus.idle,
        position = Duration.zero,
        duration = Duration.zero,
        source = null,
        volume = 100,
        rate = 1,
        isBuffering = false,
        message = null;

  final PlaybackStatus status;
  final Duration position;
  final Duration duration;
  final MediaSource? source;
  final double volume;
  final double rate;
  final bool isBuffering;
  final String? message;

  double get progress => duration.inMilliseconds == 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);

  PlaybackSnapshot copyWith({
    PlaybackStatus? status,
    Duration? position,
    Duration? duration,
    MediaSource? source,
    double? volume,
    double? rate,
    bool? isBuffering,
    String? message,
    bool clearMessage = false,
  }) =>
      PlaybackSnapshot(
        status: status ?? this.status,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        source: source ?? this.source,
        volume: volume ?? this.volume,
        rate: rate ?? this.rate,
        isBuffering: isBuffering ?? this.isBuffering,
        message: clearMessage ? null : message ?? this.message,
      );
}

abstract interface class PlayerService {
  Future<void> open(MediaSource source);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setRate(double rate);
  Stream<PlaybackSnapshot> get snapshots;
  Future<void> dispose();
}
