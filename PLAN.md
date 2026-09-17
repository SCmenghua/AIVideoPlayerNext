# AIVideoPlayerNext 重构计划

> 基线：`main` @ `30dce48`（2026-08-29）
> 制定日期：2026-09-15
> 状态：待用户确认后按 Step 0 → Step 6 顺序执行

## 0. 背景与结论

用户反馈：日语识别非常不准；UI 是"工作台"不是播放器。代码审查结论：

**识别不准是管线问题，不是 Whisper 不行。** `main` 上同时存在十处硬伤，每一处都足以单独破坏准确率或时间戳：

| # | 问题 | 位置 |
|---|---|---|
| 1 | `audio_ctx = 512`，编码器上下文从 30 s 砍到 10.24 s，时间戳校准崩坏 | `native/speech_core/src/speech_core.cpp:366` |
| 2 | 固定 4 s 窗口按采样数硬切，切点与停顿无关 | `app/lib/domain/audio/audio_window_planner.dart` |
| 3 | `no_context = true`，无 `initial_prompt`，每窗零上下文 | `speech_core.cpp:363` |
| 4 | 贪心解码，无 beam search、无温度回退 | `speech_core.cpp:358` |
| 5 | 线性插值重采样无抗混叠；声道等权平均 | `app/lib/domain/audio/audio_models.dart:173-188` |
| 6 | RMS 能量阈值冒充 VAD | `audio_window_planner.dart:156-181` |
| 7 | 质量门控只有 `no_speech_prob ≥ 0.6` + 两条黑名单；avg_logprob / compression_ratio 未过 ABI | `speech_core.cpp:439-448` |
| 8 | 组装器规范化正则剥掉全部假名，日语去重与稳定 ID 失效 | `transcript_assembler.dart:186-190` |
| 9 | 默认模型 `large-v3-turbo-q5_0`；未合并分支实测 kotoba-whisper-v2.0 对日语零幻觉、快 3 倍 | `providers.dart:54` |
| 10 | 字幕显示严格 `[start, end)` 无保持，迟到即永不显示 | `transcript_document.dart` |

**结构问题**：四个上帝文件（`recognition_media_cache_worker` 1972 行、`player_screen_phase2` 1681 行、`recognition_controller` 1496 行、`whisper_cpp_speech_service` 949 行）；`features` 之间横向耦合；死代码双轨（旧 `SpeechRecognitionService`、`SubtitleTimeline`、`LegacyPlayerScreen`）；语言/线程/模型名硬编码多处；原生 API 只暴露 `language` 与 `n_threads`；没有可量化的识别质量回归。

**分支 `origin/phase-10-ios-model-download` 不合并**，但其实验数据（`audio_ctx=0`、8 s 窗口、kotoba 对比、iOS 模型下载器设计）作为本计划的设计输入。

## 1. 执行规则

1. 开发机是 ARM Linux，没有 Flutter / Dart / Windows / macOS 工具链。本地只做：改代码、写文档、纯文本检查。
2. **所有本地无法进行的操作（编译、`flutter analyze/test`、`dart test`、原生 CTest、模型下载、识别回归、打包）一律通过 GitHub CI 完成，只修改现有四个 workflow 文件，不新增 workflow 或脚本文件。**
   - `.github/workflows/windows.yml`：质量门（analyze / test / 原生构建 / CTest / 识别回归）
   - `.github/workflows/ios.yml`：iOS 编译门
   - `.github/workflows/build-windows-release.yml`：Windows 发布包
   - `.github/workflows/build-unsigned-ios-ipa.yml`：未签名 IPA
3. 工作分支 `refactor`，从 `main` 切出；`windows.yml` / `ios.yml` 的 `push.branches` 加入 `refactor`，每次推送触发 CI。每个 Step 结束条件：CI 绿 + 用户确认（涉及真机的由用户在 Windows / iPhone 验收）。
4. 每个 Step 完成后在本文件第 5 节追加一行执行记录，只记录已验证事实。
5. 模型权重、VAD 模型、回归素材一律不入 Git，CI 下载并校验 SHA-256，用 `actions/cache` 缓存。
6. 不做向后兼容垫片：旧设置字段直接迁移或丢弃；旧接口直接删除。

