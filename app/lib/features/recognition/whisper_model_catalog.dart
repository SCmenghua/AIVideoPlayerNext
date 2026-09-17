enum WhisperModelKind { recognition, vad }

class WhisperModelSpec {
  const WhisperModelSpec({
    required this.id,
    required this.fileName,
    required this.kind,
    required this.label,
    required this.description,
    required this.url,
    required this.sha256,
    required this.sizeBytes,
    this.japaneseOnly = false,
    this.usesInitialPrompt = true,
  });

  final String id;
  final String fileName;
  final WhisperModelKind kind;
  final String label;
  final String description;
  final Uri url;

  /// Lower-case hex.
  final String sha256;
  final int sizeBytes;
  final bool japaneseOnly;

  /// Whether the weight tolerates the previous window's text as an
  /// `initial_prompt`. Fine-tunes trained on single utterances tend to
  /// hallucinate when primed, and say so on their model cards.
  final bool usesInitialPrompt;

  /// Whether this weight fits comfortably in a mobile app's memory budget.
  bool get fitsMobileMemory => sizeBytes < 700 * 1024 * 1024;

  String get sizeLabel {
    if (sizeBytes >= 1 << 30) return '${(sizeBytes / (1 << 30)).toStringAsFixed(2)} GB';
    if (sizeBytes >= 1 << 20) return '${(sizeBytes / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(sizeBytes / (1 << 10)).toStringAsFixed(0)} KB';
  }
}

/// Every weight the application knows how to install. Files are downloaded
/// on demand and verified by size and SHA-256; nothing is bundled.
class WhisperModelCatalog {
  const WhisperModelCatalog._();

  static final kotobaV2 = WhisperModelSpec(
    id: 'kotoba-whisper-v2.0',
    fileName: 'ggml-kotoba-whisper-v2.0.bin',
    kind: WhisperModelKind.recognition,
    label: 'Kotoba Whisper v2.0（日语专用，推荐）',
    description: '日语电视语音蒸馏模型：无幻觉循环、速度约为 turbo 的 3 倍。仅支持日语。',
    url: Uri.parse(
      'https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0.bin',
    ),
    sha256: 'eff70a8a236e731abba774ba71e1f6d0fce53302137208c32207e694e0bf4546',
    sizeBytes: 1519521155,
    japaneseOnly: true,
  );

  static final kotobaV2Q5 = WhisperModelSpec(
    id: 'kotoba-whisper-v2.0-q5_0',
    fileName: 'ggml-kotoba-whisper-v2.0-q5_0.bin',
    kind: WhisperModelKind.recognition,
    label: 'Kotoba Whisper v2.0 q5_0（日语，小体积）',
    description: '同上的 5-bit 量化版本，体积约三分之一，精度略低。仅支持日语。',
    url: Uri.parse(
      'https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0-q5_0.bin',
    ),
    sha256: '4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658',
    sizeBytes: 537819875,
    japaneseOnly: true,
  );

  static final animeWhisper = WhisperModelSpec(
    id: 'anime-whisper',
    fileName: 'ggml-anime-whisper.bin',
    kind: WhisperModelKind.recognition,
    label: 'Anime Whisper（日语动画/游戏配音）',
    description: '在 5300 小时动画与 Galgame 配音上微调的 Kotoba Whisper v2.0：'
        '句读贴合语气，言い淀み与笑声照写。作者要求关闭识别上下文，否则会严重幻觉。仅支持日语。',
    url: Uri.parse(
      'https://huggingface.co/Aratako/anime-whisper-ggml/resolve/main/ggml-anime-whisper.bin',
    ),
    sha256: 'bce42c15312fcdbdcc8432b2ce63ba967f4cc3d2cc783fd6ab2ba264caf0db8d',
    sizeBytes: 1519521155,
    japaneseOnly: true,
    usesInitialPrompt: false,
  );

  static final animeWhisperQ5 = WhisperModelSpec(
    id: 'anime-whisper-q5_0',
    fileName: 'ggml-anime-whisper-q5_0.bin',
    kind: WhisperModelKind.recognition,
    label: 'Anime Whisper q5_0（日语动画/游戏配音，小体积）',
    description: '同上的 5-bit 量化版本，体积约三分之一。同样需要关闭识别上下文。仅支持日语。',
    url: Uri.parse(
      'https://huggingface.co/Aratako/anime-whisper-ggml/resolve/main/ggml-anime-whisper-q5_0.bin',
    ),
    sha256: 'd5b6111bc84107bc641413516a9af083820014ea175ae3a42be05499b86d155c',
    sizeBytes: 537819875,
    japaneseOnly: true,
    usesInitialPrompt: false,
  );

  static final largeV3TurboQ5 = WhisperModelSpec(
    id: 'large-v3-turbo-q5_0',
    fileName: 'ggml-large-v3-turbo-q5_0.bin',
    kind: WhisperModelKind.recognition,
    label: 'Whisper large-v3-turbo q5_0（多语言）',
    description: '通用多语言模型，用于日语以外的语言或自动检测。',
    url: Uri.parse(
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin',
    ),
    sha256: '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2',
    sizeBytes: 574041195,
  );

  static final sileroVad = WhisperModelSpec(
    id: 'silero-vad-v5.1.2',
    fileName: 'ggml-silero-v5.1.2.bin',
    kind: WhisperModelKind.vad,
    label: 'Silero VAD v5.1.2',
    description: '语音活动检测模型，决定识别窗口的切分位置。',
    url: Uri.parse(
      'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin',
    ),
    sha256: '29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf',
    sizeBytes: 885098,
  );

  static final List<WhisperModelSpec> recognitionModels = [
    kotobaV2,
    kotobaV2Q5,
    animeWhisper,
    animeWhisperQ5,
    largeV3TurboQ5,
  ];

  static final List<WhisperModelSpec> all = [...recognitionModels, sileroVad];

  static WhisperModelSpec? byId(String id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  /// iOS gives one app roughly two to three gigabytes before the system kills
  /// it, and the weights are only part of the footprint: ggml's compute
  /// buffers, Metal and video decoding share that budget. Quantised weights
  /// are the default there; the fp16 model stays selectable on desktop.
  static WhisperModelSpec defaultFor(String language, {bool compact = false}) {
    if (language != 'ja') return largeV3TurboQ5;
    return compact ? kotobaV2Q5 : kotobaV2;
  }

  static bool supports(WhisperModelSpec spec, String language) =>
      !spec.japaneseOnly || language == 'ja';
}
