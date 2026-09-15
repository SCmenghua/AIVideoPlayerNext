import 'dart:typed_data';

import 'engine.dart';
import 'pcm.dart';

/// Recognition engine contract; [WhisperEngine] is the production
/// implementation and tests substitute fakes.
abstract interface class RecognitionEngine {
  EngineState get state;
  EngineBackendInfo? get backendInfo;
  Future<void> load();
  Future<EngineResult> recognize(EngineRequest request);
  void cancel();
  Future<void> dispose();
}

/// Speech probability contract: one probability per [frameSamples] samples.
abstract interface class SpeechProbabilityProvider {
  int get frameSamples;
  Future<void> load();
  Future<Float32List> probabilities(Float32List samples);
  Future<void> dispose();
}

/// PCM conversion contract: raw decoder output to 16 kHz mono chunks.
abstract interface class PcmConverter {
  PcmChunk? process(RawPcmChunk raw);
  void reset();
  void dispose();
}
