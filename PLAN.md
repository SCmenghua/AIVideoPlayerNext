# AIVideoPlayerNext 当前阶段执行计划

> 本文件是当前 Phase 的执行计划。每个 Phase 开始时，清空本文件并重新填充为该阶段的计划；阶段完成后保留最终状态，开始下一阶段时再整体替换。
>
> 当前项目：`AIVideoPlayerNext`
> 当前阶段：`Phase 6.5`
> 计划状态：进行中（Windows Vulkan + CPU fallback 已完成；等待 iOS Metal 验证）
> 软件版本目标：`0.6.5`
> 更新日期：2026-08-17

## 1. 阶段定位

### Phase 6.5：Whisper GPU 后端与平台加速

Phase 6 已经完成 Windows 本地视频音频解码、窗口化识别、有限队列、播放器字幕框和真实日语视频回归。Phase 6.5 专门完成 Windows 的 Whisper/whisper.cpp 原生推理后端：使用 Vulkan，并建立可验证的 CPU fallback。

本阶段不重新设计 Phase 6 的音频、分窗、队列和字幕事件契约，而是让相同的输入窗口经过不同硬件后端完成识别，并把实际运行结果完整暴露给诊断页和日志。

目标链路：

```text
AudioWindow / RecognitionEvent
  -> Whisper backend selector
  -> Vulkan (Windows) / CPU fallback
  -> actual backend + device status
  -> recognition result + diagnostics
```

## 2. 已知前提

- Phase 6 已完成，当前应用版本基线为 `0.6.0`；Phase 6.5 的目标版本为 `0.6.5`。
- Phase 6 已验证 `ggml-large-v3-turbo-q5_0.bin` 可以加载，并能对用户提供的日语本地 MP4 产生日语 `final RecognitionEvent`。
- 当前 `native/speech_core/src/speech_core.cpp` 仍将 GPU 使用关闭，历史实现包含 `params.use_gpu = false`；不能把现有 CPU 构建误认为 GPU 构建。
- whisper.cpp 固定使用 v1.7.6，commit 为 `a8d002cfd879315632a579e73f0148d06959de36`；Phase 6 的 CPU 回归结果必须保留，作为 GPU 对比基线。
- 当前已知 Windows 设备包括 `NVIDIA GeForce RTX 5060 Laptop GPU` 和 `AMD Radeon(TM) 610M`；已知 Vulkan Instance Version 为 `1.4.321`。这些信息需要通过运行时实际查询再次确认，不能写死为验收结果。
- Windows Vulkan 依赖系统 Vulkan loader、显卡驱动和 whisper.cpp/ggml Vulkan 构建；Vulkan SDK、驱动文件和开发机绝对路径不进入仓库。
- iOS Metal 必须在 macOS/Xcode 环境构建，并在真实 iPhone 上验证；Windows 环境不能宣称 iOS Metal 已编译或 IPA 已验证。模拟器测试不能替代真实 iPhone GPU 验收。
- 模型继续放在程序目录的 `models/` 或受控发布资产中。模型、视频、PCM、结果 JSONL 和 native 构建产物不提交普通 Git。
- 用户的 HTTP(S) 代理不应影响本地 Flutter 测试；运行 Flutter 测试时继续对当前会话设置 `NO_PROXY=localhost,127.0.0.1,::1`。

## 3. 本阶段完成定义

Phase 6.5 的 Windows 子目标在以下条件全部满足后算完成；整个 Phase 6.5 仍必须追加 iOS Metal 真机验证：

