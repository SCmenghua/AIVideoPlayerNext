import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/features/settings/app_settings.dart';

void main() {
  test('playback strategy and preparation gate are independent settings', () {
    final settings = AppSettingsController(
      playbackStartStrategy: PlaybackStartStrategy.playbackPriority,
      waitForSubtitlePreparation: true,
    );

    expect(settings.waitForSubtitlePreparation, isTrue);

    settings.setWaitForSubtitlePreparation(true);
    expect(settings.waitForSubtitlePreparation, isTrue);
  });

  test('iOS streaming proxy experiment defaults off and toggles independently',
      () {
    final settings = AppSettingsController();

    expect(settings.iosRecognitionStreamingProxy, isFalse);
    expect(settings.waitForSubtitlePreparation, isTrue);

    settings.setIosRecognitionStreamingProxy(true);
    expect(settings.iosRecognitionStreamingProxy, isTrue);
    expect(settings.snapshot.iosRecognitionStreamingProxy, isTrue);

    // The preparation gate is untouched by the streaming experiment.
    expect(settings.waitForSubtitlePreparation, isTrue);
  });

  test('switching strategies preserves the preparation gate', () {
    final settings = AppSettingsController(
      playbackStartStrategy: PlaybackStartStrategy.playbackPriority,
      waitForSubtitlePreparation: true,
    );

    settings.setPlaybackStartStrategy(PlaybackStartStrategy.subtitlePriority);
    expect(settings.waitForSubtitlePreparation, isTrue);

    settings.setWaitForSubtitlePreparation(true);
    expect(settings.waitForSubtitlePreparation, isTrue);

    settings.setPlaybackStartStrategy(PlaybackStartStrategy.playbackPriority);
    expect(settings.waitForSubtitlePreparation, isTrue);
  });

  test('display mode and playback strategy do not reset translation config',
      () {
    final settings = AppSettingsController(
      translationMode: TranslationMode.genericApi,
      genericEndpoint: Uri.parse('https://api.example.test/v1'),
      genericApiKey: 'key',
      genericModel: 'model-a',
    );
    final before = settings.snapshot;

    settings.setSubtitleDisplayMode(SubtitleDisplayMode.original);
    settings.setPlaybackStartStrategy(PlaybackStartStrategy.subtitlePriority);

    expect(settings.snapshot.sameTranslationConfiguration(before), isTrue);
  });

  test('translation scheduling defaults, bounds and snapshot are effective',
      () {
    final settings = AppSettingsController();

    expect(settings.translationBatchSize, 1);
    expect(settings.translationMaxConcurrent, 10);

    settings.setTranslationBatchSize(999);
    settings.setTranslationMaxConcurrent(0);

    expect(settings.translationBatchSize, 20);
    expect(settings.translationMaxConcurrent, 1);
    expect(settings.snapshot.translationBatchSize, 20);
    expect(settings.snapshot.translationMaxConcurrent, 1);
  });

  test('translation concurrency allows up to twenty requests', () {
    final settings = AppSettingsController();

    settings.setTranslationMaxConcurrent(20);

    expect(settings.translationMaxConcurrent, 20);
    expect(settings.snapshot.translationMaxConcurrent, 20);
  });

  test('system translation is a selectable translation mode', () {
    final settings = AppSettingsController();

    settings.setTranslationMode(TranslationMode.systemTranslation);

    expect(settings.translationMode, TranslationMode.systemTranslation);
    expect(
        settings.snapshot.translationMode, TranslationMode.systemTranslation);
  });

  test('translation context toggle defaults on and affects scheduling', () {
    final settings = AppSettingsController();

    expect(settings.translationContextEnabled, isTrue);

    final before = settings.snapshot;
    settings.setTranslationContextEnabled(false);

    expect(settings.translationContextEnabled, isFalse);
    expect(settings.snapshot.translationContextEnabled, isFalse);
    expect(before.sameTranslationScheduling(settings.snapshot), isFalse);
    expect(before.sameTranslationConfiguration(settings.snapshot), isTrue);
  });

  test('translation scheduling changes are isolated from provider config', () {
    final settings = AppSettingsController();
    final before = settings.snapshot;

    settings.setTranslationBatchSize(8);
    settings.setTranslationMaxConcurrent(4);

    expect(settings.snapshot.sameTranslationConfiguration(before), isTrue);
    expect(settings.snapshot.sameTranslationScheduling(before), isFalse);
  });
}
