class SpeechCoreStatus {
  const SpeechCoreStatus({required this.available, required this.message});

  final bool available;
  final String message;
}

enum WhisperRequestedBackend { auto, cpu, vulkan, metal }

enum WhisperActualBackend { unknown, cpu, vulkan, metal, unavailable }

enum WhisperFallbackReason {
  none,
  backendNotBuilt,
  loaderMissing,
  deviceUnavailable,
  initFailed,
  runtimeFailed,
  memoryError,
  modelError,
  unknown,
}

class WhisperBackendStatus {
  const WhisperBackendStatus({
    required this.requested,
    required this.actual,
    required this.gpuEnabled,
    required this.deviceName,
    required this.fallbackReason,
    required this.message,
  });

  const WhisperBackendStatus.initial({
    this.requested = WhisperRequestedBackend.auto,
  })  : actual = WhisperActualBackend.unknown,
        gpuEnabled = false,
        deviceName = '',
        fallbackReason = WhisperFallbackReason.none,
        message = 'backend status unavailable';

  final WhisperRequestedBackend requested;
  final WhisperActualBackend actual;
  final bool gpuEnabled;
  final String deviceName;
  final WhisperFallbackReason fallbackReason;
  final String message;

  String get requestedLabel => _backendLabel(requested);
  String get actualLabel => _backendLabel(actual);
  String get fallbackLabel => fallbackReason.name;

  static String _backendLabel(Object backend) => switch (backend) {
        WhisperRequestedBackend.auto => 'Auto',
        WhisperRequestedBackend.cpu => 'CPU',
        WhisperRequestedBackend.vulkan => 'Vulkan',
        WhisperRequestedBackend.metal => 'Metal',
        WhisperActualBackend.unknown => 'Unknown',
        WhisperActualBackend.cpu => 'CPU',
        WhisperActualBackend.vulkan => 'Vulkan',
        WhisperActualBackend.metal => 'Metal',
        WhisperActualBackend.unavailable => 'Unavailable',
        _ => 'Unknown',
      };
}
