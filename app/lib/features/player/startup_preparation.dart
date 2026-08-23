import '../../domain/player/player_service.dart';
import '../../domain/subtitles/transcript_document.dart';
import '../settings/app_settings.dart';
import 'playback_start_policy.dart';

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
    this.strategy = PlaybackStartStrategy.translationPriority,
    this.waitForSubtitlePreparation = true,
    this.timeout = const Duration(seconds: 10),
  });

  final DateTime startedAt;
  PlaybackStartStrategy strategy;
  bool waitForSubtitlePreparation;
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

  void updatePolicy({
    required PlaybackStartStrategy strategy,
    required bool waitForSubtitlePreparation,
  }) {
    this.strategy = strategy;
    this.waitForSubtitlePreparation = waitForSubtitlePreparation;
  }

  PlaybackStartDecision decision({
    required bool videoReady,
    required bool nextSubtitleReady,
    required bool nextTranslationReady,
    required int completedTranslationCount,
    required int skippedWindowCount,
    bool translationExpected = true,
    bool recognitionExpected = true,
    int failedTranslationCount = 0,
  }) =>
      evaluatePlaybackStart(
        videoReady: videoReady,
        nextSubtitleReady: nextSubtitleReady,
        nextTranslationReady: nextTranslationReady,
        completedTranslationCount: completedTranslationCount,
        skippedWindowCount: skippedWindowCount,
        strategy: strategy,
        waitForSubtitlePreparation: waitForSubtitlePreparation,
        translationExpected: translationExpected,
        recognitionExpected: recognitionExpected,
        failedTranslationCount: failedTranslationCount,
      );

  bool canAutoPlay({
    required int windowsSkipped,
    int completedTranslationCount = 0,
    bool nextSubtitleReady = false,
    bool nextTranslationReady = false,
    bool translationExpected = true,
    bool recognitionExpected = true,
    int failedTranslationCount = 0,
  }) =>
      decision(
        videoReady: networkReady,
        nextSubtitleReady: nextSubtitleReady,
        nextTranslationReady: nextTranslationReady || translationReady,
        completedTranslationCount: completedTranslationCount,
        skippedWindowCount: windowsSkipped,
        translationExpected: translationExpected,
        recognitionExpected: recognitionExpected,
        failedTranslationCount: failedTranslationCount,
      ).canStart;

  bool shouldPrompt({
    required DateTime now,
    required int windowsSkipped,
    int completedTranslationCount = 0,
    bool nextSubtitleReady = false,
    bool nextTranslationReady = false,
    bool translationExpected = true,
    bool recognitionExpected = true,
    int failedTranslationCount = 0,
  }) =>
      !promptShown &&
      !canAutoPlay(
        windowsSkipped: windowsSkipped,
        completedTranslationCount: completedTranslationCount,
        nextSubtitleReady: nextSubtitleReady,
        nextTranslationReady: nextTranslationReady,
        translationExpected: translationExpected,
        recognitionExpected: recognitionExpected,
        failedTranslationCount: failedTranslationCount,
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
