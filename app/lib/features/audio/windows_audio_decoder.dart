import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../domain/audio/audio_models.dart';

class AudioDecoderException implements Exception {
  const AudioDecoderException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'AudioDecoderException($status): $message';
}

/// FFI boundary for the Windows Media Foundation decoder. The native worker
/// owns media reads; the callback copies only the current bounded chunk.
class WindowsAudioDecoder implements AudioDecoder {
  WindowsAudioDecoder({required this.libraryPath});

  final String libraryPath;
  final StreamController<AudioDecoderStatus> _statuses =
      StreamController<AudioDecoderStatus>.broadcast();
  final StreamController<AudioChunk> _chunks =
      StreamController<AudioChunk>.broadcast();
  _AudioDecoderBindings? _bindings;
  Pointer<Void> _handle = nullptr;
  String? _sessionId;
  int _nextCallbackToken = 1;
  final Map<int, _AudioCallbackContext> _callbacks = {};
  _AudioCallbackContext? _activeCallback;
  bool _disposed = false;
  AudioDecoderStatus _status = const AudioDecoderStatus.idle();

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
    _sessionId = request.sessionId;
    _emit(AudioDecoderStatus(
      state: AudioDecoderState.opening,
      sessionId: request.sessionId,
    ));
    try {
      final bindings = _binding;
      final slot = calloc<Pointer<Void>>();
      final path = request.source.uri.toFilePath().toNativeUtf8();
      try {
        final result = bindings.create(slot);
        _check(result);
        _handle = slot.value;
        _check(bindings.setRealtime(_handle, 1));
        _check(bindings.open(_handle, path));
        if (request.start > Duration.zero) {
          _check(bindings.seek(_handle, request.start.inMilliseconds));
        }
      } finally {
        calloc.free(path);
        calloc.free(slot);
      }
      _emit(_status.copyWith(
        state: AudioDecoderState.ready,
        sessionId: request.sessionId,
        clearMessage: true,
      ));
    } on Object catch (error) {
      await _releaseHandle();
      final message = _errorMessage(error);
      _emit(_status.copyWith(
        state: AudioDecoderState.error,
        sessionId: request.sessionId,
        message: message,
      ));
      throw AudioDecoderException(10, message);
    }
  }

  @override
  Future<void> start() async {
    _ensureUsable();
    if (_handle == nullptr || _sessionId == null) return;
    final context = _createCallbackContext(_sessionId!);
    _activeCallback = context;
    _emit(_status.copyWith(state: AudioDecoderState.running));
    try {
      _check(_binding.start(
        _handle,
        context.callback.nativeFunction,
        Pointer<Void>.fromAddress(context.token),
      ));
    } on Object {
      _activeCallback = null;
      _callbacks.remove(context.token);
      context.callback.close();
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    if (_disposed || _handle == nullptr) return;
    _check(_binding.pause(_handle));
    await _finishActiveCallback();
    _emit(_status.copyWith(state: AudioDecoderState.paused));
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureUsable();
    if (_handle == nullptr) return;
    _emit(_status.copyWith(state: AudioDecoderState.seeking));
    _check(_binding.seek(_handle, position.inMilliseconds));
    await _finishActiveCallback();
    _emit(_status.copyWith(state: AudioDecoderState.ready));
  }

  @override
  Future<void> stop() async {
    if (_disposed || _handle == nullptr) return;
    _binding.stop(_handle);
    await _finishActiveCallback();
    _emit(_status.copyWith(state: AudioDecoderState.stopped));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    if (_handle != nullptr) {
      _binding.destroy(_handle);
      _handle = nullptr;
    }
    await Future.wait(
        _callbacks.values.map((context) => context.finished.future));
    await _statuses.close();
    await _chunks.close();
  }

  _AudioCallbackContext _createCallbackContext(String sessionId) {
    final context = _AudioCallbackContext(
      token: _nextCallbackToken++,
      sessionId: sessionId,
    );
    context.callback = NativeCallable<_ChunkCallbackNative>.listener(
      (Pointer<_NativeAudioChunk> pointer, Pointer<Void> userData) {
        _onNativeChunk(pointer, userData);
      },
    );
    _callbacks[context.token] = context;
    return context;
  }

  void _onNativeChunk(
    Pointer<_NativeAudioChunk> pointer,
    Pointer<Void> userData,
  ) {
    if (pointer == nullptr) return;
    final token = userData.address;
    final context = _callbacks[token];
    final isLast = pointer.ref.isLast != 0;
    try {
      if (context == null || _disposed) return;
      final native = pointer.ref;
      if (isLast) {
        if (native.sampleRate > 0 && native.channels > 0) {
          _chunks.add(AudioChunk(
            sessionId: context.sessionId,
            mediaStart: Duration(milliseconds: native.mediaStartMs),
            sampleRate: native.sampleRate,
            channels: native.channels,
            samples: const [],
            isLast: true,
          ));
        }
        if (identical(_activeCallback, context)) {
          _activeCallback = null;
          _emit(_status.copyWith(state: AudioDecoderState.ended));
        }
        return;
      }
      if (!identical(_activeCallback, context) ||
          !context.accepting ||
          native.samples == nullptr ||
          native.sampleCount == 0) {
        return;
      }
      final copied = List<double>.generate(
        native.sampleCount * native.channels,
        (index) => native.samples[index],
        growable: false,
      );
      _emit(_status.copyWith(
        sampleRate: native.sampleRate,
        channels: native.channels,
        emittedChunks: _status.emittedChunks + 1,
      ));
      _chunks.add(AudioChunk(
        sessionId: context.sessionId,
        mediaStart: Duration(milliseconds: native.mediaStartMs),
        sampleRate: native.sampleRate,
        channels: native.channels,
        samples: copied,
      ));
    } finally {
      _binding.freeChunk(pointer);
      if (isLast && context != null) {
        _callbacks.remove(token);
        context.callback.close();
        if (!context.finished.isCompleted) context.finished.complete();
      }
    }
  }

  Future<void> _finishActiveCallback() async {
    final context = _activeCallback;
    if (context == null) return;
    context.accepting = false;
    await context.finished.future;
  }

  Future<void> _releaseHandle() async {
    if (_handle != nullptr) {
      _binding.stop(_handle);
      _binding.destroy(_handle);
      _handle = nullptr;
    }
  }

  void _check(int status) {
    if (status == 0) return;
    throw AudioDecoderException(
        status, _binding.message(status).toDartString());
  }

  _AudioDecoderBindings get _binding =>
      _bindings ??= _AudioDecoderBindings.open(libraryPath);

  String _errorMessage(Object error) {
    if (error is AudioDecoderException) return error.message;
    return 'Windows 音频解码初始化失败（${error.runtimeType}）。';
  }

  void _emit(AudioDecoderStatus value) {
    if (_disposed) return;
    _status = value;
    _statuses.add(value);
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('audio decoder is disposed');
    if (!Platform.isWindows) {
      throw const AudioDecoderException(4, 'Windows audio decoder unavailable');
    }
  }
}

