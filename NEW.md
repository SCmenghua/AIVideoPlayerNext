# AI Video Player Next - 独立项目开发路线

> **项目性质：全新项目。** 本文定义一个新的仓库和新的工程，不是当前仓库的 Phase 10，也不迁移、调用、复制或依赖当前仓库中的任何源码、资源、配置、CI、文档、测试素材或构建产物。
>
> 开发阶段仍统一使用 `Phase` 编号，从 `Phase 1` 开始。新仓库独立初始化 Git 历史、许可证、目录、依赖锁定、测试素材和 CI。

## 1. 产品方向

目标是制作一个以手机为最终交付形态、但能在 Windows PC 上高效编译、运行、调试和回归测试的视频播放器。

产品的核心不是单纯播放视频，而是在视频的权威媒体时间轴上准时显示可读的原文与译文字幕。播放器提供时钟和画面；识别、翻译、预读与缓存都必须服务于字幕在对应时间出现，不能以识别或翻译任务完成的墙钟时间替代媒体时间。

核心体验：

1. 播放本地视频，后续扩展网络媒体与 WebDAV。
2. 从播放器音频获得带媒体时间戳的 PCM，并优先在本机完成语音识别。
3. 显示原文、译文或双语字幕；字幕必须正确响应暂停、seek、换片与取消。
4. 翻译引擎可替换；iOS 通过独立原生桥接使用 Apple Translation。
5. 具有精致的深色工作台风格 UI，移动端以视频为中心，iOS 可以局部增强为原生玻璃材质。
6. Windows 上能验证播放器、识别核心、字幕时间轴、翻译契约和大部分 UI，不把日常验证押在远程 iOS CI 或 IPA 上。

Windows 不能生成正式 iOS IPA 是 Apple 工具链限制，无法通过换语言解决。新路线解决的是绝大多数逻辑在 PC 上可测试，最终 iOS 集成和签名仍交由 macOS/Xcode 或 macOS CI。

## 2. 不可违反的独立边界

新项目创建于新的目录和新的 GitHub 仓库，例如 `D:\code\AIVideoPlayerNext`。它必须满足：

- 不引用当前仓库路径，也不以 Git submodule、包依赖、脚本、软链接或复制文件方式使用当前仓库内容。
- 不复用当前项目的 Swift、XcodeGen、WhisperKit、AVPlayer、SwiftUI、CI workflow、模型文件、视频素材或测试期望。
- 不以“修复旧实现”为任务来源；每一项能力均重新定义契约、重新实现并建立自己的测试。
- 不沿用旧版本号和旧 Phase 记录。`Phase 1` 是第一个有效开发阶段。
- 可借鉴公开项目的产品思路和公开文档，但不复制其代码、资源或品牌表达；接入第三方库时单独审查许可证与分发限制。

## 3. 技术路线

### 3.1 推荐技术栈

| 领域 | 选择 | 原因 |
|---|---|---|
| 应用与 UI | Flutter + Dart | Windows、Android、iOS 使用同一套 UI 与业务逻辑，Windows 可直接构建和测试。 |
| 状态与依赖 | Riverpod | 生命周期、依赖替换和测试替身明确，避免全局可变对象。 |
| Windows 原型播放器 | `media_kit` / libmpv | 本地文件与常见网络媒体支持成熟，适合尽快验证桌面播放体验。 |
| 跨平台语音识别基准 | `whisper.cpp`，经自有 C ABI 封装 | C/C++ 内核可在 Windows、Android、iOS 构建，直接处理播放器 PCM，便于固定音频回归与字幕时间轴对齐。 |
| iOS 系统语音识别 | Apple `Speech` Framework adapter | 使用 `SFSpeechRecognizer` 识别本应用拥有的音频；作为 iOS 专用可选 Provider，不承担跨平台基准职责。 |
| Windows 系统语音识别 | Windows Live Captions adapter | 利用 Windows 系统字幕作为 Windows 专用可选 Provider，用于快速验证翻译、Overlay 与历史工作流。 |
| Flutter 与识别核心 | Dart FFI | 音频块、取消、事件和诊断字段都可成为稳定跨平台契约。 |
| iOS 平台能力 | Swift Flutter plugin + Pigeon | Apple Translation、AVAudioSession、后台状态与系统方向只留在 iOS adapter。 |
| Android 平台能力 | Kotlin Flutter plugin | 权限、音频焦点、媒体会话与平台播放器适配集中管理。 |
| 数据与诊断 | SQLite + JSONL 导出 | 历史字幕可查询，诊断记录可追溯且方便用户导出。 |
| 构建 | Windows CI + macOS iOS CI | 日常质量在 Windows 保证，iOS 只验证平台集成与签名。 |

### 3.2 UI 原则

- 跨平台使用 Flutter 自建设计系统：深灰与中性色为基础，辅以绿色、青色或红色状态色，不做安卓设置页式堆叠表单。
- 桌面是紧凑工作台：左侧媒体与来源，中间播放器，右侧字幕、翻译和诊断面板。
- 手机是内容优先界面：播放器占首屏，控制、字幕设置和诊断采用底部抽屉或全屏二级页。
- 玻璃材质只用于真正的浮层、工具栏与字幕承载区域，不将每个区块包成浮动卡片。
- iOS 的原生玻璃效果是可选视觉增强；Flutter 基础外观必须在 Windows 和 Android 保持一致、可用。

## 4. 对 LiveCaptions Translator 的参考结论