## 2. 目标架构

```text
app/
  lib/
    app/            装配（providers）、主题、路由
    player/         PlayerShell：视频面 + 控制层 + 字幕层（唯一主页面）
    browser/        内置浏览器（抽屉/弹层）
    settings/       设置（弹层）
    diagnostics/    诊断（可选面板）
    translation/    翻译队列与 Provider（保留，适配新 Transcript）
    media/          SharedNetworkMediaBroker + 缓存 worker（拆分后）
  packages/
    recognition/    纯 Dart 识别管线，不依赖 Flutter
      lib/src/
        config.dart          RecognitionConfig
        pcm.dart             PcmSource 契约（解码器输出，带媒体时间）
        segmenter.dart       VAD 驱动切窗
        engine.dart          WhisperEngine（FFI，单 isolate worker）
        gate.dart            SegmentGate（质量门控 + 跨窗重复）
        assembler.dart       TranscriptAssembler（CJK 感知）
        transcript.dart      Transcript（不可变文档，稳定 ID，带保持的 at()）
        session.dart         RecognitionSession（显式状态机 + 有界队列 + 水位）
      test/
native/
  speech_core/      ABI v3：完整 whisper 参数、VAD、重采样、质量指标
  audio_decoder/    Windows MF 解码器（优先协商 16 kHz 单声道 float）
  tools/            speech_regression（CER + 时间戳偏差）
```

### 2.1 识别管线设计参数（默认值）

| 参数 | 值 | 依据 |
|---|---|---|
| 模型（日语） | `ggml-kotoba-whisper-v2.0.bin` fp16；备选 q5_0 | 分支实测零幻觉循环、CER 优于 large-v3 |
| 模型（其他语言） | `ggml-large-v3-turbo-q5_0.bin` | 现状 |
| VAD | whisper.cpp 内置 Silero `ggml-silero-v5.1.2.bin`，阈值 0.5，最小语音 250 ms，最小静音 100 ms | v1.7.6 原生支持 |
| 切窗 | 以 VAD 语音段累积：目标 20 s，上限 28 s，停顿 ≥ 500 ms 处切；单段 < 1 s 并入相邻 | Whisper 按 30 s 训练，边界必须落在静音 |
| `audio_ctx` | 0 | 时间戳校准前提 |
| 解码 | beam_size 5，temperature 0 起 +0.2 回退 | OpenAI 官方管线默认 |
| 门控 | entropy_thold 2.4，logprob_thold −1.0，no_speech_thold 0.6；跨窗整窗文本相同即丢弃 | 官方阈值 + 分支发现的跨段循环 |
| 上下文 | 上一窗口文本尾部 ≤ 120 字作 `initial_prompt`；seek / 换片清空 | 术语与人名一致性 |
| 时间戳 | `token_timestamps = true`，段边界取 token t0/t1 并 clamp 在段内 | 分支验证不劣化 |
| 重采样 | 原生 windowed-sinc 抗混叠到 16 kHz；下混按声道数平均 | 消除线性插值混叠 |
| 水位 | 识别领先播放 30 s 暂停解码，回落到 15 s 恢复；上限 90 s | 有界内存 |
| 字幕保持 | 段结束后保持 2.5 s，下一段开始即让位 | 首句不丢 |
| 线程 | Windows 8，iOS 4 | 现状 16 线程无收益 |

### 2.2 识别回归门

CI 每次运行 `speech_regression` 对固定日语公开素材输出：字符错误率（CER）、段数、时间戳与参考的中位偏差、幻觉循环段数、实时倍率，写入 job summary。Step 1 建立基线，Step 2 起每步与上一步比较；CER 或时间戳偏差劣化即视为该步未完成。

素材候选：JSUT（CC-BY-SA 4.0，单人朗读，带文本）用于 CER；用户自有 10 分钟对白素材仍是真机最终门（不入 Git、不进 CI）。

