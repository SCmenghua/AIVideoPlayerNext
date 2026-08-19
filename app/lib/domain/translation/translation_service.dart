class TranslationRequest {
  const TranslationRequest({
    required this.segmentId,
    required this.text,
    required this.sourceLanguage,
    required this.targetLanguage,
  });

  final String segmentId;
  final String text;
  final String sourceLanguage;
  final String targetLanguage;
}

class TranslationResult {
  const TranslationResult(
      {required this.segmentId, required this.text, required this.provider});

  final String segmentId;
  final String text;
  final String provider;
}

abstract interface class TranslationService {
  Future<TranslationResult> translate(TranslationRequest request);
}

class TranslationServiceStatus {
  const TranslationServiceStatus.available({required this.provider})
      : available = true,
        message = null;

  const TranslationServiceStatus.unavailable({
    required this.provider,
    required this.message,
  }) : available = false;

  final bool available;
  final String provider;
  final String? message;
}

abstract interface class TranslationServiceStatusProvider {
  TranslationServiceStatus get status;
}

/// Accepts either a complete chat-completions URL or the common server base
/// URL used by OpenAI-compatible providers.
Uri normalizeOpenAiCompatibleEndpoint(Uri endpoint) {
  final path = endpoint.path;
  if (path.isEmpty || path == '/') {
    return endpoint.replace(path: '/v1/chat/completions');
  }
  if (path == '/v1' || path == '/v1/') {
    return endpoint.replace(path: '/v1/chat/completions');
  }
  return endpoint;
}
