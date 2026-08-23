# AIVideoPlayerNext 当前阶段执行计划

> 当前项目：`AIVideoPlayerNext`
> 当前阶段：`Phase 9（已跳过，2026-08-23）`
> 计划状态：已跳过，主线回到 Phase 8 基线（`0.8.0`）；后续从 Phase 10 继续
> 软件版本目标：~~`0.9.0`~~（未发布）
> 更新日期：2026-08-23

## 0a. Phase 9 跳过说明（2026-08-23）

Phase 9 按本计划执行过一轮完整实现（六步全部产出代码与测试，自动化 204 项通过），但 Windows Live Captions 引擎在真机应用内无法稳定产出字幕且无法复现定位，调试成本超出收益，经用户决定跳过。代码与本地 Release 已回退到 Phase 8；实现封存在分支 `phase-9-system-engines-archive`，重启时从该分支评估。完整跳过原因与留档见 `NEW.md` 的 Phase 9 章节。下文的执行计划保留为历史留档，各步骤状态不再更新。

## 0. Phase 8 结项摘要（2026-08-22，验收通过）

Phase 8 八项要求（iOS 识别速度、iOS 原生翻译、翻译速度、三种字幕显示模式、三种播放中策略、启动准备开关、通用 API URL 规范化、模型列表下载）全部交付并验收通过，版本 `0.8.0`。真机回归确认：iOS 识别不再尾随播放；系统翻译（iOS 26 `TranslationSession(installedSource:target:)` 无头会话）在语言包预装后正常出译文，缺失时返回明确终态错误；播放门控在翻译不可用/终态失败时正确放行。最终自动化基线：`flutter analyze` 无问题，`flutter test --concurrency=1` 182 项全部通过；未签名 IPA 由 macOS CI 产出并在真实 iPhone 完成回归。完整结项记录见 `NEW.md` 的 Phase 8 结项记录（2026-08-22）。

## 1. 阶段目标

### Phase 9：系统语音识别 Adapter

接入 iOS Speech 与 Windows Live Captions，作为独立、可关闭的系统识别 Provider，与现有 whisper.cpp 本地识别并列。系统识别的价值：

- iOS `SFSpeechRecognizer` 提供零模型下载、低延迟的设备识别，可作为轻量替代（部分语言支持设备端识别）。
- Windows Live Captions 用于在桌面开发阶段快速制造识别文本流，验证翻译 Provider、Overlay、历史与导出工作流，不依赖 Whisper 模型加载。

本阶段目标链路：

```text
设置：识别引擎选择（whisper.cpp / 系统识别）
  -> 识别引擎状态契约（可用性、授权、语言、隐私/网络提示）
       不可用/未授权/语言不支持 -> 明确降级提示 -> 回退 whisper.cpp
  -> AppleSpeechRecognitionService（iOS）
       SFSpeechRecognizer 授权与语言检查
       现有窗口 PCM -> SFSpeechAudioBufferRecognitionRequest
       partial/final -> RecognitionEvent（媒体时间取自窗口）
  -> WindowsLiveCaptionsService（仅 Windows 11 + Live Captions 可用）
       可用性探测与限制说明
       字幕文本流 -> RecognitionEvent（时间精度受限，明确标注）
  -> 既有 RecognitionController / TranscriptDocument / 翻译队列不变
```

必须保留 Phase 7-8 已完成的媒体时间轴权威性、session/generation 隔离、有界队列和稳定 `segmentId` 回填能力。系统识别 Provider 只是 `WindowRecognitionService` 契约后的另一种实现来源；whisper.cpp 路径、固定素材回归和诊断口径不得被系统 Provider 污染。

## 2. 已确认事实与现状

