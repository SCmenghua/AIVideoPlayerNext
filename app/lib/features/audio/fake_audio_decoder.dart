import 'dart:async';

import '../../domain/audio/audio_models.dart';

class FakeAudioDecoder implements AudioDecoder {
  FakeAudioDecoder({required List<AudioChunk> chunks})
      : _chunks = List<AudioChunk>.from(chunks);

  final List<AudioChunk> _chunks;
  final StreamController<AudioDecoderStatus> _statuses =
      StreamController<AudioDecoderStatus>.broadcast();
  final StreamController<AudioChunk> _output =
      StreamController<AudioChunk>.broadcast();
  AudioDecoderStatus _status = const AudioDecoderStatus.idle();
  AudioDecoderRequest? _request;
  Timer? _timer;
  int _index = 0;
  int _generation = 0;
  bool _disposed = false;

  @override
  AudioDecoderStatus get status => _status;

  @override
  Stream<AudioDecoderStatus> get statuses => _statuses.stream;

  @override
  Stream<AudioChunk> get chunks => _output.stream;

  @override
  Future<void> open(AudioDecoderRequest request) async {
    _ensureOpen();
    await stop();
    _request = request;
    _index = _chunks.indexWhere((chunk) => chunk.mediaStart >= request.start);
    if (_index < 0) _index = _chunks.length;
    _emit(AudioDecoderStatus(
      state: AudioDecoderState.ready,
      sessionId: request.sessionId,
      sampleRate: _chunks.isEmpty ? null : _chunks.first.sampleRate,
      channels: _chunks.isEmpty ? null : _chunks.first.channels,
    ));
  }

  @override
  Future<void> start() async {
    _ensureOpen();
    if (_request == null) return;
    if (_status.state == AudioDecoderState.running) return;
    final generation = ++_generation;
    _emit(_status.copyWith(state: AudioDecoderState.running));
    Future<void>(() async {
      while (generation == _generation &&
          !_disposed &&
          _status.state == AudioDecoderState.running &&
          _index < _chunks.length) {
        final chunk = _chunks[_index++];
        _output.add(chunk.copyWith(sessionId: _request!.sessionId));
        _emit(_status.copyWith(emittedChunks: _status.emittedChunks + 1));
        await Future<void>.delayed(Duration.zero);
      }
      if (generation == _generation &&
          !_disposed &&
          _index >= _chunks.length &&
          _status.state == AudioDecoderState.running) {
        _emit(_status.copyWith(state: AudioDecoderState.ended));
      }
    });
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    ++_generation;
    final request = _request;
    if (request != null &&
        _status.sampleRate != null &&
        _status.channels != null) {
      _output.add(AudioChunk(
        sessionId: request.sessionId,
        mediaStart: Duration.zero,
        sampleRate: _status.sampleRate!,
        channels: _status.channels!,
        samples: const [],
        isLast: true,
      ));
    }
    _emit(_status.copyWith(state: AudioDecoderState.paused));
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureOpen();
    ++_generation;
    _emit(_status.copyWith(state: AudioDecoderState.seeking));
    _index = _chunks.indexWhere((chunk) => chunk.mediaStart >= position);
    if (_index < 0) _index = _chunks.length;
    _emit(_status.copyWith(
      state: AudioDecoderState.ready,
      emittedChunks: 0,
    ));
  }

  @override
  Future<void> stop() async {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    if (!_disposed && _status.state != AudioDecoderState.idle) {
      _emit(_status.copyWith(state: AudioDecoderState.stopped));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    await _statuses.close();
    await _output.close();
    _status = _status.copyWith(state: AudioDecoderState.disposed);
  }

  void _emit(AudioDecoderStatus status) {
    if (_disposed) return;
    _status = status;
    _statuses.add(status);
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('audio decoder is disposed');
  }
}
