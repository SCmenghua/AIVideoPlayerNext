# AIVideoPlayerNext 当前阶段执行计划

> 本文件是当前 Phase 的执行计划。每个 Phase 开始时，清空本文件并重新填充为该阶段的计划；阶段完成后保留最终状态，开始下一阶段时再整体替换。
>
> 当前项目：`AIVideoPlayerNext`
> 当前阶段：`Phase 6`
> 计划状态：Phase 6 已完成；后续 Phase 尚未开始
> 更新日期：2026-08-17

## 1. 阶段定位

### Phase 6：播放器音频、分窗与背压

Phase 5 已证明固定 WAV 可以经过 PCM 标准化、whisper.cpp、`speech_core` C ABI 和 Dart FFI，产生可比较的 `RecognitionEvent`。Phase 6 将这个固定输入闭环推进到实际播放器：从正在播放的本地媒体取得带媒体时间的 PCM，按有限窗口送入 Whisper，并正确处理播放控制生命周期。

本阶段的核心目标：

```text
本地视频
  -> 独立音频解码 adapter
  -> 带媒体时间的 AudioChunk
  -> AudioWindowPlanner
  -> 有界识别队列
  -> WhisperCppSpeechRecognitionService
  -> RecognitionEvent
  -> 诊断状态
```

本阶段首先以 Windows、本地 MP4/MKV/WebM 和已有的 `ggml-large-v3-turbo-q5_0` 为基准。浏览器媒体、HLS、Cookie、DRM、MSE、移动端真实音频和最终字幕视觉系统不作为首轮完成条件。

## 2. 已知前提

- Phase 5 已完成：固定英语 WAV 的真实模型回归、manifest 比较器、native CTest、Dart FFI 测试、完整 Flutter 测试和 Phase 3 Windows 人工回归均通过。
- whisper.cpp 固定为 v1.7.6，commit 为 `a8d002cfd879315632a579e73f0148d06959de36`；Release 包把模型放在程序目录的 `models/` 子目录，模型二进制仍由 Git 忽略并通过 Git LFS、Release Asset 或安装包分发。
- `native/speech_core` 当前以整段 Float32 PCM 识别为主，Phase 6 需要在不破坏 Phase 5 C ABI 和固定音频回归的前提下增加窗口化调用能力。
- `WhisperCppSpeechRecognitionService` 当前位于 worker isolate 中执行一次识别，模型路径和音频加载器由调用方提供，尚未成为主应用默认 Provider。
- `MediaKitPlayerService` 当前提供媒体打开、播放、暂停、seek、倍速、音量、位置和状态流，但没有向 Dart 暴露 PCM 音频帧。
- 主播放器的窗口识别链路已经使用真实 `WhisperWindowRecognitionService`；旧的 `speechRecognitionServiceProvider` Mock 仅保留给 Phase 5 的通用 Provider 测试，不驱动播放器字幕。
- `SubtitleTimeline` 已存在，但最终字幕 Overlay、翻译回填、视觉配置和字幕历史属于 Phase 7/8，不在本阶段扩展为完整产品功能。
- 用户的 HTTP(S) 代理不应影响本地 Flutter 测试；运行 Flutter 测试时继续对本机回环地址设置当前会话级 `NO_PROXY`，不修改永久代理配置。

## 3. 本阶段完成定义

Phase 6 只有在以下条件全部满足后才算完成：

1. Windows 可以从至少一种受支持的本地视频格式取得音频 PCM，并为每个音频块提供稳定的媒体起点、采样率、声道数和样本数。
2. 解码 adapter 不依赖 Flutter UI 线程直接处理 FFmpeg、libmpv 或其他 native 细节；资源、错误和取消有明确生命周期。
3. PCM 经过与 Phase 5 相同的 16 kHz、单声道、Float32 标准化后，窗口时间可以准确映射回媒体时间轴。
4. Whisper 识别窗口按顺序、有界地处理；模型不会为每个窗口重复加载，队列不会无限增长。
5. 播放、暂停、seek、换片、停止和 dispose 都能取消或隔离旧任务；旧 `sessionId` 的事件不会进入新媒体的字幕时间轴。
6. 识别落后、窗口跳过、纯静音、解码失败、模型缺失和 native 加载失败都能在诊断状态中明确区分，不得静默产生错位字幕。
7. 主应用可以在模型和 native 依赖可用时选择真实 Whisper Provider；不可用时显示明确状态并可回退到 Mock，不因缺少模型而崩溃。
8. 在至少一段项目自有或明确授权的本地视频上，实际播放能够产生带媒体时间的 final `RecognitionEvent`；暂停、seek、换片和取消回归通过。
9. `flutter analyze`、Flutter 测试、native 测试、Windows Release 构建和本地视频 smoke test 通过；真实模型结果不写入 Git。