- 当前识别管线：`RecognitionController` 消费 `AudioDecoder` 的带媒体时间 PCM，按窗口规划器切窗（目标 4 秒 / 上限 6 秒，650ms 尾静音，400ms 最小语音），交给 `WindowRecognitionService`（whisper.cpp 经 speech_core FFI）产出 `RecognitionEvent`，整理进 `TranscriptDocument` 供翻译与 Overlay 消费。
- `RecognitionController` 已具备有界队列、20s/45s 水位背压、session/generation 隔离、暂停/seek/换片取消；Windows 与 iOS 共用同一 Dart 调度，iOS 已移除墙钟节流。
- 当前设置已有识别预取策略（完整预识别 / 按需预取），但没有识别引擎选择；`WindowRecognitionService` 也没有可用性/授权状态契约（whisper.cpp 始终可用）。
- iOS 原生桥接模式已成熟：`IOSAudioDecoderBridge`、`SystemTranslationBridge` 均以 MethodChannel + AppDelegate 注册实现，Dart 侧有 `IosAudioDecoder`、`SystemTranslationService` 对应封装与测试替身，可按同一模式新增 Speech 桥接。
- iOS `SFSpeechRecognizer` 要点：需要 `NSSpeechRecognitionUsageDescription` 与运行时授权；请求级限制约 1 分钟（本项目的 4-6 秒窗口天然满足）；`supportsOnDeviceRecognition` 与语言可用性需逐locale 检查；设备端识别关闭时可能联网。音频输入用 `SFSpeechAudioBufferRecognitionRequest` 逐块追加，`endAudio` 后产出 final。
- Windows Live Captions 没有公开的字幕读取 API；可行路径是 UI Automation 读取系统字幕窗口文本（参考 LiveCaptions-Translator 的做法），且要求 Windows 11 且用户已在系统设置启用 Live Captions。时间精度只有"文本到达时刻"，无法给出精确媒体起止。
- 诊断日志已具备五级体系（调试/信息/警告/错误/关闭，默认信息级），新事件按同一分级约定接入。

## 3. 不可违反的约束

0. 若需要下载外网的内容，可使用系统的代理，端口为 mix:10808。
1. 字幕时间只服从播放器的权威媒体时间轴；系统识别结果的墙钟到达时间不能改变字幕的媒体起止时间。Apple Speech 的媒体时间取自喂入窗口的 `mediaStart/mediaEnd`；Live Captions 只能给出低精度锚点，必须在文档与 UI 中明示，不得伪装成精确时间轴来源。
2. whisper.cpp 是跨平台识别基准。系统 Provider 的输出、测试替身与开关状态不得影响 whisper.cpp 固定素材回归；两套 Provider 的结果不得混入同一识别会话。
3. 系统识别引擎必须在设置中可选择、可关闭，并显示授权、隐私与网络状态；未授权、语言不支持或系统不可用时，返回明确状态并回退 whisper.cpp，不得伪造识别结果或静默空跑。
4. 识别引擎切换、换片、重新开始会话和 seek 后，旧引擎的在途请求与迟到结果不得污染当前会话（沿用 session/generation 隔离）。
5. Apple Speech 授权弹窗只在用户主动选择该引擎或点击相关按钮时触发，不得在应用启动时抢授权。
6. Windows Live Captions adapter 是开发辅助与桌面可选能力，默认关闭；不作为移动端方案，不作为生产识别基准。
7. 设置文件写入保持后台串行和原子替换；新增字段缺失时使用明确默认值，旧设置文件必须可以继续打开（默认引擎为 whisper.cpp）。
8. 队列、PCM、事件与 UI 状态均有界；系统识别产生的 partial 流不得造成无界事件增长。
9. 测试构建的诊断数据仅保留在本机；Release 构建继续执行既有脱敏策略。识别内容不新增任何外传路径（Apple Speech 的系统联网行为需在 UI 中提示，由用户选择）。

## 4. 领域模型与决策语义

### 4.1 识别引擎设置

```text
RecognitionEngineKind
  whisper        whisper.cpp 本地识别（默认，现状）
  system         平台系统识别：iOS -> Apple Speech；Windows -> Live Captions
```

- 设置持久化、默认值回退与既有字段同一套机制；默认 `whisper` 保证旧设置无缝升级。
- 引擎选择与预取策略（完整预识别/按需预取）正交：任何引擎都沿用同一预取与背压行为。
- 引擎切换立即生效于下一次识别会话；当前会话中的切换走既有"配置变更重建"路径，不允许新旧引擎同时产出事件。

### 4.2 识别引擎状态契约

为识别引擎建立与 `TranslationServiceStatusProvider` 对称的状态契约：

