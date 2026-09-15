import 'dart:ffi';

import 'package:ffi/ffi.dart';

const int speechCoreAbiVersion = 3;

enum SpeechCoreStatus {
  ok(0),
  invalidArgument(1),
  modelNotFound(2),
  modelLoadFailed(3),
  audioFormatError(4),
  emptyAudio(5),
  audioTooLong(6),
  recognitionFailed(7),
  cancelled(8),
  backendUnavailable(9),
  internalError(10),
  bufferTooSmall(11);

  const SpeechCoreStatus(this.code);

  final int code;

  static SpeechCoreStatus fromCode(int code) => SpeechCoreStatus.values
      .firstWhere((status) => status.code == code, orElse: () => internalError);
}

class SpeechCoreException implements Exception {
  const SpeechCoreException(this.status, this.message);

  final SpeechCoreStatus status;
  final String message;

  @override
  String toString() => 'SpeechCoreException(${status.name}): $message';
}

final class RecognizeOptionsStruct extends Struct {
  external Pointer<Utf8> language;
  external Pointer<Utf8> initialPrompt;
  @Int32()
  external int nThreads;
  @Int32()
  external int beamSize;
  @Int32()
  external int audioContext;
  @Float()
  external double temperature;
  @Float()
  external double temperatureIncrement;
  @Float()
  external double entropyThreshold;
  @Float()
  external double logprobThreshold;
  @Float()
  external double noSpeechThreshold;
  @Uint8()
  external int tokenTimestamps;
  @Uint8()
  external int suppressNonSpeechTokens;
  @Uint8()
  external int suppressBlank;
}

final class SegmentStruct extends Struct {
  @Uint32()
  external int segmentIndex;
  @Int64()
  external int startMs;
  @Int64()
  external int endMs;
  external Pointer<Utf8> text;
  external Pointer<Utf8> language;
  @Float()
  external double avgLogprob;
  @Float()
  external double noSpeechProb;
  @Float()
  external double repetition;
  @Uint32()
  external int tokenCount;
}

final class DiagnosticsStruct extends Struct {
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
  @Uint32()
  external int droppedSegmentCount;
}

final class PcmBufferStruct extends Struct {
  external Pointer<Float> samples;
  @Size()
  external int sampleCount;
  @Uint32()
  external int sampleRate;
  @Uint32()
  external int channels;
}

typedef SegmentCallbackNative = Void Function(
    Pointer<SegmentStruct> segment, Pointer<Void> userData);

/// Thin lookup table over the speech_core C ABI. Each isolate that touches
/// native memory opens its own instance.
class SpeechCoreBindings {
  SpeechCoreBindings._(this.library);

  factory SpeechCoreBindings.open(String libraryPath) {
    final library = libraryPath == '@process'
        ? DynamicLibrary.process()
        : DynamicLibrary.open(libraryPath);
    final bindings = SpeechCoreBindings._(library);
    final version = bindings.abiVersion();
    if (version != speechCoreAbiVersion) {
      throw SpeechCoreException(
        SpeechCoreStatus.backendUnavailable,
        'speech_core ABI $version, expected $speechCoreAbiVersion',
      );
    }
    return bindings;
  }

  final DynamicLibrary library;

  late final int Function() abiVersion = library
      .lookupFunction<Uint32 Function(), int Function()>('speech_core_abi_version');

  late final Pointer<Utf8> Function(int status) statusMessage = library.lookupFunction<
      Pointer<Utf8> Function(Int32),
      Pointer<Utf8> Function(int)>('speech_core_status_message');

  late final void Function(Pointer<RecognizeOptionsStruct>) optionsInit =
      library.lookupFunction<Void Function(Pointer<RecognizeOptionsStruct>),
          void Function(Pointer<RecognizeOptionsStruct>)>(
        'speech_core_recognize_options_init',
      );

