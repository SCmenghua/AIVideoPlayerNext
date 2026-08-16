import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../domain/speech/speech_models.dart';
import '../../domain/speech/speech_core_status.dart';

typedef SpeechCoreAudioLoader = Future<List<double>> Function(
  RecognitionRequest request,
);

class SpeechCoreException implements Exception {
  const SpeechCoreException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'SpeechCoreException($status): $message';
}

/// FFI provider for a fixed, normalized PCM recognition input.
///
/// The model and recognition call live in a worker isolate. The native session
/// address is retained only as an opaque integer on the owner isolate so stop
/// can call the native cancellation flag while recognition is running.
class WhisperCppSpeechRecognitionService implements SpeechRecognitionService {
  WhisperCppSpeechRecognitionService({
    required this.libraryPath,
    required this.modelPath,
    required this.audioLoader,
    this.threads = 4,
    this.requestedBackend = WhisperRequestedBackend.auto,
  });

  final String libraryPath;
  final String modelPath;
  final SpeechCoreAudioLoader audioLoader;
  final int threads;
  final WhisperRequestedBackend requestedBackend;
  final StreamController<RecognitionEvent> _events =
      StreamController<RecognitionEvent>.broadcast();
  int _generation = 0;
  _SpeechCoreBindings? _bindings;
  _ActiveWorker? _activeWorker;
  bool _disposed = false;

  @override
  Stream<RecognitionEvent> get events => _events.stream;

  SpeechCoreStatus get availability {
    try {
      _bindings ??= _SpeechCoreBindings.open(libraryPath);
      return const SpeechCoreStatus(
          available: true, message: 'speech_core available');
    } on Object {
      return const SpeechCoreStatus(
          available: false, message: 'speech_core unavailable');
    }
  }

  @override
  Future<void> start(RecognitionRequest request) async {
    _ensureUsable();
    await stop();
    if (_disposed) return;
    final generation = ++_generation;

    final samples = await audioLoader(request);
    if (generation != _generation || _disposed) return;
    if (samples.isEmpty) {
      throw const SpeechCoreException(5, 'empty audio');
    }

    final receivePort = ReceivePort();
    final iterator = StreamIterator<dynamic>(receivePort);
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<List<Object?>>(
        _speechWorker,
        <Object?>[
          receivePort.sendPort,
          libraryPath,
          modelPath,
          request.sessionId,
          samples,
          request.language,
          threads,
          requestedBackend.index,
        ],
      );
      if (!await iterator.moveNext()) {
        throw const SpeechCoreException(
            10, 'speech worker exited before startup');
      }
      final ready = _asMessage(iterator.current);
      if (ready['type'] == 'error') {
        throw SpeechCoreException(
          ready['status'] as int,
          ready['message'] as String,
        );
      }
      if (ready['type'] != 'ready') {
        throw const SpeechCoreException(
            10, 'invalid speech worker startup message');
      }

      final worker = _ActiveWorker(
        isolate: isolate,
        commandPort: ready['commandPort'] as SendPort,
        sessionAddress: ready['sessionAddress'] as int,
        bindings: _bindings ??= _SpeechCoreBindings.open(libraryPath),
        iterator: iterator,
        receivePort: receivePort,
      );
      _activeWorker = worker;
      worker.commandPort.send(
        generation == _generation && !_disposed ? 'go' : 'cancel',
      );
      final result = await worker.done;
      if (identical(_activeWorker, worker)) _activeWorker = null;

      final status = result['status'] as int;
      if (status != 0 && status != 8 && generation == _generation) {
        throw SpeechCoreException(status, result['message'] as String);
      }
      if (status != 0 || generation != _generation || _disposed) return;

      final rawSegments =
          result['segments'] as List<dynamic>? ?? const <dynamic>[];
      for (final raw in rawSegments) {
        final segment = _asMessage(raw);
        _events.add(RecognitionEvent(
          sessionId: request.sessionId,
          segmentId: '${request.sessionId}-segment-${segment['index']}',
          start:
              request.from + Duration(milliseconds: segment['startMs'] as int),
          end: request.from + Duration(milliseconds: segment['endMs'] as int),
          text: segment['text'] as String,
          language: segment['language'] as String,
          kind: RecognitionKind.finalResult,
          source: RecognitionSource.whisperCpp,
          confidence: (segment['confidence'] as num?)?.toDouble(),
        ));
      }
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      await iterator.cancel();
      receivePort.close();
    }
  }

  @override
  Future<void> stop() async {
    ++_generation;
    final worker = _activeWorker;
    if (worker == null) return;
    _activeWorker = null;
    worker.bindings.cancel(Pointer<Void>.fromAddress(worker.sessionAddress));
    worker.commandPort.send('cancel');
    try {
      await worker.done;
    } catch (_) {
      // The caller is stopping the session; the worker's terminal error is stale.
    }
  }

  @override
  Future<void> reset({required Duration position}) => stop();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _events.close();
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('speech service is disposed');
    _bindings ??= _SpeechCoreBindings.open(libraryPath);
  }
}

