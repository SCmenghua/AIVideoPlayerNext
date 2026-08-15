# AI Video Player Next - 独立项目开发路线

> **项目性质：全新项目。** 本文定义一个新的仓库和新的工程，不是当前仓库的 Phase 10，也不迁移、调用、复制或依赖当前仓库中的任何源码、资源、配置、CI、文档、测试素材或构建产物。
>
> 开发阶段仍统一使用 `Phase` 编号，从 `Phase 1` 开始。新仓库独立初始化 Git 历史、许可证、目录、依赖锁定、测试素材和 CI。

## 1. 产品方向

目标是制作一个以手机为最终交付形态、但能在 Windows PC 上高效编译、运行、调试和回归测试的视频播放器。

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
2. `final` 原文不等待翻译；翻译慢、失败或取消都不能阻塞播放器与原文字幕。
3. 所有异步结果必须验证 `sessionId`，旧视频和旧 seek 的结果不能污染当前媒体。
4. 识别游标有上限与失败策略，既不无限超前，也不因单个窗口失败永久卡死。
5. UI、音频解码、模型推理、翻译、数据库和文件日志具有明确线程或 Isolate 边界。
6. 任何“没有字幕”的问题都能判定发生在音频、分窗、识别、质量门控、时间轴、翻译或 Overlay 的哪一层。

## 8. Phase 路线

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
- **待人工和真机验收：** Windows 需手动检查浏览器导航、普通 MP4/HLS 交接、播放器返回浏览器以及 `blob:` 提示。第二个 Development/Ad Hoc IPA 仍必须在 macOS/Xcode 上生成，并在真实 iPhone 上验证普通 MP4、页面 `<video>`、重定向、返回浏览器、不支持提示，以及受支持资源绝不进入 iOS 系统网页播放器；此 IPA 门槛未通过前，Phase 3 不视为完成。
- **iOS 白屏修正（2026-08-15）：** 补充 `media_kit_libs_ios_video`，并为 iOS 工程加入 CocoaPods 集成，使 `Mpv.framework/Mpv` 会随未签名 IPA 一起嵌入。未签名 IPA Action 会预缓存 iOS Flutter engine、执行 `pod install`，并在打包前硬性检查播放器 framework；缺少 framework 时构建直接失败，不再生成可下载但启动白屏的包。应用启动也增加中文诊断页，原生播放器初始化异常会显示错误信息而不是只有白屏。
- **Windows 验收修正（2026-08-15）：** 浏览器服务改为随浏览器页面创建和自动释放，避免退出后再次进入复用已释放的 WebView2 控制器。页面脚本在文档创建和完成加载后均会注入，并仅在发现 HTTP(S) 真实媒体地址时阻止网页播放并交接；来自已确认 `<video>` 元素、但 URL 没有文件扩展名的 HTTP(S) 媒体也可交接。`blob:`/MSE 页面不再被阻断，会继续在内置浏览器中按网站原逻辑播放，同时显示无法由内置播放器接管的中文原因。Bilibili 等以 MSE/`blob:` 或 DRM 为主的视频站点不能合法交接到内置播放器，此限制符合项目不绕过 DRM 的原则。
- **工作台交互修正（2026-08-15）：** 浏览器首次打开后作为根工作台中的持久工作区保留，并通过 `IndexedStack` 在播放器与浏览器之间切换；浏览器媒体交接后直接打开并播放主播放器，然后选中“播放器”工作区。已移除浏览器专用播放页、左上角返回按钮及其异步销毁路径，从而避免返回时同时销毁页面、WebView 与播放控制器导致的崩溃。交接播放复用主播放器完整控件，包括进度、前进/后退 10 秒、暂停/继续、倍速与音量调节；选择“内置浏览器”即可恢复原网页会话。
- **iPhone 本地文件与浏览器交接修正（2026-08-15）：** iOS 文件选择器补充 `public.movie` Uniform Type Identifier；此前仅声明文件扩展名会被 iOS `file_selector` 实现拒绝，导致“文件”中没有可选视频或选择调用失败。该选择器使用 `UIDocumentPicker` 的导入模式，系统会将选中的文件导入应用可访问的沙盒，不需要照片权限。选择过程的读取异常会显示中文提示。`WKWebView` 的媒体桥接改为在页面开始和完成时均安装，除了 `<video>` 本身，也会捕获视频画面范围内及带“播放”语义的自绘播放控件；它会等待网页完成真实 HTTP(S) 媒体地址的解析后再暂停网页视频并交接，支持相对地址。`blob:`、MSE、DRM 和其他无法取得真实地址的资源仍不绕过，只给出中文无法交接提示并保持网页路径。
- **iOS 播放与全屏交接强化（2026-08-15）：** iOS 通过 `WKWebView` 的原生 `WKUserScript` 在文档创建阶段、且覆盖 iframe 地注入媒体桥接；页面回调注入保留为回退。桥接会拦截普通网页视频的 `play()`、`requestFullscreen()`、`webkitEnterFullscreen()`、原生全屏事件以及含“播放/全屏”语义的自绘控件。发现真实 HTTP(S) 媒体地址时，阻止网页和 iOS 系统播放器路径并切换到应用播放器工作区；`blob:`、MSE、DRM 或无法获得真实媒体地址的页面会阻止全屏接管并显示中文不支持提示，不绕过网页保护。应用播放器新增自身的“进入全屏”按钮：全屏在 Flutter 路由内完成，提供退出全屏、播放/暂停、进度和音量控制，不调用 Safari、WKWebView 或 iOS 系统网页播放器。进入全屏时主工作区会卸载同一视频表面，避免同一原生播放器控制器被两个视图同时占用。
- **本次 iPhone IPA 验收：** 对自有或明确授权的普通 MP4/HLS 测试页，分别点击网页播放、自绘播放和网页全屏，均应切换到应用“播放器”工作区，且不出现 Safari 或 iOS 系统网页播放器；在应用播放器点击“进入全屏”后应横屏全屏，退出后仍可继续播放并可切回原浏览器会话。再验证 `blob:`/MSE/DRM 页面显示中文无法接管提示且不会进入系统全屏播放器。该验收不要求、也不能证明 Bilibili 等受 MSE/DRM 保护站点可被内置播放器接管。
- **首次点击交接修正（2026-08-15）：** 用户第一次点击播放后，桥接会在点击处理器返回后的 40ms、120ms、250ms、500ms、900ms、1.5s、2.5s 和 4s 重新检查已选视频及替换后的视频元素；网页不再因为初始源尚未就绪而只在浏览器内播放，广告源仍按广告容器和 URL 标记留在网页内。

