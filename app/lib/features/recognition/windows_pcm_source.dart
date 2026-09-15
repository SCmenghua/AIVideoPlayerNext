import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:recognition/recognition.dart';

class AudioDecoderException implements Exception {
  const AudioDecoderException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'AudioDecoderException($status): $message';
}

/// Local files become Windows paths and HTTP(S) media (loopback proxy or
/// direct) stays a URL for Media Foundation.
String windowsAudioDecoderInputFor(Uri uri) {
  if (uri.scheme == 'file') return uri.toFilePath(windows: true);
  if (uri.scheme == 'http' || uri.scheme == 'https') return uri.toString();
  throw AudioDecoderException(1, 'Windows 音频解码不支持 ${uri.scheme} 媒体地址。');
}

/// FFI boundary for the Windows Media Foundation decoder. The native worker
/// owns media reads; the callback copies only the current bounded chunk.
class WindowsPcmSource implements PcmSource {
  WindowsPcmSource({required this.libraryPath});

  final String libraryPath;
  final StreamController<PcmSourceStatus> _statuses =
      StreamController<PcmSourceStatus>.broadcast();
  final StreamController<RawPcmChunk> _chunks =
      StreamController<RawPcmChunk>.broadcast();
  _AudioDecoderBindings? _bindings;
  Pointer<Void> _handle = nullptr;
  _AudioOpenContext? _pendingOpen;
  _AudioOpenContext? _pendingSeek;
  Uri? _uri;
  int _nextCallbackToken = 1;
  final Map<int, _AudioCallbackContext> _callbacks = {};
  final Map<int, _AudioOpenContext> _openCallbacks = {};
  final Map<int, PcmSourceState> _terminalStates = {};
  _AudioCallbackContext? _activeCallback;
  bool _resumeWhenReady = false;
  bool _disposed = false;
  PcmSourceStatus _status = const PcmSourceStatus.idle();

  @override
  PcmSourceStatus get status => _status;

  @override
  Stream<PcmSourceStatus> get statuses => _statuses.stream;

  @override
  Stream<RawPcmChunk> get chunks => _chunks.stream;

  @override
  Future<void> open(Uri uri, {Duration start = Duration.zero}) async {
    _ensureUsable();
    _retireCurrentHandle();
    _retirePendingOpen();
    _uri = uri;
    _emit(const PcmSourceStatus(state: PcmSourceState.opening));
    final bindings = _binding;
    final slot = calloc<Pointer<Void>>();
    Pointer<Void> handle = nullptr;
    final input = windowsAudioDecoderInputFor(uri).toNativeUtf8();
    try {
      _check(bindings.create(slot));
      handle = slot.value;
      // Recognition is an independent sequential consumer: it must run ahead
      // of the player clock and let the session's watermarks apply
      // backpressure, so real-time pacing stays off.
      _check(bindings.setRealtime(handle, 0));
      final context = _createOpenContext(handle);
      _pendingOpen = context;
      final openStatus = bindings.openAsync(
        handle,
        input,
        start.inMilliseconds,
        context.callback.nativeFunction,
        Pointer<Void>.fromAddress(context.token),
      );
      if (openStatus != 0) {
        _discardUnstartedOpenContext(context);
        _check(openStatus);
      }
      final result = await context.finished.future;
      if (_disposed || !identical(_pendingOpen, context)) {
        _retireOpenContext(context);
        return;
      }
      _pendingOpen = null;
      if (result.status != 0) _check(result.status);
      _handle = handle;
      _emit(PcmSourceStatus(
        state: PcmSourceState.ready,
        sampleRate: result.sampleRate,
        channels: result.channels,
      ));
    } on Object catch (error) {
      final context = _pendingOpen;
      if (context != null && context.handle == handle) {
        _pendingOpen = null;
        _retireOpenContext(context);
      } else if (handle != nullptr) {
        _retireHandle(handle);
      }
      final message = _errorMessage(error);
      _emit(_status.copyWith(state: PcmSourceState.error, message: message));
      throw AudioDecoderException(10, message);
    } finally {
      calloc.free(input);
      calloc.free(slot);
    }
  }