```text
RecognitionEngineStatus
  available(provider, ...)                        可用
  unavailable(provider, message, ...)             不可用 + 用户可读原因
```

- whisper.cpp：常驻可用（模型加载失败时按现有错误路径报错）。
- Apple Speech：探测授权状态、locale 语言支持、设备端识别可用性；未授权时提供"去授权"入口，拒绝授权后给出明确回退提示。
- Live Captions：探测系统版本与功能启用状态；未启用时给出开启指引而不是报错。
- `RecognitionController` 在引擎不可用时记录警告并按设置回退（默认自动回退 whisper.cpp 并在诊断与 UI 中明示"本次会话已回退"），不中断播放。

### 4.3 Apple Speech 的窗口映射

- 复用现有窗口规划：每个 `RecognitionWindow` 的 PCM 逐块追加进一个 `SFSpeechAudioBufferRecognitionRequest`，窗口耗尽即 `endAudio`；`bestTranscription` 变化映射为 partial 事件，`isFinal` 映射为 final 事件，媒体时间取窗口边界。
- 窗口取消（seek/换片/暂停清空）必须终止对应请求并丢弃迟到结果。
- 设备端识别可用时默认 `requiresOnDeviceRecognition = true`（零联网、隐私最优）；不可用但在用户选择联网识别时，UI 必须提示该语言会使用服务器识别。

### 4.4 Live Captions 的定位与锚点

- 输出文本按到达顺序映射为低精度 `RecognitionEvent`，锚点取播放器当前媒体位置的最近窗口边界；UI 与导出明确标注来源为 Live Captions、时间为近似值。
- 该引擎只用于开发验证与桌面可选场景，移动端设置中不出现；其事件不进入 whisper.cpp 的回归断言。

## 5. 执行步骤

### Step 1：识别引擎设置模型与装配骨架

状态：`未开始`

- 新增 `RecognitionEngineKind` 设置字段、持久化、默认值回退与设置页"识别引擎"分段控件（iOS 显示 Whisper/系统识别，Windows 显示 Whisper/系统字幕，其余平台仅 Whisper）。
- `providers.dart` 按设置装配识别引擎；引擎不可见性/可用性不满足的平台只显示 Whisper。
- 建立识别引擎状态契约（`RecognitionEngineStatus`）与探测接口，whisper.cpp 返回常驻可用。

完成条件：设置可保存、重启恢复；旧 `settings.json` 打开不失败；默认行为与 Phase 8 完全一致。

### Step 2：识别引擎状态、降级与控制器接线

状态：`未开始`

- `RecognitionController` 接入引擎状态：启动会话前探测；不可用时记录警告、自动回退 whisper.cpp 并在诊断与播放器状态区明示。
- 引擎切换、换片、seek 与暂停清空时，旧引擎在途请求被取消或隔离，迟到结果不回写当前会话（沿用 generation 机制）。
- 纯 Dart 单测覆盖：不可用回退、切换隔离、迟到结果丢弃、状态上报。

完成条件：任何引擎状态下，播放、字幕时间轴与翻译管线行为不劣于 Phase 8 基线。

### Step 3：iOS Apple Speech Adapter

状态：`未开始`

- Swift 侧新增 `AppleSpeechBridge`（MethodChannel 模式同 `SystemTranslationBridge`）：授权请求与状态查询、locale 支持、`supportsOnDeviceRecognition`、按窗口创建 `SFSpeechAudioBufferRecognitionRequest`、partial/final 事件流、取消。
- `Info.plist` 增加 `NSSpeechRecognitionUsageDescription`（中文说明，注明识别内容可能由系统处理）。
- Dart 侧 `AppleSpeechRecognitionService` 实现 `WindowRecognitionService` 与状态契约；窗口 PCM 经通道喂入，事件带 requestId/sessionId 回显守卫。
- 自动化：Dart 契约测试用 mock 通道覆盖授权拒绝、语言不支持、final 映射、取消与迟到丢弃；macOS CI 编译 iOS。

完成条件：真机上授权后可产出与 whisper.cpp 同结构的 `RecognitionEvent`，字幕时间取窗口媒体时间；拒绝授权或语言不支持时明确回退。

