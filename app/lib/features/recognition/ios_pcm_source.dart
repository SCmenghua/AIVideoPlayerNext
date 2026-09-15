import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:recognition/recognition.dart';

class IosAudioDecoderException implements Exception {
  const IosAudioDecoderException(this.message);

  final String message;

  @override
  String toString() => 'IosAudioDecoderException: $message';
}

/// AVFoundation-backed media decoder on iOS. The bridge asks AVFoundation for
/// 16 kHz mono float, so chunks pass through the normaliser unchanged.
class IosPcmSource implements PcmSource {
  static const _methods = MethodChannel('ai_video_player/ios_audio');
  static const _events = EventChannel('ai_video_player/ios_audio_events');

  final StreamController<PcmSourceStatus> _statuses =
      StreamController<PcmSourceStatus>.broadcast();
  final StreamController<RawPcmChunk> _chunks =
      StreamController<RawPcmChunk>.broadcast();
  StreamSubscription<dynamic>? _eventsSubscription;
  PcmSourceStatus _status = const PcmSourceStatus.idle();
  String? _sessionId;
  int _sessionCounter = 0;
  bool _disposed = false;

  @override
  PcmSourceStatus get status => _status;

  @override
  Stream<PcmSourceStatus> get statuses => _statuses.stream;

  @override
  Stream<RawPcmChunk> get chunks => _chunks.stream;

  @override
  Future<void> open(Uri uri, {Duration start = Duration.zero}) async {
    _ensureUsable();
    await stop();
    if (!Platform.isIOS) {
      throw const IosAudioDecoderException('iOS audio decoder unavailable');
    }
    final sessionId = 'ios-${++_sessionCounter}';
    _sessionId = sessionId;
    _emit(const PcmSourceStatus(state: PcmSourceState.opening));
    _eventsSubscription ??=
        _events.receiveBroadcastStream().listen(_onEvent, onError: _onError);
    try {
      final arguments = <String, Object?>{
        'uri': uri.toString(),
        'sessionId': sessionId,
        'headers': const <String, String>{},
      };
      if (uri.scheme == 'file') arguments['path'] = uri.toFilePath();
      await _methods.invokeMethod<void>('open', arguments);
      if (start > Duration.zero) {
        await _methods.invokeMethod<void>('seek', <String, Object?>{
          'positionMs': start.inMilliseconds,
        });
      }
      _emit(const PcmSourceStatus(
        state: PcmSourceState.ready,
        sampleRate: 16000,
        channels: 1,
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
    if (_sessionId == null || _status.state == PcmSourceState.error) return;
    await _methods.invokeMethod<void>('start');
    _emit(_status.copyWith(state: PcmSourceState.running));
  }

  @override
  Future<void> pause() async {
    if (_disposed || _sessionId == null) return;
    await _methods.invokeMethod<void>('pause');
    _emit(_status.copyWith(state: PcmSourceState.paused));
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureUsable();
    if (_sessionId == null) return;
    _emit(_status.copyWith(state: PcmSourceState.opening));
    try {
      await _methods.invokeMethod<void>('seek', <String, Object?>{
        'positionMs': position.inMilliseconds,
      });
      _emit(_status.copyWith(state: PcmSourceState.ready));
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
    _emit(_status.copyWith(state: PcmSourceState.stopped));
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
    final sessionId = event['sessionId'] as String?;
    if (sessionId == null || sessionId != _sessionId) return;
    if (event['type'] == 'error') {
      _onError(event['message'] ?? 'iOS 音频解码失败');
      return;
    }
    final isLast = event['isLast'] == true;
    final ended = event['ended'] == true;
    final sampleRate = event['sampleRate'] as int? ?? 16000;
    final channels = event['channels'] as int? ?? 1;
    if (isLast) {
      // The bridge flushes a tail on pause as well; only a real end of
      // media terminates the stream.
      if (ended) {
        _chunks.add(RawPcmChunk(
          samples: Float32List(0),
          sampleRate: sampleRate,
          channels: channels,
          mediaStart: Duration(milliseconds: event['mediaStartMs'] as int? ?? 0),
          isLast: true,
        ));
        _emit(_status.copyWith(state: PcmSourceState.ended));
      }
      return;
    }
    _chunks.add(RawPcmChunk(
      samples: _floatsFromEvent(event['samples']),
      sampleRate: sampleRate,
      channels: channels,
      mediaStart: Duration(milliseconds: event['mediaStartMs'] as int? ?? 0),
    ));
    if (_status.sampleRate != sampleRate || _status.channels != channels) {
      _emit(_status.copyWith(sampleRate: sampleRate, channels: channels));
    }
  }

  void _onError(Object error) {
    if (_disposed) return;
    _emit(_status.copyWith(state: PcmSourceState.error, message: error.toString()));
  }

  void _emit(PcmSourceStatus status) {
    if (_disposed) return;
    _status = status;
    _statuses.add(status);
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('audio decoder is disposed');
  }

  static Float32List _floatsFromEvent(Object? value) {
    if (value is Uint8List) {
      final count = value.lengthInBytes ~/ Float32List.bytesPerElement;
      if (value.offsetInBytes % Float32List.bytesPerElement == 0) {
        return Float32List.fromList(
          Float32List.view(value.buffer, value.offsetInBytes, count),
        );
      }
      final bytes = ByteData.sublistView(value);
      final result = Float32List(count);
      for (var i = 0; i < count; i++) {
        result[i] = bytes.getFloat32(i * Float32List.bytesPerElement, Endian.little);
      }
      return result;
    }
    final list = value as List<dynamic>? ?? const <dynamic>[];
    final result = Float32List(list.length);
    for (var i = 0; i < list.length; i++) {
      result[i] = (list[i] as num).toDouble();
    }
    return result;
  }
}