参考项目：[SakiRinn/LiveCaptions-Translator](https://github.com/SakiRinn/LiveCaptions-Translator)。它是一个 `.NET 8 + WPF` Windows 工具，借助 Windows 11 Live Captions 取得系统识别结果，再叠加多翻译服务、透明字幕悬浮窗、历史记录和日志卡片。

值得吸收的产品和架构原则：

1. **识别与翻译分层**：识别文本进入稳定事件流，翻译 Provider 只消费文本，不反向控制识别生命周期。
2. **多 Provider 而非单一翻译绑定**：系统翻译、传统翻译、LLM、云端 API 均应位于同一抽象之后，拥有统一的超时、重试、隐私提示与错误状态。
3. **独立字幕 Overlay**：字幕显示是可配置的消费层，支持字体、颜色、透明度、显示句数与拖动位置，不成为识别管线的一部分。
4. **历史和日志是产品能力**：原文、译文、时间、来源和失败原因应可查看、搜索和导出，而不是只写在调试控制台。
5. **优先使用操作系统能力**：Windows 桌面开发阶段可增加一个可选的 Windows Live Captions adapter，用于快速验证翻译、Overlay 与历史管理，而非重做系统已擅长的实时字幕。

不采用的部分：

- Windows Live Captions 不作为手机播放器的核心识别方案，也不作为跨平台字幕时间轴的唯一来源。
- 不通过 UI Automation 抓取系统窗口文字作为移动端生产实现。
- 不复制 WPF、C#、资源、API 实现或其界面设计；新项目维护自己的代码、视觉语言与许可边界。

### 4.1 语音识别 Provider 策略

新项目不把语音识别绑定为单一实现。所有识别来源都必须输出相同的 `RecognitionEvent`，由相同的
`SubtitleTimeline`、翻译与 Overlay 消费：

```text
播放器 PCM -> WhisperCppSpeechRecognitionService -> RecognitionEvent
iOS 音频   -> AppleSpeechRecognitionService      -> RecognitionEvent
Windows 系统字幕 -> WindowsLiveCaptionsService   -> RecognitionEvent
                                                    -> SubtitleTimeline
                                                    -> TranslationService
                                                    -> Overlay / History / Diagnostics
```

- **`WhisperCppSpeechRecognitionService` 是跨平台默认实现和回归基准。** Windows、iOS、Android
  都必须能用相同的固定音频素材验证其输出；它直接消费播放器 PCM，因此能掌控媒体时间轴、seek、
  换片与取消行为。
- **`AppleSpeechRecognitionService` 是 iOS 专用的可选实现。** 使用 Apple `Speech` Framework
  的 `SFSpeechRecognizer` 对本应用已经取得的 PCM 音频进行识别，输出 partial/final、语言与可用的
  置信度信息。它可以在支持设备端识别的语言和设备上尝试低功耗、低延迟路径；当系统要求联网或能力
  不可用时，必须明确告知用户，不能静默上传音频。它不负责翻译，Apple Translation 仍是独立 Provider。
- **`WindowsLiveCaptionsService` 是 Windows 专用的可选实现。** 它依赖 Windows 11 Live Captions
  的可用性与用户配置，适合验证翻译 Provider、透明字幕 Overlay、历史、导出和桌面交互。由于系统
  字幕结果不天然具有播放器媒体时间轴，且没有可依赖的跨版本公开文本订阅 API，它不能替代
  `whisper.cpp` 的播放器生产链路或固定素材回归。
- 系统识别 Provider 任何一个不可用、未授权、语言不支持或结果无法可靠时间对齐时，都必须可切换回
  `whisper.cpp`，并显示明确的降级状态。

## 5. 新仓库结构

```text
AIVideoPlayerNext/
├─ app/                         # 独立 Flutter 应用
│  ├─ lib/
│  │  ├─ app/                   # 启动、路由、依赖装配、生命周期
│  │  ├─ core/                  # Result、错误、时钟、日志、配置
│  │  ├─ domain/
│  │  │  ├─ player/             # 播放状态、媒体源与服务接口
│  │  │  ├─ audio/              # PCM 数据、时间映射与采集接口
│  │  │  ├─ speech/             # 识别请求、事件、质量诊断与 Provider 抽象
│  │  │  ├─ subtitles/          # 时间轴、显示策略、历史模型
│  │  │  └─ translation/        # 翻译 Provider、配置与错误模型
│  │  ├─ features/              # 播放器、媒体库、字幕、设置、诊断
│  │  └─ design_system/         # 颜色、排版、图标与玻璃材质组件
│  └─ test/
├─ native/
│  ├─ speech_core/              # whisper.cpp 的独立 C ABI 包装
│  ├─ plugins/
│  │  ├─ ios/                   # Swift adapter
│  │  ├─ android/               # Kotlin adapter
│  │  └─ windows/               # C++/Windows adapter
│  └─ tools/                    # 独立命令行回归工具
├─ test_assets/                 # 新建、可授权的音频/视频和期望结果
├─ docs/                        # 契约、架构决策、测试矩阵与发布说明
└─ .github/workflows/           # 新建 Windows 与 macOS CI
```

## 6. 核心契约

Flutter UI 和业务层只能依赖以下概念，不直接依赖 libmpv、AVPlayer、ExoPlayer、Windows Live Captions 或 whisper.cpp：

```dart
abstract interface class PlayerService {
  Future<void> open(MediaSource source);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Stream<PlaybackSnapshot> get snapshots;
  Future<void> dispose();
}

abstract interface class SpeechRecognitionService {
  Future<void> start(RecognitionRequest request);
  Future<void> stop();
  Future<void> reset({required Duration position});
  Stream<RecognitionEvent> get events;
}

abstract interface class TranslationService {
  Future<TranslationResult> translate(TranslationRequest request);
}
```

每个 `RecognitionEvent` 至少包含：

- `sessionId`：换片、seek、重新激活后隔离旧任务。
- `segmentId`：用于翻译异步回填与历史索引的稳定主键。
- `start`、`end`：媒体时间轴，绝不以事件到达时间替代。
- `text`、`language`、`confidence`、`kind`（`partial` / `final`）。
- `source`：`whisper.cpp`、Apple Speech、Windows Live Captions、播放器 PCM 或麦克风。
- `diagnostics`：窗口时长、能量、推理耗时、无语音概率、过滤原因等可选字段。

`SubtitleTimeline` 是纯 Dart 模块：它负责排序、重叠收敛、partial 覆盖、final 固化、按当前位置查询、seek 处理和按 `segmentId` 回填译文。它不依赖 Flutter，不直接调用任何平台 API，必须可在 Windows 命令行测试中独立验证。

## 7. 播放到显示字幕的流程

```text
用户点击播放
  -> PlayerService 产生权威播放状态和播放位置
  -> RecognitionController 创建新的 sessionId
  -> AudioSource 输出携带媒体时间戳的 PCM
  -> AudioWindowPlanner 按能量、停顿和最大时长形成识别窗口
  -> speech_core worker 转写窗口，受取消与背压控制
  -> RecognitionQualityGate 过滤无语音、低质量和异常重复结果
  -> final 原文立即写入 SubtitleTimeline
  -> TranslationService 异步翻译并按 segmentId 回填
  -> Overlay 根据播放位置查询时间轴，显示原文和/或译文
  -> History/Diagnostics 保存可检索的最终记录和事件原因
```

必须满足：

1. `partial` 只更新一条预览，不写入最终历史列表。
2. 所有异步结果必须验证 `sessionId`，旧视频和旧 seek 的结果不能污染当前媒体。
3. 识别游标有上限与失败策略，既不无限超前，也不因单个窗口失败永久卡死。
4. UI、音频解码、模型推理、翻译、数据库和文件日志具有明确线程或 Isolate 边界。
5. 任何“没有字幕”的问题都能判定发生在音频、分窗、识别、质量门控、时间轴、翻译或 Overlay 的哪一层。

## 8. Phase 路线

### 8.0 编译版本与构建标识规则（强制）

每次编译都必须把当前开发阶段写入软件版本，并把本次编译的真实信息注入应用。整数 Phase 的版本号统一使用：

```text
0.<当前 Phase 编号>.0
```

例如执行 `Phase 6` 时，软件版本必须是 `0.6.0`；执行 `Phase 6.5` 时必须是 `0.6.5`；进入 `Phase 7` 后必须改为 `0.7.0`。版本号必须同时更新 `app/pubspec.yaml` 的 `version` 和应用默认构建信息，不能继续沿用旧 Phase 的版本号。

每一次 Windows、iOS 或其他 Release/验收构建都必须注入以下信息：

- `APP_VERSION`：当前 Phase 对应的软件版本，例如 `0.6.0`。
- `APP_BUILD_TIME`：实际编译开始或完成时间，必须包含日期、时间和时区，不能使用“开发构建”。
- `APP_BUILD_ID`：本次构建的唯一标识，例如 CI 运行号、提交号或本地构建时间戳，不能使用“未指定”。

诊断页标题和诊断日志导出文件的头部必须显示这三个字段，方便确认用户测试的确切程序。Release 包不得显示默认占位值；Debug/本地开发运行可以使用默认值，但正式测试前必须使用带真实构建信息的包。每次版本或构建标识规则发生变化时，必须同步更新构建脚本、CI 配置和本文件中的执行记录。

### Phase 1：新仓库与 Windows 工具链

目标：让独立工程在 Windows 上可重复构建与测试。

- 建立新的 Git 仓库和 Flutter 应用，启用 Windows、Android、iOS target。
- 配置 `flutter analyze`、单元测试、Widget 测试、Windows Debug/Release 构建。
- 建立新的许可清晰的测试素材与 `manifest.json`。
- 创建 Mock Player、Mock Speech、Mock Translation，先验证应用壳与依赖注入。

验收：干净 Windows 环境不依赖当前仓库或 Xcode，即可运行 `flutter analyze`、`flutter test`、`flutter build windows`。

### Phase 2：播放器基础与媒体交接契约

目标：完成可靠的本地播放器，并先证明 iOS 能将受支持网页视频交接到应用播放器。

- 文件选择、打开、播放、暂停、seek、倍速、音量和错误状态。
- 统一 `PlaybackSnapshot`，处理换片、加载失败与播放结束。
- 定义 `BrowserMediaHandoff`、媒体请求头、来源页面、临时会话信息和“返回浏览器”契约；Flutter 业务层不得直接依赖 WebKit、WebView2 或 Android WebView。
- 桌面工作台布局与移动端播放器骨架同步建立。
- 通过 Mock 对 PlayerViewModel、媒体交接和控制逻辑进行测试。
- 在 iPhone 真机完成最小 WebKit 技术尖峰：测试页面中的普通 MP4 点击后必须进入应用播放器，不得打开 Safari 或 iOS 系统网页播放器。
- **首次 IPA 验收包：** 在该技术尖峰通过后，由 macOS/Xcode 或 macOS CI 生成可安装的 Development 或 Ad Hoc IPA，并安装到至少一台 iPhone；IPA 必须验证本地视频播放、网页 MP4 交接、关闭播放器返回浏览器，以及失败时的中文提示。

验收：播放 10 分钟以上本地视频时 UI 保持响应；seek 与换片后不残留上一媒体状态；首个 iOS 验收 IPA 在真机上完成普通网页 MP4 到内置播放器的交接。

#### Phase 2 当前执行记录

- **Windows 验收已通过（2026-08-15）：** 手动验证初始中文界面、系统文件选择器、本地视频打开与播放、暂停、进度拖动、前进/后退 10 秒、音量、0.5/1.0/1.25/1.5/2.0 倍速、取消选择、换片状态清理和窗口尺寸变化。
- **自动化检查已通过：** `flutter analyze` 无问题；`flutter test` 通过 7 个测试；`flutter build windows --release` 成功生成 `app/build/windows/x64/runner/Release/ai_video_player_next.exe`。
- **实现范围：** Windows 默认运行时已切换到 `media_kit`/libmpv；`PlaybackSnapshot` 已覆盖加载、播放、暂停、结束、缓冲、错误、进度、音量和倍速；`BrowserMediaHandoff` 已定义媒体 URL、来源页面、临时请求头和浏览器会话标识的内存交接契约。
- **未完成门槛：** Phase 2 的首个 Development/Ad Hoc IPA 仍需 macOS/Xcode 或 macOS CI，并需在真实 iPhone 上验证本地播放、网页 MP4 交接、返回浏览器和中文失败提示。Windows 验收不替代该 IPA 门槛。

### Phase 3：内置浏览器核心与 iOS 视频拦截

目标：将内置浏览器作为一等能力实现，并在 iOS 上稳定阻止受支持媒体进入系统网页播放器。

- 建立浏览器页面、地址栏、前进后退、刷新、加载错误和单标签会话。
- 实现 Windows WebView2、iOS `WKWebView`、Android WebView 的统一 `BrowserService`；Dart 层仅消费浏览历史、页面状态和 `BrowserMediaHandoff`。
- iOS `WKWebView` 必须启用内联媒体策略，注入 `playsinline` / `webkit-playsinline`，并通过导航代理和 JavaScript message handler 捕获 `<video>` 点击与直接媒体导航。
- 对可获取真实 URL 的普通 MP4、HLS 和重定向媒体，先阻止网页默认播放，再路由到应用播放器；关闭播放器后恢复原浏览器页面与位置。
- 不使用 `SFSafariViewController`、`UIApplication.open` 或 WebView 默认全屏播放作为受支持媒体的播放路径。
- DRM、MSE/blob、封闭 iframe 或其他无法合法取得播放源的媒体必须给出中文“不支持由内置播放器接管”的原因，不尝试绕过 DRM，也不悄悄外跳至系统播放器。
- **第二个 IPA 验收包：** 浏览器交接实现完成后生成可安装 IPA，在至少一台 iPhone 上验证普通 MP4、页面内 `<video>`、媒体重定向、关闭后返回浏览器和不支持资源提示；任何受支持资源若进入系统网页播放器则该阶段不通过。

验收：真机 IPA 中受支持网页视频点击始终进入内置播放器；浏览器不会将这些媒体交给 Safari 或 iOS 系统网页播放器；浏览器会话可正确恢复。

#### Phase 3 当前执行记录

- **Windows 工程实现已完成（2026-08-15）：** 已建立平台无关的 `BrowserService`、浏览器页面状态和事件模型；Dart 业务层仅消费浏览器状态、媒体交接事件与不支持原因，不直接依赖 WebView2、WKWebView 或 Android WebView。
- **Windows 浏览器已接入：** 使用 Edge WebView2 提供单标签浏览器、中文地址栏、前进、后退、刷新、停止加载、加载进度和错误提示；WebView2 Runtime 缺失时显示中文原因。为兼容 Visual Studio 2026 的 MSVC 协程弃用诊断，Windows CMake 已为现有 WebView2 插件加入官方兼容宏。
- **媒体交接实现：** 普通 HTTP/HTTPS MP4、M4V、MOV、WebM、MKV 和 HLS `.m3u8` 由统一分类器交给应用播放器；页面 `<video>` 点击通过浏览器 JavaScript bridge 阻止网页默认播放并交接到应用内播放器工作区。浏览器和播放器不是嵌套路由，用户通过左侧工作区选择器切换，原浏览器路由和单标签会话会保持。
- **不支持媒体策略：** `blob:`/浏览器媒体流及未提供真实媒体地址的页面显示中文“不支持由内置播放器接管”原因；不提取或绕过 DRM，不使用 Safari、`UIApplication.open` 或 WebView 全屏播放器作为支持资源的播放路径。请求头只在内存交接对象中短暂保存，未写入日志或持久化。
- **iOS 实现已纳入工程：** `WKWebView` 启用内联媒体播放，创建时允许媒体播放，并在页面中注入 `playsinline`/`webkit-playsinline`；导航代理与 JavaScript message channel 都会拦截可获取真实 URL 的媒体。Android 复用相同的 Dart 服务契约和拦截脚本。
- **自动化检查已通过：** `flutter analyze` 无问题；`flutter test --concurrency=1` 通过 11 个测试（新增 MP4、HLS、`blob:` 和普通网页分类回归）；`flutter build windows --release` 成功生成 `app/build/windows/x64/runner/Release/ai_video_player_next.exe`。
- **验收门槛已通过（2026-08-16）：** Windows 已完成人工检查浏览器导航、普通 MP4/HLS 交接、播放器与浏览器工作区切换、播放器返回浏览器及不支持资源提示；iOS 已通过未签名 IPA 自签后的真机验证，覆盖普通网页视频播放/全屏交接、返回浏览器、不支持资源提示，以及受支持资源不进入 iOS 系统网页播放器。第二个 IPA 门槛已完成，Phase 3 不再处于待验收状态。
- **iOS 白屏修正（2026-08-15）：** 补充 `media_kit_libs_ios_video`，并为 iOS 工程加入 CocoaPods 集成，使 `Mpv.framework/Mpv` 会随未签名 IPA 一起嵌入。未签名 IPA Action 会预缓存 iOS Flutter engine、执行 `pod install`，并在打包前硬性检查播放器 framework；缺少 framework 时构建直接失败，不再生成可下载但启动白屏的包。应用启动也增加中文诊断页，原生播放器初始化异常会显示错误信息而不是只有白屏。
- **Windows 验收修正（2026-08-15）：** 浏览器服务改为随浏览器页面创建和自动释放，避免退出后再次进入复用已释放的 WebView2 控制器。页面脚本在文档创建和完成加载后均会注入，并仅在发现 HTTP(S) 真实媒体地址时阻止网页播放并交接；来自已确认 `<video>` 元素、但 URL 没有文件扩展名的 HTTP(S) 媒体也可交接。`blob:`/MSE 页面不再被阻断，会继续在内置浏览器中按网站原逻辑播放，同时显示无法由内置播放器接管的中文原因。Bilibili 等以 MSE/`blob:` 或 DRM 为主的视频站点不能合法交接到内置播放器，此限制符合项目不绕过 DRM 的原则。
- **工作台交互修正（2026-08-15）：** 浏览器首次打开后作为根工作台中的持久工作区保留，并通过 `IndexedStack` 在播放器与浏览器之间切换；浏览器媒体交接后直接打开并播放主播放器，然后选中“播放器”工作区。已移除浏览器专用播放页、左上角返回按钮及其异步销毁路径，从而避免返回时同时销毁页面、WebView 与播放控制器导致的崩溃。交接播放复用主播放器完整控件，包括进度、前进/后退 10 秒、暂停/继续、倍速与音量调节；选择“内置浏览器”即可恢复原网页会话。
- **iPhone 本地文件与浏览器交接修正（2026-08-15）：** iOS 文件选择器补充 `public.movie` Uniform Type Identifier；此前仅声明文件扩展名会被 iOS `file_selector` 实现拒绝，导致“文件”中没有可选视频或选择调用失败。该选择器使用 `UIDocumentPicker` 的导入模式，系统会将选中的文件导入应用可访问的沙盒，不需要照片权限。选择过程的读取异常会显示中文提示。`WKWebView` 的媒体桥接改为在页面开始和完成时均安装，除了 `<video>` 本身，也会捕获视频画面范围内及带“播放”语义的自绘播放控件；它会等待网页完成真实 HTTP(S) 媒体地址的解析后再暂停网页视频并交接，支持相对地址。`blob:`、MSE、DRM 和其他无法取得真实地址的资源仍不绕过，只给出中文无法交接提示并保持网页路径。
- **iOS 播放与全屏交接强化（2026-08-15）：** iOS 通过 `WKWebView` 的原生 `WKUserScript` 在文档创建阶段、且覆盖 iframe 地注入媒体桥接；页面回调注入保留为回退。桥接会拦截普通网页视频的 `play()`、`requestFullscreen()`、`webkitEnterFullscreen()`、原生全屏事件以及含“播放/全屏”语义的自绘控件。发现真实 HTTP(S) 媒体地址时，阻止网页和 iOS 系统播放器路径并切换到应用播放器工作区；`blob:`、MSE、DRM 或无法获得真实媒体地址的页面会阻止全屏接管并显示中文不支持提示，不绕过网页保护。应用播放器新增自身的“进入全屏”按钮：全屏在 Flutter 路由内完成，提供退出全屏、播放/暂停、进度和音量控制，不调用 Safari、WKWebView 或 iOS 系统网页播放器。进入全屏时主工作区会卸载同一视频表面，避免同一原生播放器控制器被两个视图同时占用。
- **本次 iPhone IPA 验收：** 对自有或明确授权的普通 MP4/HLS 测试页，分别点击网页播放、自绘播放和网页全屏，均应切换到应用“播放器”工作区，且不出现 Safari 或 iOS 系统网页播放器；在应用播放器点击“进入全屏”后应横屏全屏，退出后仍可继续播放并可切回原浏览器会话。再验证 `blob:`/MSE/DRM 页面显示中文无法接管提示且不会进入系统全屏播放器。该验收不要求、也不能证明 Bilibili 等受 MSE/DRM 保护站点可被内置播放器接管。
- **首次点击交接修正（2026-08-15）：** 用户第一次点击播放后，桥接会在点击处理器返回后的 40ms、120ms、250ms、500ms、900ms、1.5s、2.5s 和 4s 重新检查已选视频及替换后的视频元素；网页不再因为初始源尚未就绪而只在浏览器内播放，广告源仍按广告容器和 URL 标记留在网页内。
- **首次点击边界修正（2026-08-15）：** 当网页保留广告视频元素、另行创建正片视频元素时，重试逻辑会重新选择当前可见且面积最大的非广告视频，避免继续跟踪旧广告元素。
- **首次播放延迟源修正（2026-08-15）：** 针对部分网页先触发播放、稍后才写入 `currentSrc` 且不再派发媒体事件的实现，用户点击后新增约 8 秒的定时观察窗口，仅检查本次选中的视频；源地址就绪后立即执行交接，不再要求用户额外点击暂停或全屏。
- **Windows 浏览器回归修正（2026-08-15）：** 统一复用跨平台媒体桥接，补充 `Full Screen`、`Enter Full Screen`、`Maximize`、暂停等英文和中文控件语义，并在捕获阶段优先识别可见主视频。原生 `<video controls>` 的播放事件、网页自绘全屏按钮、`requestFullscreen()`、`webkitEnterFullscreen()` 和 `fullscreenchange` 均会尝试交接 HTTP(S) 真实媒体源；WebView2 的 `ContainsFullScreenElementChanged` 作为原生兜底，只对确实包含视频的网页全屏执行退出，避免视频停留在网页全屏层或继续响应网页页面点击。回归重点是用户常用且项目需要访问的网站，不以特定文档示例页面作为硬性通过条件。
- **Windows 日志导出修正（2026-08-15）：** 诊断日志工具栏在 Windows 提供独立的“复制诊断日志”和“导出 TXT 日志”操作，前者写入系统剪贴板，后者通过系统保存对话框写入 UTF-8 `.txt` 文件；移动端继续使用系统分享。日志内容沿用 URL、授权信息和本地路径脱敏规则。
- **本轮范围收敛（2026-08-16）：** 回退仅针对 MDN 动态/沙盒 iframe 的实验性媒体桥接改动，保留普通网站的媒体交接、浏览器工作区切换、iOS 防止进入系统网页播放器以及 Windows 日志复制/TXT 导出。MDN `<video>` 示例不再作为 Windows 或 iOS 的必测目标；后续以用户常用网站和项目实际需要访问的网站为准。诊断日志工具栏的 Windows 按钮修复为可见的复制和下载图标。
- **诊断工具栏标识修正（2026-08-16）：** Windows 日志页的复制和 TXT 导出按钮改用 Flutter `CustomPainter` 绘制，避免 Material 图标字体子集缺少字形时只显示圆形按钮背景。日志页标题和导出 TXT 头部显示应用版本、构建时间和构建编号；Windows 与 iOS Release 构建通过 `APP_VERSION`、`APP_BUILD_TIME`、`APP_BUILD_ID` 注入这些值，便于区分验收包。未签名 iOS IPA 的 Action 会把构建时间和 GitHub Actions 运行号写入构建编号。
- **Phase 3 完成验收（2026-08-16）：** Windows 与 iOS 全端人工验收通过。用户常用及项目实际需要访问的网站可以在内置浏览器中点击播放或全屏后进入应用“播放器”工作区，不跳转 Safari、Edge 或 iOS 系统网页播放器；播放器与浏览器通过左侧工作区切换，网页会话可以保留，播放器具备暂停、进度、倍速、音量和应用内全屏控制。Windows 日志可以复制或直接导出 TXT，iOS 诊断日志可以正常导出；日志页与导出内容包含应用版本、构建时间和构建编号，便于确认验收包。MDN `<video>` 示例页因其动态/沙盒 iframe 特征不作为硬性目标，`blob:`、MSE、DRM 及无法取得真实媒体地址的资源仍按中文不支持提示处理，不绕过网页保护。当前 UI 风格差异不影响本阶段功能验收，统一视觉系统留到 Phase 10。

### Phase 4（可选，当前跳过）：网络媒体、HLS 与浏览器会话交接

状态：**当前跳过，不阻塞后续开发。** Phase 3 已经满足当前常用网站的浏览器视频识别、播放交接和内置播放器观看需求。以下内容作为未来可选的增强阶段保留；只有当实际使用中出现明确需求时，才重新启用本阶段。

未来目标：让内置播放器在更多网络媒体、登录会话和异常网络环境下可靠工作，同时不泄露认证数据。

- 支持 HTTP 视频、HLS、媒体重定向、网络缓冲、播放错误和重试状态。
- 浏览器登录后，将当前站点、当前媒体请求所必需的 Cookie 和安全请求头按最小范围、最短生命周期交给播放器；不得写入日志、诊断导出或默认长期存储。
- 建立本项目自有、许可清晰的测试站点或测试页面，覆盖直链 MP4、HLS、重定向、Cookie 会话、失效授权和不支持资源。
- 明确 Cookie、跨域请求头、登录过期、播放器返回浏览器和清理临时授权状态的生命周期。
- **未来可选的 IPA 验收包：** 如果重新启用本阶段，再在真实 iPhone 上验证 HLS、重定向媒体和需会话 Cookie 的授权测试资源交接；验证登录信息不出现在应用日志/导出中，授权失效时显示中文错误并能返回网页重试。

未来验收：网络媒体故障不破坏本地播放；真机 IPA 可将授权测试资源交接给内置播放器，并在关闭播放器后恢复对应浏览器会话。

当前不主动开发：额外 HLS/重定向兼容、Cookie/授权请求头交接、网络断线恢复和复杂异常恢复。遇到具体常用网站故障时，再根据真实日志和可复现步骤决定是否启用对应子项。

### Phase 5：音频与识别核心技术尖峰

目标：在 Windows 上独立证明“固定音频到字幕事件”可控。

- 新建 `speech_core` C ABI，封装 whisper.cpp 模型加载、转写、取消与诊断。
- 标准化 PCM：16 kHz、单声道、Float32，并定义时间戳换算规则。
- 实现命令行回归工具：输入新建 WAV/PCM 测试素材，输出结构化 JSONL 结果。
- 建立模型与测试素材缓存策略，不提交未经授权的大模型或大视频。
- 定义 `SpeechRecognitionService` 的 Provider 选择、可用性、授权、隐私与降级状态；所有 Provider
  统一输出 `RecognitionEvent`。

验收：同一固定音频在命令行和 Flutter 测试环境产生一致的 final 文本、时间与诊断结构。

### Phase 6：播放器音频、分窗与背压

目标：将播放媒体音频稳定送入识别核心。

- 从 Windows 播放器 adapter 取得带媒体时间的 PCM；必要时增加独立解码 adapter，但不让 Flutter UI 接触 FFmpeg/C++ 细节。
- `AudioWindowPlanner` 处理前导静音、语音开始、尾部停顿、最大窗口与纯静音。
- 有界缓冲、有限预读和 worker 串行队列，避免无界累积和 O(n) 头部数组删除。
- 记录窗口起点、持续时间、采样数、推理耗时、实时倍率和跳过原因。

验收：视频播放、暂停、seek、换片和停止时任务正确取消；推理落后时状态可见且音频不悄然错位。

### Phase 6.5：Whisper GPU 后端与平台加速

目标：在不改变 Phase 6 播放器音频、分窗和字幕事件契约的前提下，为 Windows 配置 Vulkan GPU 推理，为 iOS 配置 Apple Metal GPU 推理；GPU 不可用时必须安全、明确地回退到 CPU。

- Windows：为 `speech_core` 建立独立的 Vulkan Release 构建，启用 whisper.cpp/ggml Vulkan 后端；不得污染已经通过回归的 CPU 构建目录或把 Vulkan SDK、显卡驱动文件提交到仓库。
- Windows：在实际有 Vulkan GPU 的设备上运行真实模型和本地视频回归，确认运行时日志显示真实使用的 GPU 后端与设备名称；仅“DLL 编译成功”或代码请求 GPU 不能作为验收依据。
- iOS：在 macOS/Xcode 上为 `speech_core` 或等价原生桥接启用 whisper.cpp/ggml Metal 后端，链接所需系统框架，并在真机使用同一类 PCM/`RecognitionEvent` 契约验证；Windows 环境不得宣称 Metal 已编译或 IPA 已验证。
- 原生 C ABI 与 Dart FFI 增加稳定的推理后端状态：至少区分 `Vulkan`、`Metal`、`CPU`、`不可用`，并可提供 GPU 是否启用、设备名称和回退原因；不得只显示“Whisper 已加载”。
- 诊断页和导出日志必须记录模型加载时请求的后端、最终实际后端、设备标识、GPU 启用状态、CPU 回退原因、输入窗口、输出结果、推理耗时和实时倍率；路径、PCM、Cookie 和授权信息仍须脱敏。
- Vulkan 或 Metal 初始化、设备不兼容、驱动异常、内存不足或推理失败时，自动回退 CPU 或给出明确不可用状态；不得导致播放器崩溃、卡死或产生无来源的字幕。
- 保持模型在程序目录或受控发布资产中；GPU 依赖、模型、测试媒体和原生构建产物遵循现有许可证、分发和 Git 忽略规则。

验收：Windows 在支持 Vulkan 的机器上，真实播放器或原生命令行回归能在日志中确认 `Vulkan` 和实际 GPU 设备，并与 CPU 基线比较推理耗时；GPU 不可用时能明确显示并完成 CPU 回退。iOS 必须在 macOS 构建并在真实 iPhone 上确认 `Metal` 或明确 CPU 回退，且播放、识别和字幕事件不受影响。

范围边界：本阶段不重做 AudioWindowPlanner、RecognitionQueue、播放器控制、SubtitleTimeline、字幕样式、翻译、历史或网络媒体支持；这些能力继续按既定 Phase 推进。

### Phase 7：字幕优先的连续预取、网络媒体识别、翻译与 Overlay

目标：解决当前已支持网络视频的识别与播放器控制卡顿问题，建立以字幕识别、翻译和媒体时间准确显示为第一优先级的连续预取管线，并完成真实翻译 Provider 和双语字幕显示。播放器提供画面和权威时钟，但暂停、seek、换片和打开不得同步等待后台网络读取、解码或识别 worker 清理。

网络媒体采用两个逻辑独立的消费者：播放器直接播放网络源；识别侧独立读取同一授权媒体会话，并优先使用顺序临时缓存或分段缓存持续解码。默认不完整下载两份完整视频；仅在来源、会话与用户选择适合时才使用完整缓存。识别、翻译和显示的所有字幕时间仍服从播放器媒体时间轴。

#### 7.1 网络视频识别闭环

- 先以当前播放器已经能够打开的网络视频为范围，建立“播放音频是否可取得、PCM 是否持续输出、媒体时间是否连续、识别窗口是否生成、字幕是否命中时间轴”的逐层诊断。
- 修复网络媒体音频路径与本地媒体路径之间的差异，包括重定向后的媒体地址、播放器会话参数、缓冲/断流、音频轨道选择、解码失败、音频时间戳和 seek 后的重新取流；不得把播放画面正常误判为识别音频正常。
- 网络视频识别必须使用与本地视频相同的 `AudioChunk`、`AudioWindow`、`RecognitionEvent`、`SubtitleTimeline` 和 session/generation 契约；播放、暂停、seek、换片和网络错误后的恢复不能串字幕。
- 每个网络视频识别失败都要能定位在媒体交接、授权/会话、播放器音频输出、PCM 时间映射、分窗、Whisper、质量门控或时间轴显示中的具体层级。
- Phase 7 先支持可合法取得音频并且当前播放器已能播放的普通网络媒体；HLS/DASH 的复杂变体、直播、MSE/blob、DRM 和受保护媒体仍须单独评估，不得绕过授权或保护机制。

#### 7.2 连续前瞻、启动预备与有限资源调度

- 识别和翻译可以持续领先播放，不能采用“前瞻到 30 秒后停住，播放接近时才突发处理下一批”的走停式实现。协调器维护 `playbackPosition`、`downloadedThrough`、`decodedThrough`、`recognizedThrough`、`translatedThrough` 五个媒体时间游标，以低/高水位连续调度。
- 播放启动时机不预设固定等待条件，由用户选择的播放策略和实际运行状态共同决定。
- 识别窗口保持连续媒体时间，并保留约 `0.5-1.5 秒`输入上下文重叠；结果按媒体时间、文本和稳定 `segmentId` 合并去重，避免句子被窗口边界切断。
- 下载/缓存、解码、Whisper 和翻译使用固定数量的长期 worker 与有界队列，禁止每秒新建线程、isolate 或模型。Whisper 原生线程数可配置但固定；翻译仅使用有限并发。
- pause、seek、换片、停止与 dispose 先递增 `sessionId`/generation 并立即返回 UI；旧任务可以后台退出，但其迟到 PCM、识别和翻译结果必须被丢弃。seek 只在拖动提交后建立一次新会话。
- iOS 实现相同的有界队列、取消与相对优先级语义，可使用 `OperationQueue`、Swift `Task`、`DispatchQueue`、QoS 和固定 Whisper 线程数；iOS 不承诺 CPU 核绑定、绝对 CPU 百分比或后台长期运行。

#### 7.3 翻译 MVP 与字幕 Overlay

- 完成纯 Dart `SubtitleTimeline` 与充分单元测试，保持 `final-first`、`partial` 预览、session 隔离和按 `segmentId` 回填翻译。
- 将 `MockTranslationService` 替换为至少一个可实际使用的真实翻译 Provider，同时保留 Mock 作为测试替身；Provider 必须有统一的超时、取消、失败和网络状态模型。
- 翻译设置至少支持目标语言、翻译开关和原文/译文/双语显示模式；真实 Provider 的本地或云端属性、隐私提示和用户主动启用状态必须可见。
- 实现播放器内字幕 Overlay；桌面端可打开独立透明置顶字幕窗口，支持点击穿透作为可选能力。字幕字体、字号、颜色、背景透明度、位置与显示句数可配置。
- 诊断页提供音频窗口、识别事件、翻译任务、门控原因、当前队列、时间轴命中记录以及翻译延迟/失败原因。

验收：当前支持的网络视频能够稳定取得带媒体时间的音频并输出可追溯的 final 字幕；每个未显示段都能判断丢失层级。一个真实翻译 Provider 能将 final 原文按 `segmentId` 异步回填并显示双语字幕；翻译失败、seek、换片和取消不会串片或改变字幕媒体时间。

### Phase 7.999：Phase 8 提前完成内容归档

Phase 7 的实际实现已经提前交付了 Phase 8 原计划中的一部分基础能力。以下内容不应在后续 Phase 8 中重复规划：

- 已建立统一的 `TranslationService` 契约，并保留 `MockTranslationService` 作为测试替身。
- 已接入 DeepL Provider。
- 已接入 OpenAI-compatible Chat Completions Provider，支持常见基础地址自动规范化为完整的 `/v1/chat/completions` 端点。
- 已实现翻译 Provider 状态与能力可用性检查，并区分未配置、网络失败、超时、取消和响应格式错误等状态。
- 已实现有界翻译队列、有限并发、去重、超时和异步结果回填。
- 翻译结果通过稳定的 `segmentId` 回填到当前字幕文档；换片、重新开始会话或切换配置后，旧翻译结果不会污染当前媒体。
- 已实现原文与译文的会话级 `TranscriptDocument` 数据模型，包含稳定片段 ID、原文、译文、语言、翻译状态、Provider、失败原因和 `startMs`/`endMs` 时间轴。
- 已实现 Whisper 原始窗口结果与整理后字幕文档分离：原始结果用于诊断和追溯，整理后的文档供翻译、Overlay 和诊断栏消费。
- 已实现重叠窗口去重、文本合并、时间排序和翻译按片段 ID关联。
- 已实现 `transcript.json` 会话级临时快照与 TXT/分享/诊断导出能力。该文件不是永久历史数据库，换片或退出后可以清理。

上述内容意味着：Phase 8 的“多云端文本 Provider 契约”和“字幕历史数据模型的基础部分”已经提前完成，但不代表 Phase 8 整体结项。

### Phase 8：iOS 识别与翻译速度优化

1. 优化 iOS 端的识别速度，目前的模型对于 iOS 端来说前几句太慢了。
2. 接入 iOS 原生翻译接口。
3. 优化翻译的速度，目前的翻译速度太慢了。
4. 在设置中提供双语、原文、翻译三种字幕显示模式。
5. 在设置中提供字幕优先、翻译优先、播放优先三种播放中策略：字幕优先时，播放过程中如果下一条字幕尚未返回则暂停并显示“等待字幕返回中”；翻译优先时，播放过程中如果下一条字幕的翻译尚未返回则暂停并显示“等待翻译返回中”；播放优先时，播放过程中不因字幕或翻译未返回而暂停。三种策略不改变自动开始播放的启动门槛。
6. 在设置中提供“等待两条字幕产出或跳过四个窗口后开始播放”开关。该开关只控制自动开始播放前的字幕准备门槛，与播放中的字幕/翻译等待策略独立；播放优先也不因该策略而暂停播放。
7. 优化通用 API 的 URL 输入：系统只识别用户输入的 URL，并自动补全为规范地址。例如用户输入 `abc.com`、`abc.com/v1` 或其他符合规范但不完整的地址时，系统自动识别并补全为 `https://abc.com/v1/chat/completions`。
8. 在通用 API 的 Model 一栏右侧增加“下载模型列表”按钮。点击后自动获取模型列表，并通过下拉菜单供用户选择。

#### Phase 8 当前推进记录（2026-08-19）

- Step 1 已完成代码实现：设置持久化已加入字幕显示模式、字幕/翻译/播放三种播放中策略和启动准备开关；旧设置缺失字段、未知枚举和非法字段类型会回退到默认值，启动准备开关可独立于播放策略保存。
- Step 2 已完成代码实现：新增纯 Dart 播放启动与播放中内容决策器及覆盖策略和门槛组合的测试。自动开始只检查视频 ready 与可选的“两条字幕/四窗口”门槛；播放后由字幕优先/翻译优先决定是否暂停等待下一条内容，播放优先不因字幕或翻译暂停；播放器自动启动、手动播放和设置切换均重新计算。
- Step 3 已完成代码实现：普通播放器和全屏播放器均接入字幕显示设置，支持双语、原文、翻译及翻译准备中状态，并新增相应 Widget 测试；Overlay 不改变 `TranscriptDocument` 或媒体时间轴。
- Step 6 已完成本轮的队列可靠性与 seek 优先级子项：翻译队列在 Provider 异常、超时、错误 segmentId 或空文本时进行最多三次有界重试，并在达到上限后保留失败状态，避免无结果时队列永久卡住；快进后会清理旧排队任务，优先翻译当前及后续字幕。旧 Provider 请求或重试计时器会被 session、seek 调度代次和 Provider 切换隔离，迟到结果不会回写当前调度。主播放器、全屏拖动和前进/后退按钮均接入统一跳转入口，并新增队列回归测试。
- 翻译速度配置与诊断已完成代码实现：设置页可保存每批字幕数（1-20）和并发请求数（1-8），改动会立即应用于后续翻译请求；OpenAI-compatible 和 DeepL 使用批量请求，非批量 Provider 保持严格单条并发。批量 API 请求使用稳定片段 ID 和 JSON-only 响应校验，批量失败仍进入有界重试。诊断页显示配置值、实际平均批量、并发峰值、API 均值/P95/最近、排队等待、端到端等待、失败尝试、最终失败和重试。
- Step 7 已完成代码与 Windows 自动化验证：通用 API 输入支持缺少协议、`/v1` 和完整 Chat Completions 地址的规范化，并拒绝不安全或不完整的 URL；设置页可请求 `/v1/models`、去重保留服务端顺序、在下拉菜单中选择后保存模型，并处理超时、HTTP/格式错误、重复点击和配置变更后的过期响应。
- 自动化验证已完成：`dart analyze lib test` 报告 `No issues found`，格式检查通过，`flutter test --concurrency=1` 通过全部 127 项测试，覆盖播放策略、启动门槛、字幕 Overlay、设置、翻译 seek 优先级、失败重试和模型列表。Windows Release `0.8.0` 已构建、压缩并从 ZIP 回解压覆盖原 Release 目录；解压后的程序已启动并保持运行 5 秒，关键 DLL、`data` 和 Whisper 模型均存在。Step 4-5、Step 6 的真实 Provider 性能基线，以及 iOS 真机识别/原生翻译回归仍未完成，Phase 8 不能结项。

#### Phase 8 结项记录（2026-08-22，验收通过）

八项要求全部交付；Windows 自动化与 Release smoke、macOS CI 未签名 IPA 真机回归完成后，用户在真实 iPhone 上确认功能基本正常，Phase 8 结项。版本 `0.8.0`。逐项结果：

1. **iOS 识别速度**：诊断确认尾随主因是 `IOSAudioDecoderBridge` 的墙钟 1 倍速供 PCM 而非模型大小（推理约 800ms/窗口，实时倍率 0.13-0.2）。删除墙钟等待、全速读出并限制在途块 ≤16，领先量交给共用有界队列与 20s/45s 水位背压；真机回归确认识别从"落后播放"转为提前就绪，字幕不再尾随。
2. **iOS 原生翻译**：新增第四种翻译方式"系统翻译"。`SystemTranslationBridge`（MethodChannel）以 iOS 26 无头初始化器 `TranslationSession(installedSource:target:)` 创建会话并按语言对缓存，语言包需预先在系统设置下载（无头会话无法触发下载确认），缺失时返回终态错误并提示路径；`zh-CN` 规范化为 `zh-Hans`。Dart `SystemTranslationService` 探测构造即发起、`translate` 先等探测，桥接错误分类为可重试/不可重试。真机三轮回归修复了播放门控卡死、翻译无返回（`prepareTranslation()` 无头挂起）与测试连接无效，验收通过。
3. **翻译速度**：通用 API 改为单句纯文本协议 + 共享 `HttpClient` 连接复用（空闲保活 90 秒），超时只中止当前请求；408/429/5xx 可重试并遵循 `Retry-After`，其余 4xx 终态失败；并发默认 10、上限 20。可选滑动窗口上下文（默认开，前 3 句快照 + 已定译法，带护栏），在单句协议下恢复指代/术语准确性。
4. **三种字幕显示模式**：双语/原文/翻译，普通与全屏播放器统一 Overlay 语义，译文缺失状态可预期。
5. **三种播放中策略**：字幕优先/翻译优先/播放优先由统一 `PlaybackStartPolicy` 解释；门控新增"翻译不可用即放行""前两条终态失败即放行""失败视为已了结"语义，服务不可用时不再卡播放。
6. **启动准备开关**：独立于播放策略持久化；语义为"前两条翻译完成（或失败）或跳过四个窗口"。
7. **通用 API URL 规范化**：`abc.com`/`abc.com/v1`/完整地址统一规范化，非法输入可见报错。
8. **模型列表下载**：`/v1/models` 下载、去重保序、下拉选择、持久化，超时/HTTP/格式错误与过期响应隔离。

附带交付：五级可切换诊断日志（默认"信息"级）；系统翻译测试连接（探测 + 真实试翻）；系统翻译串行语义（并发固定 1，设置页隐藏并发/批量滑块）。最终自动化基线：`flutter analyze` 无问题，`flutter test --concurrency=1` 182 项全部通过；未签名 IPA 经 GitHub Actions macOS CI 产出（run 32572273777）并在真机完成回归。

遗留（不阻塞结项，供后续阶段参考）：通用 API 的真实网络长时稳定性观察；系统翻译更多语言组合的覆盖；iOS 连续播放的发热/内存长时观察。

### Phase 9（已跳过，2026-08-23）：系统语音识别 Adapter

状态：**已跳过，不阻塞后续开发。** 本阶段曾完成一轮完整实现（iOS Apple Speech 桥接、Windows Live Captions 原生 adapter、识别引擎设置/状态/降级接线、设置页与诊断集成，自动化测试 204 项通过），但用户实测中系统字幕引擎无法稳定产出字幕：日志确认引擎判定可用且无回退，两层进程内复现（真实 DLL → 推送事件；真实媒体 + 真实解码器 + 真实控制器 → 会话事件）却均无法复现零字幕问题；叠加 Live Captions 依赖的 UI Automation 窗口类名/AutomationId 属未文档化实现细节、字幕语言与语言文件需用户在系统侧配置、系统字幕对所有系统音频出字幕等固有约束，继续调试的成本超出收益。经用户决定跳过本阶段。

处理方式：

- 代码与本地 Release 已回退到 Phase 8 基线（版本 `0.8.0`），whisper.cpp 识别管线、翻译与字幕功能不受影响。
- 本轮全部实现封存在分支 `phase-9-system-engines-archive`，不合并主线；未来若重启（例如仅采纳 iOS Apple Speech 部分），从该分支评估，不直接沿用未经真机验收的代码。
- 后续开发从 Phase 10（视觉系统与移动端适配）继续。

原定目标（留档）：接入 iOS Speech 与 Windows Live Captions，作为独立、可关闭的系统识别 Provider；不可用时可回退 `WhisperCppSpeechRecognitionService`；验收要求关闭、未授权、语言不支持或不可用时应用清晰降级且不影响本地播放器。

### Phase 9.9：iOS 网络识别修复与流式实验

背景：Phase 8 结项后的真机遗留 bug——播放网络视频时永久卡在"正在准备播放 / 等待前两条翻译"，诊断日志显示完整缓存完成后识别解码失败：`PlatformException(AUDIO, Cannot Open, null, null)`。

#### Phase 9.9 执行记录（2026-08-24）

**根因定位**：iOS 网络识别此前必须先完整下载媒体，缓存 worker 把成品命名为 `media.media`；AVFoundation 通过文件扩展名（UTI）识别本地容器，`.media` 属未知扩展名，`AVURLAsset` 加载音轨直接报 `AVFoundationErrorDomain -11828 "Cannot Open"`。Windows 不受影响，因为其回环 HTTP 代理靠 Content-Type/Range 传输字节，扩展名无关。

已交付三项修复（提交 `f3c16d1`，13 文件，+719/-44）：

1. **完整缓存文件改用真实容器扩展名**：下载完成后嗅探文件头魔数决定扩展名（`ftyp`→mp4/mov/m4a、EBML→webm、`FLV`、`ID3`/帧同步→mp3、`RIFF`+`WAVE`→wav、`OggS`、`fLaC`、ADTS→aac），嗅探不出时退回源 URL 扩展名（如 `34461.mp4`→`.mp4`），最终兜底 `mp4`。修复后 `AVURLAsset` 可正常打开缓存文件，识别在完整缓存完成后立即开始。
2. **启动闸门韧性**：`evaluatePlaybackStart` 新增 `recognitionExpected`——解码器 error、识别缓存 failed、识别服务 unavailable 任一终态失败时，"等待前两条翻译"门槛自动放行（与既有"翻译服务不可用即放行"同一语义），播放不再永久卡死；启动超时对话框（10 秒）新增"跳过准备，直接播放"按钮（原先只有"继续等待"），任何未预见的启动阻塞用户都能手动脱困。HTTP 403 缓存失败与 Cannot Open 解码失败两条路径均被覆盖。
3. **iOS 流式识别实验开关**（设置 → 播放启动策略 → "网络识别流式读取（实验）"，仅 iOS 显示，默认关）：开启后 iOS 网络识别改走 Windows 已验证的回环代理 `startProxy()`，边下边读、有界分段缓存（256MB 上限），不再先完整下载整个视频；代理路径携带容器扩展名（`/media.mp4`，仅此模式启用，Windows 保持 `/media` 不变）以最大化 AVFoundation 格式识别成功率。三层自动回退保证最坏等于现状：代理启动失败转完整缓存；AVFoundation 打不开代理源时自动改用完整缓存重开解码器（识别会话不中断）；播放中途流式读失败沿用闸门放行。诊断日志关键词：`iOS 流式识别代理已启动（实验）`、`iOS 流式识别代理启动失败，回退完整缓存`、`iOS 流式识别解码打开失败，回退完整缓存`。

历史澄清：2026-08-19 的 `cef4890`（ATS 本地网络例外）→ `f497421`（iOS 改完整缓存）切换中，iOS 实际短暂使用过回环代理但失败原因未留档；本实验开关即验证代理路线在当前 AVFoundation 行为下是否成立的对照实验，若真机仍拒绝代理源，下一步方案为 `AVAssetResourceLoaderDelegate` 自定义 scheme 流式喂数据。

附带发现：

- 媒体交接 Referer 为广告 iframe（juicyads）地址时源站返回 403，第二次交接带真实页面 Referer 即成功——属站点行为；闸门修复后此类下载失败不再卡播放。
- 本机 `ALL_PROXY=127.0.0.1:10808` 会劫持 flutter_tester 的本地 WebSocket 握手导致全部测试加载失败，运行测试需临时去除该变量（与既有记录一致）。

自动化基线：`flutter analyze` 无问题；`flutter test --concurrency=1` 193 项全部通过（Phase 8 基线 182 项 + 本阶段新增 11 项：容器扩展名 3、代理路径 2、启动闸门策略 1、启动准备 1、iOS 流式控制器 3、设置 1）。

CI：GitHub Actions macOS 构建未签名 IPA 成功，Release `ios-unsigned-v0.8.0-32`（`AI-Video-Player-Next-com.scmenghua.aivideoplayernext-unsigned.ipa`，523.62 MB，Whisper 模型 SHA-256 校验通过）——该构建在 Phase 9.9 立项前产出，仍为 `0.8.0`。立项后版本号已按 8.0 强制规则升级为 `0.9.9`（`pubspec.yaml` 与 `AppBuildInfo` 默认值同步），后续验收构建以此为准。

状态：**未结项，待真机回归。** 验收要求：(1) 默认路径（开关关闭）播放网络视频，完整缓存完成后识别恢复出字幕，无 Cannot Open；(2) 打开实验开关重播同一视频，依据诊断日志判定流式代理成立（字幕边播边出）或自动回退完整缓存（体验不差于现状）；(3) 无论哪条路径，识别失败时播放不再卡死且可手动跳过。若流式代理被 AVFoundation 拒绝，凭日志转入 `AVAssetResourceLoaderDelegate` 方案再验证。

#### Phase 9.9 第二轮执行记录（2026-08-24）：AVAssetResourceLoader 流式方案

真机回归结果：实验开关生效、回环代理成功启动（`http://127.0.0.1:<port>/media.mp4`），但 AVFoundation 自带 HTTP 栈约 7 秒后以泛化错误 "Operation Stopped" 拒绝打开该源；三层回退与启动闸门放行均正常工作（播放未卡死，自动转完整缓存）。这正是本阶段预留的转入分支。

已交付 `AVAssetResourceLoaderDelegate` 自定义 scheme 方案：

1. **Dart 端**：`RecognitionMediaCacheWorker.customSchemeProxyUri` 把回环代理 URI 映射为 `aivpmedia://127.0.0.1:<port>/media.mp4`（host/port/path 原样保留）；`_tryIosStreamingProxySource` 把映射后地址交给解码器。Windows 透明代理路径零改动。
2. **iOS 端**：新建 `IOSMediaResourceLoader`——AVURLAsset 用自定义 scheme 创建并挂 resourceLoader delegate；每个 `AVAssetResourceLoadingRequest` 转成对同一 Dart 回环代理的 URLSession Range 请求，字节分块（≤128KB）`respond(with:)` 喂回。元数据探测用 GET bytes=0-0（不用 HEAD，保留代理缓存头部能力）；上游返回 200 时丢弃偏移前缀；超时 15s 空闲/120s 总上限；didCancel 后绝不触碰 loadingRequest；bridge stop() 先 invalidate loader 再取消 reader，seek 重开自动重建。`IOSAudioDecoderBridge` 错误富化：loadTracks 与读循环的 NSError 现在携带 domain/code/underlying 链，替代裸 "Operation Stopped"。
3. **诊断提升**：每个识别会话的前 12 条代理请求事件按信息级记录（默认日志级别即可见流式握手过程），之后回落调试级。

自动化基线：`flutter analyze` 无问题；测试套件通过（含 customSchemeProxyUri 新测试与 aivpmedia scheme 断言更新）。真机验收判据不变：(2) 开启开关播放网络视频，日志应不再出现 "Operation Stopped"，而是"识别解码器打开完成"且字幕边播边出；前 12 条上游请求事件现在应为信息级可见；若仍失败，新错误消息应含 domain/code 定位根因，随后自动回退完整缓存。

#### Phase 9.9 第三轮执行记录（2026-08-24）：字幕优先卡死修复与流式提速

真机日志（构建 20260824-065346-36）确认两项遗留问题：

**1. 字幕/翻译优先模式无字幕时永久暂停（长期遗留 bug）。** `evaluatePlaybackContent` 只要"当前位置之后没有任何字幕段"就暂停，而片头静音、片尾音乐、识别尚未覆盖的区间永远不产生字幕段，导致启动后立即冻结且无法恢复。修复为**限期等待**：内容缺失先暂停（保留"演员开口即有字幕"的核心体验），但超过 8 秒（识别游标仍在推进时延长至 16 秒）自动放行继续播放，字幕到达后门控自然收紧。用户在等待期间手动按播放立即放行（`_contentGateSuppressed` 压制门控直至内容追上）；seek 与换片重置等待时钟；等待面板显示已等待秒数。策略层新增 `recognitionProgressing`（识别 processedThrough 2 秒内前进视为存活）、`waited`、`suppressWait` 参数，纯函数可测。

**2. iOS 流式识别网速慢（TTFB 2.5–4 s 每请求）。** 日志显示每个上游 Range 请求首字节耗时 2.4–4 秒，根因有二：
- **Dart 端每请求新建 HttpClient**：`_ActiveProxyRequest` 自带 `HttpClient()`，每次解码器 Range 都付全额 TCP+TLS 握手。改为 worker 级共享 keep-alive 客户端（`maxConnectionsPerHost=4`、空闲 30s 回收），会话取消时统一关闭；被抢占的旧请求通过 `HttpClientRequest.abort()` 立即断开在途 socket，不阻塞新位置。
- **Swift 端窗口串行链接**：上一个 2MB 窗口收完才发下一个，每个窗口都重新付 TTFB。新增**半窗预取**：当前窗口交付过半字节时提前发起下一窗口，其 TTFB 与当前传输重叠；主窗口完成后"采纳"预取——已到字节缓冲回放给 reader、在途任务转正为主任务，预取先行完成也不卡链（采纳后同步驱动 advanceAfterCompletedFetch）。采纳要求预取响应为 206（保证缓冲起点正确），不可用则丢弃缓冲回退全新 beginFetch 并取消重复任务；supersedeStaleRecords/didCancel/invalidate 全部覆盖预取任务取消。

自动化基线：`flutter analyze` 无问题；`flutter test` 199 项全部通过（上轮 +6：限期等待策略 6 项；等待面板文案改为前缀匹配）。Swift 变更待 macOS CI / Xcode 编译验证。

真机验收补充判据：(3) 字幕优先模式下播放片头静音或长音乐段，最多暂停约 8 秒后应自动继续；(4) 开启流式开关后诊断日志中同一会话第 2 个及以后的"上游 Range 首字节耗时"应显著低于首个（连接复用生效），相邻窗口"上游 Range 请求已开始"时间应部分重叠于前一窗口传输期内（预取生效）。

CI 附注（2026-08-25）：本地路径测试在 macOS runner 失败为历史问题（`Uri.file` 对反斜杠字面量在 POSIX 上不产生 file scheme），已改为按宿主构造路径；iOS smoke 自 2026-08-19 起持续红灯的根因是工作流缺少 whisper.cpp 准备步骤——Runner 目标的 "Build speech_core" Xcode 脚本阶段要求 `AI_VIDEO_WHISPER_CPP_SOURCE_DIR`，缺失时 xcodebuild 在该阶段失败，Flutter 误报为 "Development Team" 签名横幅。已在 ios.yml 补齐固定源准备、引擎 precache 与显式 pod install（与 IPA 工作流一致）。验收产物：GitHub Release `windows-v0.9.9-2`（含两项修复，fe16c29）与 `ios-unsigned-v0.9.9-37`（fe16c29）。

### Phase 10：视觉系统与移动端适配

目标：完成功能稳定后的高品质 UI。

- 建立颜色、排版、间距、图标、动效、明暗主题和无障碍 token。
- 完成 Windows 工作台与手机视频优先布局，检查最小窗口和小屏文字不溢出、不重叠。
- iOS 仅为关键控件增加 Swift 原生玻璃材质增强，Flutter 外观为基础回退。
- Android 与 iOS 对同一 Dart 状态、字幕时间轴和翻译契约进行 adapter 接入。

验收：桌面/手机各自符合使用场景但业务逻辑一致；在不同窗口与设备尺寸下字幕、控制和文字均可操作。

### Phase 11：移动端原生闭环与 IPA 回归

目标：在真实 Android 与 iOS 设备完成播放、浏览器媒体交接、识别、翻译与字幕的完整闭环。

- iOS：AVAudioSession、后台状态、耳机切换、系统中断、方向、Apple Translation plugin、`WKWebView` 会话恢复和媒体交接后的生命周期管理。
- Android：媒体会话、音频焦点、权限、后台播放与设备输出。
- 两个平台构建并接入 `speech_core`，对模型大小、热量、内存和实时倍率做基准测试。
- 处理锁屏、应用切后台、内存警告、来电中断、seek、任务取消、浏览器返回播放器和播放器返回浏览器。
- **完整功能 IPA 验收包：** 生成签名的 Ad Hoc IPA 或 TestFlight 构建，在真实 iPhone 上回归本地视频、网页 MP4、HLS、会话授权测试资源、字幕、翻译、后台/前台切换、耳机与中断；每个失败项必须带回归记录和诊断。

验收：不修改 Dart 领域逻辑即可替换平台 adapter；验收 IPA 在真机稳定完成本地和受支持网络视频播放、浏览器交接与本地识别字幕。

### Phase 12：WebDAV、发布与 CI

目标：扩展剩余媒体来源，并完成可重复交付与发布前质量门。

- WebDAV 目录、凭据、媒体交接与断线恢复。
- 明确不绕过 DRM；浏览器媒体提取只支持授权的普通资源。
- 新建 Windows CI 与 macOS CI；macOS CI 负责 Xcode 构建、签名配置和按阶段产出可安装 IPA。
- **发布候选 IPA 验收包：** 在版本冻结后生成 Release Candidate IPA，通过与 Phase 11 相同的 iPhone 回归矩阵，并额外验证 WebDAV、升级安装、首次启动、隐私声明和崩溃日志符号化；通过后才可提交 TestFlight 或 App Store 审核。

验收：网络和 WebDAV 功能出错不破坏本地播放和本地识别；CI 分别报告 Windows 核心质量和 iOS 集成状态；发布候选 IPA 通过真机回归。

## 9. 测试矩阵

### 跨平台验证节奏

Windows 是日常开发和核心逻辑验证的主战场，但 Windows 通过不等于 iOS 平台适配已经正确。Dart
领域逻辑、字幕时间轴、分窗、质量门控、识别取消、翻译回填和大部分 Flutter UI 应优先在 Windows
完成回归；iOS 仍必须验证播放器 PCM 时间映射、音频会话、原生插件、模型性能、系统生命周期和真实
渲染行为。

- 从 **Phase 2** 起，每完成一个跨平台核心契约，macOS CI 都必须执行一次 iOS 编译和相关 plugin
  smoke test；Phase 2 完成后必须产出首个可安装 IPA，尽早发现签名、Swift、Flutter plugin 和 iOS SDK 集成问题。
- 从 **Phase 2** 起，使用至少一台 iPhone 回归网页视频到内置播放器的交接；Phase 3、Phase 11 和
  Phase 12 的 IPA 验收为强制门。可选的 Phase 4 不属于当前主线，也不构成强制验收门；不得以模拟器、截图或仅 macOS 编译成功替代仍在主线中的 IPA 验收。
- 从 **Phase 6** 起，使用至少一台 iPhone 对音频采集、PCM 与播放时间轴对齐、识别实时倍率、内存和
  发热进行抽样验证；不能等到移动端闭环阶段才第一次测试。
- 从 **Phase 10** 起，每个 UI 和平台 adapter 的重要变更都要在 iOS 模拟器或真机检查布局、手势、全屏、
  横竖屏和原生玻璃增强的降级行为。

目标不是在 Windows 上假设 iOS 无风险，而是把风险限制在小范围的平台 adapter 和真机行为，避免在
Phase 9 才首次发现基础集成问题。

| 能力 | Windows 本地 | CI | 真机 |
|---|---:|---:|---:|
| 内置浏览器媒体交接 | Mock/WebView2 | macOS iOS 编译与 WebKit smoke test | Phase 2 起必须；Phase 3/11/12 IPA 验收；Phase 4 可选 |
| Dart 模型、状态机、字幕时间轴 | 必须 | 必须 | 抽样 |
| 音频分窗、质量门控、session 隔离 | 必须 | 必须 | 抽样 |
| whisper.cpp 固定素材回归 | 必须 | 必须（缓存模型） | 必须抽样 |
| Apple Speech Provider | Mock | macOS/iOS 编译与 smoke test | iOS 必须 |
| Windows Live Captions Provider | Windows 11 抽样 | Windows adapter smoke test | 不适用 |
| 播放控制与换片 | 必须 | Mock/集成 | 必须；Phase 2 首个 IPA |
| Flutter UI | 必须 | 必须 | 必须抽样 |
| 翻译 Provider | 必须 | 必须 | iOS/Android 抽样 |
| Apple Translation | Mock | macOS 集成 | iOS 必须 |
| 耳机、中断、后台、方向 | 不适用 | 不适用 | Phase 11 完整功能 IPA；Phase 12 发布候选 IPA |

每份测试素材记录语言、许可、采样率、时长、背景噪声、预期文本、允许时间误差、最低可接受识别率与已知局限。测试不能只断言“有字幕”，还必须覆盖重复幻觉、跨视频串句、字幕时间轴空洞、翻译 ID 对齐与任务取消。

## 10. 性能与可靠性红线

- UI 线程不得执行同步模型推理、整轨解码、网络请求或逐行磁盘写入。
- 识别队列、PCM 缓冲和日志缓存均必须有上限。
- 识别不允许无限超前播放；失败窗口具有明确重试与跳过策略。
- partial 不得触发全量字幕历史列表刷新。
- 翻译结果必须通过明确的任务归属与时间轴关联更新字幕，不得污染当前媒体或破坏播放器控制与时间轴一致性。
- 每个异步任务有 owner、取消路径与 `sessionId`/generation 守卫。
- 测试/诊断构建在本机保留完整媒体和网络诊断，包括 URL、查询参数、请求头、Cookie、Referer、重定向、缓存路径和会话关联字段；不自动上传、不提交 Git。正式发布构建默认脱敏或省略敏感字段，并提供本机日志清理能力。

## 11. 首轮执行清单

1. 在当前仓库之外创建新的 `AIVideoPlayerNext` 目录和 GitHub 仓库。
2. 安装并验证 Flutter Windows、Visual Studio C++ Desktop workload、CMake 与 Git 工具链。
3. 创建全新 Flutter 工程，完成 `flutter analyze`、`flutter test`、`flutter build windows`。
4. 建立 Mock 驱动的播放器与字幕 Overlay，先验证 UI 和时间轴不依赖真实识别。
5. 实现 Phase 2 本地播放器，再执行 Phase 3 的 whisper.cpp 固定 WAV 技术尖峰。
6. 只有音频、识别事件、时间轴与诊断闭环通过后，才接入翻译和移动端平台能力。

首轮完成定义：Windows 上可打开本地视频，并通过独立、可诊断、可回归的流程显示至少一条本地识别字幕；任何层的失败都能定位，且不依赖当前仓库的任何文件。

#### Phase 5 执行记录（2026-08-16）

本轮按 `PLAN.md` 执行 Windows 固定音频识别核心尖峰，范围限定为：固定 WAV/PCM -> 16 kHz 单声道 Float32 PCM -> whisper.cpp/speech_core C ABI -> Dart FFI -> `RecognitionEvent`。未接入播放器实时音频、字幕 UI、翻译、移动端真实音频或 Phase 6 内容。

已完成：

- 建立 `native/speech_core`，实现 WAV/PCM 标准化、模型/会话 C ABI、识别回调、取消、生命周期、错误状态和非敏感诊断字段。
- whisper.cpp 使用仓库外固定缓存 v1.7.6、commit `a8d002cfd879315632a579e73f0148d06959de36`；没有提交第三方源码、模型或音频。
- 建立 `native/tools/speech_regression.cpp`，输出带 session、时间戳、语言、来源、采样规格、推理耗时和实时倍率的 JSONL；支持 `--threads`、`--manifest` 和 `--output`。`tool/verify_speech_regression.dart` 使用 manifest 自动比较归一化文本、语言、分段时间和诊断字段。
- 建立 Dart `WhisperCppSpeechRecognitionService`，在 worker isolate 中调用 native，映射统一 `RecognitionEvent`。Mock Provider 仍保留用于通用契约测试和依赖缺失时的明确降级，不驱动主播放器的真实字幕。
- `test_assets/speech/` 只包含 manifest 和素材准备说明，不包含未经确认授权的真实音频或模型。

验证结果：

- 默认 speech_core Release 构建通过。
- 启用 whisper.cpp 的 speech_core Release 构建通过。
- 两套构建的 CTest 均通过，结果为 `100% tests passed`。
- deterministic test model 的 CLI JSONL smoke 通过，且验证了 `--manifest`、`--language en` 和 `--threads 1`。
- `flutter analyze` 通过。
- 设置当前 PowerShell 会话的 `NO_PROXY=localhost,127.0.0.1,::1` 后，`flutter test --concurrency=1` 通过 16 项测试，其中包含 Dart FFI -> worker isolate -> native C ABI -> `RecognitionEvent` 的 focused 契约测试。
- Windows Release 构建通过。
- 真实模型回归已通过：本地 `ggml-large-v3-turbo-q5_0` 成功加载，使用项目自有的 Windows SAPI 生成英语 WAV 进行 `--language auto --threads 8` 回归，自动检测为 `en`，输出 7 个带毫秒时间戳的 final segment；耗时 50,637 ms，实时倍率 1.05725。模型、WAV、结果文件和本地路径均未进入 Git。

限制与未完成验收：

- 真实模型/英语 WAV 已通过 manifest 驱动的文本、分段时间和诊断比较，但仅覆盖一个项目自有的合成英语素材，不能据此宣布中文或多语言准确率、真实媒体鲁棒性或设备性能门槛。
- 全局 HTTP(S) 代理会使 `flutter_tester` 的本机 WebSocket 握手失败；运行 Flutter 测试前仅需在当前会话设置 `NO_PROXY=localhost,127.0.0.1,::1`，不修改用户的永久代理设置。
- 用户已完成 Phase 3 Windows 人工回归：内置浏览器媒体交接、播放器/浏览器工作区切换、二次进入浏览器和诊断日志脱敏均正常。
- Whisper 核心已在 native CLI 和 Dart FFI 测试链路启用并通过验证；主播放器已经改用真实的窗口 Whisper Provider，旧的 `MockSpeechRecognitionService` 只保留给测试和明确的降级场景。
- Phase 5 已完成验收；中文/多语言准确率、真实媒体噪声鲁棒性、iPhone 性能和主应用实时识别属于后续阶段。

#### Phase 6.5 Windows Release 启动修复（2026-08-17）

- Windows Release 首次启用 Vulkan 时出现 `0xC0000005` 内存写入错误。对照确认 CPU 模式可启动，临时移除程序目录中的 `vulkan-1.dll` 后 Vulkan 模型初始化和应用运行均稳定。
- 根因是 `media_kit` 的 ANGLE 资源携带了 2022 年旧 Vulkan loader；它会优先于显卡驱动提供的系统 loader 被加载。Windows CMake 现排除该文件，仅保留播放器需要的 EGL/GLES 资源，由系统 Vulkan runtime 提供 Whisper/ggml Vulkan loader。
- 重新构建后的 Release 包不包含 `vulkan-1.dll`。使用 `AI_VIDEO_WHISPER_BACKEND=vulkan` 的原始启动命令复测通过，日志显示 NVIDIA GeForce RTX 5060 Laptop GPU、`Vulkan0 total size` 和 `using Vulkan0 backend`，且 media_kit 硬件视频纹理仍正常创建。

#### Phase 6.5 当前记录（2026-08-17）

- Windows Vulkan + CPU fallback 子目标已完成。独立 Vulkan Release 构建、C ABI/FFI 后端状态、诊断日志、CPU fallback、真实模型回归和 Windows `0.6.5` Release 启动稳定性均已验证；Windows 不接入 CUDA 或 OpenGL 推理后端。
- 同一短音频基准中，Vulkan 与 CPU 的文本、语言和时间轴一致；该机器上的短样本 CPU 更快，因此不能把“已启用 Vulkan”误作普遍性能更快的结论。首个真实 Vulkan 推理还有明显预热成本，后续窗口应与首窗口分开观察。
- iOS Metal 已完成 macOS/Xcode Release 构建和真实 iPhone 验收：诊断日志确认实际后端为 `Metal`，GPU 为 `true`，设备为 `Apple A19 GPU`，模型加载成功并持续输出日语字幕。
- iOS 开发决策（2026-08-17，历史记录）：暂缓 Phase 6 原定的 iOS 单独验收，先补齐 Phase 6.5 的 iOS Metal/CPU fallback、speech_core 原生集成、Dart 平台装配和本地媒体 PCM 适配；随后已将 Phase 6 与 Phase 6.5 的 iOS 播放、识别、字幕时间轴和生命周期统一在真实 iPhone 上回归。
- iOS Phase 6.5 验收记录（2026-08-17）：已完成 Dart、Swift、CMake 和 Xcode 工程接入；GitHub Actions 成功构建内置 Whisper 模型的未签名 IPA。真实 iPhone 已确认 Metal、模型加载、PCM 播放时间轴、日语识别和字幕输出。
- iOS seek 回归记录（2026-08-17）：首次暂停后拖动进度曾暴露临时文件访问和 AVAssetReader 重建问题；现已通过应用内稳定媒体副本、security-scoped 访问保持、seek 错误清理和拖动结束后单次提交修复。修复后重复暂停、拖动和继续识别基本稳定。
- Phase 6.5 已结项（2026-08-17）。本阶段未包含本地媒体预读、识别/翻译提前处理和网络媒体音频预读；这些内容进入下一阶段，并继续以视频媒体时间轴裁决字幕显示。
- Phase 6.5 结项后的下一阶段优先目标是字幕准时性和网络视频识别稳定性：先修复当前支持网络视频的音频取得、时间映射和识别闭环，再对本地媒体进行受限预读、提前识别并开始翻译；字幕显示始终由视频媒体时间轴裁决。网络媒体预读须作为独立子范围设计，遵守数据可得性、会话和 DRM 边界。

#### Phase 7 Step 1 网络媒体日志诊断（2026-08-17）

- 已分析一份 Windows `0.6.5` 的测试诊断日志；原始日志保留在用户本机且不写入 Git。测试构建允许保留媒体完整地址、查询参数、Cookie、授权信息和用户内容；正式发布构建另行执行脱敏策略。
- 浏览器 `video` 元素成功发现普通 HTTPS MP4，媒体分类、浏览器交接与 `media_kit` 播放器打开均通过。音频解码器在 `opening` 状态、输出任何 PCM 之前失败，故 Whisper、质量门控、时间轴、翻译和 Overlay 均未开始，不能将其判为“Whisper 无字幕”。
- 根因已确认在 Windows Dart FFI adapter：它对浏览器交接的 HTTPS URI 调用 `Uri.toFilePath()`，抛出 `UnsupportedError`，native Media Foundation decoder 并未收到媒体 URL。现已改为本地 `file:` 传 Windows 路径、HTTP(S) 传 URL，并用单元测试覆盖两种输入和不支持 scheme。
- 已用用户允许的同类资源确认网络识别恢复，并发现打开、pause 与 seek 被网络 decoder 的同步停止等待显著拖慢。下一步将把旧 worker 的停止/回收移出 UI 调用链，并实施字幕优先的连续前瞻调度。若资源仍要求瞬态 `Referer` 才可取得音频，可在测试构建完整记录、在运行时最小范围传递；正式发布构建不得默认保留或导出该值，也不得绕过 DRM 或受保护会话。

#### Phase 7 Step 2 非阻塞 decoder 验证包（2026-08-17）

- Windows native audio decoder 已拆分为异步打开 worker 与解码 worker。`pause`/`stop` 只请求取消，不会在 UI 调用链同步等待网络 `ReadSample()` 返回；seek 通过新 decoder handle 与新 generation 建立，初始定位也在打开 worker 中执行。
- native reader、采样格式和 callback 生命周期已收紧为短锁发布：打开 worker 只在成功时发布局部 `IMFSourceReader`，解码 worker 复制本地 reader 与格式快照后才执行阻塞读取，回调元数据在锁内移交后于锁外调用。此修复不以取消领先识别或降低识别速度换取控制响应。
- 自动验证已通过：`dart analyze lib test` 无问题，`flutter test --concurrency=1` 通过 `36/36`，native Windows Release `/W4 /WX` 构建无警告、无错误，`git diff --check` 无空白错误（仅有既有 CRLF 提示）。
- 已生成 Windows `0.7.0` Release 验证构建：`APP_BUILD_TIME=2026-08-17 16:36:25 +08:00`，`APP_BUILD_ID=phase-7-nonblocking-decoder-20260817-163625`。Release 目录已确认包含应用、`ai_audio_decoder.dll`、`speech_core.dll`、Whisper 模型及 Flutter data。
- 此构建尚未替代真实网络回归。下一次测试须覆盖短视频、5 分钟和约 1 小时的普通 HTTPS 视频，重点观察打开、暂停、连续 seek、换片的 UI 响应，旧 worker 实际退出时刻，以及识别/翻译领先量是否持续而非在水位边界突发跳跃。

#### Phase 6 执行记录（2026-08-16）

本轮开始执行 `PLAN.md` 中的 Phase 6“播放器音频、分窗与背压”。范围限定为 Windows 本地媒体音频、带媒体时间的 PCM、有限识别窗口、Whisper 持久 worker、播放器生命周期、播放器字幕框和诊断状态；不扩展网络媒体、HLS、DRM、MSE、移动端真实音频或完整字幕 Overlay。

已完成：

- 建立 Windows Media Foundation Source Reader 音频 adapter。native 侧在 worker 线程读取本地媒体并输出带媒体起点、采样率、声道数、样本数和结束标记的 PCM chunk；Dart 侧通过 FFI 管理 open/start/pause/seek/stop/dispose。
- 建立 `AudioChunk`、PCM 标准化、`AudioWindowPlanner`、`RecognitionQueue` 和诊断模型。标准化目标为 16 kHz、单声道、Float32；窗口固定上限、静音跳过、EOF 尾部静音裁剪和媒体时间映射均有测试。
- 建立持久 Whisper window worker。模型在 worker isolate 中保持长生命周期，窗口按顺序识别，不为每个窗口重复加载模型。
- 建立 `RecognitionController`。播放、暂停、seek、换片、停止和 dispose 会清理或隔离旧 session；识别落后时 decoder 受队列背压暂停，队列恢复后继续。
- 主播放器和诊断页已接入识别控制器。Provider 默认从程序目录 `models\\ggml-large-v3-turbo-q5_0.bin` 加载模型，`AI_VIDEO_WHISPER_MODEL` 仅作为显式覆盖；native DLL 默认从 exe 目录加载，依赖缺失时保留可启动的明确降级状态。
- 播放器下方字幕框已经消费真实的 `RecognitionEvent`，显示 Whisper 输出的日语原文和媒体时间；没有识别结果时显示加载中、识别中、不可用或失败状态，不使用 Mock 文本冒充真实字幕。
- 诊断界面显示 Whisper 是否成功加载，并记录识别模块状态、输入窗口的起点/时长/采样数、队列深度、跳过与失败原因、推理耗时、实时倍率、输出数量和输出文本。

验证结果：

- `dart analyze lib` 和 `dart analyze test` 均通过。
- `flutter test --concurrency=1` 通过 29 项测试，包含 AudioChunk、分窗、队列、控制器 session 隔离/暂停竞态和 Whisper FFI 契约测试；新增短对白静音门控和暂停尾部窗口回归。
- `native/audio_decoder` Visual Studio 2026 Release 构建通过，生成 `ai_audio_decoder.dll` 和 `audio_decode_smoke.exe`。
- `native/speech_core` 两套 Release 构建和 CTest 通过；Windows Flutter Release 构建通过；`git diff --check` 通过。
- 用户明确允许的日语本地 MP4 已完成真实回归：native decoder 成功读取前 30 秒的 44.1 kHz 双声道 PCM，音量统计确认存在语音；仓库外 `ggml-large-v3-turbo-q5_0` 成功输出 2 个日语 final segment。媒体、PCM、完整文本和结果文件均未进入 Git。
- 修复短对白被误判为静音的问题：8 秒整窗 RMS 会把对白前后的安静部分平均进去，现以 200 ms 短帧进行门控。修复暂停时 decoder 结束标记被忽略的问题，暂停会冲刷已有尾部窗口，并允许已提交的识别完成。
- 此前 Windows Release 验收构建：版本 `0.6.0`，构建时间 `2026-08-16 22:10:04 +08:00`，构建编号 `phase-6-windows-20260816-221004`。
- Release 程序目录已包含 `ai_audio_decoder.dll`、`speech_core.dll` 和 `models\\ggml-large-v3-turbo-q5_0.bin`。模型 SHA-256 为 `394221709CD5AD1F40C46E6031CA61BCE88931E6E088C188294C6D5A55FFA7E2`；模型二进制约 574 MB，继续由普通 Git 忽略，后续应使用 Git LFS、Release Asset 或安装包分发。
- 最终播放器人工验收通过：Windows Release `0.6.0`，构建时间 `2026-08-16 23:41:28 +08:00`，构建编号 `phase-6-windows-20260816-234128`。`test.mp4` 在真实播放器中成功产生多个日语字幕事件；4 秒窗口的推理耗时约 1.73-1.81 秒，实时倍率约 0.43-0.45，没有出现队列积压。

当前限制与持续回归项：

- 真实 native decoder 和仓库外 Whisper 模型回归已经完成，识别结果已接入播放器字幕框。播放、暂停、seek、换片、停止和 dispose 的控制器行为已由自动化 fake decoder/recognizer 回归覆盖；真实播放器窗口的人工复核作为后续持续回归，不再阻塞 Phase 6 结项。
- 当前 Windows CPU 处理这段日语素材的 30 秒窗口约需 50 秒，实时倍率约 1.67；它只是当前机器的性能观察值，不能外推到其他设备。
- 模型、视频、PCM、结果和 native build 产物继续保持本地忽略，不会写入 Git。

Phase 6 结项状态（2026-08-17）：已完成。核心音频识别链路、播放器字幕接入、诊断可观察性、Windows native 构建、程序目录模型打包、自动化生命周期测试和真实日语视频解码/Whisper 回归均已完成。GPU 后端、iOS Metal、完整字幕 Overlay、翻译和字幕历史不属于 Phase 6，留待后续 Phase。

#### Phase 7 当前推进记录（2026-08-17）

- 诊断工作区已调整为三栏：左侧保留完整诊断日志，中间显示后台持续推进的 final 识别结果，右侧预留翻译结果。三栏均可独立复制和 TXT 导出，移动端可分享；识别和翻译结果按媒体时间排序，不按播放器当前位置筛选。播放器页不再显示旧的字幕结果列表，`SubtitleTimeline` 仍保留给未来 Overlay 消费。
- 后续架构已收束为当前媒体会话的 `TranscriptDocument`：Whisper 原始窗口结果先保留为诊断证据，再由时间轴整理器去重、合并并生成稳定片段；原文与译文通过稳定 `segmentId` 关联。内存文档负责 Overlay 查询，`transcript.json` 只作为会话期临时快照、导出和诊断交换格式，换片或退出后清理，不作为永久历史缓存。
- 当前诊断发现窗口级 `segment_index` 会在每个 Whisper 窗口重新从零开始，而后台识别结果仓库曾将其用作覆盖式 Map key。这会使原始输出互相覆盖，表现为本地或网络视频只显示少数条结果；这不是 Whisper 只识别一条。修复前不得把当前三栏中的原始 event 数量视为最终识别数量。
- 识别会话语义已收紧：普通 seek 只改变播放器权威时钟，不重开 decoder/session，也不请求 recognizer stop；暂停只暂停播放器，不暂停后台识别。只有换片、停止和 dispose 才建立或终止识别生命周期。
- 连续预取现在有低/高水位调度。Windows 识别 decoder 关闭 native realtime pacing，由有界队列和水位控制领先量，避免播放 10 秒时停在 30 秒、到 29 秒才突发处理到 60 秒。识别 worker、模型和队列仍为固定且有界的长期资源。
- 修正了水位游标语义：`processedThrough` 表示窗口已经完成处理，成功、静音、失败都必须推进；`recognizedThrough` 表示实际 final 字幕覆盖位置，只在有非空 final 结果时推进。这样长静音或失败段不会导致后台无界预读，同时诊断仍能区分“处理完成”和“有字幕”。
- 新增 `RecognitionMediaCacheWorker` 作为 Step 3 第一层实现。它为识别消费者创建独立 HTTP 客户端、请求头和 session 临时目录，优先顺序 Range 下载，Range 不可用时退回一次顺序下载；缓存有字节数、分段数、连续下载游标和取消边界。
- 当前缓存 worker 只在完整副本落盘后交给平台 decoder。Media Foundation 尚未接入可边下载边读取的分段消费接口，因此本轮不能宣称“独立缓存消费者”完整完成，也未改变现有网络 decoder 的真实回归路径。

验证状态：`D:\Software\flutter\bin\cache\dart-sdk\bin\dart.exe analyze lib test` 已通过；`git diff --check` 无空白错误。两次设置 `NO_PROXY=localhost,127.0.0.1,::1` 的 Flutter 定向测试均在启动后超过 90 秒无 runner 输出，已停止，完整 Flutter 测试和 Windows Release 构建暂不能标记为本轮通过。新增缓存 worker 的 Flutter 测试文件已加入，待 Flutter runner 恢复后执行。

#### Phase 7 网络代理真实回归与局部回退（2026-08-18）

- `phase-7-network-segmented-proxy-warmup` 的真实大网络视频验收失败：识别 decoder 打开、首个 PCM 和首条字幕均比透明代理基线明显变慢，但 Whisper 对首个约 4 秒窗口的推理仅约 `80ms`，因此不是 GPU 或 Whisper 算力问题。
- 日志确认容器头部预热在取得首字节前即被真实 decoder 请求取消，既没有实际提供容器索引，又额外建立了竞争连接；同时默认将 Media Foundation 的开放 `Range: bytes=0-` 重写为 2 MB 上游分段，改变了其可观察到的 MP4 流式读取语义。
- 不回退已完成的 Phase 7 能力。网络播放器与识别器继续保持独立消费者，授权上下文、会话隔离、seek 目标优先、字幕文档和三栏诊断均保留；仅将默认网络读取恢复为透明流式 loopback 代理，decoder 的 Range、上游 Range、状态码和 Content-Range 均记录到测试日志。
- 分段上游读取和容器头尾预热保留为显式实验开关，不能再作为默认策略，须在真实站点上单独证明首 PCM、首字幕和长时稳定性均优于透明流式代理后才可重新启用。
- 自动验证：`dart analyze lib test` 无问题，`flutter test --concurrency=1` 通过 `72/72`。下一包仍需使用相同大网络视频，比较“识别解码器打开完成”“首个 PCM 已到达”“首条字幕已识别”和“上游实际 Range 已响应”。

## 2026-08-18 回退基线与工作冻结

- 已恢复并确认 `phase-7-network-proxy-full-prefetch-20260817-234000` 为当前网络行为基线：短视频应立即响应，长网络视频允许短暂落后后追赶。
- 其后的网络代理、分段缓存、容器预热与 seek 性能实验不视为已验收源码，暂时冻结，不再与当前翻译工作交叉修改。
- 后续网络诊断必须从这份已验收二进制和重新设计的生命周期汇总日志开始；当前优先完成 Step 5 翻译 MVP。

## 未来 1.x 候选优化（不纳入当前 Phase）

长距离前跳时，当前 0.x 的默认方案仍是一个持久、有限并发的 Whisper 调度器：播放器立即跳转；识别网络缓存把新目标区域的实际 Range 请求提升为最高优先级；目标区域覆盖后再回填历史缺口。不复用播放器的 reader。

待 1.x 正式版之后，只有实测证明单链路在特定网络下仍无法在短超时内取得目标区域的首个 PCM，且网络、内存、GPU/显存预算均有余量并且用户已经停止连续拖动时，才可评估短生命周期的“优先识别 lane”：

- 该 lane 必须拥有自己的 priority decoder 和 priority network/cache lane，只共享媒体 URL 与合法的授权上下文；不得直接读取或复用播放器的 reader。
- 原始结果统一汇入 `TranscriptDocument`，按媒体时间、文本重叠与稳定 `segmentId` 去重，不能产生两套竞争的字幕时间轴。
- 默认仍只有一个共享且有界的 Whisper 调度器。只有设备实测确认 GPU 与显存有余量时，才允许创建第二个模型 context 并行推理。
- 目标区域达到可显示覆盖并领先既有链路超过阈值后，优先 lane 必须停止或接管，既有链路降为历史缺口回填，避免长期双重推理和重复下载。

这是正式 1.x 之后的候选优化方向，当前不实现，也不写入 `PLAN.md` 的 0.x Phase。
## 2026-08-18 本地翻译模型选择更正（历史记录）

- Gemma 4 本地 LLM 目标更正为 `google/gemma-4-E2B-it-qat-mobile-transformers`。
- 该仓库是面向移动硬件的 QAT `wNa8o8` 版本，不能按原始 BF16 Gemma 权重的加载方式处理；需要 mobile-transformers 兼容的原生推理运行时。
- 当前工程仍未下载 NLLB 或 Gemma 权重，Windows Release/未来 IPA 也尚未包含翻译模型。
- 当前只有模型选择、目录约定和能力检测代码；翻译模型加载器及实际推理 runtime 尚未接入。现有 `speech_core` 只负责 Whisper，不能加载 NLLB 或 Gemma。

### 2026-08-18 NLLB runtime 技术尖峰执行记录

- NLLB 先采用独立的 ONNX Runtime 路线，native 模块为 `native/translation_core`，与 Whisper 的 ggml/`speech_core` 完全分离。
- C ABI 已建立并通过 Windows MinGW 编译及 CTest；修复了 C++ 中枚举类型与查询函数重名的问题，并增加 `manifest.json`、SentencePiece tokenizer、encoder、decoder 和 decoder-with-past 的包完整性校验。
- Flutter Windows 已接入 `translation_core.dll` 探测；当前只报告准确的资源/runtime 状态，真实 NLLB 翻译仍明确显示为未实现。
- 新增 `native/translation_core/tools/New-NllbManifest.ps1`，为模型文件生成 SHA-256 manifest；新增 iOS 静态库构建脚本，要求外部提供固定版本的 ONNX Runtime。
- 当前尚未下载 NLLB 权重、SentencePiece 或 ONNX Runtime 开发包；本机 Python 环境缺少 PyTorch、Transformers、ONNX、ONNX Runtime 和 SentencePiece。其他软件目录中的 ORT DLL 未被复用。
- 验证：Dart `analyze lib test` 通过；native CTest `1/1` 通过；Flutter 定向测试启动后超过 90 秒无 runner 输出，已停止，不能标记为 Flutter 测试通过。官方 Hugging Face/GitHub HTTPS 请求还受到本机 SSL 连接失败影响。

## 2026-08-18 Gemma + LiteRT-LM 路线核验（当前结论）

- 本轮通过本机代理 `http://127.0.0.1:10808` 访问并核验了 Google AI Edge LiteRT-LM 官方 GitHub 资料和 Hugging Face 模型仓库元数据。
- LiteRT-LM 是 Google 官方端侧 LLM runtime，README 明确列出 Android、iOS、Web、Desktop 和 IoT；Windows 原生 CLI 支持 CPU/GPU，C++ API 为 Stable，Swift 原生 iOS/macOS API 为 Early Preview，Flutter API 标为 Community。
- 原始 Hugging Face 仓库 `google/gemma-4-E2B-it-qat-mobile-transformers` 是公开的 Apache-2.0 `wNa8o8` 移动 QAT 权重，包含 `model.safetensors`，不能据此假设 LiteRT-LM 或任意通用 loader 能直接读取。
- 已确认官方/社区转换部署仓库 `litert-community/gemma-4-E2B-it-litert-lm`：公开、Apache-2.0，提供 `gemma-4-E2B-it.litertlm`、GPU/Desktop/Web 等变体，模型卡明确说明这些文件供 LiteRT-LM 使用，并列出 iOS、Desktop、Android、IoT、Web 部署方向。
- LiteRT-LM 模型卡给出的文本模型磁盘文件约 2.58GB，文本运行内存约 0.8GB 起，实际设备内存仍需以 spike 测量；不能只用参数量推断应用包和峰值内存。
- 因此本地翻译主候选切换为 `Gemma 4 E2B IT + LiteRT-LM`。现有 NLLB ONNX Runtime/手写 decoder 已从源码和应用接入中移除；后续如需 NLLB，优先重新评估 CTranslate2，不再恢复或扩展手写 decoder。
- 当前尚未宣称 Gemma 可用。下一步固定为：Windows LiteRT-LM C++/C API 加载和文本 smoke test；iOS Swift/native 真机加载和文本 smoke test；两端通过后再接 Flutter bridge、翻译队列和模型安装。
