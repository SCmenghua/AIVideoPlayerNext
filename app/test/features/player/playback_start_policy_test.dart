import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/features/player/playback_start_policy.dart';
import 'package:ai_video_player_next/features/settings/app_settings.dart';

void main() {
  PlaybackStartDecision evaluate({
    bool videoReady = true,
    bool nextSubtitleReady = false,
    bool nextTranslationReady = false,
    int completedTranslationCount = 0,
    int skippedWindowCount = 0,
    PlaybackStartStrategy strategy = PlaybackStartStrategy.subtitlePriority,
    bool waitForSubtitlePreparation = false,
  }) =>
      evaluatePlaybackStart(
        videoReady: videoReady,
        nextSubtitleReady: nextSubtitleReady,
        nextTranslationReady: nextTranslationReady,
        completedTranslationCount: completedTranslationCount,
        skippedWindowCount: skippedWindowCount,
        strategy: strategy,
        waitForSubtitlePreparation: waitForSubtitlePreparation,
      );

  test('video readiness is required for every strategy', () {
    final decision = evaluate(
      videoReady: false,
      nextSubtitleReady: true,
      nextTranslationReady: true,
      strategy: PlaybackStartStrategy.playbackPriority,
    );

    expect(decision.canStart, isFalse);
    expect(decision.waitingFor, PlaybackStartWaitingFor.video);
  });

  test('subtitle priority does not add a startup content wait', () {
    final decision = evaluate(
      strategy: PlaybackStartStrategy.subtitlePriority,
    );
    expect(decision.canStart, isTrue);
  });

  test('translation priority does not add a startup content wait', () {
    final decision = evaluate(
      strategy: PlaybackStartStrategy.translationPriority,
    );
    expect(decision.canStart, isTrue);
  });

  test('playback priority still observes the independent preparation gate', () {
    final decision = evaluate(
      strategy: PlaybackStartStrategy.playbackPriority,
      waitForSubtitlePreparation: true,
    );

    expect(decision.canStart, isFalse);
    expect(decision.gateEnabled, isTrue);
    expect(decision.waitingFor, PlaybackStartWaitingFor.translationPreparation);
  });

  test(
      'enabled preparation gate requires two translations or four skipped windows',
      () {
    final blocked = evaluate(
      waitForSubtitlePreparation: true,
      nextSubtitleReady: true,
      completedTranslationCount: 1,
      skippedWindowCount: 0,
    );
    expect(blocked.canStart, isFalse);
    expect(blocked.waitingFor, PlaybackStartWaitingFor.translationPreparation);

    expect(
      evaluate(
        waitForSubtitlePreparation: true,
        completedTranslationCount: 2,
      ).canStart,
      isTrue,
    );
    expect(
      evaluate(
        waitForSubtitlePreparation: true,
        skippedWindowCount: 4,
      ).canStart,
      isTrue,
    );
  });

  test('disabled preparation gate does not add an implicit threshold', () {
    final decision = evaluate(
      waitForSubtitlePreparation: false,
      nextSubtitleReady: true,
      completedTranslationCount: 1,
    );
    expect(decision.canStart, isTrue);
    expect(decision.gateEnabled, isFalse);
  });

  test(
      'content policy pauses subtitle priority when the next subtitle is absent',
      () {
    final decision = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.subtitlePriority,
      subtitleReadyAtPosition: false,
      translationReadyAtPosition: false,
    );

    expect(decision.canContinue, isFalse);
    expect(decision.waitingFor, PlaybackContentWaitingFor.subtitle);
    expect(decision.reason, '等待字幕返回中。');
  });

  test('content policy pauses translation priority until translation returns',
      () {
    final decision = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.translationPriority,
      subtitleReadyAtPosition: true,
      translationReadyAtPosition: false,
    );

    expect(decision.canContinue, isFalse);
    expect(decision.waitingFor, PlaybackContentWaitingFor.translation);
    expect(decision.reason, '等待翻译返回中。');
  });

  test('content policy allows playback priority to continue without content',
      () {
    final decision = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.playbackPriority,
      subtitleReadyAtPosition: false,
      translationReadyAtPosition: false,
    );

    expect(decision.canContinue, isTrue);
    expect(decision.waitingFor, isNull);
  });
}
