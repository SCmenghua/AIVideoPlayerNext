import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../domain/audio/audio_models.dart';
import '../../domain/player/player_service.dart';

class IosAudioDecoderException implements Exception {
  const IosAudioDecoderException(this.message);

  final String message;

  @override
  String toString() => 'IosAudioDecoderException: $message';
}

/// AVFoundation-backed local-media decoder used on iOS.
///
/// It receives media PCM from the app-owned file, never from the microphone.
/// Browser handoff/network sources remain explicitly unavailable until their
/// authenticated media pipeline can expose an equivalent timeline safely.
class IosAudioDecoder implements AudioDecoder {
  static const _methods = MethodChannel('ai_video_player/ios_audio');
  static const _events = EventChannel('ai_video_player/ios_audio_events');

  final StreamController<AudioDecoderStatus> _statuses =
      StreamController<AudioDecoderStatus>.broadcast();
  final StreamController<AudioChunk> _chunks =
      StreamController<AudioChunk>.broadcast();
  StreamSubscription<dynamic>? _eventsSubscription;
  AudioDecoderStatus _status = const AudioDecoderStatus.idle();
  String? _sessionId;
  bool _disposed = false;

  @override
  AudioDecoderStatus get status => _status;

  @override
  Stream<AudioDecoderStatus> get statuses => _statuses.stream;

  @override
  Stream<AudioChunk> get chunks => _chunks.stream;

  @override
  Future<void> open(AudioDecoderRequest request) async {
    _ensureUsable();
    await stop();
    if (!Platform.isIOS) {
      throw const IosAudioDecoderException('iOS audio decoder unavailable');
    }
    if (request.source.kind != MediaSourceKind.localFile ||
        request.source.uri.scheme != 'file') {
      const message = 'iOS 当前只支持本地文件的识别音频；网络媒体尚未接入 PCM。';
      _emit(AudioDecoderStatus(
        state: AudioDecoderState.error,
        sessionId: request.sessionId,
        message: message,
      ));
      throw const IosAudioDecoderException(message);
    }
    _sessionId = request.sessionId;
    _emit(AudioDecoderStatus(
      state: AudioDecoderState.opening,
      sessionId: request.sessionId,
    ));
    _eventsSubscription ??= _events.receiveBroadcastStream().listen(
          _onEvent,
          onError: _onError,
        );
    try {
      await _methods.invokeMethod<void>('open', <String, Object?>{
        'path': request.source.uri.toFilePath(),
        'sessionId': request.sessionId,
      });
      if (request.start > Duration.zero) {
        await _methods.invokeMethod<void>('seek', <String, Object?>{
          'positionMs': request.start.inMilliseconds,
        });
      }
      _emit(_status.copyWith(
        state: AudioDecoderState.ready,
        sessionId: request.sessionId,
        sampleRate: 16000,
        channels: 1,
        clearMessage: true,
      ));
    } on PlatformException catch (error) {
      _onError(error);
      _sessionId = null;
      throw IosAudioDecoderException(error.message ?? 'iOS 音频解码初始化失败');
    }
  }

  @override
  Future<void> start() async {
    _ensureUsable();
    if (_sessionId == null || _status.state == AudioDecoderState.error) return;
    await _methods.invokeMethod<void>('start');
    _emit(_status.copyWith(state: AudioDecoderState.running));
  }

  @override
  Future<void> pause() async {
    if (_disposed || _sessionId == null) return;
    await _methods.invokeMethod<void>('pause');
    _emit(_status.copyWith(state: AudioDecoderState.paused));
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureUsable();
    if (_sessionId == null) return;
    _emit(_status.copyWith(state: AudioDecoderState.seeking));
    try {
      await _methods.invokeMethod<void>('seek', <String, Object?>{
        'positionMs': position.inMilliseconds,
      });
      _emit(_status.copyWith(state: AudioDecoderState.ready));
    } on PlatformException catch (error) {
      _onError(error);
      _sessionId = null;
      throw IosAudioDecoderException(error.message ?? 'iOS 音频跳转失败');
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed || _sessionId == null) return;
    await _methods.invokeMethod<void>('stop');
    _emit(_status.copyWith(state: AudioDecoderState.stopped));
    _sessionId = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _eventsSubscription?.cancel();
    await _statuses.close();
    await _chunks.close();
  }

  void _onEvent(dynamic raw) {
    if (_disposed || raw is! Map) return;
    final event = Map<Object?, Object?>.from(raw);
    if (event['type'] == 'error') {
      _onError(event['message'] ?? 'iOS 音频解码失败');
      return;
    }
    final sessionId = event['sessionId'] as String?;
    if (sessionId == null || sessionId != _sessionId) return;
    final isLast = event['isLast'] == true;
    final ended = event['ended'] == true;
    final samples = _samplesFromEvent(event['samples']);
    final sampleRate = event['sampleRate'] as int? ?? 16000;
    final channels = event['channels'] as int? ?? 1;
    _chunks.add(AudioChunk(
      sessionId: sessionId,
      mediaStart: Duration(milliseconds: event['mediaStartMs'] as int? ?? 0),
      sampleRate: sampleRate,
      channels: channels,
      samples: samples,
      isLast: isLast,
    ));
    if (isLast && ended) {
      _emit(_status.copyWith(state: AudioDecoderState.ended));
    } else {
      _emit(_status.copyWith(
        sampleRate: sampleRate,
        channels: channels,
        emittedChunks: _status.emittedChunks + 1,
      ));
    }
  }

  void _onError(Object error) {
    if (_disposed) return;
    _emit(_status.copyWith(
      state: AudioDecoderState.error,
      message: error.toString(),
    ));
  }

  void _emit(AudioDecoderStatus status) {
    if (_disposed) return;
    _status = status;
    _statuses.add(status);
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('audio decoder is disposed');
  }

  List<double> _samplesFromEvent(Object? value) {
    if (value is Uint8List) {
      final bytes = ByteData.sublistView(value);
      final count = value.lengthInBytes ~/ Float32List.bytesPerElement;
      return List<double>.generate(
        count,
        (index) => bytes.getFloat32(index * Float32List.bytesPerElement,
            Endian.little),
        growable: false,
      );
    }
    return (value as List<dynamic>? ?? const <dynamic>[])
        .map((sample) => (sample as num).toDouble())
        .toList(growable: false);
  }
}
