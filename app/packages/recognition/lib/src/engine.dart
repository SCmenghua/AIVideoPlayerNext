import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'config.dart';
import 'contracts.dart';
import 'native_bindings.dart';

enum EngineState { unloaded, loading, ready, busy, error, disposed }

class RawSegment {
  const RawSegment({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.language,
    required this.avgLogprob,
    required this.noSpeechProb,
    required this.repetition,
    required this.tokenCount,
  });

  final int index;
  final int startMs;
  final int endMs;
  final String text;
  final String language;
  final double avgLogprob;
  final double noSpeechProb;
  final double repetition;
  final int tokenCount;

  Map<String, Object?> toMap() => {
        'index': index,
        'startMs': startMs,
        'endMs': endMs,
        'text': text,
        'language': language,
        'avgLogprob': avgLogprob,
        'noSpeechProb': noSpeechProb,
        'repetition': repetition,
        'tokenCount': tokenCount,
      };

  static RawSegment fromMap(Map<Object?, Object?> map) => RawSegment(
        index: map['index'] as int,
        startMs: map['startMs'] as int,
        endMs: map['endMs'] as int,
        text: map['text'] as String,
        language: map['language'] as String,
        avgLogprob: map['avgLogprob'] as double,
        noSpeechProb: map['noSpeechProb'] as double,
        repetition: map['repetition'] as double,
        tokenCount: map['tokenCount'] as int,
      );
}

class EngineBackendInfo {
  const EngineBackendInfo({
    required this.requested,
    required this.actual,
    required this.gpuEnabled,
    required this.deviceName,
    required this.fallbackReason,
    required this.message,
  });

  final String requested;
  final String actual;
  final bool gpuEnabled;
  final String deviceName;
  final int fallbackReason;
  final String message;

  Map<String, Object?> toMap() => {
        'requested': requested,
        'actual': actual,
        'gpuEnabled': gpuEnabled,
        'deviceName': deviceName,
        'fallbackReason': fallbackReason,
        'message': message,
      };

  static EngineBackendInfo fromMap(Map<Object?, Object?> map) => EngineBackendInfo(
        requested: map['requested'] as String,
        actual: map['actual'] as String,
        gpuEnabled: map['gpuEnabled'] as bool,
        deviceName: map['deviceName'] as String,
        fallbackReason: map['fallbackReason'] as int,
        message: map['message'] as String,
      );

  @override
  String toString() =>
      'EngineBackendInfo($requested -> $actual, gpu=$gpuEnabled, $deviceName, $message)';
}

class EngineRequest {
  const EngineRequest({
    required this.samples,
    required this.language,
    required this.threads,
    required this.decoder,
    this.prompt,
  });

  final Float32List samples;
  final String language;
  final int threads;
  final DecoderOptions decoder;
  final String? prompt;
}

class EngineResult {
  const EngineResult({
    required this.segments,
    required this.inference,
    required this.droppedSegments,
    required this.backend,
  });

  final List<RawSegment> segments;
  final Duration inference;
  final int droppedSegments;
  final EngineBackendInfo backend;
}

/// A resident whisper.cpp model in a worker isolate. Requests run one at a
/// time; [cancel] aborts the in-flight native call from the owner isolate.
class WhisperEngine implements RecognitionEngine {
  WhisperEngine({
    required this.libraryPath,
    required this.modelPath,
    this.backend = SpeechBackend.auto,
  });

  final String libraryPath;
  final String modelPath;
  final SpeechBackend backend;

  EngineState _state = EngineState.unloaded;
  String? _error;
  EngineBackendInfo? _backend;
  SpeechCoreBindings? _bindings;
  Isolate? _isolate;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _subscription;
  SendPort? _commandPort;
  int _sessionAddress = 0;
  Completer<void>? _loading;
  final Queue<_QueuedRequest> _queue = Queue<_QueuedRequest>();
  _QueuedRequest? _active;
  int _nextId = 0;
  final StreamController<EngineState> _states = StreamController<EngineState>.broadcast();