## 3. 执行步骤

### Step 0：清理文档与死代码（纯本地）

- 删除 `NEW.md`、`docs/phase-1.md`；`README.md` 重写为一屏（项目定位、目录、CI 入口）；`docs/architecture.md` 清空待 Step 6 重写；本文件替换旧 `PLAN.md`。
- 删除死代码：`SpeechRecognitionService` / `MockSpeechRecognitionService` / `WhisperCppSpeechRecognitionService`、`SubtitleTimeline`、`LegacyPlayerScreen`、`player_screen.dart` export 壳（`player_screen_phase2.dart` 改名 `player_screen.dart`）、`providers.dart` 中对应 provider。
- 切 `refactor` 分支，`windows.yml` / `ios.yml` 触发加 `refactor`。
- 完成条件：`flutter analyze` / `flutter test` 在 CI 通过。

### Step 1：CI 补齐原生构建与识别回归门

- `windows.yml`：安装 Vulkan SDK；CMake 构建 `native/audio_decoder` 与 `native/speech_core`（`SPEECH_CORE_WITH_WHISPER=ON`、`GGML_VULKAN=ON`）到 `app/windows/CMakeLists.txt` 期望的路径；运行 CTest；`flutter build windows` 后校验包内存在两个 DLL。
- 下载并校验（缓存）：kotoba-whisper-v2.0 fp16、`ggml-silero-v5.1.2.bin`、回归素材。
- 运行 `speech_regression` 写 job summary，作为基线。
- `build-windows-release.yml` 同样接入原生构建与模型打包；`build-unsigned-ios-ipa.yml` 改为只打包 VAD 模型、不再内置 547 MB 权重并断言包体不含权重。
- 完成条件：Windows CI 产出含 DLL 的包；回归基线数字记入第 5 节。

### Step 2：原生识别核心重写（speech_core ABI v3）

- `speech_core_recognize_options` 结构体承载 §2.1 全部参数；`speech_core_segment` 增加 `avg_logprob`、`no_speech_prob`、`compression_ratio`、token 级时间戳。
- 新增 `speech_core_vad_*`：加载 Silero 模型，输入 PCM 输出语音段列表，供 Dart 切窗。
- 新增 `speech_core_pcm_resample`：抗混叠重采样 + 下混；删除 `audio_ctx = 512`。
- CTest：参数透传、VAD 分段、重采样（1 kHz + 14 kHz 合成信号验证 14 kHz 被滤除而非折叠）。
- `speech_regression` 改用新 API，支持 `--vad --beam --prompt`，输出 CER。
- 完成条件：CTest 通过；回归数字优于 Step 1 基线；iOS CI 编译通过。

### Step 3：Dart 识别管线重建（`app/packages/recognition`）

- 按 §2 目录实现 `config / pcm / segmenter / engine / gate / assembler / transcript / session`。
- `TranscriptAssembler` 重写：CJK 感知规范化（保留假名）、时间 + 文本去重、日语句末形态与标点断句、显示宽度切行（36 半角格）。
- `RecognitionSession` 取代 1496 行控制器：显式状态机（idle / running / paused / seeking / stopped）、单一有界队列、§2.1 水位、seek 即以新 generation 从目标位置重启切窗；旧 generation 结果全部丢弃。
- 纯 Dart 单测：segmenter（合成 VAD 概率）、gate、assembler（日语固定用例）、session（fake engine）。
- `windows.yml` / `ios.yml` 增加 `dart test` 步骤（包目录）。
- 完成条件：包测试 + `flutter analyze` 通过。

### Step 4：接线与平台层