1. Windows 建立独立的 whisper.cpp/ggml Vulkan Release 构建，且不破坏已经通过回归的 CPU 构建。
2. Windows 在支持 Vulkan 的真实设备上，用真实模型和固定音频或本地视频完成识别；日志能够证明实际后端为 `Vulkan`，并显示实际 GPU 设备名。
3. Windows 在 Vulkan loader 缺失、设备不兼容、初始化失败或运行时错误时，可以明确回退到 CPU，或显示明确的不可用状态；不能伪造 GPU 成功。
4. C ABI 和 Dart FFI 能稳定查询请求后端、实际后端、GPU 状态、设备名、模型状态和回退原因；增加状态不得破坏 Phase 6 的现有 ABI 使用者。
5. 诊断页和导出日志显示 Whisper 是否加载、请求后端、实际后端、设备、GPU 是否启用、回退原因、输入窗口、输出文本/数量、推理耗时和实时倍率。
6. 真实识别结果仍进入播放器下方字幕框，播放、暂停、seek、换片、停止和 dispose 的 session 隔离不受后端切换影响。
7. CPU 与 GPU 对同一模型、同一音频窗口、同一语言参数的结果、时间轴和失败语义可比较；性能记录包含加载耗时、推理耗时和实时倍率。
8. Flutter 分析和测试、Windows native 构建与 CTest、Windows Release smoke 均有记录。
9. 版本、构建时间、构建编号均符合 `NEW.md` 的强制规则：版本为 `0.6.5`，构建信息是真实值且可在诊断页和导出日志中确认。
10. iOS 在 macOS/Xcode 上完成 Metal 原生构建，并在真实 iPhone 上确认实际后端为 `Metal` 或明确的 CPU fallback；未完成时，Phase 6.5 整体不得结项。

## 4. 范围边界

### 本阶段包含

- whisper.cpp/ggml 的 Windows Vulkan 后端构建和运行时选择。
- CPU、Vulkan、不可用状态的统一后端状态契约。
- GPU 设备名称、实际后端、初始化错误、回退原因和性能指标的诊断记录。
- Windows 的模型加载、native 动态库打包和路径检查。
- 真实模型的 CPU/GPU 对照回归和固定输入性能记录。
- GPU 初始化失败、驱动异常、内存不足、取消和生命周期错误的回退测试。
- `0.6.5` 版本注入、构建标识、构建脚本和相关文档更新。

### 本阶段不包含

- 重做 `AudioWindowPlanner`、`RecognitionQueue`、`RecognitionController` 或 `SubtitleTimeline` 的产品契约。
- 完整字幕 Overlay、字幕样式、翻译 Provider、字幕历史和导出增强；这些仍按 Phase 7/8 推进。
- HLS、MSE、DRM、blob URL、Cookie/授权头提取和网络媒体音频抓取。
- 自行提交 Vulkan SDK、显卡驱动、Metal SDK、模型或测试视频。
- 以编译成功、DLL 存在或请求参数为依据宣称 GPU 已经运行。
- 在 Windows 上模拟 iOS Metal 验收，或用 iOS Simulator 代替真实 iPhone GPU 验收。

## 5. 设计原则

### 5.1 请求后端不等于实际后端

应用可以请求 `Vulkan` 或 `Metal`，但只有原生运行时成功初始化设备并完成至少一个识别窗口后，才能把实际后端记为 GPU 后端。诊断必须同时展示：

```text
requestedBackend: Vulkan | Metal | CPU | Auto
actualBackend: Vulkan | Metal | CPU | Unavailable
gpuEnabled: true | false
deviceName: 脱敏后的设备名称
fallbackReason: none | loaderMissing | deviceUnavailable | initFailed | runtimeFailed | memoryError
```

### 5.2 兼容现有 ABI

优先增加独立的状态查询函数和版本化能力查询，而不是直接改变已有结构体布局。所有返回字符串都必须有明确的所有权和释放规则；未知字段、未知枚举和未来版本必须安全处理。旧的 CPU 调用方继续可用。

### 5.3 GPU 失败必须可降级

Vulkan 或 Metal 初始化失败时，先记录失败阶段和错误码，再按配置回退 CPU。回退后产生的字幕必须标记实际后端为 CPU，不能继续显示上一次 GPU 状态。CPU 也不可用时，识别模块进入 `Unavailable`，播放器仍可以继续播放。

### 5.4 相同输入才能比较性能

CPU、Vulkan、Metal 对照必须使用相同模型文件、相同 PCM、相同窗口边界、相同语言、相同线程/批量配置和相同输出规则。性能记录不能改变字幕文本的质量门控，也不能用识别完成时间代替媒体时间。

### 5.5 诊断全面但不泄露内容

记录模块初始化、输入窗口、native 调用、输出段数、文本结果、推理耗时、队列状态和错误原因；继续脱敏本地完整路径、Cookie、授权头和网页请求内容。日志记录需要有稳定事件名和字段，便于用户复制后定位问题。