  @override
  EngineState get state => _state;
  String? get error => _error;
  @override
  EngineBackendInfo? get backendInfo => _backend;
  Stream<EngineState> get states => _states.stream;
  bool get isReady => _state == EngineState.ready || _state == EngineState.busy;

  @override
  Future<void> load() {
    final pending = _loading;
    if (pending != null) return pending.future;
    if (_state == EngineState.disposed) {
      return Future.error(StateError('engine disposed'));
    }
    if (isReady) return Future.value();
    final completer = Completer<void>();
    _loading = completer;
    _setState(EngineState.loading);
    _start().then((_) {
      _setState(EngineState.ready);
      completer.complete();
    }, onError: (Object error, StackTrace stack) {
      _error = error.toString();
      _setState(EngineState.error);
      completer.completeError(error, stack);
    }).whenComplete(() => _loading = null);
    return completer.future;
  }

  Future<void> _start() async {
    _bindings = SpeechCoreBindings.open(libraryPath);
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    final ready = Completer<Map<Object?, Object?>>();
    _subscription = receivePort.listen((dynamic message) {
      // Uncaught isolate errors arrive through onError as [error, stack].
      final map = message is List
          ? <Object?, Object?>{'type': 'fatal', 'message': message.first.toString()}
          : message as Map<Object?, Object?>;
      if (!ready.isCompleted) {
        ready.complete(map);
        return;
      }
      _onWorkerMessage(map);
    });
    _isolate = await Isolate.spawn<List<Object?>>(
      _engineMain,
      <Object?>[receivePort.sendPort, libraryPath, modelPath, backend.index],
      errorsAreFatal: true,
      onError: receivePort.sendPort,
    );
    final first = await ready.future;
    if (first['type'] != 'ready') {
      _teardown();
      throw SpeechCoreException(
        SpeechCoreStatus.fromCode(first['status'] as int? ?? 10),
        first['message'] as String? ?? 'engine worker failed to start',
      );
    }
    _commandPort = first['commandPort'] as SendPort;
    _sessionAddress = first['sessionAddress'] as int;
    _backend = EngineBackendInfo.fromMap(first['backend'] as Map<Object?, Object?>);
  }

  @override
  Future<EngineResult> recognize(EngineRequest request) {
    if (_state == EngineState.disposed) {
      return Future.error(StateError('engine disposed'));
    }
    if (!isReady) {
      return Future.error(StateError('engine not loaded: ${_error ?? _state.name}'));
    }
    if (request.samples.isEmpty) {
      return Future.error(
        const SpeechCoreException(SpeechCoreStatus.emptyAudio, 'empty audio'),
      );
    }
    final queued = _QueuedRequest(_nextId++, request);
    _queue.add(queued);
    _pump();
    return queued.completer.future;
  }

  /// Aborts the in-flight recognition and drops queued requests. Their
  /// futures complete with a cancelled [SpeechCoreException].
  @override
  void cancel() {
    for (final queued in _queue) {
      queued.completer.completeError(
        const SpeechCoreException(SpeechCoreStatus.cancelled, 'cancelled'),
      );
    }
    _queue.clear();
    final active = _active;
    if (active != null && _sessionAddress != 0) {
      _bindings?.sessionCancel(Pointer<Void>.fromAddress(_sessionAddress));
    }
  }

  @override
  Future<void> dispose() async {
    if (_state == EngineState.disposed) return;
    cancel();
    _setState(EngineState.disposed);
    final active = _active;
    if (active != null) {
      try {
        await active.completer.future;
      } on Object {
        // The worker is going away; its last result is irrelevant.
      }
    }
    _commandPort?.send(const {'type': 'dispose'});
    await Future<void>.delayed(Duration.zero);
    _teardown();
    await _states.close();
  }

  void _pump() {
    if (_active != null || _queue.isEmpty || !isReady) return;
    final next = _queue.removeFirst();
    _active = next;
    _setState(EngineState.busy);
    _commandPort!.send({
      'type': 'recognize',
      'id': next.id,
      'samples': TransferableTypedData.fromList([next.request.samples]),
      'language': next.request.language,
      'prompt': next.request.prompt,
      'threads': next.request.threads,
      'decoder': next.request.decoder.toMap(),
    });
  }