  late final int Function(Pointer<Utf8>, int, Pointer<Pointer<Void>>)
      modelCreateWithBackend = library.lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, Pointer<Pointer<Void>>),
          int Function(Pointer<Utf8>, int, Pointer<Pointer<Void>>)>(
        'speech_core_model_create_with_backend',
      );

  late final void Function(Pointer<Void>) modelDestroy =
      library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'speech_core_model_destroy',
  );

  late final int Function(Pointer<Void>) modelRequestedBackend =
      library.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'speech_core_model_requested_backend',
  );

  late final int Function(Pointer<Void>) modelActualBackend =
      library.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'speech_core_model_actual_backend',
  );

  late final int Function(Pointer<Void>) modelGpuEnabled =
      library.lookupFunction<Uint8 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'speech_core_model_gpu_enabled',
  );

  late final Pointer<Utf8> Function(Pointer<Void>) modelDeviceName =
      library.lookupFunction<Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)>('speech_core_model_device_name');

  late final int Function(Pointer<Void>) modelFallbackReason =
      library.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'speech_core_model_fallback_reason',
  );

  late final Pointer<Utf8> Function(Pointer<Void>) modelBackendMessage =
      library.lookupFunction<Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)>('speech_core_model_backend_message');

  late final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Void>>)
      sessionCreate = library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Void>>),
          int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Void>>)>(
        'speech_core_session_create',
      );

  late final void Function(Pointer<Void>) sessionDestroy =
      library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'speech_core_session_destroy',
  );

  late final int Function(Pointer<Void>) sessionCancel =
      library.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'speech_core_session_cancel',
  );

  late final int Function(
    Pointer<Void>,
    Pointer<Float>,
    int,
    int,
    Pointer<RecognizeOptionsStruct>,
    Pointer<NativeFunction<SegmentCallbackNative>>,
    Pointer<Void>,
    Pointer<DiagnosticsStruct>,
  ) sessionRecognize = library.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Float>,
        Size,
        Uint32,
        Pointer<RecognizeOptionsStruct>,
        Pointer<NativeFunction<SegmentCallbackNative>>,
        Pointer<Void>,
        Pointer<DiagnosticsStruct>,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Float>,
        int,
        int,
        Pointer<RecognizeOptionsStruct>,
        Pointer<NativeFunction<SegmentCallbackNative>>,
        Pointer<Void>,
        Pointer<DiagnosticsStruct>,
      )>('speech_core_session_recognize');

  late final int Function(Pointer<Utf8>, int, Pointer<Pointer<Void>>) vadCreate =
      library.lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, Pointer<Pointer<Void>>),
          int Function(Pointer<Utf8>, int, Pointer<Pointer<Void>>)>('speech_core_vad_create');

  late final void Function(Pointer<Void>) vadDestroy =
      library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'speech_core_vad_destroy',
  );

  late final int Function(Pointer<Void>) vadFrameSamples =
      library.lookupFunction<Uint32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'speech_core_vad_frame_samples',
  );

  late final int Function(
    Pointer<Void>,
    Pointer<Float>,
    int,
    Pointer<Float>,
    int,
    Pointer<Size>,
  ) vadProbabilities = library.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Float>, Size, Pointer<Float>, Size, Pointer<Size>),
      int Function(Pointer<Void>, Pointer<Float>, int, Pointer<Float>, int,
          Pointer<Size>)>('speech_core_vad_probabilities');

  late final int Function(int, int, Pointer<Pointer<Void>>) resamplerCreate =
      library.lookupFunction<Int32 Function(Uint32, Uint32, Pointer<Pointer<Void>>),
          int Function(int, int, Pointer<Pointer<Void>>)>('speech_core_resampler_create');

  late final void Function(Pointer<Void>) resamplerDestroy =
      library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'speech_core_resampler_destroy',
  );

  late final int Function(Pointer<Void>, int) resamplerMaxOutput =
      library.lookupFunction<Size Function(Pointer<Void>, Size),
          int Function(Pointer<Void>, int)>('speech_core_resampler_max_output');

  late final int Function(Pointer<Void>, Pointer<Float>, int, Pointer<Float>, int, Pointer<Size>)
      resamplerProcess = library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Float>, Size, Pointer<Float>, Size, Pointer<Size>),
          int Function(Pointer<Void>, Pointer<Float>, int, Pointer<Float>, int,
              Pointer<Size>)>('speech_core_resampler_process');

  late final int Function(Pointer<Void>, Pointer<Float>, int, Pointer<Size>) resamplerFlush =
      library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Float>, Size, Pointer<Size>),
          int Function(Pointer<Void>, Pointer<Float>, int, Pointer<Size>)>(
        'speech_core_resampler_flush',
      );

  late final int Function(Pointer<Uint8>, int, Pointer<PcmBufferStruct>, Pointer<DiagnosticsStruct>)
      wavToPcm = library.lookupFunction<
          Int32 Function(Pointer<Uint8>, Size, Pointer<PcmBufferStruct>, Pointer<DiagnosticsStruct>),
          int Function(Pointer<Uint8>, int, Pointer<PcmBufferStruct>,
              Pointer<DiagnosticsStruct>)>('speech_core_wav_to_pcm_f32');

  late final void Function(Pointer<PcmBufferStruct>) pcmBufferFree =
      library.lookupFunction<Void Function(Pointer<PcmBufferStruct>),
          void Function(Pointer<PcmBufferStruct>)>('speech_core_pcm_buffer_free');

  String message(int status) => statusMessage(status).toDartString();

  void check(int status, String context) {
    if (status == SpeechCoreStatus.ok.code) return;
    throw SpeechCoreException(
      SpeechCoreStatus.fromCode(status),
      '$context: ${message(status)}',
    );
  }
}