/// Keeps one native Whisper model alive while the caller submits many windows.
/// The worker isolate owns the model; the owner isolate only retains the active
/// native session address long enough to request cancellation.
class WhisperCppPersistentRecognitionWorker {
  WhisperCppPersistentRecognitionWorker({
    required this.libraryPath,
    required this.modelPath,
    this.threads = 4,
    this.requestedBackend = WhisperRequestedBackend.auto,
  });

  final String libraryPath;
  final String modelPath;
  final int threads;
  final WhisperRequestedBackend requestedBackend;
  WhisperBackendStatus _backendStatus = const WhisperBackendStatus.initial();
  _SpeechCoreBindings? _bindings;
  ReceivePort? _receivePort;
  StreamIterator<dynamic>? _iterator;
  SendPort? _commandPort;
  Isolate? _isolate;
  Future<void>? _active;
  int? _activeSessionAddress;
  bool _cancelRequested = false;
  int _requestId = 0;
  bool _disposed = false;
  Future<void>? _startup;

  Future<void> warmUp() => _ensureWorker();

  WhisperBackendStatus get backendStatus => _backendStatus;

  Future<List<RecognitionEvent>> recognize({
    required RecognitionRequest request,
    required List<double> samples,
  }) async {
    _ensureUsable();
    await stop();
    if (samples.isEmpty) return const [];
    _cancelRequested = false;
    final future = _recognizeInternal(request, samples);
    _active = future;
    try {
      return await future;
    } finally {
      if (identical(_active, future)) _active = null;
      _activeSessionAddress = null;
      _cancelRequested = false;
    }
  }

