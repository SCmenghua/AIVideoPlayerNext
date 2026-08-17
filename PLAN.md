# AIVideoPlayerNext 当前阶段执行计划

> 本文件是当前 Phase 的执行计划。每个 Phase 开始时，清空本文件并重新填充为该阶段的计划；阶段完成后保留最终状态，开始下一阶段时再整体替换。
>
> 当前项目：`AIVideoPlayerNext`
> 当前阶段：`Phase 7`
> 计划状态：进行中（等待用户提供网络视频字幕识别失败日志，作为首项诊断输入）
> 软件版本目标：`0.7.0`
> 更新日期：2026-08-17

## 1. 阶段定位

### Phase 7：网络媒体识别、字幕时间轴、翻译与 Overlay

Phase 6 和 Phase 6.5 已完成本地视频音频解码、窗口化 Whisper 识别、有限队列、Windows Vulkan、iOS Metal、播放器生命周期和基础字幕输出。Phase 7 处理当前已经能够播放、但字幕识别不稳定或无法输出的网络视频，同时建立字幕准时显示、有限预读、识别预热、异步翻译和双语 Overlay 的可用闭环。

本阶段的核心不是让任务尽可能快地完成，而是让识别和翻译围绕播放器的权威媒体时间轴工作：原文和译文可以提前准备，但只能在对应媒体起止时间内显示；识别或翻译失败不能阻塞播放，也不能产生没有来源或时间错位的字幕。

目标链路：

```text
Local file / supported network media
  -> player media session and audio output
  -> AudioChunk with media timestamp
  -> AudioWindowPlanner / bounded pre-read
  -> Whisper RecognitionEvent(final / partial)
  -> SubtitleTimeline
  -> TranslationQueue -> TranslationService
  -> SubtitleTimeline translation by segmentId
  -> in-player bilingual Overlay
  -> diagnostics
```

网络视频首项诊断链路：

```text
user-provided failure log
  -> reproduce the same media class and lifecycle
  -> media handoff / authorization / player audio
  -> PCM continuity and media timestamps
  -> window planning and recognition
  -> quality gate and SubtitleTimeline
  -> classify root cause before changing implementation
```

## 2. 已知前提

- Phase 6.5 已完成，Windows 使用 Vulkan 与 CPU fallback，iOS 使用 Metal；本阶段不重做 GPU 后端。
- 当前版本基线为 `0.6.5`；进入 Phase 7 后版本目标统一切换为 `0.7.0`，并注入真实构建时间和唯一构建编号。
- 本地视频已经能够输出带媒体时间的 PCM，并通过 Whisper 产出 `RecognitionEvent`；Phase 7 必须保持现有 `AudioChunk`、`AudioWindow`、`RecognitionEvent` 和 session 生命周期契约。
- 当前代码已经有 `TranslationService`、`TranslationRequest`、`TranslationResult`、`SubtitleEntry.translation` 和按 `segmentId` 回填的基础结构；Mock 实现不等于真实翻译功能。
- 当前播放器能够交接并播放部分普通网络媒体，但播放画面正常不代表音频、PCM、时间戳和识别链路正常，必须逐层诊断。
- Phase 7 开始时，用户会提供一份网络视频字幕识别失败日志。该日志是第一项实际问题输入；收到并分析前，不预设根因，不盲目修改代码。
- 普通 HTTP(S) MP4、重定向媒体或当前播放器已能合法取得音频的网络资源是优先范围；HLS/DASH 复杂变体、直播、MSE/blob、DRM 和受保护媒体分别评估。
- 模型、视频、PCM、授权信息、Cookie、请求头、原始诊断日志和 native build 产物不提交普通 Git；日志展示和导出必须脱敏。
- Flutter 测试继续只对当前会话设置 `NO_PROXY=localhost,127.0.0.1,::1`，不修改用户永久代理。

## 3. 本阶段完成定义