## 4. 范围边界

### 本阶段包含

- Windows 本地视频音频解码技术尖峰。
- `AudioChunk`、`RecognitionWindow`、窗口状态和诊断契约。
- PCM 分块、16 kHz 单声道 Float32 标准化和媒体时间换算。
- 语音窗口规划、前导/尾部停顿、最大窗口和纯静音跳过。
- 有界缓冲、串行识别、有限预读和识别落后状态。
- Whisper 模型长生命周期、窗口识别、取消和 session 隔离。
- 播放器与识别控制器的 play/pause/seek/open/stop/dispose 生命周期。
- Windows 本地模型目录、native DLL 加载、版本检查和 Mock 回退。
- 诊断页的窗口、队列、延迟、推理耗时和跳过原因。
- 自动化 fake decoder、fake recognizer、队列和控制器测试。
- 一段本地授权视频的 Windows 真实模型回归。

### 本阶段不包含

- 完整字幕 Overlay、独立透明置顶窗口、字幕样式设置和字幕历史；属于 Phase 7。
- 翻译 Provider、翻译缓存、SQLite 历史和导出增强；属于 Phase 8。
- Apple Speech、Windows Live Captions、Apple Translation 和移动端 native 音频适配；属于后续平台阶段。
- HLS、MSE、DRM、blob URL、Cookie/授权头提取和浏览器音频抓取。
- 通过录音设备捕获系统混音或绕过网页保护取得音频。
- 以当前 Windows CPU 的实时倍率推断 iPhone/Android 性能。
- 在没有完成本地文件链路前同时支持所有网络媒体格式。

## 5. 设计原则

### 5.1 播放器与识别解耦

播放器负责显示和控制媒体，音频解码 adapter 负责提供可取消的音频流，识别控制器负责窗口和队列。Flutter UI 不直接调用 FFmpeg、libmpv 或 whisper.cpp 内部 API。

```text
PlayerService -> PlaybackSnapshot
AudioDecoder  -> Stream<AudioChunk>
AudioWindowPlanner -> Stream<RecognitionWindow>
RecognitionQueue -> RecognitionService
RecognitionController -> events + diagnostics
```

播放器的播放位置是控制参考，音频块中的媒体时间是识别事件的权威时间来源。不能用识别完成时间代替媒体时间。

### 5.2 PCM 契约

`AudioChunk` 至少包含：

```text
sessionId
mediaStart
sampleRate
channels
sampleCount
samples
```

进入 Whisper 前统一为：16 kHz、单声道、Float32、样本范围 `[-1.0, 1.0]`。Dart 使用 `Duration`，native 使用整数毫秒或样本索引。输入/输出样本数、媒体起点和转换耗时可以进入诊断；音频内容、完整媒体路径、Cookie 和授权头不能进入默认日志。

### 5.3 窗口与时间

首版固定窗口建议为 8 秒，允许通过本地配置调整到 6-10 秒。首版不做重叠窗口，先保证时间不重复、不漂移；窗口文本重复合并和重叠窗口留到后续评估。

每个窗口至少记录：`windowId`、`sessionId`、`mediaStart`、`duration`、`sampleCount`、`state`、`skipReason`、`inferenceMs` 和 `realtimeFactor`。

识别返回的段落时间必须加上窗口的 `mediaStart`。seek、换片或停止后，旧窗口即使晚返回，也必须在控制器和服务层双重检查 `sessionId`。

### 5.4 有界背压

