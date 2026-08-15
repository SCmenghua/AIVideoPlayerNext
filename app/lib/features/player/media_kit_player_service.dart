import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../domain/player/player_service.dart';

class MediaKitPlayerService implements PlayerService {
  MediaKitPlayerService({Player? player}) : _player = player ?? Player() {
    videoController = VideoController(_player);
    _subscriptions.add(_player.stream.position.listen((value) {
      _emit(_snapshot.copyWith(position: value));
    }));
    _subscriptions.add(_player.stream.duration.listen((value) {
      _emit(_snapshot.copyWith(duration: value));
    }));
    _subscriptions.add(_player.stream.playing.listen((isPlaying) {
      if (_snapshot.source == null) return;
      _emit(_snapshot.copyWith(
        status: isPlaying ? PlaybackStatus.playing : PlaybackStatus.paused,
      ));
    }));
    _subscriptions.add(_player.stream.completed.listen((completed) {
      if (completed && _snapshot.source != null) {
        _emit(_snapshot.copyWith(
          status: PlaybackStatus.ended,
          position: _snapshot.duration,
        ));
      }
    }));
    _subscriptions.add(_player.stream.buffering.listen((isBuffering) {
      _emit(_snapshot.copyWith(isBuffering: isBuffering));
    }));
    _subscriptions.add(_player.stream.volume.listen((value) {
      _emit(_snapshot.copyWith(volume: value.clamp(0, 100).toDouble()));
    }));
    _subscriptions.add(_player.stream.rate.listen((value) {
      _emit(_snapshot.copyWith(rate: value));
    }));
    _subscriptions.add(_player.stream.error.listen(_handlePlayerError));
  }

  final Player _player;
  final StreamController<PlaybackSnapshot> _controller =
      StreamController<PlaybackSnapshot>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  late final VideoController videoController;
  bool _disposed = false;

  @override
  Stream<PlaybackSnapshot> get snapshots => _controller.stream;

  @override
  Future<void> open(MediaSource source) async {
    _emit(PlaybackSnapshot(
      status: PlaybackStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
      source: source,
      volume: _snapshot.volume,
      rate: _snapshot.rate,
      isBuffering: true,
    ));

    try {
      await _player.open(
        Media(
          source.uri.toString(),
          httpHeaders:
              source.requestHeaders.isEmpty ? null : source.requestHeaders,
        ),
        play: false,
      );
      _emit(_snapshot.copyWith(
        status: PlaybackStatus.paused,
        isBuffering: false,
        clearMessage: true,
      ));
    } catch (_) {
      _emit(_snapshot.copyWith(
        status: PlaybackStatus.error,
        isBuffering: false,
        message: '无法打开此媒体，请检查文件或媒体链接。',
      ));
    }
  }

  @override
  Future<void> play() async {
    if (_snapshot.source == null) return;
    try {
      await _player.play();
    } catch (_) {
      _emit(_snapshot.copyWith(
        status: PlaybackStatus.error,
        message: '播放失败，请检查媒体格式。',
      ));
    }
  }

  @override
  Future<void> pause() async {
    if (_snapshot.source == null) return;
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_snapshot.source == null) return;
    final duration = _snapshot.duration;
    final bounded = position < Duration.zero
        ? Duration.zero
        : duration > Duration.zero && position > duration
            ? duration
            : position;
    await _player.seek(bounded);
  }

  @override
  Future<void> setRate(double rate) async {
    await _player.setRate(rate.clamp(0.5, 2).toDouble());
  }

  @override
  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume.clamp(0, 100).toDouble());
  }

  void _handlePlayerError(String _) {
    if (_snapshot.source == null) return;
    _emit(_snapshot.copyWith(
      status: PlaybackStatus.error,
      isBuffering: false,
      message: '无法播放此媒体，请检查格式、链接或访问权限。',
    ));
  }

  void _emit(PlaybackSnapshot snapshot) {
    if (_disposed) return;
    _snapshot = snapshot;
    _controller.add(snapshot);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _controller.close();
  }
}