Phase 7 只有同时满足网络识别、字幕时间轴、翻译和 Overlay 的验收条件后才能结项：

1. 用户提供的网络视频失败日志已脱敏归档并完成根因分类；至少修复其中属于项目可控范围的问题。
2. 当前播放器已能合法播放的目标网络视频能够持续取得音频，输出带连续媒体时间的 PCM，并追溯到 `AudioChunk`、`AudioWindow` 和 `RecognitionEvent`。
3. 网络视频播放、暂停、seek、换片、停止、网络错误恢复和重新取流不会让旧 session 的音频、识别、翻译或字幕污染当前媒体。
4. 每个 `final RecognitionEvent` 都能进入 `SubtitleTimeline`；未显示字幕能定位在媒体交接、授权、播放器音频、PCM、时间映射、分窗、Whisper、质量门控或 Overlay 层。
5. 本地媒体支持有界音频预读、Whisper 首次推理预热和有限识别领先量，所有队列有上限、取消路径和 session/generation 守卫。
6. 至少一个真实翻译 Provider 可消费 final 原文并异步返回译文，具有超时、取消、网络失败和不可用状态，同时保留 Mock。
7. 原文在 final 识别完成后立即显示，不等待翻译；翻译失败、超时、落后或取消不会阻塞播放器、原文字幕或时间轴。
8. 翻译结果按 `sessionId`、`segmentId`、源文本、源语言和目标语言校验后回填，不会串片、重复或覆盖错误语言。
9. 播放器内字幕 Overlay 支持原文、译文和双语模式，按照媒体位置命中时间轴，样式和显示句数可配置。
10. 诊断页和导出日志可区分网络媒体、识别、翻译和 Overlay 链路，并记录延迟、落后量、失败、取消和恢复事件；敏感信息已脱敏。
11. Flutter 质量门、单元/集成测试、Windows Release smoke、网络视频回归、本地预读回归和真实翻译 Provider 回归均有记录；共享 Dart 逻辑和 iOS 生命周期完成构建或抽样验证。

## 4. 范围边界

### 本阶段包含

- 用户网络视频字幕识别失败日志的脱敏分析、复现、根因分类和项目可控修复。
- 当前播放器支持范围内网络媒体的音频获取、PCM 连续性、媒体时间映射、seek/缓冲/恢复和识别闭环。
- 本地媒体有界音频预读、识别预热、有限识别领先量、结果缓存和队列诊断。
- `SubtitleTimeline` 的 final-first、partial 预览、session 隔离、时间命中和翻译按 ID 回填。
- 至少一个真实翻译 Provider、统一错误模型、翻译开关、目标语言和原文/译文/双语模式。
- 播放器内字幕 Overlay、基础样式配置、字幕命中诊断和翻译延迟诊断。
- `0.7.0` 版本注入、构建标识、测试矩阵、诊断记录和文档更新。

### 本阶段不包含

- 重做已通过验收的 Whisper Vulkan/Metal 后端、模型格式或 GPU 选择策略。
- 无边界的整段网络媒体下载、绕过 DRM、提取受保护媒体、破解授权或将私有媒体上传到翻译服务。
- 对所有 HLS/DASH、直播、MSE/blob、DRM 和封闭 iframe 做无条件支持。
- Phase 8 的多 Provider 生态、离线翻译模型、缓存、术语表、SQLite 历史、搜索和完整导出。
- Phase 9 的 iOS Speech 和 Windows Live Captions Adapter。
- 将翻译完成时间当作字幕显示时间，或让翻译 Provider 修改播放器和识别生命周期。
- 将原始失败日志、视频、模型、PCM、授权信息、SDK、驱动或 native build 产物加入 Git。

## 5. 设计原则

### 5.1 先用日志定位，再决定改动

网络视频失败首先记录证据，不根据“能播放画面”推断“能识别音频”。收到用户日志后，按以下层级检查：

