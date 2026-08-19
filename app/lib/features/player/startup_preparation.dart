import '../../domain/player/player_service.dart';
import '../../domain/subtitles/transcript_document.dart';

const minimumNetworkStartupBuffer = Duration(seconds: 1);

/// Reports readiness only after the playback engine has cached enough media
/// time to begin playing, rather than when its HTTP request merely opens.
bool hasStartupPlayableMediaData({
  required MediaSource source,
  required PlaybackSnapshot snapshot,
}) {
  final statusCanPlay = snapshot.status == PlaybackStatus.paused ||
      snapshot.status == PlaybackStatus.playing ||
      snapshot.status == PlaybackStatus.ended;
  if (!statusCanPlay || snapshot.isBuffering) return false;
  if (!source.uri.isScheme('http') && !source.uri.isScheme('https')) {
    return true;
  }
  return snapshot.bufferedDuration >= minimumNetworkStartupBuffer;
}

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
