import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_bindings.dart';

typedef VadProbabilityFunction = Future<Float32List> Function(Float32List samples);

/// Silero VAD in a worker isolate, one speech probability per frame.
class VadDetector {
  VadDetector({
    required this.libraryPath,
    required this.modelPath,
    this.threads = 2,
  });

  final String libraryPath;
  final String modelPath;
  final int threads;

  Isolate? _isolate;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _subscription;
  SendPort? _commandPort;
  int _frameSamples = 0;
  int _nextId = 0;
  final Map<int, Completer<Float32List>> _pending = {};
  bool _disposed = false;

  int get frameSamples => _frameSamples;
  bool get isLoaded => _commandPort != null;

  Future<void> load() async {
    if (_disposed) throw StateError('vad disposed');
    if (isLoaded) return;
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    final ready = Completer<Map<Object?, Object?>>();
    _subscription = receivePort.listen((dynamic message) {
      final map = message is List
          ? <Object?, Object?>{'type': 'fatal', 'message': message.first.toString()}
          : message as Map<Object?, Object?>;
      if (!ready.isCompleted) {
        ready.complete(map);
        return;
      }
      if (map['type'] == 'fatal') {
        final error = SpeechCoreException(
          SpeechCoreStatus.internalError,
          map['message'] as String? ?? 'vad worker crashed',
        );
        for (final completer in _pending.values) {
          completer.completeError(error);
        }
        _pending.clear();
        _teardown();
        return;
      }
      final id = map['id'] as int?;
      final completer = id == null ? null : _pending.remove(id);
      if (completer == null) return;
      if (map['type'] == 'result') {
        completer.complete(
          (map['probabilities'] as TransferableTypedData).materialize().asFloat32List(),
        );
      } else {
        completer.completeError(SpeechCoreException(
          SpeechCoreStatus.fromCode(map['status'] as int? ?? 10),
          map['message'] as String? ?? 'vad failed',
        ));
      }
    });
    _isolate = await Isolate.spawn<List<Object?>>(
      _vadMain,
      <Object?>[receivePort.sendPort, libraryPath, modelPath, threads],
      errorsAreFatal: true,
      onError: receivePort.sendPort,
    );
    final first = await ready.future;
    if (first['type'] != 'ready') {
      _teardown();
      throw SpeechCoreException(
        SpeechCoreStatus.fromCode(first['status'] as int? ?? 10),
        first['message'] as String? ?? 'vad worker failed to start',
      );
    }
    _commandPort = first['commandPort'] as SendPort;
    _frameSamples = first['frameSamples'] as int;
  }

  Future<Float32List> probabilities(Float32List samples) {
    final port = _commandPort;
    if (port == null) return Future.error(StateError('vad not loaded'));
    final id = _nextId++;
    final completer = Completer<Float32List>();
    _pending[id] = completer;
    port.send({
      'type': 'detect',
      'id': id,
      'samples': TransferableTypedData.fromList([samples]),
    });
    return completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _commandPort?.send(const {'type': 'dispose'});
    await Future<void>.delayed(Duration.zero);
    for (final completer in _pending.values) {
      completer.completeError(
        const SpeechCoreException(SpeechCoreStatus.cancelled, 'vad disposed'),
      );
    }
    _pending.clear();
    _teardown();
  }

  void _teardown() {
    _subscription?.cancel();
    _subscription = null;
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commandPort = null;
  }
}

/// Streams frame-aligned audio through a VAD whose state resets per call,
/// overlapping consecutive calls so the LSTM has warmed up before the frames
/// that are actually reported.
class VadStream {
  VadStream({
    required this.frameSamples,
    required this.probabilities,
    this.overlapFrames = 8,
  });

  final int frameSamples;
  final VadProbabilityFunction probabilities;
  final int overlapFrames;
  Float32List _carry = Float32List(0);

  void reset() => _carry = Float32List(0);

  /// [samples] must be a whole number of frames.
  Future<Float32List> process(Float32List samples) async {
    if (samples.length % frameSamples != 0) {
      throw ArgumentError('samples must be frame aligned');
    }
    if (samples.isEmpty) return Float32List(0);
    final carryFrames = _carry.length ~/ frameSamples;
    final input = Float32List(_carry.length + samples.length)
      ..setAll(0, _carry)
      ..setAll(_carry.length, samples);
    final all = await probabilities(input);
    final frames = samples.length ~/ frameSamples;
    final result = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      final index = carryFrames + i;
      result[i] = index < all.length ? all[index] : 0;
    }
    final keep = overlapFrames * frameSamples;
    if (input.length <= keep) {
      _carry = input;
    } else {
      _carry = Float32List.sublistView(input, input.length - keep);
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

Future<void> _vadMain(List<Object?> arguments) async {
  final replyPort = arguments[0] as SendPort;
  final libraryPath = arguments[1] as String;
  final modelPath = arguments[2] as String;
  final threads = arguments[3] as int;

  late final SpeechCoreBindings bindings;
  Pointer<Void> vad = nullptr;
  try {
    bindings = SpeechCoreBindings.open(libraryPath);
    final out = calloc<Pointer<Void>>();
    final pathUtf8 = modelPath.toNativeUtf8();
    try {
      bindings.check(bindings.vadCreate(pathUtf8, threads, out), 'vad load');
      vad = out.value;
    } finally {
      calloc.free(pathUtf8);
      calloc.free(out);
    }
  } on SpeechCoreException catch (error) {
    replyPort.send({'type': 'error', 'status': error.status.code, 'message': error.message});
    return;
  } on Object catch (error) {
    replyPort.send({'type': 'error', 'status': 10, 'message': error.toString()});
    return;
  }

  final frameSamples = bindings.vadFrameSamples(vad);
  final commands = ReceivePort();
  replyPort.send({
    'type': 'ready',
    'commandPort': commands.sendPort,
    'frameSamples': frameSamples,
  });

  await for (final dynamic message in commands) {
    final map = message as Map<Object?, Object?>;
    final type = map['type'];
    if (type == 'dispose') break;
    if (type != 'detect') continue;
    final id = map['id'] as int;
    final samples = (map['samples'] as TransferableTypedData).materialize().asFloat32List();
    final capacity = samples.length ~/ frameSamples + 1;
    final input = calloc<Float>(samples.length);
    final output = calloc<Float>(capacity);
    final count = calloc<Size>();
    try {
      input.asTypedList(samples.length).setAll(0, samples);
      final status = bindings.vadProbabilities(
        vad, input, samples.length, output, capacity, count);
      if (status != SpeechCoreStatus.ok.code) {
        replyPort.send({
          'type': 'error',
          'id': id,
          'status': status,
          'message': bindings.message(status),
        });
        continue;
      }
      final produced = count.value;
      final result = Float32List.fromList(output.asTypedList(produced));
      replyPort.send({
        'type': 'result',
        'id': id,
        'probabilities': TransferableTypedData.fromList([result]),
      });
    } on Object catch (error) {
      replyPort.send({'type': 'error', 'id': id, 'status': 10, 'message': error.toString()});
    } finally {
      calloc.free(input);
      calloc.free(output);
      calloc.free(count);
    }
  }

  commands.close();
  bindings.vadDestroy(vad);
}