```text
media source / handoff
  -> authorization and session
  -> player audio track and decoder
  -> PCM chunk count / format / continuity
  -> media timestamp mapping
  -> window planner and queue
  -> Whisper provider and model
  -> quality gate
  -> SubtitleTimeline
  -> Overlay position lookup
```

每层给出 `pass`、`fail`、`unknown` 或 `not_applicable`，并说明下一条证据。只有根因属于项目可控边界时才修改代码；外部授权、DRM 或媒体不可取得音频时，显示明确不可用状态。

### 5.2 媒体时间轴是唯一显示依据

识别和翻译可以领先播放，但字幕显示只能满足：

```text
entry.start <= playbackPosition <= entry.end
```

任务完成时间、网络响应时间和队列入队时间只能用于诊断，不能替代媒体起止时间。seek 后使用新 session 或 generation 过滤旧事件。

### 5.3 原文优先，翻译异步

`final` 原文立即进入时间轴，翻译在独立队列执行。翻译失败只更新译文状态，不删除或延迟原文。Provider 不得同步阻塞 UI、播放器、PCM 解码或识别 worker。

### 5.4 异步结果必须可取消、可验证

每个预读、识别和翻译任务都带 `sessionId`/`generation`。翻译回填至少验证：

```text
sessionId + segmentId + sourceText + sourceLanguage + targetLanguage
```

取消后返回的旧任务只能被丢弃并记录原因，不能修改当前字幕。

### 5.5 预读必须有界

本地预读以 PCM 缓冲大小、最多领先秒数、最大识别窗口数和最大翻译任务数为边界。网络媒体不默认整段预读，只在播放器取得可用数据且会话/授权边界明确时，为具体媒体类型设计有限缓冲。

### 5.6 翻译隐私必须显式

Provider 必须标记本地或云端属性。云端翻译默认关闭或需要用户主动启用，并显示文本会离开设备、目标语言、Provider、超时和失败状态；本地媒体和音频不因翻译功能默认上传。

### 5.7 诊断要能回答“为什么没有字幕”

日志必须区分媒体没有交接、播放器没有音频、PCM 没输出、时间戳断裂、窗口被跳过、Whisper 失败、质量门控过滤、翻译失败和 Overlay 未命中。详细网络内容只在用户主动开启且脱敏后导出。

## 6. 执行步骤

### Step 1：接收网络视频失败日志并建立诊断基线

状态：`等待用户提供失败日志`

这是 Phase 7 的第一项工作。用户将在阶段开头发送网络视频字幕识别失败日志；收到后先保存脱敏摘要和复现条件，再进入代码修改。

任务：

- 读取版本、构建编号、媒体来源、播放器状态、识别后端、模型状态、音频事件、窗口事件、时间轴事件、异常和生命周期事件。
- 提取平台、网络媒体类型、是否浏览器交接、是否重定向、会话需求、语言、播放时长、暂停/seek/换片动作和失败时间。
- 对路径、Cookie、授权头、完整 URL 查询参数、用户内容和个人信息脱敏；原始日志不写入 Git。
- 建立覆盖媒体交接、授权会话、播放器音频、PCM、媒体时间、分窗、识别、质量门控、时间轴和 Overlay 的诊断表。
- 如果字段不足，列出最小追加日志项和复现动作；不把未知状态直接判定为代码 bug。
- 使用相同媒体类型或用户允许的等价测试资源复现；不能访问原媒体时，先完成静态日志定位和可控链路测试。

输出物：脱敏日志摘要、复现条件、根因假设、证据缺口、回归命令和待修改文件清单。

完成条件：明确失败层级，或明确仍需补充的证据；根因未形成可验证假设前不进入大范围重构。

### Step 2：修复当前支持网络视频的音频识别闭环

状态：`待 Step 1 根因确认`

任务：

