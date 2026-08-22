import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../domain/player/player_service.dart';

class MediaKitPlayerService implements PlayerService {
  MediaKitPlayerService({Player? player, DiagnosticLogService? logs})
      : _player = player ?? Player(),
        _logs = logs {
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
    _subscriptions.add(_player.stream.buffer.listen((value) {
      _emit(_snapshot.copyWith(bufferedDuration: value));
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
  final DiagnosticLogService? _logs;
  final StreamController<PlaybackSnapshot> _controller =
      StreamController<PlaybackSnapshot>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  late final VideoController videoController;
  bool _disposed = false;
  PlaybackStatus? _lastLoggedStatus;
  bool? _lastLoggedBuffering;

  @override
  Stream<PlaybackSnapshot> get snapshots => _controller.stream;

  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Future<void> open(MediaSource source) async {
    final elapsed = Stopwatch()..start();
    _logs?.info('播放器', '开始打开媒体', {
      '标题': source.title,
      '地址': source.uri,
      '来源类型': source.kind.name,
      '来源页面': source.originPage,
      '请求头数量': source.requestHeaders.length,
      '请求头': source.requestHeaders,
    });
    _emit(PlaybackSnapshot(
      status: PlaybackStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
      source: source,
      volume: _snapshot.volume,
      rate: _snapshot.rate,
      isBuffering: true,
      bufferedDuration: Duration.zero,
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
      _logs?.info('播放器', '媒体打开成功', {
        '标题': source.title,
        '地址': source.uri,
        '调用耗时': elapsed.elapsed,
      });
    } catch (error) {
      _logs?.error('播放器', '媒体打开失败', {
        '标题': source.title,
        '地址': source.uri,
        '错误': error,
        '调用耗时': elapsed.elapsed,
      });
      _emit(_snapshot.copyWith(
        status: PlaybackStatus.error,
        isBuffering: false,
        message: '无法打开此媒体，请检查文件或媒体链接。',
      ));
    }
  }

  @override
  Future<void> play() async {
    if (_snapshot.source == null) {
      _logs?.warning('播放器', '忽略播放操作：没有媒体');
      return;
    }
    final elapsed = Stopwatch()..start();
    _logs?.debug('播放器', '用户点击播放', {
      '标题': _snapshot.source?.title,
      '状态': _snapshot.status.name,
    });
    try {
      await _player.play();
      _logs?.debug('播放器', '播放调用返回', {'调用耗时': elapsed.elapsed});
    } catch (error) {
      _logs?.error('播放器', '播放调用失败', {
        '错误': error,
        '调用耗时': elapsed.elapsed,
      });
      _emit(_snapshot.copyWith(
        status: PlaybackStatus.error,
        message: '播放失败，请检查媒体格式。',
      ));
    }
  }

  @override
  Future<void> pause() async {
    if (_snapshot.source == null) {
      _logs?.warning('播放器', '忽略暂停操作：没有媒体');
      return;
    }
    final elapsed = Stopwatch()..start();
    _logs?.debug('播放器', '用户点击暂停', {'标题': _snapshot.source?.title});
    await _player.pause();
    _logs?.debug('播放器', '暂停调用返回', {'调用耗时': elapsed.elapsed});
  }

  @override
  Future<void> seek(Duration position) async {
    if (_snapshot.source == null) {
      _logs?.warning('播放器', '忽略跳转操作：没有媒体');
      return;
    }
    final duration = _snapshot.duration;
    final bounded = position < Duration.zero
        ? Duration.zero
        : duration > Duration.zero && position > duration
            ? duration
            : position;
    final elapsed = Stopwatch()..start();
    await _player.seek(bounded);
    _logs?.debug('播放器', '用户调整播放进度', {
      '目标位置': bounded,
      '媒体标题': _snapshot.source?.title,
      '调用耗时': elapsed.elapsed,
    });
  }

  @override
  Future<void> setRate(double rate) async {
    final bounded = rate.clamp(0.5, 2).toDouble();
    await _player.setRate(bounded);
    _logs?.debug('播放器', '用户调整播放速度', {'速度': bounded});
  }

  @override
  Future<void> setVolume(double volume) async {
    final bounded = volume.clamp(0, 100).toDouble();
    await _player.setVolume(bounded);
    _logs?.debug('播放器', '用户调整音量', {'音量': bounded});
  }

  void _handlePlayerError(String error) {
    if (_snapshot.source == null) return;
    _logs?.error('播放器', '媒体引擎报告错误', {
      '媒体标题': _snapshot.source?.title,
      '错误': error,
    });
    _emit(_snapshot.copyWith(
      status: PlaybackStatus.error,
      isBuffering: false,
      message: '无法播放此媒体，请检查格式、链接或访问权限。',
    ));
  }

  void _emit(PlaybackSnapshot snapshot) {
    if (_disposed) return;
    if (snapshot.status != _lastLoggedStatus) {
      _lastLoggedStatus = snapshot.status;
      _logs?.debug('播放器', '播放状态变化', {
        '状态': snapshot.status.name,
        '媒体标题': snapshot.source?.title,
      });
    }
    if (snapshot.isBuffering != _lastLoggedBuffering) {
      _lastLoggedBuffering = snapshot.isBuffering;
      _logs?.debug('播放器', snapshot.isBuffering ? '开始缓冲' : '缓冲结束', {
        '媒体标题': snapshot.source?.title,
      });
    }
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