- Windows 解码器优先协商 16 kHz 单声道 float，失败退回原生格式交原生重采样；iOS 解码器输出原生格式交原生重采样。
- `providers.dart` 装配新包；删除 `recognition_controller` / `audio_recognition_adapters` / `audio_window_planner` / 旧 `transcript_assembler` / `recognition_queue` / `whisper_cpp_speech_service`。
- `RecognitionConfig` 由设置生成：识别语言（auto / ja / en / zh / …）、模型选择、VAD 开关、领先水位。
- 模型管理：目录（kotoba fp16 / q5_0、turbo、Silero）+ 断点续传下载器 + SHA-256 校验；Windows 放程序目录 `models/`，iOS 放 Application Support；设置页可安装 / 删除。
- 翻译队列适配新 `Transcript`（稳定 ID + `sourceText` 双重校验）。
- `recognition_media_cache_worker` 拆为 `proxy_server / segment_cache / upstream_filler` 三个文件，行为不变。
- 完成条件：CI 全绿；用户真机验收：日语素材首句不丢、无重复字幕行、译文跟随、seek 后 5 s 内出字幕。

### Step 5：播放器 UI 重做

- `PlayerShell` 为唯一主页面：全幅视频面、自动隐藏控制层（3 s）、底部字幕层；浏览器 / 设置 / 诊断改为抽屉或弹层。
- 控制层：点击 / 空格暂停，双击全屏，← / → 5 s，↑ / ↓ 音量，进度条 hover 时间预览与拖动预览；手机端左右滑 seek、上下滑音量。
- 字幕层：双语 / 单语，字号可调，2.5 s 保持，译文未到显示原文。
- 状态提示压缩为一条细状态线（缓冲 / 识别领先 / 翻译）；删除三行启动面板。
- Material 3 深色 `ColorScheme` token 化，删除全部硬编码 hex。
- Widget 测试：控制层显隐、键盘快捷键、字幕层显示模式。
- 完成条件：CI 全绿；用户真机看外观与手感。

### Step 6：收尾与发布

- 重写 `docs/architecture.md`；更新 `README.md`；版本 `0.11.0`。
- 触发 `build-windows-release.yml` 与 `build-unsigned-ios-ipa.yml` 产出验收包。
- 完成条件：两个发布包真机回归通过。

## 4. 已知风险

- CI 上 Vulkan SDK 安装与 kotoba fp16（约 3 GB）下载耗时，依赖 `actions/cache` 命中；首轮会慢。
- JSUT 是单人朗读，不代表电视对白噪声；CER 基线只保证"不劣化"，真机素材仍是最终门。
- Silero VAD 对音乐 / 人群声的判断不是万能，门控阈值需按回归数据调整一到两轮。
- iOS 侧原生重采样与 Metal 后端只能靠 CI 编译 + 用户真机验证，无法在 CI 运行推理。

## 5. 执行记录

