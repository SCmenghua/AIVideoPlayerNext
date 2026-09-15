/// VAD-driven speech recognition pipeline on top of whisper.cpp.
///
/// Pure Dart plus FFI: no Flutter dependency, so the same code runs inside the
/// application and in the command-line regression runner.
library;

export 'src/assembler.dart';
export 'src/config.dart';
export 'src/contracts.dart';
export 'src/diagnostics.dart';
export 'src/engine.dart';
export 'src/gate.dart';
export 'src/native_bindings.dart' show SpeechCoreException, SpeechCoreStatus;
export 'src/normalizer.dart';
export 'src/pcm.dart';
export 'src/segmenter.dart';
export 'src/session.dart';
export 'src/text.dart';
export 'src/transcript.dart';
export 'src/vad.dart';