class _AudioCallbackContext {
  _AudioCallbackContext({required this.token, required this.sessionId});

  final int token;
  final String sessionId;
  final Completer<void> finished = Completer<void>();
  late final NativeCallable<_ChunkCallbackNative> callback;
  bool accepting = true;
}

final class _NativeAudioChunk extends Struct {
  @Int64()
  external int mediaStartMs;

  @Uint32()
  external int sampleRate;

  @Uint32()
  external int channels;

  @Uint32()
  external int sampleCount;

  external Pointer<Float> samples;

  @Uint8()
  external int isLast;
}

typedef _ChunkCallbackNative = Void Function(
  Pointer<_NativeAudioChunk> chunk,
  Pointer<Void> userData,
);
typedef _StatusMessageNative = Pointer<Utf8> Function(Int32 status);
typedef _StatusMessageDart = Pointer<Utf8> Function(int status);
typedef _CreateNative = Int32 Function(Pointer<Pointer<Void>> decoder);
typedef _CreateDart = int Function(Pointer<Pointer<Void>> decoder);
typedef _DestroyNative = Void Function(Pointer<Void> decoder);
typedef _DestroyDart = void Function(Pointer<Void> decoder);
typedef _OpenNative = Int32 Function(Pointer<Void> decoder, Pointer<Utf8> path);
typedef _OpenDart = int Function(Pointer<Void> decoder, Pointer<Utf8> path);
typedef _SetRealtimeNative = Int32 Function(
    Pointer<Void> decoder, Uint8 enabled);
typedef _SetRealtimeDart = int Function(Pointer<Void> decoder, int enabled);
typedef _StartNative = Int32 Function(
  Pointer<Void> decoder,
  Pointer<NativeFunction<_ChunkCallbackNative>> callback,
  Pointer<Void> userData,
);
typedef _StartDart = int Function(
  Pointer<Void> decoder,
  Pointer<NativeFunction<_ChunkCallbackNative>> callback,
  Pointer<Void> userData,
);
typedef _DecoderControlNative = Int32 Function(
  Pointer<Void> decoder,
);
typedef _DecoderControlDart = int Function(Pointer<Void> decoder);
typedef _SeekNative = Int32 Function(Pointer<Void> decoder, Int64 positionMs);
typedef _SeekDart = int Function(Pointer<Void> decoder, int positionMs);
typedef _ChunkFreeNative = Void Function(Pointer<_NativeAudioChunk> chunk);
typedef _ChunkFreeDart = void Function(Pointer<_NativeAudioChunk> chunk);

class _AudioDecoderBindings {
  _AudioDecoderBindings(DynamicLibrary library)
      : message =
            library.lookupFunction<_StatusMessageNative, _StatusMessageDart>(
                'ai_audio_decoder_status_message'),
        create = library.lookupFunction<_CreateNative, _CreateDart>(
            'ai_audio_decoder_create'),
        destroy = library.lookupFunction<_DestroyNative, _DestroyDart>(
            'ai_audio_decoder_destroy'),
        open = library
            .lookupFunction<_OpenNative, _OpenDart>('ai_audio_decoder_open'),
        setRealtime =
            library.lookupFunction<_SetRealtimeNative, _SetRealtimeDart>(
                'ai_audio_decoder_set_realtime'),
        start = library
            .lookupFunction<_StartNative, _StartDart>('ai_audio_decoder_start'),
        pause =
            library.lookupFunction<_DecoderControlNative, _DecoderControlDart>(
                'ai_audio_decoder_pause'),
        seek = library
            .lookupFunction<_SeekNative, _SeekDart>('ai_audio_decoder_seek'),
        stop =
            library.lookupFunction<_DecoderControlNative, _DecoderControlDart>(
                'ai_audio_decoder_stop'),
        freeChunk = library.lookupFunction<_ChunkFreeNative, _ChunkFreeDart>(
            'ai_audio_decoder_chunk_free');

  factory _AudioDecoderBindings.open(String path) =>
      _AudioDecoderBindings(DynamicLibrary.open(path));

  final _StatusMessageDart message;
  final _CreateDart create;
  final _DestroyDart destroy;
  final _OpenDart open;
  final _SetRealtimeDart setRealtime;
  final _StartDart start;
  final _DecoderControlDart pause;
  final _SeekDart seek;
  final _DecoderControlDart stop;
  final _ChunkFreeDart freeChunk;
}