## 6. 执行步骤

### Step 1：盘点构建工具链和 GPU 运行环境

状态：`已完成（Windows；iOS 前置条件待 macOS 环境确认）`

任务：

- 检查 Vulkan loader、Vulkan headers、`vulkan-1.lib`、`glslc`/shader 编译工具和 Visual Studio 构建工具是否可用。
- 记录 `vulkaninfo --summary` 的实例版本、设备名、驱动版本、队列能力和显存信息；记录结果作为环境快照，不把它写死到代码中。
- 检查 NVIDIA 和 AMD 设备是否分别可见，确认实际运行测试时使用的设备选择规则。
- 盘点 whisper.cpp v1.7.6 中 `GGML_VULKAN` 的 CMake 选项、依赖和动态库要求。
- 确认 iOS Metal 所需的 macOS、Xcode、CocoaPods、部署目标和真实 iPhone 测试条件；如果当前没有 macOS/真机，只记录阻塞项，不伪造通过。
- 检查当前 CPU 构建目录、Vulkan 构建目录和 iOS 构建产物的隔离规则。

输出物：Windows GPU 环境快照、iOS 构建前置条件清单、依赖和许可证记录。

完成条件：可以明确回答 Windows 是否具备 Vulkan 构建和运行条件；可以明确回答 iOS Metal 是否已有可验证的 macOS/Xcode/真机条件。

### Step 2：定义后端能力与 C ABI/FFI 契约

状态：`已完成（Windows ABI/FFI）`

任务：

- 定义统一的 backend enum，至少包含 `UNKNOWN`、`CPU`、`VULKAN`、`METAL` 和 `UNAVAILABLE`。
- 定义 requested backend、actual backend、GPU enabled、device name、driver/API 摘要、模型 loaded、fallback reason 和 error code。
- 增加能力查询、初始化结果查询和最近一次回退原因查询；避免通过 Dart 猜测 DLL 或文件名判断 GPU 状态。
- 优先新增独立 C 函数，或使用明确的 ABI 版本号和大小字段扩展结构体，避免破坏已有 CPU ABI。
- 定义字符串缓冲区、释放函数、枚举未知值和错误生命周期；为 Windows 和 iOS 保持同一语义。
- 在 Dart FFI 层建立不可变 `WhisperBackendStatus` 和转换测试。

输出物：native 后端状态头文件、实现、Dart FFI 类型和契约测试。

完成条件：不启动识别也能查询能力；识别启动后能查询实际后端；旧 Phase 6 CPU 测试仍能编译和通过。

### Step 3：建立独立 Windows Vulkan 构建

状态：`已完成（Windows）`

任务：

- 创建独立构建目录 `native/speech_core/build-whisper-vulkan`，不污染 `build-vs`、`build-whisper-optimized` 或既有 CPU 产物。
- 使用 `SPEECH_CORE_WITH_WHISPER=ON`、`GGML_VULKAN=ON`、`GGML_NATIVE=ON`、`GGML_OPENMP=ON` 配置 Release 构建。
- 确认 Vulkan 相关符号、shader 资源、运行时 DLL 和 `speech_core` 导出函数均能被正确打包。
- 保持模型路径由程序目录或显式配置提供，不在 CMake 或源码写入用户机器绝对路径。
- 让 CPU 构建和 Vulkan 构建可并行存在，并分别运行 CTest。
- 核对 Vulkan/whisper.cpp/ggml 的许可证和分发说明，不提交 SDK 或驱动文件。

输出物：Windows Vulkan Release 构建、构建配置记录、native CTest 结果和 DLL 依赖检查。

完成条件：Vulkan 版本可加载真实模型；但只有运行时完成设备初始化和识别后，才进入 GPU 功能验收。

### Step 4：实现 Windows Vulkan 运行时选择与 CPU fallback

状态：`部分完成（Windows 代码与 CPU 回退路径；异常注入待验收）`

任务：

