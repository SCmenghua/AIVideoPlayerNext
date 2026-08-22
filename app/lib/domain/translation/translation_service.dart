const defaultTranslationRequestTimeout = Duration(seconds: 40);

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

/// Optional batch capability. Implementations must return one result for each
/// request, matched by segmentId.
abstract interface class BatchTranslationService {
  Future<List<TranslationResult>> translateBatch(
    List<TranslationRequest> requests,
  );
}

/// A batch provider that owns its network timeout. This lets the provider
/// close its HttpClient before the queue schedules a retry.
abstract interface class TimedBatchTranslationService
    implements TranslationService, BatchTranslationService {
  Future<List<TranslationResult>> translateBatchWithTimeout(
    List<TranslationRequest> requests,
    Duration timeout,
  );
}

/// Optional cancellation support for a service that owns network requests.
abstract interface class TranslationServiceRequestCanceller {
  void cancelActiveRequests();
}

abstract interface class TranslationServiceDiagnosticsProvider {
  Map<String, Object?> get diagnostics;
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
  var path = endpoint.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.isEmpty) path = '/';
  if (path.isEmpty || path == '/') {
    return endpoint.replace(path: '/v1/chat/completions', query: null);
  }
  if (path.endsWith('/v1')) {
    return endpoint.replace(path: '$path/chat/completions', query: null);
  }
  if (path.endsWith('/v1/chat/completions')) {
    return endpoint.replace(path: path, query: null);
  }
  return endpoint.replace(path: path, query: null);
}

/// Parses the endpoint forms accepted by the settings UI. A missing scheme is
/// treated as HTTPS, while credentials, fragments and non-HTTP schemes are
/// rejected before any network request is made.
Uri? parseOpenAiCompatibleEndpoint(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return null;
  if (!value.contains('://')) value = 'https://$value';
  final endpoint = Uri.tryParse(value);
  if (endpoint == null ||
      (endpoint.scheme != 'https' && endpoint.scheme != 'http') ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.fragment.isNotEmpty) {
    return null;
  }
  return normalizeOpenAiCompatibleEndpoint(endpoint);
}
