import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/speech/speech_models.dart';
import 'package:ai_video_player_next/features/speech/whisper_cpp_speech_service.dart';
import 'package:ai_video_player_next/domain/speech/speech_core_status.dart';

void main() {
  final nativeLibrary = File(
    '${Directory.current.parent.path}\\native\\speech_core\\build-vs\\Release\\speech_core.dll',
  );

  test('backend status keeps requested, actual and fallback values distinct', () {
    const status = WhisperBackendStatus(
      requested: WhisperRequestedBackend.vulkan,
      actual: WhisperActualBackend.cpu,
      gpuEnabled: false,
      deviceName: 'NVIDIA test device',
      fallbackReason: WhisperFallbackReason.runtimeFailed,
      message: 'CPU fallback active',
    );
    expect(status.requestedLabel, 'Vulkan');
    expect(status.actualLabel, 'CPU');
    expect(status.gpuEnabled, isFalse);
    expect(status.fallbackLabel, 'runtimeFailed');
  });

  test(
    'FFI provider maps the deterministic native segment to RecognitionEvent',
    () async {
      final model =
          File('${Directory.systemTemp.path}\\speech_core_test_model.bin');
      await model.writeAsString('SPEECH_CORE_TEST_MODEL_V1\n');
      addTearDown(() async {
        if (await model.exists()) await model.delete();
      });

      final service = WhisperCppSpeechRecognitionService(
        libraryPath: nativeLibrary.path,
        modelPath: model.path,
        audioLoader: (_) async => List<double>.filled(1600, 0),
        threads: 1,
      );
      addTearDown(service.dispose);

      expect(service.availability.available, isTrue);
      final events = <RecognitionEvent>[];
      final subscription = service.events.listen(events.add);
      addTearDown(subscription.cancel);

      await service.start(const RecognitionRequest(
        sessionId: 'ffi-test',
        from: Duration(seconds: 2),
        language: 'en',
      ));

      expect(events, hasLength(1));
      expect(events.single.sessionId, 'ffi-test');
      expect(events.single.segmentId, 'ffi-test-segment-0');
      expect(events.single.start, const Duration(seconds: 2));
      expect(events.single.end, const Duration(seconds: 2, milliseconds: 100));
      expect(events.single.text, 'speech_core test transcript');
      expect(events.single.language, 'en');
      expect(events.single.kind, RecognitionKind.finalResult);
      expect(events.single.source, RecognitionSource.whisperCpp);
    },
    skip: !nativeLibrary.existsSync(),
  );
}