| 日期 | Step | 状态 | 说明 |
|---|---|---|---|
| 2026-09-15 | 计划制定 | 已完成 | 基于 `main` @ `30dce48` 代码审查；等待用户确认开始 |
| 2026-09-15 | Step 0 | 代码完成，待 CI | 删除 `NEW.md`、`docs/phase-1.md`；`README.md` 重写；删除旧识别接口、`SubtitleTimeline`、`LegacyPlayerScreen` 等死代码；分支 `refactor` |
| 2026-09-15 | Step 1 | 代码完成，待 CI | `windows.yml`：Vulkan SDK（缓存）、audio_decoder 与 speech_core（CPU 用于测试/回归，Vulkan 用于打包）、CTest、`dart test`、Flutter 测试、JSUT 前 20 条回归（job summary + JSON artifact）、包内 DLL/VAD 校验；`ios.yml` 增加 CPU CTest 与包测试；发布 workflow 改为只打包 VAD 模型，IPA 不再内置权重 |
| 2026-09-15 | Step 2 | 代码完成，待 CI | speech_core ABI v3：`speech_core_recognize_options`（beam/温度回退/熵/logprob/no-speech/prompt/token 时间戳/audio_ctx=0）、段级 avg_logprob/no_speech_prob/repetition、Silero VAD API、流式抗混叠重采样器、静默日志；CTest 覆盖重采样混叠/流式一致性/VAD；`speech_regression` 改用新 API |
| 2026-09-15 | Step 3 | 代码完成，待 CI | `app/packages/recognition`：config/pcm/normalizer/vad/segmenter/engine/gate/assembler/transcript/session + 6 组单测 + `bin/regression.dart`（CER、首段偏差、阈值可选） |
| 2026-09-15 | Step 4 | 代码完成，待 CI | `WindowsPcmSource`/`IosPcmSource`、`RecognitionMediaResolver`、`WhisperModelCatalog`/`WhisperModelStore`（断点续传 + SHA-256）、`TranscriptStore`、`RecognitionService`；设置新增识别语言/模型/VAD/目标语言/字号；翻译队列改接 `TranscriptStore`；Windows 解码器优先协商 16 kHz 单声道；AppDelegate 删除模型通道；CMake 打包 `windows/models/`。**偏离：** `recognition_media_cache_worker` 未拆分（无编译器条件下盲改 2k 行网络代码风险过高，行为保持不变，后续单独处理） |
| 2026-09-15 | Step 5 | 代码完成，待 CI | `PlayerShell` + `PlayerOverlay`（自动隐藏控制层、键盘/手势、进度 hover 预览、音量/倍速/字幕模式/全屏）+ `SubtitleLayer`（2.5 s 保持、字号）+ `PlaybackGate`；设置/诊断改为独立页面；Material 3 token 主题；widget 测试与门控单测 |
| 2026-09-15 | Step 6 | 文档完成 | `docs/architecture.md` 重写；版本 `0.11.0`；发布待 Step 1–5 CI 全绿与真机验收后触发 |
| 2026-09-17 | Phase 11 Step A | 代码完成，待 CI | 回归口径：`--gap` 默认改为 `longSilence + 0.5 s`（2.0 s）并拒绝更小的值；报告新增窗口亏空、无人认领的片段、按原因分类的丢弃明细；`--no-context` 开关。`识别窗口完成` 日志补窗口起止与切分原因。切窗阈值写成两条单测。`WhisperModelSpec.usesInitialPrompt` + 设置页"识别上下文"三态（跟随模型/开/关）；目录加入 Anime Whisper fp16 与 q5_0（均标记不使用 initial prompt） |
| 2026-09-15 | CI 首轮通过 | 已完成 | `refactor` @ `e37ab15`，7 轮修复后 `windows.yml` 与 `ios.yml` 全绿：原生 CTest、Dart 包 28 项、Flutter 139 项、Windows 包内 DLL/VAD 校验、iOS 编译。修复内容均为盲写错误（MSVC 字面量、测试期望、接口未 `implements`、import 路径、`dispose` 内用 `ref`、控制条溢出）与 Vulkan 构建 MAX_PATH 问题 |

### 识别回归基线（作废，见 §6.1.1）

下表是 `--gap 1.0` 下测得的，窗口横跨多条 clip，逐条认领不可信。保留仅作历史记录，
不再作为任何改动的判据；新基线待 Phase 11 Step A 的 CI 运行产生后替换。

<details><summary>旧基线（CI，JSUT 前 20 条，kotoba-whisper-v2.0 fp16 + Silero VAD，CPU 4 线程）</summary>

| 指标 | 值 |
|---|---|
| 总体 CER | 11.34% |
| 单条 CER 中位数 | 6.07% |
| 首段起点偏差中位数 | 278 ms |
| 无输出的条目 | 1 / 20（`0006.wav`，待查） |
| 窗口 / 片段 / 丢弃 | 18 / 30 / 0 |
| 实时倍率（CI CPU） | 5.92（GPU 真机另计） |

</details>

### 待用户操作

1. 真机验收（§3 Step 4/5 完成条件）：手动触发 `build-windows-release.yml` 与 `build-unsigned-ios-ipa.yml`，Windows 与 iPhone 各跑一段日语素材；首次启动会提示下载 kotoba 模型（1.5 GB）。
2. 验收通过后合并 `refactor` 到 `main`。

## 6. Phase 11：第二识别引擎（Qwen3-ASR via transcribe.cpp）