  @override
  Future<void> start() async {
    _ensureUsable();
    if (_handle == nullptr) return;
    if (_activeCallback != null) {
      _resumeWhenReady = true;
      return;
    }
    final context = _createCallbackContext();
    _activeCallback = context;
    _emit(_status.copyWith(state: PcmSourceState.running));
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
    if (_disposed) return;
    _resumeWhenReady = false;
    if (_handle == nullptr) {
      _emit(_status.copyWith(state: PcmSourceState.paused));
      return;
    }
    _check(_binding.pause(_handle));
    final context = _activeCallback;
    if (context != null) _terminalStates[context.token] = PcmSourceState.paused;
    _emit(_status.copyWith(state: PcmSourceState.paused));
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureUsable();
    final uri = _uri;
    if (uri == null) return;
    if (_handle == nullptr) {
      await open(uri, start: position);
      return;
    }
    final existing = _pendingSeek;
    if (existing != null) {
      await existing.finished.future;
      return;
    }
    // Stop the running read first so no chunk from the old position lands
    // after the seek result.
    final active = _activeCallback;
    if (active != null) {
      active.accepting = false;
      _terminalStates[active.token] = PcmSourceState.paused;
      _activeCallback = null;
      _binding.pause(_handle);
    }
    final context = _createOpenContext(_handle);
    _pendingSeek = context;
    _emit(_status.copyWith(state: PcmSourceState.opening));
    try {
      final seekStatus = _binding.seekAsync(
        _handle,
        position.inMilliseconds,
        context.callback.nativeFunction,
        Pointer<Void>.fromAddress(context.token),
      );
      if (seekStatus != 0) {
        _discardUnstartedOpenContext(context, pendingSeek: true);
        _check(seekStatus);
      }
      final result = await context.finished.future;
      if (_disposed || !identical(_pendingSeek, context)) {
        _retireOpenContext(context, retireHandle: false);
        return;
      }
      _pendingSeek = null;
      if (result.status != 0) _check(result.status);
      _emit(PcmSourceStatus(
        state: PcmSourceState.ready,
        sampleRate: result.sampleRate,
        channels: result.channels,
      ));
    } on Object catch (error) {
      if (identical(_pendingSeek, context)) _pendingSeek = null;
      _retireOpenContext(context, retireHandle: false);
      final message = _errorMessage(error);
      _emit(_status.copyWith(state: PcmSourceState.error, message: message));
      throw AudioDecoderException(10, message);
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _resumeWhenReady = false;
    _retirePendingOpen();
    _retirePendingSeek();
    if (_handle == nullptr) {
      _emit(_status.copyWith(state: PcmSourceState.stopped));
      return;
    }
    final context = _activeCallback;
    if (context != null) _terminalStates[context.token] = PcmSourceState.stopped;
    _binding.stop(_handle);
    _emit(_status.copyWith(state: PcmSourceState.stopped));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retirePendingOpen();
    _retireCurrentHandle();
    await _statuses.close();
    await _chunks.close();
  }

  _AudioCallbackContext _createCallbackContext() {
    final context = _AudioCallbackContext(token: _nextCallbackToken++);
    context.callback = NativeCallable<_ChunkCallbackNative>.listener(
      (Pointer<_NativeAudioChunk> pointer, Pointer<Void> userData) {
        _onNativeChunk(pointer, userData);
      },
    );
    _callbacks[context.token] = context;
    return context;
  }

  _AudioOpenContext _createOpenContext(Pointer<Void> handle) {
    final context = _AudioOpenContext(token: _nextCallbackToken++, handle: handle);
    context.callback = NativeCallable<_OpenCallbackNative>.listener(
      (int status, int sampleRate, int channels, Pointer<Void> userData) {
        final current = _openCallbacks.remove(userData.address);
        if (current == null) return;
        current.callback.close();
        if (!current.finished.isCompleted) {
          current.finished.complete(_AudioOpenResult(
            status: status,
            sampleRate: sampleRate,
            channels: channels,
          ));
        }
      },
    );
    _openCallbacks[context.token] = context;
    return context;
  }

  void _onNativeChunk(Pointer<_NativeAudioChunk> pointer, Pointer<Void> userData) {
    if (pointer == nullptr) return;
    final token = userData.address;
    final context = _callbacks[token];
    final isLast = pointer.ref.isLast != 0;
    try {
      if (context == null || _disposed) return;
      final native = pointer.ref;
      if (isLast) {
        final wasActive = identical(_activeCallback, context);
        final terminal = _terminalStates.remove(context.token);
        // Only a natural end of media ends the stream; pause and stop also
        // produce a final native chunk but must not look like EOF.
        if (wasActive && terminal == null && native.sampleRate > 0) {
          _chunks.add(RawPcmChunk(
            samples: Float32List(0),
            sampleRate: native.sampleRate,
            channels: native.channels,
            mediaStart: Duration(milliseconds: native.mediaStartMs),
            isLast: true,
          ));
        }
        if (wasActive) {
          _activeCallback = null;
          final resume = _resumeWhenReady && terminal == PcmSourceState.paused;
          _resumeWhenReady = false;
          _emit(_status.copyWith(
            state: resume ? PcmSourceState.ready : terminal ?? PcmSourceState.ended,
          ));
          if (resume) unawaited(start());
        }
        return;
      }
      if (!identical(_activeCallback, context) ||
          !context.accepting ||
          native.samples == nullptr ||
          native.sampleCount == 0) {
        return;
      }
      final count = native.sampleCount * native.channels;
      final copied = Float32List.fromList(native.samples.asTypedList(count));
      _chunks.add(RawPcmChunk(
        samples: copied,
        sampleRate: native.sampleRate,
        channels: native.channels,
        mediaStart: Duration(milliseconds: native.mediaStartMs),
      ));
    } finally {
      _binding.freeChunk(pointer);
      if (isLast && context != null) {
        _callbacks.remove(token);
        context.callback.close();
      }
    }
  }

  void _retireCurrentHandle() {
    final handle = _handle;
    _handle = nullptr;
    _resumeWhenReady = false;
    _retirePendingSeek();
    final context = _activeCallback;
    if (context != null) {
      context.accepting = false;
      _terminalStates.remove(context.token);
      _activeCallback = null;
    }
    if (handle != nullptr) _retireHandle(handle);
  }

  void _retireHandle(Pointer<Void> handle) {
    try {
      _binding.stop(handle);
    } on Object {
      // The background reaper still makes a best-effort cleanup attempt.
    }
    unawaited(_reapHandle(handle).catchError((Object _) {}));
  }

  void _retirePendingOpen() {
    final context = _pendingOpen;
    _pendingOpen = null;
    if (context != null) _retireOpenContext(context);
  }

  void _retirePendingSeek() {
    final context = _pendingSeek;
    _pendingSeek = null;
    // A seek callback shares the current handle; whoever retires the handle
    // owns destruction, this only marks the callback stale.
    if (context != null) _retireOpenContext(context, retireHandle: false);
  }

  void _retireOpenContext(_AudioOpenContext context, {bool retireHandle = true}) {
    if (context.retired) return;
    context.retired = true;
    if (retireHandle) _retireHandle(context.handle);
  }

  void _discardUnstartedOpenContext(_AudioOpenContext context, {bool pendingSeek = false}) {
    _openCallbacks.remove(context.token);
    context.callback.close();
    if (pendingSeek) {
      if (identical(_pendingSeek, context)) _pendingSeek = null;
    } else if (identical(_pendingOpen, context)) {
      _pendingOpen = null;
    }
  }

  Future<void> _reapHandle(Pointer<Void> handle) async {
    // Joining can block on a network read, so do it away from the UI isolate.
    // Destruction stays here because the decoder's COM initialization belongs
    // to the isolate that created the native handle.
    await Isolate.run(() {
      final bindings = _AudioDecoderBindings.open(libraryPath);
      bindings.wait(Pointer<Void>.fromAddress(handle.address));
    });
    _binding.destroy(handle);
  }

  void _check(int status) {
    if (status == 0) return;
    throw AudioDecoderException(status, _binding.message(status).toDartString());
  }

  _AudioDecoderBindings get _binding => _bindings ??= _AudioDecoderBindings.open(libraryPath);

  String _errorMessage(Object error) {
    if (error is AudioDecoderException) return error.message;
    return 'Windows 音频解码初始化失败（${error.runtimeType}）。';
  }

  void _emit(PcmSourceStatus value) {
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
  _AudioCallbackContext({required this.token});

  final int token;
  late final NativeCallable<_ChunkCallbackNative> callback;
  bool accepting = true;
}

class _AudioOpenContext {
  _AudioOpenContext({required this.token, required this.handle});

  final int token;
  final Pointer<Void> handle;
  final Completer<_AudioOpenResult> finished = Completer<_AudioOpenResult>();
  late final NativeCallable<_OpenCallbackNative> callback;
  bool retired = false;
}

class _AudioOpenResult {
  const _AudioOpenResult({
    required this.status,
    required this.sampleRate,
    required this.channels,
  });

  final int status;
  final int sampleRate;
  final int channels;
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
    Pointer<_NativeAudioChunk> chunk, Pointer<Void> userData);
typedef _OpenCallbackNative = Void Function(
    Int32 status, Uint32 sampleRate, Uint32 channels, Pointer<Void> userData);
typedef _StatusMessageNative = Pointer<Utf8> Function(Int32 status);
typedef _StatusMessageDart = Pointer<Utf8> Function(int status);
typedef _CreateNative = Int32 Function(Pointer<Pointer<Void>> decoder);
typedef _CreateDart = int Function(Pointer<Pointer<Void>> decoder);
typedef _DestroyNative = Void Function(Pointer<Void> decoder);
typedef _DestroyDart = void Function(Pointer<Void> decoder);
typedef _OpenAsyncNative = Int32 Function(
  Pointer<Void> decoder,
  Pointer<Utf8> path,
  Int64 startPositionMs,
  Pointer<NativeFunction<_OpenCallbackNative>> callback,
  Pointer<Void> userData,
);
typedef _OpenAsyncDart = int Function(
  Pointer<Void> decoder,
  Pointer<Utf8> path,
  int startPositionMs,
  Pointer<NativeFunction<_OpenCallbackNative>> callback,
  Pointer<Void> userData,
);
typedef _SetRealtimeNative = Int32 Function(Pointer<Void> decoder, Uint8 enabled);
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
typedef _DecoderControlNative = Int32 Function(Pointer<Void> decoder);
typedef _DecoderControlDart = int Function(Pointer<Void> decoder);
typedef _SeekAsyncNative = Int32 Function(
  Pointer<Void> decoder,
  Int64 positionMs,
  Pointer<NativeFunction<_OpenCallbackNative>> callback,
  Pointer<Void> userData,
);
typedef _SeekAsyncDart = int Function(
  Pointer<Void> decoder,
  int positionMs,
  Pointer<NativeFunction<_OpenCallbackNative>> callback,
  Pointer<Void> userData,
);
typedef _ChunkFreeNative = Void Function(Pointer<_NativeAudioChunk> chunk);
typedef _ChunkFreeDart = void Function(Pointer<_NativeAudioChunk> chunk);
typedef _WaitNative = Void Function(Pointer<Void> decoder);
typedef _WaitDart = void Function(Pointer<Void> decoder);

class _AudioDecoderBindings {
  _AudioDecoderBindings(DynamicLibrary library)
      : message = library.lookupFunction<_StatusMessageNative, _StatusMessageDart>(
            'ai_audio_decoder_status_message'),
        create = library.lookupFunction<_CreateNative, _CreateDart>('ai_audio_decoder_create'),
        destroy =
            library.lookupFunction<_DestroyNative, _DestroyDart>('ai_audio_decoder_destroy'),
        openAsync = library.lookupFunction<_OpenAsyncNative, _OpenAsyncDart>(
            'ai_audio_decoder_open_async'),
        setRealtime = library.lookupFunction<_SetRealtimeNative, _SetRealtimeDart>(
            'ai_audio_decoder_set_realtime'),
        start = library.lookupFunction<_StartNative, _StartDart>('ai_audio_decoder_start'),
        pause = library.lookupFunction<_DecoderControlNative, _DecoderControlDart>(
            'ai_audio_decoder_pause'),
        seekAsync = library.lookupFunction<_SeekAsyncNative, _SeekAsyncDart>(
            'ai_audio_decoder_seek_async'),
        stop = library.lookupFunction<_DecoderControlNative, _DecoderControlDart>(
            'ai_audio_decoder_stop'),
        wait = library.lookupFunction<_WaitNative, _WaitDart>('ai_audio_decoder_wait'),
        freeChunk = library.lookupFunction<_ChunkFreeNative, _ChunkFreeDart>(
            'ai_audio_decoder_chunk_free');

  factory _AudioDecoderBindings.open(String path) =>
      _AudioDecoderBindings(DynamicLibrary.open(path));

  final _StatusMessageDart message;
  final _CreateDart create;
  final _DestroyDart destroy;
  final _OpenAsyncDart openAsync;
  final _SetRealtimeDart setRealtime;
  final _StartDart start;
  final _DecoderControlDart pause;
  final _SeekAsyncDart seekAsync;
  final _DecoderControlDart stop;
  final _WaitDart wait;
  final _ChunkFreeDart freeChunk;
}