  Future<void> stop() async {
    final active = _active;
    final address = _activeSessionAddress;
    if (active == null) return;
    _cancelRequested = true;
    if (address != null) {
      try {
        (_bindings ??= _SpeechCoreBindings.open(libraryPath))
            .cancel(Pointer<Void>.fromAddress(address));
      } catch (_) {
        // The active future reports the worker failure to its caller.
      }
    }
    try {
      await active;
    } catch (_) {
      // Cancellation is a normal lifecycle operation.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    _commandPort?.send(<String, dynamic>{'type': 'shutdown'});
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    await _iterator?.cancel();
    _receivePort?.close();
    _commandPort = null;
    _isolate = null;
  }

  Future<List<RecognitionEvent>> _recognizeInternal(
    RecognitionRequest request,
    List<double> samples,
  ) async {
    await _ensureWorker();
    final id = ++_requestId;
    _commandPort!.send(<String, dynamic>{
      'type': 'recognize',
      'id': id,
      'sessionId': request.sessionId,
      'fromMs': request.from.inMilliseconds,
      'language': request.language,
      'samples': samples,
    });
    final iterator = _iterator!;
    if (!await iterator.moveNext()) {
      throw const SpeechCoreException(10, 'speech worker exited unexpectedly');
    }
    final started = _asMessage(iterator.current);
    if (started['type'] == 'error') {
      throw SpeechCoreException(
          started['status'] as int, started['message'] as String);
    }
    if (started['type'] != 'started' || started['id'] != id) {
      throw const SpeechCoreException(
          10, 'invalid speech worker start message');
    }
    _activeSessionAddress = started['sessionAddress'] as int;
    if (_cancelRequested) {
      (_bindings ??= _SpeechCoreBindings.open(libraryPath)).cancel(
        Pointer<Void>.fromAddress(_activeSessionAddress!),
      );
    }
    if (!await iterator.moveNext()) {
      throw const SpeechCoreException(10, 'speech worker exited unexpectedly');
    }
    final done = _asMessage(iterator.current);
    _activeSessionAddress = null;
    if (done['type'] == 'error') {
      throw SpeechCoreException(
          done['status'] as int, done['message'] as String);
    }
    if (done['type'] != 'done' || done['id'] != id) {
      throw const SpeechCoreException(
          10, 'invalid speech worker result message');
    }
    _backendStatus = _backendStatusFromMessage(done['backend']);
    final status = done['status'] as int;
    if (status == 8) return const [];
    if (status != 0) {
      throw SpeechCoreException(status, done['message'] as String);
    }
    final from = request.from;
    return (done['segments'] as List<dynamic>? ?? const <dynamic>[]).map((raw) {
      final segment = _asMessage(raw);
      return RecognitionEvent(
        sessionId: request.sessionId,
        segmentId: '${request.sessionId}-segment-${segment['index']}',
        start: from + Duration(milliseconds: segment['startMs'] as int),
        end: from + Duration(milliseconds: segment['endMs'] as int),
        text: segment['text'] as String,
        language: segment['language'] as String,
        kind: RecognitionKind.finalResult,
        source: RecognitionSource.whisperCpp,
        confidence: (segment['confidence'] as num?)?.toDouble(),
      );
    }).toList(growable: false);
  }

  Future<void> _ensureWorker() async {
    if (_commandPort != null) return;
    final startup = _startup;
    if (startup != null) return startup;
    final next = _startWorker();
    _startup = next;
    try {
      await next;
    } finally {
      if (identical(_startup, next)) _startup = null;
    }
  }

  Future<void> _startWorker() async {
    final receivePort = ReceivePort();
    final iterator = StreamIterator<dynamic>(receivePort);
    final isolate = await Isolate.spawn<List<Object?>>(
      _persistentSpeechWorker,
      <Object?>[
        receivePort.sendPort,
        libraryPath,
        modelPath,
        threads,
        requestedBackend.index,
      ],
    );
    _receivePort = receivePort;
    _iterator = iterator;
    _isolate = isolate;
    if (!await iterator.moveNext()) {
      throw const SpeechCoreException(
          10, 'speech worker exited before startup');
    }
    final ready = _asMessage(iterator.current);
    if (ready['type'] == 'error') {
      throw SpeechCoreException(
          ready['status'] as int, ready['message'] as String);
    }
    if (ready['type'] != 'ready') {
      throw const SpeechCoreException(
          10, 'invalid speech worker startup message');
    }
    _backendStatus = _backendStatusFromMessage(ready['backend']);
    _commandPort = ready['commandPort'] as SendPort;
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('speech worker is disposed');
    _bindings ??= _SpeechCoreBindings.open(libraryPath);
  }
}

final class _NativeSpeechSegment extends Struct {
  @Uint32()
  external int segmentIndex;

  @Int64()
  external int startMs;

  @Int64()
  external int endMs;

  external Pointer<Utf8> text;
  external Pointer<Utf8> language;

  @Float()
  external double confidence;

  @Uint8()
  external int isFinal;
}

final class _NativeSpeechDiagnostics extends Struct {
  @Uint64()
  external int audioSamples;

  @Uint32()
  external int inputSampleRate;

  @Uint32()
  external int inputChannels;

  @Uint64()
  external int inputSamples;

  @Uint32()
  external int outputSampleRate;

  @Uint32()
  external int outputChannels;

  @Uint64()
  external int inferenceMs;

  @Double()
  external double realtimeFactor;

