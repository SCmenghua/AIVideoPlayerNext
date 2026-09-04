import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/speech/whisper_model_catalog.dart';
import 'package:ai_video_player_next/features/settings/app_settings.dart';

void main() {
  test('every downloadable weight is a selectable setting', () {
    // The download list writes its choice straight into the recognition
    // model setting, and the setter silently ignores a value it does not
    // recognise. A weight offered for download but missing from the settings
    // options would install and then refuse to be selected.
    final options = whisperModelOptions.map((option) => option.fileName).toSet();
    for (final model in whisperModelCatalog) {
      expect(options, contains(model.fileName), reason: model.id);
    }
  });

  test('every selectable setting is a weight the app can install', () {
    final catalog = whisperModelCatalog.map((model) => model.fileName).toSet();
    for (final option in whisperModelOptions) {
      expect(catalog, contains(option.fileName), reason: option.fileName);
    }
  });

  test('the default model is one of them', () {
    expect(whisperModelByFileName(defaultWhisperModel), isNotNull);
  });
}