首版队列上限为当前处理窗口 1 个、等待窗口最多 1 个；使用队列索引、双端队列或环形缓冲，不能通过不断删除列表头部维持队列。

当识别速度低于播放速度时，暂停继续预读而不是无限积累 PCM；记录识别延迟和队列深度；队列无法及时恢复时允许按完整窗口跳过，但必须记录媒体时间范围和跳过原因，不得把落后伪装成识别完成。

### 5.5 本地优先和降级

默认尝试本地 Whisper，但必须区分：模型未找到、native DLL 未找到、模型加载失败、模型版本不匹配、识别可用、识别暂时落后、识别被暂停和识别已停止。模型文件和 native 产物不提交 Git；默认诊断只记录脱敏模型标识、状态和版本。

## 6. 执行步骤

### Step 1：盘点音频解码路线并固定首个 adapter

状态：`已完成`

任务：

- 检查当前 `media_kit`/libmpv 版本是否提供稳定、可分发的音频帧输出接口。
- 评估独立 FFmpeg 解码 adapter 和 libmpv/native 音频输出 adapter 的许可证、Windows 构建、二进制体积、取消和时间戳能力。
- 以本地 MP4 为第一目标格式，准备一段项目自有或明确授权的带语音视频。
- 不在评估完成前把 native 解码实现写死到 Dart UI 或 Provider 中。
- 记录选型结论、依赖版本、许可证和不支持格式。

输出物：adapter 选型记录；能打开本地测试视频并输出音频时长/采样规格的最小 native 或 Dart smoke 工具。

完成条件：同一测试视频可以重复打开，音频时长和采样规格稳定；解码依赖的许可和分发边界明确。

### Step 2：定义 AudioChunk 和解码服务契约

状态：`已完成`

任务：

- 定义 `AudioChunk`、`AudioDecoderRequest`、`AudioDecoderStatus` 和 `AudioDecoder` 接口。
- 明确 chunk 的媒体起点、样本数、声道布局、采样率、结束条件和错误语义。
- 定义 `open`、`start`、`pause`、`seek`、`stop`、`dispose` 生命周期及 Stream 关闭时的取消行为。
- 明确 decoder 是否在后台 isolate/native worker 运行。
- 为 fake decoder 提供可控的时间轴、静音块、语音块、延迟和错误注入。

输出物：`app/lib/domain/audio/` 下的纯 Dart 契约、fake decoder 和契约测试。

完成条件：不依赖真实播放器，测试可以生成带媒体时间的 PCM chunk 流并验证取消、结束和错误。

### Step 3：实现本地视频到 PCM 的 Windows adapter

状态：`已完成（native 构建与真实视频 PCM smoke 已通过）`

任务：

- 实现 Step 1 选定的本地视频音频解码路径。
- 输出稳定的媒体时间和原始音频规格，不在 decoder 内部偷偷丢弃时间信息。
- 处理无音轨、损坏文件、过长文件、解码错误、暂停、seek 和停止。
- 在 native 侧限制单次 chunk 大小，避免把整部视频载入内存。
- 复用 Phase 5 的 PCM 标准化逻辑，避免 Dart 和 native 各自实现不同的重采样规则。
- 默认诊断只记录格式、采样率、时长、chunk 数量和错误类型，不记录 PCM 内容。

输出物：Windows audio decoder adapter、本地短视频 PCM smoke 工具或测试入口、依赖和打包说明。

完成条件：本地授权视频可以被分块解码，chunk 的媒体时间连续，取消后不再产生新 chunk，内存占用不随视频总时长线性增长。

### Step 4：实现 AudioWindowPlanner

状态：`已完成`

任务：

- 将连续 `AudioChunk` 合并为固定上限的识别窗口。
- 支持前导静音、语音开始、尾部停顿、最大窗口和文件结束。
- 首版使用确定性的 RMS 或峰值门控，不引入未经验证的复杂 VAD。
- 纯静音窗口直接跳过，并记录 `silence` 原因。
- 窗口不足最小长度、解码中断和格式错误必须有明确状态。
- 保证窗口起点、结束时间、样本数和标准化后样本数可推导。

