import '../../domain/subtitles/transcript_document.dart';

class StartupPreparation {
  StartupPreparation({
    required this.startedAt,
    this.timeout = const Duration(seconds: 10),
  });

  final DateTime startedAt;
  final Duration timeout;
  DateTime? networkReadyAt;
  DateTime? recognitionReadyAt;
  DateTime? translationReadyAt;
  bool promptShown = false;
  bool dialogActive = false;
  bool dialogClosing = false;
  bool bypassed = false;

  bool get networkReady => networkReadyAt != null;
  bool get recognitionReady => recognitionReadyAt != null;
  bool get translationReady => translationReadyAt != null;

  bool canAutoPlay({
    required int windowsSkipped,
    bool hasRecognizedSubtitle = false,
  }) =>
      networkReady &&
      (translationReady || (!hasRecognizedSubtitle && windowsSkipped >= 4));

  bool shouldPrompt({
    required DateTime now,
    required int windowsSkipped,
    bool hasRecognizedSubtitle = false,
  }) =>
      !promptShown &&
      !canAutoPlay(
        windowsSkipped: windowsSkipped,
        hasRecognizedSubtitle: hasRecognizedSubtitle,
      ) &&
      now.difference(startedAt) >= timeout;
}

bool hasEnoughTranslatedSubtitles(
  Iterable<TranscriptTranslation> translations, {
  String targetLanguage = 'zh-CN',
  int requiredCount = 2,
}) {
  if (requiredCount <= 0) return true;
  return translations
          .where((translation) =>
              translation.targetLanguage == targetLanguage &&
              translation.status == TranscriptTranslationStatus.translated &&
              translation.text.trim().isNotEmpty)
          .length >=
      requiredCount;
}