- 根据 Step 1 检查媒体交接对象、重定向地址、会话参数、音频轨选择和网络缓冲；只保留 PCM 解码所需的最小授权信息。
- 分别确认画面和音频轨可用；记录音频轨数量、采样率、声道、解码错误和连续 PCM chunk 数。
- 对网络错误、缓冲、断流、重连和重新打开建立明确状态；不能让 worker 永久等待或无限重试。
- 保持网络与本地媒体输出相同的 `AudioChunk` 格式、采样率、声道和媒体起点语义。
- 对不可取得音频、失效授权、DRM 或不支持媒体返回可解释状态，不伪造空字幕。

输出物：网络音频修复、失败状态映射、网络识别集成测试和诊断字段。

完成条件：目标网络媒体在允许会话条件下持续产生可验证 PCM；不支持媒体不会导致播放器崩溃或识别假成功。

### Step 3：统一时间映射、seek 恢复与 session 隔离

状态：`未开始`

任务：

- 检查网络 PCM 时间戳是否以媒体时间为基准，处理重定向、缓冲跳变、暂停恢复和重新取流的连续性。
- 验证播放、暂停、seek、换片、stop、dispose 和网络恢复后，旧 session/generation 的音频、识别、翻译事件均被丢弃。
- seek 后建立新的音频游标、窗口边界和队列状态，避免旧窗口覆盖新位置。
- 处理重复 final、partial 更新、窗口重试和窗口跳过；同一 `segmentId` 不重复创建翻译任务。
- 记录媒体位置、已解码位置、已识别位置、已翻译位置、领先/落后秒数和当前 session。

输出物：时间映射修复、生命周期回归、旧事件丢弃测试和 session 诊断记录。

完成条件：网络和本地媒体在暂停、seek、换片、停止和恢复后均不会串字幕、卡住识别或显示错误时间。

### Step 4：实现本地媒体有界预读与识别预热

状态：`未开始`

任务：

- 本地媒体打开后启动受限 PCM 预读，设定最大缓冲字节数、最大领先秒数、最大未完成识别窗口数和翻译数。
- 预热 Whisper worker 和实际模型，分别记录首次加载/首窗推理耗时与稳态窗口耗时。
- 缓存使用媒体时间和 session 标识；seek、换片、stop 和 dispose 必须取消或隔离旧缓存。
- 识别或翻译落后时按策略限流、跳过或等待，不得无限追赶导致内存增长。
- 网络媒体先完成 Step 2 的数据和授权判断，再为具体类型设计有限策略。

输出物：预读调度器、预热状态、队列上限、缓存失效规则和性能诊断。

完成条件：本地视频可在播放前或初期完成有限识别/翻译准备，且内存、队列和旧任务均受控。

### Step 5：建立真实翻译 Provider 与异步翻译队列

状态：`未开始`

任务：

- 保留 `TranslationService` 和 Mock，增加至少一个实际可用 Provider；通过依赖注入或设置选择，不在播放器页面硬编码。
- 定义 Provider 能力、源/目标语言、本地/云端属性、超时、取消、网络错误、认证错误、限流和不可用状态。
- final 原文进入时间轴后提交翻译任务；任务带 session、segment、原文、源语言和目标语言。
- 支持有限并发、队列上限、重复文本去重和取消；返回后再次验证身份，再按 `segmentId` 回填。
- 失败、超时、落后或取消时保留原文并记录译文状态，不无限重试、不阻塞播放器。
- 云端 Provider 必须有用户主动启用、隐私说明和文本上传提示，不发送音频、Cookie 或完整媒体地址。

输出物：真实 Provider、翻译队列、错误模型、配置模型、Mock/集成测试和隐私提示。

完成条件：真实 final 原文可以稳定异步得到译文；故障、超时、取消和换片不影响原文或污染后续 session。

### Step 6：完善 SubtitleTimeline 与播放器字幕 Overlay

状态：`未开始`

任务：