> 制定日期：2026-09-17
> 起因：重构后识别仍不准。用户症状三项并存：字词错、整句漏掉不出字幕、重复或凭空编造。
> 目标平台已明确：**最终目标是 iOS（A19）**，Windows 只作开发期辅助。

### 6.1 症状归因

| 症状 | 归因 | 对策 |
|---|---|---|
| 字词识别错 | 模型能力 | 换引擎（§6.2） |
| 整句漏掉，不出字幕 | 待查。只有真机观察，无可信量化证据（见 §6.1.1） | Step A 修好度量后重新定位 |
| 重复或凭空编造 | whisper 自回归幻觉 | 换引擎 + 保留并强化文本侧重复检测 |

换模型只解决第一项。第二项必须独立查清，否则新引擎会继承同一条丢弃路径。

#### 6.1.1 §5 的回归基线不可信

`bin/regression.dart` 把全部 clip 首尾拼成一条流，间隔 `--gap` 默认 1.0 s，跑单个 session
（`regression.dart:182-198`）。但 §2.1 的切窗规则在 1.0 s 间隔上都不成立：
`longSilence` 要 1500 ms；`minSilence` 500 ms 要求窗口已累积 ≥ `minCutWindow` 6 s，
而 JSUT 单条只有 4–5 s；`shortSilence` 要求 ≥ 20 s。结果是一个窗口横跨多条 clip——
基线里"窗口 / 片段 = 18 / 30"对应 20 条 clip，正是这个现象。

打分却按 clip 时间区间认领段（段中点落在 `[offset−gap/2, offset+duration+gap/2)`，
`regression.dart:255-260`）。窗口跨 clip 时，段时间戳偏移、或组装器跨 clip 合并
（`assembler.dart:69`：上一句未结束且间隔 ≤ 300 ms 即并），会让一条 clip 认领到两段文本、
相邻一条认领到零段。

**因此基线中"1 / 20 无输出"大概率是度量假象而非识别漏句，11.34% 也混入了拼接边界的错配。**
连带影响：这条回归门是 Step 2–5 每一步"不劣化"的判据，其噪声意味着"重构未使识别劣化"
这一结论的置信度低于 §5 记录的措辞。重构修掉的十项硬伤本身与该门无关，仍然成立；
但重构究竟带来多少提升，目前没有可信数字。

### 6.2 选型

第二引擎运行时：**`handy-computer/transcribe.cpp`**（MIT，ggml 底座，Metal / Vulkan / CUDA，
单头 C ABI `include/transcribe.h` + `transcribe.abihash` 摘要）。与现有 speech_core 同构：
静态构建（`TRANSCRIBE_BUILD_SHARED=OFF` 为默认）、Apple Silicon 自动 `TRANSCRIBE_METAL=ON`
且 `GGML_METAL_EMBED_LIBRARY=ON`（无需单独 metallib）、`transcribe_backend_request` 与
`SpeechBackend` 一一对应、`transcribe_set_abort_callback` 对应现有 cancel 语义。

模型：**Qwen3-ASR**（Apache-2.0，音频编码器 + Qwen3 因果 LM，30 语种自动识别）。

| 变体 | 参数 | FLEURS ja CER (q8_0) | q8_0 体积 | 备注 |
|---|---|---|---|---|
| `qwen3-asr-1.7b` | 2B | **5.29%** | 2.19 GB | iOS 主力候选；另有 Q6_K 1.69 GB / Q4_K_M 1.32 GB |
| `qwen3-asr-0.6b` | 782M | 约差 0.5pp | 850 MB | 降级档 / CI 回归用 |

选它而不是日语专用模型，因为用户素材混杂（动画、真人、综艺都有），通用最强项优于单域最强项。

同时加进目录但不作主力：

- `litagin/anime-whisper`（MIT，base 即 kotoba-whisper-v2.0，5300 小时动画/Galgame 微调）。
  架构与现有 speech_core 完全一致，`Aratako/anime-whisper-ggml` 已有全套量化，接入成本≈加一条目录条目。
  **模型卡明确要求关闭 initial prompt**，否则严重幻觉——这也是 `contextEnabled` 需要按模型可关的直接原因。
