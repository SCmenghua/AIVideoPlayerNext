import '../settings/app_settings.dart';

enum PlaybackStartWaitingFor {
  video,
  translationPreparation,
}

enum PlaybackContentWaitingFor { subtitle, translation }

class PlaybackStartDecision {
  const PlaybackStartDecision({
    required this.canStart,
    required this.reason,
    required this.waitingFor,
    required this.gateEnabled,
    required this.nextSubtitleReady,
    required this.nextTranslationReady,
  });

  final bool canStart;
  final String reason;
  final PlaybackStartWaitingFor? waitingFor;
  final bool gateEnabled;
  final bool nextSubtitleReady;
  final bool nextTranslationReady;
}

class PlaybackContentDecision {
  const PlaybackContentDecision({
    required this.canContinue,
    required this.reason,
    this.waitingFor,
  });

  final bool canContinue;
  final String reason;
  final PlaybackContentWaitingFor? waitingFor;
}

/// Pure playback-start semantics shared by the player and unit tests.
/// Recognition and translation completion times never affect media timestamps.
PlaybackStartDecision evaluatePlaybackStart({
  required bool videoReady,
  required bool nextSubtitleReady,
  required bool nextTranslationReady,
  required int completedTranslationCount,
  required int skippedWindowCount,
  required PlaybackStartStrategy strategy,
  required bool waitForSubtitlePreparation,
  bool translationExpected = true,
  bool recognitionExpected = true,
  int failedTranslationCount = 0,
}) {
  if (!videoReady) {
    return PlaybackStartDecision(
      canStart: false,
      reason: '视频尚未达到可播放状态。',
      waitingFor: PlaybackStartWaitingFor.video,
      gateEnabled: false,
      nextSubtitleReady: nextSubtitleReady,
      nextTranslationReady: nextTranslationReady,
    );
  }

  // The preparation switch is the only automatic-start content gate. The
  // selected playback strategy applies after playback has started. When no
  // translation can ever arrive (service unavailable) or the provider has
  // already failed terminally, waiting longer cannot help, so the gate opens
  // and subtitles keep their original text. A terminal recognition failure
  // (decoder error, cache failure, no recognizer) releases the gate for the
  // same reason: no windows means no subtitles and no translations.
  final gateEnabled = waitForSubtitlePreparation;
  if (gateEnabled &&
      translationExpected &&
      recognitionExpected &&
      completedTranslationCount < 2 &&
      failedTranslationCount < 2 &&
      skippedWindowCount < 4) {
    return PlaybackStartDecision(
      canStart: false,
      reason: '等待前两条翻译完成（或失败），或跳过四个识别窗口。',
      waitingFor: PlaybackStartWaitingFor.translationPreparation,
      gateEnabled: true,
      nextSubtitleReady: nextSubtitleReady,
      nextTranslationReady: nextTranslationReady,
    );
  }
  return PlaybackStartDecision(
    canStart: true,
    reason: '视频已准备好，自动启动门槛已满足。',
    waitingFor: null,
    gateEnabled: gateEnabled,
    nextSubtitleReady: nextSubtitleReady,
    nextTranslationReady: nextTranslationReady,
  );
}

/// Playback priorities apply to the running media clock, rather than to the
/// automatic start decision above. The player supplies availability at the
/// current media position, so missing future results cannot be skipped.
///
/// Subtitle/translation priority may pause the media while the pipeline is
/// catching up, but only for a bounded grace period. Speech gaps (silence,
/// credits, music) never produce subtitles, so an indefinite wait would
/// freeze the player: after [maxWait] playback resumes, extended once to
/// [maxWait * 2] while recognition is still visibly advancing (a live
/// pipeline is likely about to deliver the line). The gate re-engages
/// normally as soon as content is available again at the position.
PlaybackContentDecision evaluatePlaybackContent({
  required PlaybackStartStrategy strategy,
  required bool subtitleReadyAtPosition,
  required bool translationReadyAtPosition,
  bool recognitionProgressing = true,
  Duration waited = Duration.zero,
  Duration maxWait = const Duration(seconds: 8),
  bool suppressWait = false,
}) {
  if (strategy == PlaybackStartStrategy.playbackPriority) {
    return const PlaybackContentDecision(
      canContinue: true,
      reason: '播放优先，不等待字幕或翻译。',
    );
  }
  final hardLimit = recognitionProgressing ? maxWait * 2 : maxWait;
  final String waitingReason;
  PlaybackContentWaitingFor? waitingFor;
  if (strategy == PlaybackStartStrategy.subtitlePriority &&
      !subtitleReadyAtPosition) {
    waitingReason = '等待字幕返回中。';
    waitingFor = PlaybackContentWaitingFor.subtitle;
  } else if (strategy == PlaybackStartStrategy.translationPriority &&
      !translationReadyAtPosition) {
    waitingReason = '等待翻译返回中。';
    waitingFor = PlaybackContentWaitingFor.translation;
  } else {
    return const PlaybackContentDecision(
      canContinue: true,
      reason: '当前字幕内容已返回。',
    );
  }
  if (suppressWait) {
    return const PlaybackContentDecision(
      canContinue: true,
      reason: '当前字幕内容已返回。',
    );
  }
  if (waited < hardLimit) {
    return PlaybackContentDecision(
      canContinue: false,
      reason: waitingReason,
      waitingFor: waitingFor,
    );
  }
  return PlaybackContentDecision(
    canContinue: true,
    reason: '$waitingReason 已超过 ${hardLimit.inSeconds} 秒，继续播放以避免卡住。',
  );
}