  @Uint32()
  external int segmentCount;
}

typedef _StatusMessageNative = Pointer<Utf8> Function(Int32 status);
typedef _StatusMessageDart = Pointer<Utf8> Function(int status);
typedef _ModelCreateWithBackendNative = Int32 Function(
  Pointer<Utf8> path,
  Int32 requestedBackend,
  Pointer<Pointer<Void>> model,
);
typedef _ModelCreateWithBackendDart = int Function(
  Pointer<Utf8> path,
  int requestedBackend,
  Pointer<Pointer<Void>> model,
);
typedef _AbiVersionNative = Uint32 Function();
typedef _AbiVersionDart = int Function();
typedef _ModelBackendIntNative = Int32 Function(Pointer<Void> model);
typedef _ModelBackendIntDart = int Function(Pointer<Void> model);
typedef _ModelGpuEnabledNative = Uint8 Function(Pointer<Void> model);
typedef _ModelGpuEnabledDart = int Function(Pointer<Void> model);
typedef _ModelStringNative = Pointer<Utf8> Function(Pointer<Void> model);
typedef _ModelStringDart = Pointer<Utf8> Function(Pointer<Void> model);
typedef _ModelDestroyNative = Void Function(Pointer<Void> model);
typedef _ModelDestroyDart = void Function(Pointer<Void> model);
typedef _SessionCreateNative = Int32 Function(
  Pointer<Void> model,
  Pointer<Utf8> sessionId,
  Pointer<Pointer<Void>> session,
);
typedef _SessionCreateDart = int Function(
  Pointer<Void> model,
  Pointer<Utf8> sessionId,
  Pointer<Pointer<Void>> session,
);
typedef _SessionDestroyNative = Void Function(Pointer<Void> session);
typedef _SessionDestroyDart = void Function(Pointer<Void> session);
typedef _SessionCancelNative = Int32 Function(Pointer<Void> session);
typedef _SessionCancelDart = int Function(Pointer<Void> session);
typedef _SessionRecognizeNative = Int32 Function(
  Pointer<Void> session,
  Pointer<Float> samples,
  IntPtr sampleCount,
  Uint32 sampleRate,
  Pointer<Utf8> language,
  Int32 threads,
  Pointer<NativeFunction<_SegmentCallbackNative>> callback,
  Pointer<Void> userData,
  Pointer<_NativeSpeechDiagnostics> diagnostics,
);
typedef _SessionRecognizeDart = int Function(
  Pointer<Void> session,
  Pointer<Float> samples,
  int sampleCount,
  int sampleRate,
  Pointer<Utf8> language,
  int threads,
  Pointer<NativeFunction<_SegmentCallbackNative>> callback,
  Pointer<Void> userData,
  Pointer<_NativeSpeechDiagnostics> diagnostics,
);
typedef _SegmentCallbackNative = Void Function(
  Pointer<_NativeSpeechSegment> segment,
  Pointer<Void> userData,
);

class _SpeechCoreBindings {
  _SpeechCoreBindings(this.library)
      : statusMessage =
            library.lookupFunction<_StatusMessageNative, _StatusMessageDart>(
                'speech_core_status_message'),
        createModel = library.lookupFunction<
            _ModelCreateWithBackendNative, _ModelCreateWithBackendDart>(
          'speech_core_model_create_with_backend',
        ),
        abiVersion = library.lookupFunction<_AbiVersionNative, _AbiVersionDart>(
            'speech_core_abi_version'),
        modelRequestedBackend = library.lookupFunction<
            _ModelBackendIntNative, _ModelBackendIntDart>(
          'speech_core_model_requested_backend',
        ),
        modelActualBackend = library.lookupFunction<
            _ModelBackendIntNative, _ModelBackendIntDart>(
          'speech_core_model_actual_backend',
        ),
        modelGpuEnabled = library.lookupFunction<
            _ModelGpuEnabledNative, _ModelGpuEnabledDart>(
          'speech_core_model_gpu_enabled',
        ),
        modelFallbackReason = library.lookupFunction<
            _ModelBackendIntNative, _ModelBackendIntDart>(
          'speech_core_model_fallback_reason',
        ),
        modelDeviceName = library.lookupFunction<_ModelStringNative,
            _ModelStringDart>('speech_core_model_device_name'),
        modelBackendMessage = library.lookupFunction<_ModelStringNative,
            _ModelStringDart>('speech_core_model_backend_message'),
        destroyModel =
            library.lookupFunction<_ModelDestroyNative, _ModelDestroyDart>(
                'speech_core_model_destroy'),
        createSession =
            library.lookupFunction<_SessionCreateNative, _SessionCreateDart>(
                'speech_core_session_create'),
        destroySession =
            library.lookupFunction<_SessionDestroyNative, _SessionDestroyDart>(
                'speech_core_session_destroy'),
        cancelSession =
            library.lookupFunction<_SessionCancelNative, _SessionCancelDart>(
                'speech_core_session_cancel'),
        recognize = library.lookupFunction<_SessionRecognizeNative,
            _SessionRecognizeDart>('speech_core_session_recognize');