### Phase 4：网络媒体、HLS 与浏览器会话交接

目标：让内置播放器可靠承接网络媒体和浏览器已有的临时会话，不泄露认证数据。

- 支持 HTTP 视频、HLS、媒体重定向、网络缓冲、播放错误和重试状态。
- 浏览器登录后，将当前站点、当前媒体请求所必需的 Cookie 和安全请求头按最小范围、最短生命周期交给播放器；不得写入日志、诊断导出或默认长期存储。
- 建立本项目自有、许可清晰的测试站点或测试页面，覆盖直链 MP4、HLS、重定向、Cookie 会话、失效授权和不支持资源。
- 明确 Cookie、跨域请求头、登录过期、播放器返回浏览器和清理临时授权状态的生命周期。
- **第三个 IPA 验收包：** 在真实 iPhone 上从内置浏览器完成 HLS、重定向媒体和需会话 Cookie 的授权测试资源交接；验证登录信息不出现在应用日志/导出中，授权失效时显示中文错误并能返回网页重试。

验收：网络媒体故障不破坏本地播放；真机 IPA 可将授权测试资源交接给内置播放器，并在关闭播放器后恢复对应浏览器会话。

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

### Phase 7：字幕时间轴、Overlay 与诊断

目标：让字幕结果准确显示且可定位问题。

- 完成纯 Dart `SubtitleTimeline` 与充分单元测试。
- 实现 final-first、partial 预览、session 隔离、翻译按 ID 回填。
- 实现播放器内字幕 Overlay；桌面端可打开独立透明置顶字幕窗口，支持点击穿透作为可选能力。
- 字幕字体、字号、颜色、背景透明度、位置与显示句数可配置。
- 诊断页提供音频窗口、识别事件、门控原因、当前队列和时间轴命中记录。

验收：每个 final 段都能追溯其音频窗口；每个未显示段都能判断丢失层级。

