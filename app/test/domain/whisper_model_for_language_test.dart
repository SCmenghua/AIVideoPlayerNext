import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/speech/whisper_model_catalog.dart';
import 'package:ai_video_player_next/features/settings/app_settings.dart';

AppSettings settingsWith({
  required String recognitionLanguage,
  required String whisperModel,
}) =>
    AppSettingsController(
      recognitionLanguage: recognitionLanguage,
      whisperModel: whisperModel,
    ).snapshot;

void main() {
  group('whisperModelForLanguage', () {
    test('Japanese takes the specialised weight', () {
      expect(whisperModelForLanguage('ja')?.fileName, japaneseWhisperModel);
      expect(japaneseWhisperModel, 'ggml-kotoba-whisper-v2.0.bin');
    });

    test('a regional Japanese tag still counts as Japanese', () {
      expect(whisperModelForLanguage('ja-JP')?.fileName, japaneseWhisperModel);
      expect(whisperModelForLanguage('JA')?.fileName, japaneseWhisperModel);
    });

    test('every other pinned language takes turbo', () {
      for (final code in ['en', 'zh', 'ko', 'ru', 'fr', 'de', 'es']) {
        expect(whisperModelForLanguage(code)?.fileName, multilingualWhisperModel,
            reason: code);
      }
      expect(multilingualWhisperModel, 'ggml-large-v3-turbo-q5_0.bin');
    });

    test('detection leaves the choice alone', () {
      // The feature is only active when a language is pinned, so `auto` has to
      // return null rather than a default - otherwise the model dropdown would
      // never do anything.
      expect(whisperModelForLanguage('auto'), isNull);
      expect(whisperModelForLanguage(''), isNull);
      expect(whisperModelForLanguage('  '), isNull);
    });

    test('both automatic choices are weights the app can install', () {
      // A typo here would silently disable recognition, since the resolver
      // skips names the catalog does not know.
      expect(whisperModelByFileName(japaneseWhisperModel), isNotNull);
      expect(whisperModelByFileName(multilingualWhisperModel), isNotNull);
    });

    test('every pinnable language maps to a catalog weight', () {
      for (final option in recognitionLanguageOptions) {
        if (option.code == 'auto') continue;
        expect(whisperModelForLanguage(option.code), isNotNull,
            reason: option.code);
      }
    });
  });

  group('AppSettings model preference', () {
    test('a pinned language overrides the manual selection', () {
      final settings = settingsWith(
        recognitionLanguage: 'ja',
        whisperModel: 'ggml-large-v3.bin',
      );
      expect(settings.whisperModelFollowsLanguage, isTrue);
      expect(settings.effectiveWhisperModel, japaneseWhisperModel);
      // The manual choice stays as the fallback: on iOS the automatic weight
      // may simply not be installed yet.
      expect(settings.whisperModelPreference,
          [japaneseWhisperModel, 'ggml-large-v3.bin']);
    });

    test('a non-Japanese pin selects turbo', () {
      final settings = settingsWith(
        recognitionLanguage: 'en',
        whisperModel: 'ggml-kotoba-whisper-v2.0.bin',
      );
      expect(settings.effectiveWhisperModel, multilingualWhisperModel);
      expect(settings.whisperModelPreference,
          [multilingualWhisperModel, 'ggml-kotoba-whisper-v2.0.bin']);
    });

    test('detection keeps the manual selection', () {
      final settings = settingsWith(
        recognitionLanguage: 'auto',
        whisperModel: 'ggml-large-v3.bin',
      );
      expect(settings.whisperModelFollowsLanguage, isFalse);
      expect(settings.effectiveWhisperModel, 'ggml-large-v3.bin');
      expect(settings.whisperModelPreference, ['ggml-large-v3.bin']);
    });

    test('no duplicate when the manual choice already matches', () {
      final settings = settingsWith(
        recognitionLanguage: 'ja',
        whisperModel: japaneseWhisperModel,
      );
      expect(settings.whisperModelPreference, [japaneseWhisperModel]);
    });
  });
}