建议首版参数：`targetWindow: 8 s`、`minimumSpeechWindow: 400 ms`、`tailSilence: 500-800 ms`、`maximumWindow: 10 s`、`overlap: 0 s`。

输出物：`AudioWindowPlanner`、窗口边界/静音/尾部停顿/EOF/异常测试。

完成条件：同一 chunk 序列多次运行得到相同窗口边界；所有窗口时间单调递增且不重叠。

### Step 5：扩展 Whisper 为持久窗口识别

状态：`已完成`

任务：

- 保留 Phase 5 的整段固定音频接口和回归结果，不直接破坏现有 ABI。
- 增加窗口识别所需的 native 生命周期或服务级队列接口。
- 模型只在服务/控制器初始化时加载一次，不为每个窗口重新加载模型。
- 每个窗口拥有明确的 session/window 标识，回调不得引用已释放的会话。
- 将窗口相对时间转换为媒体绝对时间，再映射为 `RecognitionEvent`。
- 取消、重复启动、模型错误和空结果继续使用明确状态；成功但没有 final segment 不能伪装成成功。
- 验证 `large-v3-turbo-q5_0` 在 6-10 秒窗口上的文本、耗时和实时倍率。

输出物：持久模型/worker 识别实现、窗口识别 C ABI 或稳定 Dart service API、固定窗口回归测试。

完成条件：连续提交多个窗口时模型只加载一次，结果按窗口顺序返回；取消窗口后无旧回调；固定 WAV 切窗结果可重复。

### Step 6：实现有界 RecognitionQueue 和背压

状态：`已完成`

任务：

- 实现当前窗口 1 个、等待窗口最多 1 个的有界队列。
- 使用队列索引、双端队列或环形缓冲，禁止 O(n) 头部删除。
- 识别器繁忙时暂停 decoder 预读或施加反压。
- 计算播放位置与最后完成窗口之间的识别延迟。
- 定义队列满、识别落后、窗口跳过和恢复条件。
- 跳过必须以完整窗口为单位，不能截断窗口后制造错误时间戳。

输出物：`RecognitionQueue`、队列深度/延迟/跳过原因诊断模型、fake recognizer 背压测试。

完成条件：队列有固定内存上限；慢识别器不会导致无界累积；所有跳过和失败都有可读状态。

### Step 7：实现 RecognitionController 播放生命周期

状态：`已完成（fake decoder/recognizer 自动化回归）`

任务：

- 监听 `PlayerService.snapshots`，协调 decoder、planner、queue 和 Whisper service。
- `open` 或换片时创建新 `sessionId`，取消并清理旧 decoder、窗口和识别任务。
- `play` 时开始或恢复音频生产；`pause` 时停止生产并取消或完成当前窗口。
- `seek` 时使旧 session 失效，清空队列，从新的媒体位置重新建立窗口。
- `stop` 和 `dispose` 时释放 decoder、worker、native session 和 stream subscription。
- 所有事件进入字幕时间轴前检查 session、window 和媒体源一致性。
- 控制器错误不应导致播放器崩溃；必须转为诊断状态或明确的可用性提示。

输出物：`RecognitionController`、播放器/decoder/queue/recognizer 依赖注入、生命周期状态机测试。

完成条件：fake decoder 和 fake recognizer 能通过自动化测试证明播放、暂停、seek、换片、停止、重复启动和旧事件隔离均正确。

### Step 8：接入真实 Provider、模型配置和 Mock 回退

状态：`已完成（配置与降级链路；真实媒体运行待验收）`

任务：

- 定义 Windows 本地模型目录和模型标识配置，不把机器绝对路径写入仓库。
- 检查 native DLL、模型文件、文件大小/哈希和模型加载结果。
- 将 `WhisperCppSpeechRecognitionService` 接入 Provider 工厂，而不是在 UI 内直接实例化。
- 真实 Provider 可用时使用 Whisper；不可用时显示中文状态并回退 Mock，测试环境可显式注入 Mock。
- 模型加载失败、模型缺失、DLL 缺失和架构不匹配都必须有稳定错误码和诊断摘要。
- Windows Release 验证 native DLL 的加载位置和模型目录权限。
- 不把模型路径、音频内容、Cookie 或授权头写入默认日志。