- 为 `SubtitleTimeline` 增加 final、partial、翻译状态、session 和时间命中逻辑测试。
- 设计原文、译文、双语和关闭字幕模式；目标语言和显示模式可配置。
- 实现播放器内 Overlay，根据播放位置查询时间轴，不按任务完成顺序显示字幕。
- 支持字体、字号、颜色、背景透明度、位置和显示句数配置；暂停、seek、全屏和窗口变化不影响播放控制。
- 桌面透明置顶窗口和点击穿透是可选增强，必须在内置 Overlay 稳定后实现。
- Overlay 只消费时间轴快照，识别、翻译和媒体控制保持独立生命周期。

输出物：SubtitleTimeline 测试、字幕显示模型、播放器 Overlay、样式设置和显示层测试。

完成条件：原文和译文按媒体时间准确显示；翻译未完成时原文仍可见，Overlay 不影响播放或识别。

### Step 7：诊断页、日志和失败可定位性

状态：`未开始`

任务：

- 增加网络媒体字段：来源、交接、播放器、音频轨、PCM 数/格式/连续性、媒体位置、缓冲和恢复状态。
- 增加识别字段：窗口编号、媒体起止、样本数、队列、跳过原因、模型、后端、推理耗时、输出段数和门控原因。
- 增加翻译字段：Provider、源/目标语言、任务状态、排队/响应时间、延迟、取消、超时、错误和领先/落后。
- 增加时间轴/Overlay 字段：播放位置、命中 segment、未命中原因、原文/译文状态和 session/generation。
- 导出日志默认脱敏路径、URL 查询参数、Cookie、授权头、PCM 和完整网络响应。
- 使用稳定事件名和关联 ID，避免重复监听器导致日志刷屏。

输出物：诊断模型、日志事件、脱敏导出、失败分类页面和诊断测试。

完成条件：仅凭诊断页和导出日志即可判断字幕缺失位于媒体、音频、识别、翻译、时间轴还是 Overlay 层。

### Step 8：跨平台回归、打包和性能验收

状态：`未开始`

任务：

- Windows 完成网络视频、本地视频、Vulkan/CPU、预读、翻译和 Overlay 回归，保留 GPU 日志字段。
- iOS 使用共享 Dart 逻辑完成构建检查和可行真机回归，确认 Metal/CPU、翻译、Overlay、暂停和 seek 不受影响。
- 网络视频覆盖正常音频、无音频、缓冲/断流、重定向、失效授权、暂停、seek、换片和恢复；不把 DRM/MSE/blob 当作必然成功。
- 本地视频覆盖首次预热、稳态识别、识别/翻译提前、翻译失败、目标语言切换、原文/译文/双语和队列上限。
- 记录首窗、稳态耗时、识别领先/落后、翻译延迟、字幕时间偏差和内存/队列峰值。
- 版本升级到 `0.7.0`，注入真实 `APP_BUILD_TIME` 和唯一 `APP_BUILD_ID`，检查 Release 模型和 native 依赖路径。

输出物：跨平台测试记录、网络回归日志、预读/翻译性能表、Windows `0.7.0` Release、iOS 构建或真机记录。

完成条件：失败日志对应问题已修复或标记为外部不可控限制；本地双语字幕稳定；翻译故障不影响原文；共享生命周期回归通过。

### Step 9：文档、验收和 Phase 7 结项

状态：`未开始`

任务：

- 将 Step 1 的日志摘要、根因、修复、复现步骤和回归结果写入 `NEW.md`，不提交原始敏感日志。
- 更新两份文档的 Phase 7 状态、已知限制、Provider、网络支持范围和版本信息。
- 执行 `git diff --check`、Dart/Flutter 质量门、必要 native 构建、Release smoke、Git 忽略和脱敏检查。
- 检查未完成项是否正确留给 Phase 8/9/后续网络媒体专项，不以普通网络视频可用宣称支持所有媒体。
- 形成 Phase 7 结项记录，逐项列出网络识别、预读、翻译、Overlay、诊断、测试、构建和剩余风险。

输出物：路线文档、Phase 7 最终验收表、构建产物链接或本地路径、已知限制清单。

