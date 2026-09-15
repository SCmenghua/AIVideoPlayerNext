# Architecture

```text
app/lib
  app/          装配（Riverpod providers）、主题
  player/       PlayerShell（唯一主页面）+ PlayerOverlay（控制层、字幕层、状态）+ PlaybackGate
  recognition/  应用侧识别编排：RecognitionService、平台 PcmSource、模型目录/下载、网络媒体解析、TranscriptStore
  translation/  翻译队列与 Provider（DeepL / OpenAI 兼容 / 系统翻译）
  browser/      内置浏览器与媒体交接
  settings/     AppSettings（识别语言/模型/VAD、翻译、字幕、播放门控）
  diagnostics/  状态 / 字幕 / 日志三页
  domain/       与平台无关的契约：PlayerService、TranscriptDocument、翻译契约、浏览器模型
  core/         诊断日志、构建信息
app/packages/recognition   纯 Dart 识别管线（无 Flutter 依赖）
native/speech_core         whisper.cpp C ABI v3：识别、Silero VAD、抗混叠重采样
native/audio_decoder       Windows Media Foundation 解码器（优先输出 16 kHz 单声道 float）
app/ios/Runner             AVFoundation 解码桥（输出 16 kHz 单声道）、系统翻译桥
```

## 识别管线（`app/packages/recognition`）

```text
PcmSource（平台解码器，任意采样率）
  → PcmNormalizer（原生 windowed-sinc 重采样到 16 kHz 单声道，跨块连续）
  → VadStream（Silero 逐帧语音概率，512 样本/帧，调用间重叠 8 帧）
  → SpeechSegmenter（在停顿处切窗：≥1 s 长停顿 / ≥6 s 普通停顿 / ≥20 s 短停顿 / 28 s 强制）
  → WhisperEngine（worker isolate，beam 5，温度回退，token 时间戳，上一窗口尾部作 initial_prompt）
  → SegmentGate（重复 4-gram、no-speech、黑名单短语、整窗重复、按 VAD 语音区间夹紧时间）
  → TranscriptAssembler（续句合并、句末切分、按显示宽度换行、覆盖替换、稳定 ID）
  → Transcript（不可变；at(position, hold: 2.5 s)）
```

`RecognitionSession` 串起以上环节：显式状态机、generation 隔离（seek/换片后旧结果全部丢弃）、
有界待识别队列（≥3 个窗口时暂停解码）与领先水位（领先播放 30 s 暂停、回落 15 s 恢复）。

`bin/regression.dart` 用同一条管线跑标注语料，输出 CER 与首段时间偏差；CI 每次运行并写入 job summary。

## 应用侧

- `RecognitionService` 按设置创建 `WhisperEngine`/`VadDetector`，缺模型时给出可下载状态，
  通过 `RecognitionMediaResolver` 把网络媒体解析为共享回环缓存地址（失败退回完整缓存），
  并把 `Transcript` 镜像进 `TranscriptStore`（`TranscriptDocument` = 片段 + 译文）。
- `TranscriptTranslationQueue` 订阅 `TranscriptStore`，按稳定 ID + 原文双重校验写回译文。
- `PlaybackGate` 决定播放开始与内容等待（字幕/翻译优先时最多暂停 8 s）。
- `PlayerShell` 全窗口视频面；`PlayerOverlay` 作为 media_kit `Video.controls` 绘制，全屏时同样生效；
  浏览器以离屏层常驻，设置与诊断为独立页面。

## 网络媒体

播放与识别共用一条回环下载流：`SharedNetworkMediaBroker` 以原始 URI 为键维护唯一
`RecognitionMediaCacheWorker` 会话（单飞上游 GET、有界分段缓存、断点续传、seek 抢占）；
mpv 与识别解码器都打开 `http://127.0.0.1:<port>/media.<ext>`，代理向上游注入浏览器授权头。

## 模型与构建

- 权重不入包：`WhisperModelCatalog` 描述 kotoba-whisper-v2.0（fp16 / q5_0）、large-v3-turbo q5_0 与 Silero VAD，
  `WhisperModelStore` 断点续传下载并按大小 + SHA-256 校验后落盘到应用数据目录；仅 VAD 模型随包分发。
- CI（`.github/workflows`）负责原生构建（Windows Vulkan/CPU、iOS Metal）、CTest、Dart 包测试、Flutter 测试、
  识别回归与打包；本地开发机不需要任何模型或工具链即可改代码。