  void _onWorkerMessage(Map<Object?, Object?> map) {
    final type = map['type'];
    if (type == 'result' || type == 'error') {
      final active = _active;
      if (active == null || active.id != map['id']) return;
      _active = null;
      if (type == 'result') {
        final segments = (map['segments'] as List<Object?>)
            .map((raw) => RawSegment.fromMap(raw as Map<Object?, Object?>))
            .toList(growable: false);
        _backend = EngineBackendInfo.fromMap(map['backend'] as Map<Object?, Object?>);
        active.completer.complete(EngineResult(
          segments: segments,
          inference: Duration(milliseconds: map['inferenceMs'] as int),
          droppedSegments: map['dropped'] as int,
          backend: _backend!,
        ));
      } else {
        active.completer.completeError(SpeechCoreException(
          SpeechCoreStatus.fromCode(map['status'] as int),
          map['message'] as String,
        ));
      }
      if (_state == EngineState.busy) _setState(EngineState.ready);
      _pump();
      return;
    }
    if (type == 'fatal') {
      _error = map['message']?.toString() ?? map.toString();
      _setState(EngineState.error);
      final active = _active;
      _active = null;
      active?.completer.completeError(
        SpeechCoreException(SpeechCoreStatus.internalError, _error!),
      );
      cancel();
    }
  }

  void _teardown() {
    _subscription?.cancel();
    _subscription = null;
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commandPort = null;
    _sessionAddress = 0;
  }

  void _setState(EngineState value) {
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }
}

class _QueuedRequest {
  _QueuedRequest(this.id, this.request);