  factory _SpeechCoreBindings.open(String path) =>
      _SpeechCoreBindings(
        path == '@process' ? DynamicLibrary.process() : DynamicLibrary.open(path),
      );

  final DynamicLibrary library;
  final _StatusMessageDart statusMessage;
  final _ModelCreateWithBackendDart createModel;
  final _AbiVersionDart abiVersion;
  final _ModelBackendIntDart modelRequestedBackend;
  final _ModelBackendIntDart modelActualBackend;
  final _ModelGpuEnabledDart modelGpuEnabled;
  final _ModelBackendIntDart modelFallbackReason;
  final _ModelStringDart modelDeviceName;
  final _ModelStringDart modelBackendMessage;
  final _ModelDestroyDart destroyModel;
  final _SessionCreateDart createSession;
  final _SessionDestroyDart destroySession;
  final _SessionCancelDart cancelSession;
  final _SessionRecognizeDart recognize;

  String message(int status) => statusMessage(status).toDartString();
  WhisperBackendStatus modelStatus(Pointer<Void> model) => WhisperBackendStatus(
        requested: _requestedBackend(modelRequestedBackend(model)),
        actual: _actualBackend(modelActualBackend(model)),
        gpuEnabled: modelGpuEnabled(model) != 0,
        deviceName: modelDeviceName(model).toDartString(),
        fallbackReason: _fallbackReason(modelFallbackReason(model)),
        message: modelBackendMessage(model).toDartString(),
      );
  int cancel(Pointer<Void> session) => cancelSession(session);
}

class _ActiveWorker {
  _ActiveWorker({
    required this.isolate,
    required this.commandPort,
    required this.sessionAddress,
    required this.bindings,
    required this.iterator,
    required this.receivePort,
  }) : done = _readDone(iterator);

  final Isolate isolate;
  final SendPort commandPort;
  final int sessionAddress;
  final _SpeechCoreBindings bindings;
  final StreamIterator<dynamic> iterator;
  final ReceivePort receivePort;
  final Future<Map<String, dynamic>> done;