### Phase 8：翻译 Provider 与历史管理

目标：将翻译和字幕生命周期彻底解耦。

- `MockTranslationService`、离线 Windows Provider、HTTP Provider 的统一实现与错误模型。
- 明确 Provider 的本地/云端属性、网络状态、超时、取消、API Key 存储和隐私说明。
- SQLite 保存 final 原文、译文、语言、时间与来源；支持搜索、复制和 CSV/JSONL 导出。
- 增加可选“最近字幕日志卡片”，服务于上下文浏览，不直接驱动字幕显示。

验收：任一翻译 Provider 超时、失败或被取消时，原文仍按播放时间显示，历史不会重复或串片。

### Phase 9：系统语音识别 Adapter

目标：接入 iOS Speech 与 Windows Live Captions，作为独立、可关闭的系统识别 Provider。

- iOS：实现 `AppleSpeechRecognitionService`，使用 `SFSpeechRecognizer` 识别本应用取得的音频；
  检查授权、设备端识别可用性、语言支持和联网要求，并将系统 partial/final 映射为
  `RecognitionEvent`。
- Windows：仅在 Windows 11 支持 Live Captions 的环境中启用 `WindowsLiveCaptionsService`；明确
  用户配置、可用性、时间精度和语言限制，不将它伪装成播放器精确时间轴来源。
- 两种系统 Provider 都必须可以在设置中选择、关闭、显示隐私/网络状态，并在不可用时切回
  `WhisperCppSpeechRecognitionService`。
- 使用 Windows Live Captions 快速验证翻译 Provider、透明 Overlay、历史和导出工作流；不影响
  whisper.cpp 核心、播放器 PCM 路径或 Android 功能。

验收：关闭、未授权、语言不支持或不可用时，应用清晰降级且不影响本地播放器；适配层可独立测试和
禁用，系统 Provider 输出不会污染 `whisper.cpp` 的回归结果。

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
- 从 **Phase 2** 起，使用至少一台 iPhone 回归网页视频到内置播放器的交接；Phase 3、Phase 4、Phase 11 和
  Phase 12 的 IPA 验收为强制门，不得以模拟器、截图或仅 macOS 编译成功替代。
- 从 **Phase 6** 起，使用至少一台 iPhone 对音频采集、PCM 与播放时间轴对齐、识别实时倍率、内存和
  发热进行抽样验证；不能等到移动端闭环阶段才第一次测试。
- 从 **Phase 10** 起，每个 UI 和平台 adapter 的重要变更都要在 iOS 模拟器或真机检查布局、手势、全屏、
  横竖屏和原生玻璃增强的降级行为。

目标不是在 Windows 上假设 iOS 无风险，而是把风险限制在小范围的平台 adapter 和真机行为，避免在
Phase 9 才首次发现基础集成问题。

| 能力 | Windows 本地 | CI | 真机 |
|---|---:|---:|---:|
| 内置浏览器媒体交接 | Mock/WebView2 | macOS iOS 编译与 WebKit smoke test | Phase 2 起必须；Phase 3/4/11/12 IPA 验收 |
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
- 翻译不得阻塞原文字幕、播放器控制或时间轴更新。
- 每个异步任务有 owner、取消路径与 `sessionId`/generation 守卫。
- 默认日志轻量，详细诊断由用户主动开启；本地媒体和音频默认不上传。

## 11. 首轮执行清单

1. 在当前仓库之外创建新的 `AIVideoPlayerNext` 目录和 GitHub 仓库。
2. 安装并验证 Flutter Windows、Visual Studio C++ Desktop workload、CMake 与 Git 工具链。
3. 创建全新 Flutter 工程，完成 `flutter analyze`、`flutter test`、`flutter build windows`。
4. 建立 Mock 驱动的播放器与字幕 Overlay，先验证 UI 和时间轴不依赖真实识别。
5. 实现 Phase 2 本地播放器，再执行 Phase 3 的 whisper.cpp 固定 WAV 技术尖峰。
6. 只有音频、识别事件、时间轴与诊断闭环通过后，才接入翻译和移动端平台能力。

首轮完成定义：Windows 上可打开本地视频，并通过独立、可诊断、可回归的流程显示至少一条本地识别字幕；任何层的失败都能定位，且不依赖当前仓库的任何文件。
