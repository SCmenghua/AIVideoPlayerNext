/// A Whisper weight the app can install, with everything needed to fetch and
/// verify it.
///
/// The values here mirror `test_assets/speech/manifest.json`, which is the
/// project's record of which weights were qualified against which whisper.cpp
/// build. `whisper_model_catalog_test.dart` fails if the two drift apart, so
/// the manifest stays the place a new model is registered.
class WhisperModelDescriptor {
  const WhisperModelDescriptor({
    required this.id,
    required this.label,
    required this.sizeBytes,
    required this.sha256,
    required this.source,
    required this.license,
  });

  /// Manifest model id. The installed file is `<id>.bin`.
  final String id;

  /// Text shown in settings.
  final String label;

  /// Exact size of the published file. Checked before the hash so a truncated
  /// or redirected download fails without reading gigabytes back off disk.
  final int sizeBytes;

  /// Lowercase SHA-256 of the published file.
  final String sha256;

  /// Where the file is published.
  final String source;

  /// Licence of the weights, shown beside the download so it is visible
  /// before the user takes a copy.
  final String license;

  String get fileName => '$id.bin';

  Uri get sourceUri => Uri.parse(source);

  /// Size rounded for display, in the unit that reads naturally.
  String get sizeLabel {
    const mb = 1000 * 1000;
    const gb = mb * 1000;
    return sizeBytes >= gb
        ? '${(sizeBytes / gb).toStringAsFixed(2)} GB'
        : '${(sizeBytes / mb).round()} MB';
  }
}

/// Every weight the app offers, smallest first: the list doubles as the
/// download menu, and the cheapest usable option should be the first one a
/// user sees.
const whisperModelCatalog = <WhisperModelDescriptor>[
  WhisperModelDescriptor(
    id: 'ggml-kotoba-whisper-v2.0-q5_0',
    label: 'kotoba-whisper v2.0 量化（日语特化）',
    sizeBytes: 537819875,
    sha256: '4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658',
    source: '$_kotobaBase/ggml-kotoba-whisper-v2.0-q5_0.bin',
    license: 'Apache-2.0',
  ),
  WhisperModelDescriptor(
    id: 'ggml-large-v3-turbo-q5_0',
    label: 'large-v3-turbo 量化（多语言，带标点）',
    sizeBytes: 574041195,
    sha256: '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2',
    source: '$_whisperCppBase/ggml-large-v3-turbo-q5_0.bin',
    license: 'MIT',
  ),
  WhisperModelDescriptor(
    id: 'ggml-large-v3-q5_0',
    label: 'large-v3 量化（多语言）',
    sizeBytes: 1081140203,
    sha256: 'd75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1',
    source: '$_whisperCppBase/ggml-large-v3-q5_0.bin',
    license: 'MIT',
  ),
  WhisperModelDescriptor(
    id: 'ggml-kotoba-whisper-v2.0',
    label: 'kotoba-whisper v2.0 全精度（日语特化，推荐）',
    sizeBytes: 1519521155,
    sha256: 'eff70a8a236e731abba774ba71e1f6d0fce53302137208c32207e694e0bf4546',
    source: '$_kotobaBase/ggml-kotoba-whisper-v2.0.bin',
    license: 'Apache-2.0',
  ),
  WhisperModelDescriptor(
    id: 'ggml-large-v3',
    label: 'large-v3 全精度（多语言，最慢）',
    sizeBytes: 3095033483,
    sha256: '64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2',
    source: '$_whisperCppBase/ggml-large-v3.bin',
    license: 'MIT',
  ),
];

const _whisperCppBase =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';
const _kotobaBase =
    'https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main';

/// Weight that suits a pinned recognition language, or null when no language
/// is pinned.
///
/// Japanese gets the specialised kotoba weight, which transcribed Japanese
/// noticeably better than any general model in the Phase 10 comparisons -
/// large-v3 in particular hallucinates a stock closing phrase over near-silent
/// audio. Every other language gets turbo, the fastest multilingual weight
/// that still punctuates. `auto` returns null: with nothing pinned there is no
/// language to choose from, so the user's own selection stands.
WhisperModelDescriptor? whisperModelForLanguage(String recognitionLanguage) {
  final language = recognitionLanguage.trim().toLowerCase();
  if (language.isEmpty || language == 'auto') return null;
  final japanese = language == 'ja' || language.startsWith('ja-');
  return whisperModelByFileName(
    japanese ? japaneseWhisperModel : multilingualWhisperModel,
  );
}

/// Weight picked automatically for Japanese.
const japaneseWhisperModel = 'ggml-kotoba-whisper-v2.0.bin';

/// Weight picked automatically for every other pinned language.
const multilingualWhisperModel = 'ggml-large-v3-turbo-q5_0.bin';

/// The catalog entry a stored settings value refers to, or null when the value
/// names a weight this build does not know about.
WhisperModelDescriptor? whisperModelByFileName(String fileName) {
  for (final descriptor in whisperModelCatalog) {
    if (descriptor.fileName == fileName) return descriptor;
  }
  return null;
}

/// Raised when recognition is asked for before any weight has been installed.
///
/// This is an ordinary state on a fresh install, not a fault: builds ship
/// without a model so the user chooses which one to fetch.
class WhisperModelMissingException implements Exception {
  const WhisperModelMissingException();

  @override
  String toString() => '尚未安装识别模型，请在设置中下载一个。';
}