  static Future<Map<String, dynamic>> _readDone(
    StreamIterator<dynamic> iterator,
  ) async {
    while (await iterator.moveNext()) {
      final message = _asMessage(iterator.current);
      if (message['type'] == 'done') return message;
    }
    throw const SpeechCoreException(10, 'speech worker exited unexpectedly');
  }
}

Map<String, dynamic> _asMessage(dynamic value) =>
    Map<String, dynamic>.from(value as Map<dynamic, dynamic>);

Map<String, dynamic> _backendStatusMessage(
  _SpeechCoreBindings bindings,
  Pointer<Void> model,
) {
  final status = bindings.modelStatus(model);
  return <String, dynamic>{
    'requested': status.requested.index,
    'actual': status.actual.index,
    'gpuEnabled': status.gpuEnabled,
    'deviceName': status.deviceName,
    'fallbackReason': status.fallbackReason.index,
    'message': status.message,
  };
}

WhisperBackendStatus _backendStatusFromMessage(dynamic value) {
  final message = _asMessage(value);
  return WhisperBackendStatus(
    requested: _requestedBackend(message['requested'] as int? ?? 0),
    actual: _actualBackend(message['actual'] as int? ?? 0),
    gpuEnabled: message['gpuEnabled'] == true,
    deviceName: message['deviceName'] as String? ?? '',
    fallbackReason: _fallbackReason(message['fallbackReason'] as int? ?? 0),
    message: message['message'] as String? ?? '',
  );
}

WhisperRequestedBackend _requestedBackend(int value) =>
    WhisperRequestedBackend.values[value.clamp(
      0,
      WhisperRequestedBackend.values.length - 1,
    )];

WhisperActualBackend _actualBackend(int value) =>
    WhisperActualBackend.values[value.clamp(
      0,
      WhisperActualBackend.values.length - 1,
    )];

WhisperFallbackReason _fallbackReason(int value) => value >= 0 &&
        value < WhisperFallbackReason.unknown.index
    ? WhisperFallbackReason.values[value]
    : WhisperFallbackReason.unknown;

Future<void> _speechWorker(List<Object?> args) async {
  final mainPort = args[0] as SendPort;
  final libraryPath = args[1] as String;
  final modelPath = args[2] as String;
  final sessionId = args[3] as String;
  final samples = (args[4] as List<dynamic>).cast<num>();
  final language = args[5] as String;
  final threads = args[6] as int;
  final requestedBackend = args[7] as int;
  final bindings = _SpeechCoreBindings.open(libraryPath);
  Pointer<Void> model = nullptr;
  Pointer<Void> session = nullptr;
  ReceivePort? commandPort;
  final segments = <Map<String, dynamic>>[];

  void sendError(int status, String message) {
    mainPort.send(<String, dynamic>{
      'type': 'error',
      'status': status,
      'message': message,
    });
  }

  try {
    final modelPathPointer = modelPath.toNativeUtf8();
    final modelSlot = calloc<Pointer<Void>>();
    try {
      final status = bindings.createModel(
        modelPathPointer,
        requestedBackend,
        modelSlot,
      );
      if (status != 0) {
        sendError(status, bindings.message(status));
        return;
      }
      model = modelSlot.value;
    } finally {
      calloc.free(modelSlot);
      calloc.free(modelPathPointer);
    }

    final sessionIdPointer = sessionId.toNativeUtf8();
    final sessionSlot = calloc<Pointer<Void>>();
    try {
      final status =
          bindings.createSession(model, sessionIdPointer, sessionSlot);
      if (status != 0) {
        sendError(status, bindings.message(status));
        return;
      }
      session = sessionSlot.value;
    } finally {
      calloc.free(sessionSlot);
      calloc.free(sessionIdPointer);
    }

    final workerCommandPort = ReceivePort();
    commandPort = workerCommandPort;
    mainPort.send(<String, dynamic>{
      'type': 'ready',
      'commandPort': workerCommandPort.sendPort,
      'sessionAddress': session.address,
      'backend': _backendStatusMessage(bindings, model),
    });
    final command = await workerCommandPort.first;
    if (command == 'cancel') {
      mainPort.send(<String, dynamic>{
        'type': 'done',
        'status': 8,
        'message': bindings.message(8),
        'segments': const <Map<String, dynamic>>[],
      });
      return;
    }

    final samplePointer = calloc<Float>(samples.length);
    final languagePointer = language.toNativeUtf8();
    final diagnostics = calloc<_NativeSpeechDiagnostics>();
    final nativeCallback = NativeCallable<_SegmentCallbackNative>.isolateLocal(
      (Pointer<_NativeSpeechSegment> segmentPointer, Pointer<Void> _) {
        final segment = segmentPointer.ref;
        segments.add(<String, dynamic>{
          'index': segment.segmentIndex,
          'startMs': segment.startMs,
          'endMs': segment.endMs,
          'text': segment.text.toDartString().trim(),
          'language': segment.language.toDartString(),
          'confidence': segment.confidence == 0 ? null : segment.confidence,
        });
      },
    );
    try {
      for (var index = 0; index < samples.length; index++) {
        samplePointer[index] = samples[index].toDouble().clamp(-1.0, 1.0);
      }
      final status = bindings.recognize(
        session,
        samplePointer,
        samples.length,
        16000,
        languagePointer,
        threads,
        nativeCallback.nativeFunction,
        nullptr,
        diagnostics,
      );
      mainPort.send(<String, dynamic>{
        'type': 'done',
        'status': status,
        'message': bindings.message(status),
        'segments': segments,
        'backend': _backendStatusMessage(bindings, model),
      });
    } finally {
      nativeCallback.close();
      calloc.free(diagnostics);
      calloc.free(languagePointer);
      calloc.free(samplePointer);
    }
  } on Object catch (error) {
    sendError(10, error.toString());
  } finally {
    commandPort?.close();
    if (session != nullptr) bindings.destroySession(session);
    if (model != nullptr) bindings.destroyModel(model);
  }
}

Future<void> _persistentSpeechWorker(List<Object?> args) async {
  final mainPort = args[0] as SendPort;
  final libraryPath = args[1] as String;
  final modelPath = args[2] as String;
  final threads = args[3] as int;
  final requestedBackend = args[4] as int;
  final bindings = _SpeechCoreBindings.open(libraryPath);
  Pointer<Void> model = nullptr;
  ReceivePort? commandPort;

  void sendError(int status, String message) {
    mainPort.send(<String, dynamic>{
      'type': 'error',
      'status': status,
      'message': message,
    });
  }

  try {
    final modelPathPointer = modelPath.toNativeUtf8();
    final modelSlot = calloc<Pointer<Void>>();
    try {
      final status = bindings.createModel(
        modelPathPointer,
        requestedBackend,
        modelSlot,
      );
      if (status != 0) {
        sendError(status, bindings.message(status));
        return;
      }
      model = modelSlot.value;
    } finally {
      calloc.free(modelSlot);
      calloc.free(modelPathPointer);
    }

    commandPort = ReceivePort();
    mainPort.send(<String, dynamic>{
      'type': 'ready',
      'commandPort': commandPort.sendPort,
      'backend': _backendStatusMessage(bindings, model),
    });
    await for (final raw in commandPort) {
      final command = _asMessage(raw);
      if (command['type'] == 'shutdown') break;
      if (command['type'] != 'recognize') continue;

      final requestId = command['id'] as int;
      final sessionId = command['sessionId'] as String;
      final samples = (command['samples'] as List<dynamic>).cast<num>();
      final sessionIdPointer = sessionId.toNativeUtf8();
      final sessionSlot = calloc<Pointer<Void>>();
      Pointer<Void> session = nullptr;
      try {
        final createStatus =
            bindings.createSession(model, sessionIdPointer, sessionSlot);
        if (createStatus != 0) {
          sendError(createStatus, bindings.message(createStatus));
          continue;
        }
        session = sessionSlot.value;
      } finally {
        calloc.free(sessionSlot);
        calloc.free(sessionIdPointer);
      }

      final samplePointer = calloc<Float>(samples.length);
      final languagePointer =
          (command['language'] as String? ?? 'auto').toNativeUtf8();
      final diagnostics = calloc<_NativeSpeechDiagnostics>();
      final segments = <Map<String, dynamic>>[];
      final nativeCallback =
          NativeCallable<_SegmentCallbackNative>.isolateLocal(
        (Pointer<_NativeSpeechSegment> segmentPointer, Pointer<Void> _) {
          final segment = segmentPointer.ref;
          segments.add(<String, dynamic>{
            'index': segment.segmentIndex,
            'startMs': segment.startMs,
            'endMs': segment.endMs,
            'text': segment.text.toDartString().trim(),
            'language': segment.language.toDartString(),
            'confidence': segment.confidence == 0 ? null : segment.confidence,
          });
        },
      );
      mainPort.send(<String, dynamic>{
        'type': 'started',
        'id': requestId,
        'sessionAddress': session.address,
      });
      var status = 0;
      try {
        for (var index = 0; index < samples.length; index++) {
          samplePointer[index] = samples[index].toDouble().clamp(-1.0, 1.0);
        }
        status = bindings.recognize(
          session,
          samplePointer,
          samples.length,
          16000,
          languagePointer,
          threads,
          nativeCallback.nativeFunction,
          nullptr,
          diagnostics,
        );
      } finally {
        nativeCallback.close();
        calloc.free(diagnostics);
        calloc.free(languagePointer);
        calloc.free(samplePointer);
      }
      bindings.destroySession(session);
      session = nullptr;
      mainPort.send(<String, dynamic>{
        'type': 'done',
        'id': requestId,
        'status': status,
        'message': bindings.message(status),
        'segments': segments,
        'backend': _backendStatusMessage(bindings, model),
      });
    }
  } on Object catch (error) {
    sendError(10, error.toString());
  } finally {
    commandPort?.close();
    if (model != nullptr) bindings.destroyModel(model);
  }
}