- 增加 `Auto`/`Vulkan`/`CPU` 的配置选择，并明确默认策略。
- Vulkan 请求时初始化 ggml Vulkan 后端，读取真实设备信息并写入后端状态。
- Vulkan loader 缺失、驱动不兼容、设备初始化失败、模型显存不足或首个窗口运行失败时，记录错误码和阶段。
- 按策略释放失败的 GPU context 并建立 CPU context；回退成功后更新实际后端为 `CPU`。
- 回退期间不得重复加载模型、泄漏 native handle 或向 UI 发送无效的旧状态。
- 验证多个 GPU、无 GPU、禁用 GPU、缺失 loader、错误 DLL 和模型缺失场景。

输出物：Windows backend selector、fallback 实现、错误码映射和运行时状态测试。

完成条件：支持 Vulkan 的机器实际使用 Vulkan；人为禁用或破坏 Vulkan 时应用能明确回退 CPU 或显示不可用，不崩溃、不伪造字幕来源。

### Step 5：接入 Dart Provider、诊断页和完整日志

状态：`部分完成（Windows 代码、自动化测试和 Release 已验证；播放器人工回归待复测）`

任务：

- 将后端选择和状态接入现有 Whisper Provider 工厂，不在播放器 UI 直接判断平台或 DLL。
- 诊断页显示 Whisper 是否成功加载、请求后端、实际后端、GPU 是否启用、设备名、模型标识、回退原因和当前状态。
- 识别日志记录初始化开始/完成、能力查询、输入窗口编号/起点/时长/样本数、native 调用开始/完成、输出段数/文本、推理耗时和实时倍率。
- 记录队列深度、跳过原因、取消、异常和恢复；确保重复事件不会无限刷屏，可保留计数与最近记录。
- 播放器下方字幕框继续只消费真实 `RecognitionEvent`，Mock 或 fallback 状态必须可区分。
- 对本地路径、模型路径、PCM、Cookie 和授权信息继续脱敏。

输出物：诊断状态模型、诊断页字段、日志事件和 Provider 集成测试。

完成条件：用户仅凭诊断页和导出日志即可判断识别模块是否加载、使用何种后端、是否发生 CPU 回退，以及每个窗口输入输出情况。

### Step 6：完成 iOS Metal 原生路径

状态：`未开始`

任务：

- 在 macOS/Xcode 环境配置 `GGML_METAL=ON` 或项目等价的 Metal 构建选项。
- 确认 Metal shader/resource 的编译、复制和签名流程；链接 `Metal.framework` 及 whisper.cpp 所需的系统框架。
- 将 iOS 后端状态和错误码接入与 Windows 相同的 C ABI/FFI 语义。
- 在真实 iPhone 上使用同一类模型、PCM 窗口和 `RecognitionEvent` 契约进行加载、识别、暂停、seek、换片和停止测试。
- Metal 初始化失败、设备不可用、内存不足或运行时失败时回退 CPU，并在诊断中显示原因。
- 明确记录设备型号、iOS 版本、Xcode 版本和实际后端；Simulator 结果只能作为辅助构建验证。

输出物：iOS Metal 构建配置、真机 Release/Debug 验证记录、Metal/CPU fallback 结果。

完成条件：真实 iPhone 日志能够确认 `Metal` 或明确的 `CPU` fallback；Windows 本地不能替代这一完成条件。

### Step 7：固定输入和真实视频性能回归

状态：`未开始`

任务：

- 准备仓库外固定 PCM/WAV 和用户允许测试的本地视频，建立脱敏 manifest。
- 使用同一模型、语言、窗口、线程/批量和输出配置分别跑 CPU、Windows Vulkan、iOS Metal。
- 记录模型加载耗时、每个窗口推理耗时、总耗时、实时倍率、输出段数、文本和时间轴偏差。
- 检查 GPU 首次加载成本与后续窗口成本，避免只测 warm-up 或只测单个空窗口。
- 对同一输入比较文本、段落时间、失败语义和字幕框显示；允许 GPU/CPU 文本存在细微差异，但必须记录并解释。
- 真实播放器回归覆盖播放、暂停、seek、换片、停止、长静音、短对白和模型加载等待。

输出物：CPU/Vulkan/Metal 性能与结果对照表、真实视频回归日志、已知差异说明。

完成条件：至少 Windows Vulkan 和 CPU 完成可重复对照；iOS 必须在真实 iPhone 完成 Metal 或 CPU fallback 对照，不能只提供编译日志。