### Step 4：Windows Live Captions 调研与 Adapter

状态：`未开始`

- 先做可行性 spike：Windows 11 版本检测、Live Captions 启用状态探测、UI Automation 读取字幕文本的技术路径与稳定性（窗口类名/文本节点可能在系统更新中变化，需容错与版本标注）。
- 依据调研结果实现 `WindowsLiveCaptionsService`：默认关闭；启用时输出低精度 `RecognitionEvent`；系统不支持或功能未开启时返回明确状态与开启指引。
- 明确该引擎"开发验证工具"定位：用于快速验证翻译 Provider、Overlay、历史与导出工作流；文档与 UI 注明时间近似。

完成条件：Windows 11 环境可开关；不可用环境清晰降级；调研结论（含 UI Automation 的脆弱性风险）写入执行记录。

### Step 5：设置页与诊断集成

状态：`未开始`

- 识别引擎分段的说明文案包含隐私/网络提示：Apple Speech 设备端识别零联网，联网语言会提示；Live Captions 完全本机。
- 引擎状态、授权入口、回退事件进入诊断日志（信息/警告分级遵循五级体系）。
- 诊断页能区分事件来源引擎（whisper/system），export 字段与脱敏策略不变。

完成条件：用户可以在设置中选择、关闭、查看状态与授权；诊断可追溯引擎与回退原因。

### Step 6：跨模块集成、回归与结项

状态：`未开始`

- 回归：whisper.cpp 固定素材回归结果与 Phase 8 基线完全一致（系统 Provider 代码不得影响该路径）；识别引擎切换 × 换片 × seek × 翻译并行的组合测试。
- 真机：iPhone 上 Apple Speech 授权、单句/连续识别、取消、换片、回退；Windows 11 上 Live Captions 验证翻译/Overlay/历史/导出工作流。
- 运行 `dart analyze lib test`、`flutter analyze`、`flutter test --concurrency=1`；iOS 构建走 macOS CI 产出未签名 IPA 并真机回归。
- 更新 `NEW.md` 实际进度，只记录已验证行为。

完成条件：验收清单全部通过，`NEW.md` 记录 Phase 9 结项。

## 6. 本阶段范围边界

包含：识别引擎设置与状态契约、引擎降级回退、iOS Apple Speech adapter（Swift + Dart + 授权）、Windows Live Captions 调研与 adapter、设置页与诊断集成、相关自动化与真机回归。

不包含：Android 系统识别、whisper.cpp 模型更换或量化调整、识别控制器核心调度重写、Live Captions 的生产级时间轴精确化、永久字幕历史数据库、与识别引擎无关的视觉重构。

## 7. 验收清单

- [ ] 设置提供识别引擎选择，持久化且旧设置文件兼容；默认 whisper.cpp，行为与 Phase 8 一致。
- [ ] Apple Speech：授权请求只在用户主动操作时触发；授权后能产出结构一致的 `RecognitionEvent`，媒体时间取自窗口；取消/换片/seek 不串会话。
- [ ] Apple Speech：拒绝授权、语言不支持或不可用时明确降级回 whisper.cpp，播放与字幕不受影响。
- [ ] Live Captions：仅 Windows 11 且功能可用时可选；输出标注低精度时间与来源；不可用环境清晰降级。
- [ ] 两种系统 Provider 都可独立测试与禁用；其输出不污染 whisper.cpp 固定素材回归。
- [ ] 引擎状态、回退与授权事件可在诊断日志追溯；Release 脱敏策略不变。
- [ ] `dart analyze lib test`、`flutter analyze`、`flutter test --concurrency=1` 通过；iOS 未签名 IPA 构建并完成真机回归；Windows Release smoke 通过。

## 8. 本轮执行记录

| 日期 | 项目 | 状态 | 说明 |
|---|---|---|---|
| 2026-08-22 | Phase 9 计划制定 | 已完成 | Phase 8 验收结项（见第 0 节与 `NEW.md`）；依据 `NEW.md` Phase 9 要求制定本计划：识别引擎设置与状态契约、iOS Apple Speech adapter、Windows Live Captions 调研与 adapter、降级回退与诊断集成。 |