完成条件：第 3 节全部满足，所有未支持媒体和 Provider 限制均有明确用户可见状态或文档记录。

## 7. 计划中的测试命令

以下命令中的模型、音频、视频、网络地址和结果路径均为仓库外路径，实际参数以 Step 1 日志和复现资源为准：

```powershell
flutter analyze
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:no_proxy = $env:NO_PROXY
flutter test --concurrency=1
dart format --set-exit-if-changed lib test
dart analyze lib test
```

Phase 7 网络媒体诊断检查：

```powershell
# 只使用已脱敏的会话参数；不要把 Cookie 或授权头写入脚本和 Git。
$env:AI_VIDEO_DIAGNOSTICS = 'verbose'
$env:AI_VIDEO_WHISPER_BACKEND = 'vulkan'
& ".\app\build\windows\x64\runner\Release\ai_video_player_next.exe"
```

本地媒体预读与固定音频回归应记录：

```text
media type, duration, sample rate, channels
first model load time
first inference time
steady-state window time
decoded/recognized/translated media position
recognition lead or lag
translation queue depth and latency
subtitle media-time error
```

Windows Release 构建示例：

```powershell
flutter build windows --release `
  --dart-define=APP_VERSION=0.7.0 `
  --dart-define="APP_BUILD_TIME=<真实构建时间和时区>" `
  --dart-define="APP_BUILD_ID=phase-7-windows-<唯一标识>"