### Step 8：异常、回退和生命周期回归

状态：`未开始`

任务：

- 测试 Vulkan loader 缺失、旧驱动、错误架构 DLL、符号缺失、设备不可用、模型加载失败和显存不足。
- 测试 Metal 不可用、真机内存压力、framework/resource 缺失、模型错误和 native exception。
- 验证后端失败后只回退一次，重复播放不会叠加 worker、context、stream subscription 或日志监听器。
- 验证 pause、seek、换片、stop、dispose 后旧 session 不再产生字幕、日志输出或 native 回调。
- 验证 GPU 与 CPU 两种后端都遵守 Phase 6 的有界队列和时间轴契约。
- 诊断状态必须从加载中、已加载、识别中、回退、不可用、已停止等状态正确迁移。

输出物：异常注入测试、生命周期测试、内存/handle 释放检查和回退矩阵。

完成条件：所有已知后端失败均有明确可读结果，播放器不会因为识别后端失败而崩溃或卡死。

### Step 9：版本、打包、文档和最终验收

状态：`未开始`

任务：

- 将 `app/pubspec.yaml`、`app/lib/core/app_build_info.dart` 默认值和构建脚本统一更新为 `0.6.5`。
- Windows Release 注入真实 `APP_VERSION=0.6.5`、带时区的 `APP_BUILD_TIME` 和唯一 `APP_BUILD_ID`。
- iOS 构建在 macOS/Xcode 注入同样字段，保证诊断页标题和导出日志可确认实际包版本。
- 更新 `NEW.md`、`PLAN.md`、README/CI 或打包说明中的后端、构建和验证规则。
- 检查 Release 目录中的 `speech_core`、Vulkan 运行时资源、iOS Metal resources 和模型路径；不把开发 SDK、驱动、视频、模型和 native build 产物加入 Git。
- 运行完整验收矩阵；未完成 iOS 真机验证时保留为进行中，不标记 Phase 6.5 已完成。

输出物：Windows `0.6.5` Release、iOS `0.6.5` 真机包或明确阻塞记录、完整测试记录、文档更新。

完成条件：所有第 3 节完成定义均满足，且 `git diff --check`、版本检查、日志字段检查和 Git 忽略检查通过。

## 7. 计划中的测试命令

以下命令中的模型、音频和视频路径均为仓库外路径；实际参数以本机工具链和 Step 1 结果为准：

```powershell
flutter analyze
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:no_proxy = $env:NO_PROXY
flutter test --concurrency=1

cmake -S native/speech_core -B native/speech_core/build-whisper-vulkan `
  -D SPEECH_CORE_WITH_WHISPER=ON `
  -D WHISPER_CPP_SOURCE_DIR=<仓库外 whisper.cpp-v1.7.6> `
  -D GGML_VULKAN=ON `
  -D GGML_NATIVE=ON `
  -D GGML_OPENMP=ON `
  -D GGML_BUILD_EXAMPLES=OFF `
  -D GGML_BUILD_TESTS=OFF

cmake --build native/speech_core/build-whisper-vulkan --config Release
ctest --test-dir native/speech_core/build-whisper-vulkan -C Release --output-on-failure

native/speech_core/build-whisper-vulkan/Release/speech_regression.exe `
  --model <仓库外模型路径> `
  --audio <仓库外固定音频路径> `
  --language ja `
  --threads 16 `
  --output <仓库外 vulkan-result.jsonl>
```

Windows Release 构建示例：

```powershell
flutter build windows --release `
  --dart-define=APP_VERSION=0.6.5 `
  --dart-define="APP_BUILD_TIME=<真实构建时间和时区>" `
  --dart-define="APP_BUILD_ID=phase-6.5-windows-<唯一标识>"