  final int id;
  final EngineRequest request;
  final Completer<EngineResult> completer = Completer<EngineResult>();
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

List<RawSegment> _collected = <RawSegment>[];

void _collectSegment(Pointer<SegmentStruct> segment, Pointer<Void> _) {
  final ref = segment.ref;
  _collected.add(RawSegment(
    index: ref.segmentIndex,
    startMs: ref.startMs,
    endMs: ref.endMs,
    text: ref.text.toDartString().trim(),
    language: ref.language.toDartString(),
    avgLogprob: ref.avgLogprob,
    noSpeechProb: ref.noSpeechProb,
    repetition: ref.repetition,
    tokenCount: ref.tokenCount,
  ));
}

const _backendNames = ['auto', 'cpu', 'vulkan', 'metal'];
const _actualBackendNames = ['unknown', 'cpu', 'vulkan', 'metal', 'unavailable'];

Map<String, Object?> _backendMap(SpeechCoreBindings bindings, Pointer<Void> model) {
  final requested = bindings.modelRequestedBackend(model);
  final actual = bindings.modelActualBackend(model);
  return {
    'requested': requested >= 0 && requested < _backendNames.length
        ? _backendNames[requested]
        : 'unknown',
    'actual': actual >= 0 && actual < _actualBackendNames.length
        ? _actualBackendNames[actual]
        : 'unknown',
    'gpuEnabled': bindings.modelGpuEnabled(model) != 0,
    'deviceName': bindings.modelDeviceName(model).toDartString(),
    'fallbackReason': bindings.modelFallbackReason(model),
    'message': bindings.modelBackendMessage(model).toDartString(),
  };
}

Future<void> _engineMain(List<Object?> arguments) async {
  final replyPort = arguments[0] as SendPort;
  final libraryPath = arguments[1] as String;
  final modelPath = arguments[2] as String;
  final backend = arguments[3] as int;

  late final SpeechCoreBindings bindings;
  Pointer<Void> model = nullptr;
  Pointer<Void> session = nullptr;
  try {
    bindings = SpeechCoreBindings.open(libraryPath);
    final modelOut = calloc<Pointer<Void>>();
    final pathUtf8 = modelPath.toNativeUtf8();
    try {
      bindings.check(
        bindings.modelCreateWithBackend(pathUtf8, backend, modelOut),
        'model load',
      );
      model = modelOut.value;
    } finally {
      calloc.free(pathUtf8);
      calloc.free(modelOut);
    }
    final sessionOut = calloc<Pointer<Void>>();
    final sessionId = 'engine'.toNativeUtf8();
    try {
      bindings.check(bindings.sessionCreate(model, sessionId, sessionOut), 'session');
      session = sessionOut.value;
    } finally {
      calloc.free(sessionId);
      calloc.free(sessionOut);
    }
  } on SpeechCoreException catch (error) {
    if (model != nullptr) bindings.modelDestroy(model);
    replyPort.send({'type': 'error', 'status': error.status.code, 'message': error.message});
    return;
  } on Object catch (error) {
    replyPort.send({'type': 'error', 'status': 10, 'message': error.toString()});
    return;
  }

  final callback = NativeCallable<SegmentCallbackNative>.isolateLocal(_collectSegment);
  final commands = ReceivePort();
  replyPort.send({
    'type': 'ready',
    'commandPort': commands.sendPort,
    'sessionAddress': session.address,
    'backend': _backendMap(bindings, model),
  });

  await for (final dynamic message in commands) {
    final map = message as Map<Object?, Object?>;
    final type = map['type'];
    if (type == 'dispose') break;
    if (type != 'recognize') continue;
    final id = map['id'] as int;
    final samples = (map['samples'] as TransferableTypedData).materialize().asFloat32List();
    final decoder = DecoderOptions.fromMap(map['decoder'] as Map<Object?, Object?>);
    final language = map['language'] as String;
    final prompt = map['prompt'] as String?;
    final threads = map['threads'] as int;

    final input = calloc<Float>(samples.length);
    final options = calloc<RecognizeOptionsStruct>();
    final diagnostics = calloc<DiagnosticsStruct>();
    final languageUtf8 = language.toNativeUtf8();
    final promptUtf8 = prompt == null || prompt.isEmpty ? nullptr : prompt.toNativeUtf8();
    try {
      input.asTypedList(samples.length).setAll(0, samples);
      bindings.optionsInit(options);
      final ref = options.ref;
      ref.language = languageUtf8;
      ref.initialPrompt = promptUtf8 == nullptr ? nullptr : promptUtf8.cast<Utf8>();
      ref.nThreads = threads;
      ref.beamSize = decoder.beamSize;
      ref.audioContext = decoder.audioContext;
      ref.temperature = decoder.temperature;
      ref.temperatureIncrement = decoder.temperatureIncrement;
      ref.entropyThreshold = decoder.entropyThreshold;
      ref.logprobThreshold = decoder.logprobThreshold;
      ref.noSpeechThreshold = decoder.noSpeechThreshold;
      ref.tokenTimestamps = decoder.tokenTimestamps ? 1 : 0;
      _collected = <RawSegment>[];
      final status = bindings.sessionRecognize(
        session,
        input,
        samples.length,
        16000,
        options,
        callback.nativeFunction,
        nullptr,
        diagnostics,
      );
      if (status != SpeechCoreStatus.ok.code) {
        replyPort.send({
          'type': 'error',
          'id': id,
          'status': status,
          'message': bindings.message(status),
        });
        continue;
      }
      replyPort.send({
        'type': 'result',
        'id': id,
        'segments': _collected.map((segment) => segment.toMap()).toList(growable: false),
        'inferenceMs': diagnostics.ref.inferenceMs,
        'dropped': diagnostics.ref.droppedSegmentCount,
        'backend': _backendMap(bindings, model),
      });
    } on Object catch (error) {
      replyPort.send({'type': 'error', 'id': id, 'status': 10, 'message': error.toString()});
    } finally {
      calloc.free(input);
      calloc.free(options);
      calloc.free(diagnostics);
      calloc.free(languageUtf8);
      if (promptUtf8 != nullptr) calloc.free(promptUtf8);
    }
  }

  callback.close();
  commands.close();
  bindings.sessionDestroy(session);
  bindings.modelDestroy(model);
}