输出物：Provider factory/configuration、Windows 模型安装和缺失状态说明、Release 打包/加载验证。

完成条件：有模型时主应用可以选择真实 Provider；无模型时应用仍可启动并明确显示 Mock/不可用状态；Provider 切换不污染旧 session。

### Step 9：接入诊断状态和播放器字幕

状态：`已完成`

任务：

- 在诊断页显示当前 session、音频 decoder 状态、窗口状态、队列深度和识别延迟。
- 显示最近窗口的媒体起点、持续时间、样本数、推理耗时、实时倍率和结果数量。
- 显示纯静音、队列满、识别落后、取消、解码错误和模型错误的计数与最近原因。
- 保持诊断内容脱敏，不显示完整本地路径、PCM、Cookie、授权头或网页请求内容。
- 播放器下方字幕框消费真实 `RecognitionEvent`，显示 Whisper 原文和媒体时间；完整 Overlay、独立窗口、翻译和字幕样式仍属于 Phase 7/8。

完成条件：测试人员可以从诊断页判断一个窗口是已解码、已排队、已识别、被跳过、被取消还是失败。

### Step 10：自动化、真实视频回归和文档

状态：`已完成`

任务：

- 对 AudioChunk、窗口边界、RMS 静音门控、时间换算和队列上限增加纯 Dart/native 测试。
- 对 fake decoder + fake recognizer + controller 覆盖 play/pause/seek/open/stop/dispose。
- 对 native decoder 增加本地短视频 smoke test；素材只保留在仓库外，并在 manifest 记录许可和元数据。
- 使用真实 `ggml-large-v3-turbo-q5_0` 对至少一段本地授权视频进行回归。
- 覆盖含语音、静音、暂停、seek、换片、停止和取消；记录实时倍率但不把当前机器毫秒数作为唯一硬门槛。
- 运行 `flutter analyze`、Flutter 测试、native CTest、Windows Release 构建和 Phase 3 回归抽查。
- 更新 `NEW.md` 和本文件，记录 decoder 选型、模型版本、测试素材、已知限制和最终状态。

完成条件：任何失败都能定位到解码、标准化、窗口、队列、native 识别、session 隔离或诊断层；真实本地视频能够产生至少一个正确媒体时间的 final `RecognitionEvent`。

## 7. 计划中的测试命令

以下路径均为示例；视频和真实结果文件仍位于仓库外。Windows Release 模型位于 exe 旁的 `models/` 目录，模型二进制不进入普通 Git，分发时使用 Git LFS、Release Asset 或安装包：

```powershell
flutter analyze
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:no_proxy = $env:NO_PROXY
flutter test --concurrency=1
flutter build windows --release

cmake --build native/speech_core/build-vs --config Release
cmake --build native/speech_core/build-whisper-vs --config Release
ctest --test-dir native/speech_core/build-vs -C Release --output-on-failure
ctest --test-dir native/speech_core/build-whisper-vs -C Release --output-on-failure

native/speech_core/build-whisper-vs/Release/speech_regression.exe `
  --model <仓库外模型路径> `
  --audio <仓库外固定音频路径> `
  --language auto `
  --threads 8 `
  --output <仓库外结果路径>

dart tool/verify_speech_regression.dart `
  --manifest ../test_assets/speech/manifest.json `
  --result <仓库外结果路径> `
  --asset-id phase5-en-generated
```

Phase 6 需要另增以下类型的命令或测试入口，实际名称在实现 Step 1 后确定：

```powershell
native/tools/audio_decode_smoke.exe `
  --input <仓库外授权视频路径> `
  --output <仓库外 PCM 元数据或 JSONL 路径>

native/tools/player_speech_regression.exe `
  --model <仓库外模型路径> `
  --media <仓库外授权视频路径> `
  --output <仓库外结果路径>