```

iOS 命令只能在 macOS/Xcode 环境执行：

```bash
pod install
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' build
```

翻译 Provider 测试必须使用 Mock 和用户明确允许的真实 Provider，记录 Provider 属性、源/目标语言、是否上传文本、超时、取消、重试、错误类别和 `sessionId`/`segmentId` 回填结果。

## 8. 风险与决策门

### 网络视频没有可取得的音频

如果媒体通过 DRM、MSE/blob、封闭播放器或受保护会话播放，应用可能只能看到画面或无法合法取得音频。不得绕过保护，应记录证据并显示明确不支持原因。只有项目可控的交接、轨道、PCM 或时间映射问题进入修复。

### 播放正常但音频链路失败

画面、音频输出、PCM 解码和 Whisper 是不同层。必须用 chunk 数、格式、时间戳、窗口和模型事件证明每层状态；没有音频证据不能宣称识别正常。

### 网络重定向、授权和缓冲

临时地址、请求头和 Cookie 只按最小范围短暂保存在内存。失效授权、断流和重连必须有状态迁移和上限重试，不能把敏感信息写入诊断，也不能让旧会话产生字幕。

### 预读超过播放器时间

识别和翻译领先过大可能增加内存、请求和错误字幕风险。所有缓冲、队列和领先秒数必须有硬上限；显示仍严格受媒体位置约束。

### 翻译 Provider 不稳定

超时、限流、断网、认证失败和文本质量问题只影响译文，原文必须独立显示。返回结果必须校验任务身份，晚到结果不能覆盖新语言或新媒体。

### 翻译隐私和费用

云端 Provider 可能上传原文并产生费用。默认不上传，或必须用户主动开启并明确提示；API Key 不进入源码、日志、Git 或诊断导出。

### iOS 与 Windows 行为差异

iOS 使用 Metal 和不同播放器/音频生命周期。共享 Dart 时间轴、翻译和 session 契约先通过 Windows，再用 iOS 构建和真机抽样确认；平台差异留在 adapter。

### native 生命周期和资源泄漏

网络重连、预读、识别、翻译、Overlay 和播放器均可能拥有 worker 或订阅。重复打开、暂停、seek、换片、停止和 dispose 后必须检查旧回调、队列、文件句柄和 native 资源释放。

## 9. Phase 6.5 前置结果

| 项目 | 状态 | 备注 |
|---|---|---|
| Windows 本地视频音频解码 | 已完成 | Media Foundation adapter 输出带媒体时间的 PCM |
| PCM 标准化与窗口规划 | 已完成 | 16 kHz、单声道、Float32；静音和短对白门控已回归 |
| Whisper 持久窗口识别 | 已完成 | 模型复用，窗口结果转换为媒体绝对时间 |
| 有界队列与生命周期 | 已完成 | 播放、暂停、seek、换片、停止和 dispose 已覆盖 |
| 真实日语视频回归 | 已完成 | 识别结果已进入播放器下方字幕框 |
| Windows CPU 基线 | 已完成 | 作为 Phase 7 识别回归对照，不代表其他设备性能 |
| Windows Vulkan GPU | 已完成 | 实际运行于 NVIDIA GeForce RTX 5060 Laptop GPU |
| iOS Metal GPU | 已完成 | 真实 iPhone 日志确认 `Metal`、`GPU: true` 和 `Apple A19 GPU` |
| 翻译接口与时间轴回填骨架 | 已完成（基础代码） | `TranslationService`、Mock、`SubtitleEntry.translation` 和 `segmentId` 回填已存在，真实 Provider/完整 Overlay 待 Phase 7 |
| 网络视频识别稳定性 | 待 Step 1 | 以用户即将提供的失败日志为第一项诊断输入 |

## 10. 本阶段最终状态记录

本节记录 Phase 7 的执行结果；初始计划中的“待开始”和“等待日志”是阶段启动时状态，最终结项记录以本节末和 Step 9 结项记录为准。

初始状态：

- 当前阶段为 `Phase 7`，目标版本为 `0.7.0`。
- Phase 6.5 的 Windows Vulkan/CPU、iOS Metal、模型内置、播放器字幕和生命周期能力作为前置结果保留。
- 网络视频字幕识别失败日志尚未收到；收到后先完成脱敏、复现条件提取和分层诊断，再决定代码改动。
- 当前代码有翻译抽象和 Mock 回填基础，但真实翻译 Provider、完整翻译队列和 Phase 7 Overlay 尚未完成。

#### Phase 7 执行记录

| 日期 | 步骤 | 状态 | 说明 |
|---|---|---|---|
| 2026-08-17 | Phase 7 计划建立 | 已完成 | 根据 `NEW.md` 将网络视频识别、预读/预热、翻译 MVP、字幕 Overlay 和诊断纳入同一阶段 |
| 待定 | 网络视频失败日志接收 | 待开始 | 等待用户提供日志；原始日志不提交 Git，先做脱敏摘要 |
| 待定 | 网络视频根因定位 | 待开始 | 按媒体交接、授权、音频、PCM、时间映射、分窗、Whisper、门控和 Overlay 分层判断 |
| 待定 | 网络媒体识别修复 | 待开始 | 仅修复已确认属于项目可控范围的问题 |
| 待定 | 本地媒体预读与识别预热 | 待开始 | 建立有限 PCM、识别和翻译领先量及取消机制 |
| 待定 | 翻译 MVP | 待开始 | 接入至少一个真实 Provider，保留 Mock，翻译失败不影响原文 |
| 待定 | 字幕 Overlay | 待开始 | 原文、译文、双语按媒体时间轴显示 |
| 待定 | 跨平台与 Release 验收 | 待开始 | Windows `0.7.0`、iOS 构建/真机抽样、网络和本地媒体回归 |

#### 最终结项记录

- 网络视频失败日志与根因：待 Step 1。
- 网络视频音频、PCM、时间映射和识别闭环：待完成。
- 本地媒体预读、识别预热和有限领先量：待完成。
- 真实翻译 Provider、翻译队列和故障隔离：待完成。
- 原文/译文/双语字幕 Overlay：待完成。
- 诊断页和脱敏日志：待完成。
- Phase 7 结项状态：进行中。
- 下一阶段：Phase 8 多 Provider、历史管理与缓存；只有 Phase 7 的单一真实 Provider 和时间轴闭环稳定后才进入。
