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

  test('preparation gate opens when no translation can ever arrive', () {
    final decision = evaluate(
      waitForSubtitlePreparation: true,
      nextSubtitleReady: true,
      translationExpected: false,
    );

    expect(decision.canStart, isTrue);
    expect(decision.gateEnabled, isTrue);
  });

  test('preparation gate opens when recognition has terminally failed', () {
    final decision = evaluate(
      waitForSubtitlePreparation: true,
      translationExpected: true,
      recognitionExpected: false,
    );

    expect(decision.canStart, isTrue);
    expect(decision.gateEnabled, isTrue);
  });

  test('preparation gate opens after two terminal translation failures', () {
    final stillBlocked = evaluate(
      waitForSubtitlePreparation: true,
      completedTranslationCount: 0,
      failedTranslationCount: 1,
    );
    expect(stillBlocked.canStart, isFalse);

    final opens = evaluate(
      waitForSubtitlePreparation: true,
      failedTranslationCount: 2,
    );
    expect(opens.canStart, isTrue);
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

  test('bounded wait pauses within the grace period even without progress', () {
    final decision = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.subtitlePriority,
      subtitleReadyAtPosition: false,
      translationReadyAtPosition: false,
      recognitionProgressing: false,
      waited: const Duration(seconds: 3),
    );

    expect(decision.canContinue, isFalse);
    expect(decision.waitingFor, PlaybackContentWaitingFor.subtitle);
  });

  test(
      'stalled recognition releases the pause once the short grace expires',
      () {
    final decision = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.subtitlePriority,
      subtitleReadyAtPosition: false,
      translationReadyAtPosition: false,
      recognitionProgressing: false,
      waited: const Duration(seconds: 9),
    );

    expect(decision.canContinue, isTrue);
    expect(decision.waitingFor, isNull);
  });

  test(
      'progressing recognition extends the grace before releasing the pause',
      () {
    final stillWaiting = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.subtitlePriority,
      subtitleReadyAtPosition: false,
      translationReadyAtPosition: false,
      recognitionProgressing: true,
      waited: const Duration(seconds: 12),
    );
    expect(stillWaiting.canContinue, isFalse);

    final released = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.subtitlePriority,
      subtitleReadyAtPosition: false,
      translationReadyAtPosition: false,
      recognitionProgressing: true,
      waited: const Duration(seconds: 17),
    );
    expect(released.canContinue, isTrue);
  });

  test('translation priority obeys the same bounded wait', () {
    final waiting = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.translationPriority,
      subtitleReadyAtPosition: true,
      translationReadyAtPosition: false,
      recognitionProgressing: false,
      waited: const Duration(seconds: 2),
    );
    expect(waiting.canContinue, isFalse);
    expect(waiting.reason, '等待翻译返回中。');

    final released = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.translationPriority,
      subtitleReadyAtPosition: true,
      translationReadyAtPosition: false,
      recognitionProgressing: false,
      waited: const Duration(seconds: 10),
    );
    expect(released.canContinue, isTrue);
  });

  test('suppressed gate keeps playing until content returns', () {
    final decision = evaluatePlaybackContent(
      strategy: PlaybackStartStrategy.subtitlePriority,
      subtitleReadyAtPosition: false,
      translationReadyAtPosition: false,
      suppressWait: true,
    );

    expect(decision.canContinue, isTrue);
  });
}