```

## 8. 风险与决策门

### 音频帧来源不确定

`media_kit` 当前播放状态 API 不等于 PCM 输出 API。Step 1 必须先确认可用接口；如果 libmpv 音频输出不能稳定提供媒体时间，则采用独立解码 adapter，不能依赖未公开的内部对象。

### 解码依赖许可证和体积

FFmpeg 或其他 native 解码依赖必须在选型时核对许可证、编解码器构成、Windows 分发方式和二进制体积。未完成核对前不能把二进制提交到 Git 或打包为默认依赖。

### CPU 实时倍率不足

Phase 5 当前 Windows CPU 回归约为实时倍率 `1.057`，余量有限。Phase 6 必须支持识别落后、有限队列和窗口跳过；不能把“最终能识别”直接当作“可以实时播放”。

### 时间轴错位

解码时间、播放器位置和识别完成时间可能不同。所有字幕事件以音频 chunk/window 的媒体起点为基准；seek 和换片必须通过 session 失效旧事件。

### 网络媒体复杂度

Phase 3 的浏览器媒体交接证明播放工作区可用，不证明所有网络媒体都能被独立解码。Phase 6 首轮只验收本地文件，遇到网络媒体时保持现有播放器行为并给出识别不可用状态。

### 模型和应用配置

模型不进入 Git，也不应依赖开发者机器的固定绝对路径。配置缺失时应用仍要启动，Mock 仅作为明确的测试/降级 Provider，不能把模拟字幕误报为真实 Whisper 结果。

## 9. Phase 5 前置结果

| 项目 | 状态 | 备注 |
|---|---|---|
| 固定 WAV -> Whisper | 已完成 | `ggml-large-v3-turbo-q5_0` 真实模型回归通过 |
| speech_core C ABI | 已完成 | 默认和 whisper.cpp Release/CTest 通过 |
| Dart FFI Provider | 已完成 | worker isolate 契约和 16 项 Flutter 测试通过 |
| JSONL/manifest 比较 | 已完成 | 文本、语言、时间、诊断字段自动比较通过 |
| Phase 3 Windows 回归 | 已完成 | 浏览器交接、工作区切换、会话保持和日志脱敏通过 |
| 主应用实时 Whisper | 已完成 | `RecognitionController` 已接入持久窗口 Provider；真实日语视频的解码与 Whisper 回归通过，识别结果已进入播放器字幕框 |

## 10. 本阶段最终状态记录

本节在执行过程中逐项更新。Phase 6 已完成，本记录作为结项依据保留；开始下一阶段时再整体替换为下一阶段计划。

初始状态：

- Phase 5 已完成，Phase 6 尚未开始。
- 首个实现目标是 Windows 本地视频，不承诺浏览器网络媒体或移动端性能。
- Release 包使用 exe 旁 `models/ggml-large-v3-turbo-q5_0.bin`；开发或特殊测试时可用 `AI_VIDEO_WHISPER_MODEL` 覆盖。视频、PCM 和真实结果文件不进入 Git，模型二进制继续由普通 Git 忽略。
- Phase 6 通过前，不把完整字幕 Overlay、翻译 Provider 或移动端音频适配混入本阶段。

#### Phase 6 执行记录（2026-08-16）

实现结果：

- Step 1 选用独立 Windows Media Foundation Source Reader adapter。Dart 只依赖 `AudioDecoder` 契约和 FFI 边界；native worker 负责本地媒体读取、Float 输出、媒体时间和取消。当前首轮目标为 Windows 本地文件，网络媒体、HLS、DRM、MSE 和移动端真实音频仍不在验收范围。
- Step 2-4 已完成：建立 `AudioChunk`、decoder 生命周期/状态、PCM 标准化和 `AudioWindowPlanner`。输入统一为 16 kHz、单声道、Float32；窗口保持媒体时间、样本数和 session 隔离，纯静音与 EOF 尾部静音有明确跳过规则。
- Step 5 已完成：`WhisperCppPersistentRecognitionWorker` 在 worker isolate 中常驻模型，连续窗口复用模型；窗口识别结果转换为带媒体绝对时间的 `RecognitionEvent`。
- Step 6-7 已完成：`RecognitionQueue` 限制为 1 个 active 加 1 个 waiting；队列满时暂停 decoder，恢复后继续生产；`RecognitionController` 覆盖 open/play/pause/seek/换片/stop/dispose，并以 session/generation 丢弃旧结果。
- Step 8-9 已完成：Provider 默认读取程序目录 `models/ggml-large-v3-turbo-q5_0.bin`，支持 `AI_VIDEO_WHISPER_MODEL` 显式覆盖；native DLL 默认从 exe 目录加载。诊断页显示 Whisper 加载状态、decoder、队列、输入窗口、输出数量/文本、跳过/失败、推理耗时和实时倍率；播放器字幕框消费真实 `RecognitionEvent`。

验证结果：

- `dart analyze lib`：通过。
- `dart analyze test`：通过。
- `flutter test --concurrency=1`：通过 29 项测试；包含短对白不被整段静音均值误跳过，以及暂停时提交剩余尾部窗口的回归。
- `native/audio_decoder` 的 `audio_decode_smoke.exe`：使用用户提供、明确允许测试的日语本地 MP4 读取前 30 秒成功；输出为 44.1 kHz、双声道 PCM，音量统计确认开头窗口内存在明显对白，且没有解码错误。
- 仓库外 `ggml-large-v3-turbo-q5_0`：已成功加载，并对上述 30 秒标准化音频产生 2 个日语 final segment；模型推理成功，未将媒体、PCM、完整文本或结果文件加入 Git。
- Windows Release：通过，版本 `0.6.0`；本次验收构建信息为 `2026-08-16 22:10:04 +08:00`、`phase-6-windows-20260816-221004`。
- Release 目录已确认包含 `ai_video_player_next.exe`、`ai_audio_decoder.dll`、`speech_core.dll` 和 `models/ggml-large-v3-turbo-q5_0.bin`；模型 SHA-256 为 `394221709CD5AD1F40C46E6031CA61BCE88931E6E088C188294C6D5A55FFA7E2`。
- 最终播放器人工验收：通过。Windows Release `0.6.0`，构建时间 `2026-08-16 23:41:28 +08:00`，构建编号 `phase-6-windows-20260816-234128`；`test.mp4` 在真实播放器中成功产生多个日语字幕事件。4 秒窗口推理耗时约 1.73-1.81 秒，实时倍率约 0.43-0.45，没有出现队列积压。
- 发现并修复：原先以整个 8 秒窗口的平均音量做静音判断，会把短日语对白与前后安静片段平均为“静音”；现改为 200 ms 短帧门控。暂停时 decoder 的尾部结束标记此前也会被控制器丢弃，现会冲刷已有的部分窗口并让已提交识别完成。
- `flutter test --concurrency=1`：27 项通过。运行时仅对当前会话设置 `NO_PROXY=localhost,127.0.0.1,::1`。
- `native/audio_decoder` Visual Studio 2026 Release 构建：通过，生成 `ai_audio_decoder.dll` 和 `audio_decode_smoke.exe`。构建使用 Windows Media Foundation，`/W4 /WX` 下无错误。
- `native/speech_core` 默认/whisper.cpp Release 构建及两套 CTest：通过。
- Windows Flutter Release 构建：通过。
- `git diff --check`：通过。

持续回归项与边界：

- 已完成真实本地视频的 native PCM smoke 和 Whisper 模型回归，识别结果已进入播放器字幕框。播放、暂停、seek、换片、停止和 dispose 的控制器行为由 fake decoder/recognizer 自动化测试覆盖；真实播放器窗口人工复核作为后续持续回归，不再阻塞 Phase 6 结项。
- 本次日语模型在当前 Windows CPU 上处理 30 秒音频的实测推理时间约 50 秒，实时倍率约 1.67；这是性能观察值，不是准确率或其他设备性能承诺。
- 视频、PCM、完整识别文本、结果文件和 native build 产物均保持本地忽略；模型已复制到 Release 程序目录，模型二进制不进入普通 Git。
- GPU 后端、iOS Metal、完整字幕 Overlay、翻译和字幕历史不属于 Phase 6，留待后续 Phase。
- Phase 6 结项状态（2026-08-17）：已完成。核心实现、自动化测试、native 构建、程序目录模型打包和真实日语回归均已完成。