- ReazonSpeech NeMo v2（FastConformer-RNNT，3.5 万小时日本电视音频，自带 token 时间戳、结构上无幻觉循环）
  暂不纳入：只覆盖日语，且需先验证能否经 transcribe.cpp 的 parakeet 转换器进同一运行时。留作 Phase 11 之后的备选。

### 6.3 管线改动

Qwen3-ASR **不输出时间戳、不接 initial prompt**（transcribe.cpp 的能力表如此声明）。因此：

- `SpeechSegmenter` 增加 `utterance` 模式：一个 VAD 语音段（合并 <300 ms 间隙，上限约 15 s 强制切）
  = 一个识别窗 = 一条字幕，时间直接取 VAD 边界。字幕定时改由 VAD 负责，不再依赖模型吐的时间戳。
- 引入 `EngineCapabilities`（timestamps: none/segment/word/token、hasConfidence、acceptsPrompt）。
  `SegmentGate` 对无置信度引擎跳过 `avgLogprob` / `noSpeechProb` 分支，只跑空文本、黑名单、
  n-gram 重复与跨窗整窗重复；utterance 模式下不再需要把段时间 clamp 进语音区间。
- `contextEnabled` 按引擎能力与模型自动关闭。

Dart 侧直接绑定 `transcribe.h` 的子集，**不再写新的 C++ 封装层**——本地无编译器，盲写 C++ 是
Step 0–5 里唯一反复出错的部分（§5 记录的 7 轮 CI 修复几乎全是盲写错误）。

### 6.4 执行步骤

| Step | 内容 | 完成条件 |
|---|---|---|
| A | 修回归度量（§6.1.1）：`--gap` 默认提到 2.0 s 使 `longSilence` 能切开每条 clip，断言窗口数 == clip 数（跨 clip 合并即 CI 红），报告输出每个丢弃段的原因与时间；`contextEnabled` 改为按模型可关。重跑并以新数字替换 §5 基线 | 窗口与 clip 一一对应；新基线记入 §5，旧基线标注作废 |
| B | CI 接 transcribe.cpp：pin commit，Windows Vulkan 共享库、iOS 静态归档合并；断言 `transcribe.abihash` 未漂移；冒烟测试（加载 + `samples/jfk.wav`） | `windows.yml` / `ios.yml` 绿，包内产物校验通过 |
| C | `TranscribeEngine`（worker isolate + FFI）、`EngineCapabilities`、utterance 切窗、门控降级、模型目录泛化为按引擎分类 | 包测试 + `flutter analyze` 通过 |
| D | `regression.dart --engine`；CI 上 kotoba 与 `qwen3-asr-0.6b` 双跑同一语料；诊断页加双引擎对照视图 | 两条 CER 数字并列写入 job summary |
| E | iOS 真机：量化档位按内存与 RTF 定案，发未签名 IPA 验收 | 用户在 iPhone 上跑自有素材，三项症状逐条对照 |

Step A 与 Step B 无依赖，可并行。

### 6.5 风险

- transcribe.cpp 处于 0.2.0 开发期，ABI 会动：必须 pin commit 并在 CI 断言 `transcribe.abihash`。
- 字幕定时完全交给 Silero VAD：BGM 与人群声下 VAD 成为新瓶颈。若 utterance 模式时间不稳，
  需调阈值或补一次强制对齐。
- iOS 内存：1.7B Q8_0 2.19 GB 与视频解码、Flutter 共存，需真机 jetsam 验证；
  降级路径 Q6_K → Q4_K_M → 0.6B。
- 短窗多次跑自回归 LLM，总开销高于长窗；A19 Metal 的实际 RTF 只能真机测。
- 现有 JSUT 基线是单人朗读，测不出混杂素材的问题。Step D 的双跑只用于防劣化，最终门仍是 Step E。