```

iOS 命令只能在 macOS/Xcode 环境执行：

```bash
pod install
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' build
```

还必须执行真实设备回归，并记录：

- `vulkaninfo --summary` 或等价 Vulkan 设备信息。
- Windows 日志中的 `actualBackend=Vulkan`、`gpuEnabled=true` 和设备名称。
- iPhone 日志中的 `actualBackend=Metal`，或 `actualBackend=CPU` 与 fallback 原因。
- CPU/GPU 相同输入的模型加载耗时、窗口推理耗时、实时倍率和输出对照。

## 8. 风险与决策门

### Vulkan 工具链不可用

如果当前 Windows 缺少 Vulkan headers、loader、shader 工具或兼容驱动，先记录具体缺项并补齐开发环境；不能用 CPU 结果代替 Vulkan 验收。系统驱动文件不随项目提交。

### Vulkan 编译成功但运行失败

whisper.cpp/ggml 编译通过只证明构建链路成立。必须在真实设备完成 context 初始化和至少一个真实模型窗口，日志确认实际设备后，才可判定 Vulkan 通过。

### 多 GPU 设备选择不确定

默认选择策略必须可观察。至少记录枚举到的设备数量、最终设备名和选择原因；不要通过固定显卡序号硬编码验收。

### CPU fallback 性能不足

CPU 回退是可靠性保障，不等于性能达标。若 CPU 实时倍率不足，必须显示识别落后或不可用状态，继续遵守 Phase 6 的有界队列，不无限堆积窗口。

### iOS 缺少 macOS 或真实 iPhone

Windows 无法编译或验证 Metal。若当前没有 macOS/Xcode/真机，本阶段只能完成 Windows 子目标，Phase 6.5 保持未完成，并在最终记录中明确阻塞。

### GPU 与 CPU 文本存在差异

不同后端可能产生轻微文本、分段或耗时差异。验收重点是语言、时间轴、错误语义、字幕来源和可重复性；所有差异都必须保留测试记录，不能静默改写结果。

### native 生命周期和资源泄漏

GPU context、模型、shader、FFI 字符串和 worker 必须有清晰释放路径。重复打开、暂停、seek、换片和 dispose 后做 handle/内存检查，防止只在首次播放时工作。

## 9. Phase 6 前置结果

| 项目 | 状态 | 备注 |
|---|---|---|
| Windows 本地视频音频解码 | 已完成 | Media Foundation adapter 输出带媒体时间的 PCM |
| PCM 标准化与窗口规划 | 已完成 | 16 kHz、单声道、Float32；静音和短对白门控已回归 |
| Whisper 持久窗口识别 | 已完成 | 模型复用，窗口结果转换为媒体绝对时间 |
| 有界队列与生命周期 | 已完成 | 播放、暂停、seek、换片、停止和 dispose 已覆盖 |
| 真实日语视频回归 | 已完成 | 识别结果已进入播放器下方字幕框 |
| Windows CPU 基线 | 已完成 | 作为 Phase 6.5 CPU 对照，不代表其他设备性能 |
| Windows Vulkan GPU | 已完成 | 实际运行于 NVIDIA GeForce RTX 5060 Laptop GPU |
| iOS Metal GPU | 待验证 | 必须在 macOS/Xcode 和真实 iPhone 验证后 Phase 6.5 才能结项 |

## 10. 本阶段最终状态记录

本节记录 Phase 6.5 的当前执行结果；iOS 真机验证完成前，不得写入整体结项结论。

初始状态：

- Windows 目标后端为 Vulkan，CPU 为明确可观察的 fallback；不启用 CUDA 或 OpenGL。
- 版本为 `0.6.5`，并已生成带真实构建标识的 Windows Release 包。
- iOS Metal 尚未实现或验证，仍是 Phase 6.5 的未完成验收项；本阶段不将 Windows 结果外推为 iOS GPU 支持。
- 模型、视频、PCM、测试结果、GPU SDK/驱动和 native build 产物继续保持仓库外或 Git 忽略。

#### Phase 6.5 执行记录

| 日期 | 步骤 | 状态 | 说明 |
|---|---|---|---|
| 2026-08-17 | 初始化计划 | 进行中 | 已建立 Windows Vulkan 与 CPU fallback 的执行边界；iOS Metal 真机验证仍待完成 |
| 2026-08-17 | Windows ABI/FFI | 已完成 | 新增 ABI v2、请求/实际后端、GPU 状态、设备名、回退原因和后端说明；旧 CPU 创建函数保持兼容 |
| 2026-08-17 | Windows fallback | 已完成（代码） | Vulkan 初始化失败或首个窗口运行失败时释放 GPU context、重建 CPU context 并重试一次；失败状态不会伪造为 CPU |
| 2026-08-17 | Provider/诊断 | 已完成（代码） | Windows 默认请求 Vulkan；支持 `AI_VIDEO_WHISPER_BACKEND=auto|vulkan|cpu`，诊断页和日志显示后端状态；版本默认值更新为 `0.6.5` |
| 2026-08-17 | Windows 验证 | 已完成（CPU/FFI） | Dart analyze 通过；Flutter 测试 31 项通过；speech_core CPU 与 whisper CPU 构建/CTest 均通过 |
| 2026-08-17 | Windows 环境快照 | 已完成（运行时） | Vulkan Instance Version `1.4.321`；可见 NVIDIA GeForce RTX 5060 Laptop GPU（driver `591.86`）和 AMD Radeon(TM) 610M（driver `24.30.50`）；设备名称来自 `vulkaninfo`，未写入代码 |
| 2026-08-17 | CPU 回归复核 | 已完成 | 已生成 CPU 构建的 `speech_core_tests.exe` 与 whisper CPU CTest 均通过；本次重新构建受 Visual Studio Windows SDK 目录访问权限限制，未覆盖已有 Release 产物 |
| 2026-08-17 | Windows 范围决策 | 已确定 | Windows 只使用 Vulkan 与 CPU fallback；不启用 CUDA 或 OpenGL |
| 2026-08-17 | Vulkan 构建 | 已完成（Windows） | 安装官方 LunarG Vulkan SDK `1.4.357.0` 后，独立 `build-whisper-vulkan` Release 构建成功；Vulkan CTest `100% tests passed` |
| 2026-08-17 | Vulkan 真实回归 | 已完成（Windows） | 同一真实模型与 WAV、`en`、8 threads：`requestedBackend=Vulkan`、`actualBackend=Vulkan`、`gpuEnabled=true`、设备 `NVIDIA GeForce RTX 5060 Laptop GPU`；输出 1 段，时间 `0-11000 ms` |
| 2026-08-17 | CPU/Vulkan 对照 | 已完成（Windows） | 同一模型、输入和参数下文本/语言/时间轴一致；Vulkan `9979 ms` / 实时倍率 `0.907`，CPU `3229 ms` / 实时倍率 `0.294`。短样本当前 CPU 更快，结果只作本机基准，不外推性能 |
| 2026-08-17 | Flutter 质量门 | 已完成（Windows） | `dart format --set-exit-if-changed`、`dart analyze lib test` 通过；Flutter 测试 `31` 项全部通过 |
| 2026-08-17 | Windows 0.6.5 Release | 已完成（Windows） | 构建时间 `2026-08-17 01:59:36 +08:00`；构建编号 `phase-6.5-windows-20260817-015936`；Release 包内 `speech_core.dll` 与 Vulkan 构建产物 SHA-256 相同 |
| 2026-08-17 | Windows Release 启动修复 | 已完成（Windows） | 定位为 media_kit ANGLE 携带的旧 `vulkan-1.dll` 抢先加载，导致 ggml Vulkan 模型初始化时 `0xC0000005`；CMake 已排除该 loader，Release 包改用系统 Vulkan runtime；原始启动命令复测 8 秒稳定，日志确认 `using Vulkan0 backend` |

#### 最终结项记录

- Windows Vulkan 实际设备和运行日志：已完成；NVIDIA GeForce RTX 5060 Laptop GPU，`actualBackend=Vulkan`，`gpuEnabled=true`。
- Windows CPU/Vulkan 性能与识别结果对照：已完成；同输入文本、语言和时间轴一致，性能数据见执行记录。
- 版本、构建时间和构建编号：已完成；Windows `0.6.5`，构建时间 `2026-08-17 01:59:36 +08:00`，构建编号 `phase-6.5-windows-20260817-015936`。
- Windows 子目标状态：已完成（Vulkan + CPU fallback）。
- Phase 6.5 结项状态：进行中（iOS Metal 及真实 iPhone 验收尚未完成）。
- 后续产品项：本地媒体预读、首次真实推理预热与网络媒体预读策略待 Phase 6.5 结项后进入下一阶段，服务于字幕和翻译相对播放器时间轴的准时显示。
