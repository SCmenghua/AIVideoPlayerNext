class TranslationRequest {
  const TranslationRequest(
      {required this.segmentId,
      required this.text,
      required this.targetLanguage});

  final String segmentId;
  final String text;
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
