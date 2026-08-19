# AIVideoPlayerNext 当前阶段修复计划

> 当前项目：`AIVideoPlayerNext`
> 当前阶段：`Phase 7`
> 计划状态：进行中，按本计划重新收束
> 软件版本目标：`0.7.0`
> 更新日期：2026-08-18

## 1. 阶段目标

### Phase 7：字幕优先的连续预取管线

产品优先级已经明确：**识别、翻译和按媒体时间显示字幕是第一优先级；播放器是承载视频与提供权威时钟的第二优先级。**

这不允许以降低识别能力或禁止领先识别来换取播放器流畅度。修复目标是将播放器控制与后台媒体、解码、识别和翻译清理解耦：字幕可持续领先，播放、暂停、拖动和换片必须立即响应。

本阶段实现的目标链路：

```text
播放器媒体消费者（视频、权威播放时间）
独立识别媒体消费者（网络读取/分段缓存、音频解码）
  -> 连续媒体时间窗口 + 小范围重叠
  -> 有界队列
  -> 持久 Whisper worker（固定线程数）
  -> 原始窗口结果（诊断证据）
  -> TranscriptAssembler（时间轴整理、去重和合并）
  -> 当前会话 TranscriptDocument（内存索引 + 临时 JSON 快照）
  -> 有界翻译队列（固定有限并发，按稳定 segmentId 回填）
  -> 原文/译文/双语 Overlay（只按播放位置显示）
```

网络媒体的两个消费者逻辑独立，但不默认完整下载两份视频。优先实现“播放器直接读网络源，识别器独立顺序下载/分段缓存并持续解码”；只有来源、授权和用户选择适合时才允许完整本地缓存。

## 2. 已确认事实与问题

- `0.7.0` 已修复网络 HTTPS URL 被错误调用 `Uri.toFilePath()` 的问题；网络媒体能够进入 Media Foundation 音频解码链路。
- 最新用户日志确认网络视频可识别并可领先播放，1 小时视频中约在播放 `12s` 时已识别至 `30s`。这说明 Whisper 持久 worker 与媒体时间映射具备有价值的预取能力，应保留并受控。
- 当前打开网络媒体、暂停和 seek 会出现秒级到十余秒级卡顿。Windows native decoder 的 `stop/pause/seek` 同步等待 worker `join`；网络 `ReadSample()` 或网络 I/O 未返回时，这条等待会阻塞 Dart 调用链和 UI 操作。
- 当前前瞻不能实现为“达到 30 秒后彻底停止，播放追上时再突发处理到 60 秒”。该方式会在窗口边界损失上下文、造成字幕衔接空洞，并导致资源负载呈脉冲。
- 识别不能每秒创建新线程或新模型。Whisper worker、下载/解码 worker 和翻译 worker 都应长期存在、数量固定、通过有界队列与水位调度工作。
- iOS 当前仅有本地媒体 PCM 管线；网络识别源、独立下载/缓存和连续前瞻仍待实现。iOS 可以实现有界并发与相对优先级调度，不能可靠绑定 CPU 核或保证绝对 CPU 百分比。

## 3. 不可违反的约束

1. 字幕起止时间只由媒体时间决定，绝不使用识别或翻译完成的墙钟时间。
2. 识别和翻译可以领先播放，但队列、PCM 与缓存必须有硬上限；完整预识别允许持续处理至媒体结束，播放控制不得同步等待旧 worker 停止或网络读取返回。
3. 换片、停止和 dispose 使用新的 `sessionId`/`generation` 隔离旧任务；暂停和普通/短距离 seek 只改变播放器权威时钟，不重开识别 decoder、重置识别游标或停止识别。长距离前跳到未覆盖位置时，允许在后台同一 session 内切换识别 decoder 游标，优先覆盖当前位置附近后回填缺口；播放器 seek 本身不得等待该操作。旧任务可以延迟退出，但其 PCM、识别、整理、翻译和文件写入结果必须立即失效并被丢弃。
4. 每条后台链路使用固定数目的持久 worker 与有界队列；禁止按秒创建线程、isolate、模型或无限积压 PCM。
5. 前瞻在窗口边界连续推进。窗口之间保留 `0.5-1.5s` 输入上下文重叠；原始窗口结果必须先按媒体时间、文本相似度和来源窗口整理为稳定时间轴片段，不能把窗口局部 `segment_index` 当作全局 `segmentId`。
6. 初始播放可等待有限的“双语可用预备量”，但不能无限等待。网络慢、识别或翻译失败、超时后必须允许用户立即播放，并保持可见的准备/降级状态。
7. 测试/诊断构建在本机保留完整日志，包括 URL、查询参数、请求头、Cookie、Referer、重定向、缓存路径和会话关联信息；日志不自动上传、不提交 Git。正式发布构建默认脱敏或省略敏感字段，并提供本机清理能力。
8. 不绕过 DRM、MSE/blob、受保护会话或服务端访问控制。授权信息仅在所需生命周期内保存并仅交给需要它的媒体消费者。

## 4. 调度模型与验收指标

### 4.1 可配置连续预识别与前瞻水位

每个 session 独立维护以下媒体时间游标：

```text
playbackPosition     播放器当前位置
downloadedThrough    识别缓存可用至的位置
decodedThrough       PCM 已解码至的位置
recognizedThrough    Whisper final 结果覆盖至的位置
translatedThrough    已有目标译文覆盖至的位置
```

启动和运行时以 `translatedThrough - playbackPosition` 为主要用户体验指标；未启用翻译时使用 `recognizedThrough - playbackPosition`。

Windows 首轮调度参数由 `RecognitionController` 公开，设置 UI 后续只负责绑定；默认策略为完整预识别，以设置项和诊断项暴露，后续按真机/真实网络回归调优：

| 项目 | 初始值 | 说明 |
| 识别策略 | 完整预识别 | 默认从当前识别游标连续处理至 EOF；队列、PCM 与缓存上限仍生效 |
| 可选策略 | 按需预取 | 以低/高水位约束领先量，适合用户主动限制后台资源的场景 |
|---|---:|---|
| 启动预备量 | 8-15s 或 2-4 个已翻译窗口 | 达到后自动播放；有超时和“立即播放”降级 |
| 目标领先量 | 30s | 正常持续维持的中心值 |
| 低水位 | 20s | 低于此值持续生产 |
| 高水位 | 45s | 到达完整窗口边界后暂停/降速生产 |
| Whisper 输入窗口 | 4s | 保持现有表现，另带上下文重叠 |
| 窗口上下文重叠 | 0.5-1.5s | 保护跨边界句子；结果按媒体时间去重 |
| 识别待处理窗口 | 有界，首轮 1-3 个 | 具体值由内存和速度回归确认 |
| 翻译并发 | 有界，首轮 1-2 个 | Provider 特性决定最终默认值 |

按需预取的高水位不是“停在 30 秒不动”。识别器在完成当前自然窗口后受控地暂停；播放器消耗领先量到低水位后，由原来的常驻 worker 继续推进。完整预识别模式不受该水位暂停，直到媒体 EOF 或有界队列背压要求暂停。两种模式都必须在长距离前跳时后台优先覆盖新播放位置附近，再回填跳过区间并恢复常规顺序遍历。

### 4.2 资源模型

```text
网络下载/缓存 worker：1 个每个识别 session
音频解码 worker：1 个每个识别 session
Whisper：1 个持久识别 worker，native n_threads 固定且可配置
翻译：1-2 个长期 worker，队列有上限
UI：只订阅状态和时间轴快照，绝不等待 native join 或网络 I/O
```

Windows 可设置 Whisper 的固定线程数并观察 GPU/CPU 使用；iOS 使用 `OperationQueue`、Swift `Task` 或 `DispatchQueue` 的并发上限与 QoS，以及 Whisper 固定 `n_threads`。iOS 的 QoS 是相对优先级，不是核心亲和性或硬实时 CPU 配额。

## 5. 执行步骤

### Step 1：补齐完整测试诊断与性能基线

状态：`代码完成，等待真实网络回归`

- 将诊断模式明确分为测试完整日志与正式脱敏日志，测试模式保留原始网络、请求、缓存、会话、解码、队列和时间线字段，只写入本机诊断目录。
- 记录打开请求、播放器首帧/首个可播放状态、识别 decoder open、首个 PCM、首个识别、首个翻译、自动播放时刻，以及每次 pause/seek 的 UI 返回时间和旧 worker 实际退出时间。
- 每个 session 记录五个游标、领先秒数、低/高水位触发、队列深度、线程配置、解码阻塞、取消请求和迟到结果丢弃原因。
- 对每个识别网络请求记录请求角色（decoder、容器头部预热、容器尾部预热）、Range、首字节耗时、传输字节、总耗时、平均吞吐、上游 HTTP 状态和 `Content-Range`，以区分网络/服务器延迟与容器索引读取延迟。
- 用已允许的网络视频覆盖短视频与约 1 小时视频；保留原始测试日志在本机，不加入 Git。

完成条件：能从一次日志判断“卡在播放器打开、网络读取、同步停止、解码、识别、翻译、时间轴或 Overlay”的具体位置，并量化 UI 卡顿与字幕领先。

### Step 2：解除播放控制与旧解码 worker 的同步耦合

状态：`代码完成，等待真实网络回归`

- 已将 Windows native decoder 拆分为异步打开 worker 与解码 worker；`pause/stop` 仅请求取消，尾部 marker 只在解码 worker 实际退出后发送。
- Dart 控制层立即使旧 callback 和 handle 失效，在后台 isolate 等待旧 worker，再在创建 handle 的 isolate 销毁 native 对象；UI 主调用路径不再等待网络 `ReadSample()` 返回。
- 每次 seek 使用新的 decoder handle 和新 generation；起始 `SetCurrentPosition` 也在异步打开 worker 中执行，避免网络定位重新落回 UI 线程。
- 新识别会话不等待旧 Whisper `stop()`，但新窗口会经过共享模型的停止屏障，避免迟到的 stop 取消新推理。
- 已添加阻塞旧 recognizer stop 的回归测试，并完成静态分析、Flutter 单测及 native Release 构建；仍需对真实网络 `ReadSample()` 迟缓情形做人工回归。

完成条件：网络视频的 pause、seek、换片和返回播放器工作区不再被旧识别读取阻塞；旧结果不会进入新 session。

### Step 3：建立独立识别媒体消费者与分段缓存

状态：`独立消费者已完成；实验性分段/预热策略已回退，等待透明流式代理的真实网络验收`

- 抽象播放器媒体源与识别媒体源，保留同一授权会话所需的最小请求上下文。
- Windows 识别 decoder 读取会话专属 loopback HTTP 代理，而不是原始 URL。代理保留浏览器授权上下文、将响应即时流给 Media Foundation，并按字节段缓存已读取范围；播放器仍直接读取原网络 URL，两个消费者互不共享 reader 或播放时钟。
- 默认代理透明转发 decoder 的实际 Range（包括 `bytes=0-`）和上游响应头/流式 body，使 Media Foundation 保持此前真实验证过的 MP4 流式读取语义；播放器仍使用原网络 URL，识别器仍是独立消费者。
- “连续有限上游 Range 分段”与 MP4 头部/尾部预热保留为关闭状态的实验策略，只有逐站点能力验证和独立真实网络回归通过后才可启用。上游不支持 Range 时，代理明确记录顺序流式读取，不能伪装为随机访问缓存。
- 自动化覆盖授权头转发、透明开放 Range、重复 Range 缓存命中、显式启用实验分段、预热让位及取消生命周期；真实普通 HTTPS 媒体仍须验证 Media Foundation 的请求模式与长时网络表现。
- 缓存元数据以媒体时间或字节范围追踪数据可得性、失败、重试、过期和 session；设置磁盘、内存、分段数和预取领先量上限。
- 不假设所有站点支持 Range。Range 不可用时改为一次顺序下载并边写边消费；授权 URL 将过期时给出可诊断状态，不无限重试。
- 保留“无需物理缓存、直接第二次读取 URL”的兼容策略，只在其不会抢占播放器或使 seek 不可控的资源上使用。

完成条件：播放器和识别器各自有可观测的媒体消费者；网络读取、播放器缓冲或识别缓存问题能够单独判断，且不默认下载完整视频两遍。

### Step 4：实现连续窗口与可配置预取调度器

状态：`代码与定向测试完成，等待真实媒体验收`

- 新建/调整预取协调器，以五个时间游标和高低水位为唯一调度依据，而非每秒创建任务或固定批量处理。
- 已将 `processedThrough` 与 `recognizedThrough` 分开：静音、失败和成功窗口都会推进处理游标，只有实际 final 字幕推进识别覆盖游标，避免长静音媒体绕过高水位。
- 以连续媒体时间形成窗口，携带重叠上下文；暂停只停止推进，恢复时从连续游标继续；seek/换片创建新 generation。
- 默认完整预识别模式连续处理到 EOF；按需预取模式才在高水位完成当前窗口后停顿、低水位恢复。两种模式在识别、翻译滞后时都维持有界队列并记录原因，不清空已完成的连续字幕。
- 长距离前跳到未覆盖位置时，播放器先完成自身 seek；控制器随后在同一 session 中后台重定位 decoder，从目标前少量上下文开始优先覆盖当前位置，随后回填原游标与优先段之间的缺口，最后继续顺序处理。窗口编号保持单调，过时工作 epoch 的结果被丢弃。
- 定义翻译领先不足时的策略：原文可先准备和显示，启动门槛优先要求双语；超时则降级为原文先行并继续补译。
- 完成 5 分钟和 1 小时媒体回归，证明播放 10 秒时后台不会停在 30 秒直到 29 秒才突发跳到 60 秒。

完成条件：识别/翻译领先量稳定落在水位范围附近，字幕跨窗口连贯，不出现走停式断层、无界内存或按秒线程创建。

### Step 4E：前跳优先与区间覆盖回归

状态：`代码与定向测试完成，等待真实媒体验收`

- 维护已完成识别窗口的媒体时间区间，避免仅依赖单一最大游标而误判跳过区间已经覆盖。
- 完整与按需策略共享前跳优先语义；普通/短距离 seek 保持原有不重开 decoder 的快速路径。
- 自动化覆盖完整预识别不因高水位停顿、按需预取高低水位循环、普通 seek 不打开 decoder/取消识别，以及长距离前跳后台从目标附近开始识别。

### Step 4A：修复跨窗口结果 ID 与原始结果留存

状态：`代码完成，等待真实媒体回归`

- 修正 `WhisperCppSpeechRecognitionService`：Whisper 的窗口局部 `segment_index` 只可作为窗口内排序信息，不能单独组成跨窗口 `segmentId`。
- 每个 raw segment 生成跨窗口唯一的原始 ID，例如 `sessionId + windowId + segmentIndex`；同时保存窗口媒体起点、相对/绝对起止毫秒、文本、语言、置信度、final 状态和诊断字段。
- raw event 不再直接用 `segmentId` 覆盖式 Map 作为识别结果 UI 的唯一来源。测试构建写入当前 session 的原始证据文件，例如 `transcript.raw.json`，供诊断和整理算法重跑；正式构建按日志策略控制留存。
- 明确本次缺陷回归：本地 session 的约 13 个窗口、12 条 Whisper 输出，以及网络 session 的约 17 个窗口、30 条输出，均不得因 `segment-0`、`segment-1` 等窗口局部 ID 冲突而被覆盖成少数结果。

完成条件：原始结果数量、窗口来源和绝对时间可追溯；同一窗口编号在不同窗口中出现时不会相互覆盖。

### Step 4B：建立当前会话 TranscriptDocument 与临时快照

状态：`代码完成，等待集成回归`

- 为每条打开的媒体创建一个会话专属字幕文档，运行期内存模型为唯一查询源，建议路径为 `<系统临时目录>/ai-video-player/sessions/<sessionId>/transcript.json`。
- 文档至少包含 `schemaVersion`、`revision`、`sessionId`、稳定 `segments` 和按 `segmentId` 关联的 `translations`。时间使用 `startMs`/`endMs`，不把格式化字符串作为机器时间字段；`speaker` 可选，当前 Whisper 无说话人分离数据时固定为 `null`。
- 原文 `text` 不可被翻译覆盖；翻译必须以稳定 `segmentId` 回填，不能复制、改写或重新推断原始时间轴。
- 内存文档每次变更先更新时间索引并通知 UI；JSON 只作为同一会话的临时快照、导出和诊断交换格式。写入在后台串行、防抖并采用 `.tmp` 后原子替换，必要时保留 `.bak`，不得在 UI isolate 逐条同步写文件。
- 文件写入、整理和翻译均验证 `sessionId`/generation。换片、停止和退出时串行 flush 或删除旧会话目录；已失效的异步写入不得重建旧文件，更不得污染新会话。

建议文档结构：

```json
{
  "schemaVersion": 1,
  "revision": 12,
  "sessionId": "audio-1786967615255913",
  "segments": [
    {
      "id": "seg-000001",
      "startMs": 0,
      "endMs": 10000,
      "speaker": null,
      "text": "I love you.",
      "language": "en",
      "confidence": 0.94,
      "status": "timelineFinal",
      "sourceWindows": ["audio-1786967615255913-window-0"]
    }
  ],
  "translations": [
    {
      "segmentId": "seg-000001",
      "targetLanguage": "zh-CN",
      "text": "我喜欢你。",
      "status": "translated"
    }
  ]
}
```

完成条件：每个媒体只存在当前会话临时文档；内存索引和导出 JSON 内容一致，旧会话不会残留或复活。

### Step 4C：实现 TranscriptAssembler 时间轴整理器

状态：`第一版代码完成，等待真实媒体调参`

- `TranscriptAssembler` 接收每个 Whisper 窗口的 final raw segments，将窗口相对时间换算为媒体绝对时间，并保留 `sourceWindows`。
- 按 `startMs` 排序后，使用时间重叠、文本归一化相似度和置信度收敛相邻窗口的重复结果；窗口重叠仅为上下文，不能直接重复展示为两条最终字幕。
- 合并明确属于同一句且时间连续的相邻片段；边界不确定时宁可保留多条并标记来源，不能错误吞掉一条字幕或篡改原文。
- 稳定片段生成单调、会话唯一的 `seg-000001` 类 ID。翻译只消费 `timelineFinal` 片段；后续整理修订必须通过 revision 和原片段关联使译文可判定失效或保留。
- 先实现可复现的纯 Dart 单元测试：重叠重复、同文不同句、跨窗口半句、乱序到达、迟到结果和空/低质量结果；raw 证据可以在不重新运行 Whisper 的情况下重放整理逻辑。

完成条件：最终时间轴按媒体时间连续、无窗口重复覆盖，且所有最终片段能回溯原始窗口证据。

### Step 4D：迁移诊断三栏与导出来源

状态：`代码完成，等待真实媒体回归`

- 左栏继续显示原始诊断日志；中栏改为显示 `TranscriptDocument.segments` 的完整后台整理结果；右栏显示同一文档的按 ID 回填译文。三个区域继续独立复制、导出和移动端分享。
- 中栏和右栏不按播放器当前时间过滤，也不显示短生命周期的实时 partial；它们应在播放器暂停、拖动和后台识别领先时持续推进。
- UI 的排序、计数和导出均从统一文档读取，不再直接读取 raw event 的覆盖式 Map。测试期可在诊断导出中附 raw 证据，但不能把它当成最终字幕。

完成条件：诊断三栏展示的数量与会话文档一致，播放器状态变化不会丢失或倒退已整理结果。

### Step 5：启动预备与翻译队列

状态：`核心翻译队列、启动预备 UI 与自动播放代码完成，等待真实 Provider/媒体验收`

- 打开媒体后显示准备状态；网络缓冲、首批窗口识别和翻译并行准备，达到启动预备量后自动播放。
- 提供用户可见的立即播放入口；超过 10 秒、翻译不可用或网络错误时不锁死播放器，并显示当前阻塞原因和已完成耗时。
- 接入至少一个真实翻译 Provider，保留 Mock；翻译仅消费 final 原文，不上传音频、媒体 URL、Cookie 或请求头。
- 翻译队列具备固定并发、超时、取消、去重与 `sessionId + segmentId + sourceText + sourceLanguage + targetLanguage` 回填校验；翻译结果按 `segmentId` 补写 `TranscriptDocument.translations`。

完成条件：首批正确字幕和译文准备后可以自动开始播放；翻译故障不影响原文、时间轴或控制操作。

### Step 5B：将 Overlay 收口为内存时间索引查询

状态：`代码完成，定向测试通过；等待真实媒体验收`

- Overlay 已消费 `TranscriptDocument` 的稳定片段和翻译回填，使用 `TranscriptDocument.at()` 执行 `startMs`/`endMs` 内存时间查询。
- 普通播放器和全屏播放器按权威播放位置显示译文，并在译文暂未返回时降级显示原文；seek 预览时立即查询已整理片段，不重新读 JSON、重新识别或等待翻译。
- 翻译文档更新会主动通知播放器重绘，也会重新评估启动预备门槛。
- JSON 文件监听不属于当前范围。只有未来支持用户外部编辑临时字幕文件时，才增加防抖重载和 revision 校验。

完成条件：暂停、回拖或快进不会重开 decoder/Whisper；已覆盖位置的字幕即时显示，未覆盖位置保持准备状态并由后台持续推进。

### Step 5C：会话清理与临时数据边界

状态：`未开始`

- `transcript.json` 不是永久字幕库、跨媒体缓存或历史数据库。打开下一条媒体时停止旧 session、删除旧 session 临时目录并创建新文档；退出应用时删除当前会话临时目录。
- 测试构建可在同一 session 临时目录保留 `transcript.raw.json` 和完整诊断证据，仅限本机且不进入 Git；Release 延续现有脱敏策略。
- 异常退出后的残留目录在下次启动时按会话锁与过期策略清理，绝不扫描并加载为新媒体字幕。

完成条件：换片和退出后旧 JSON、raw 证据及迟到任务均不会影响下一条媒体。

### Step 6：iOS 调度适配与平台边界

状态：`未开始，Windows 验证后开始`

- 保持 Dart 层调度契约一致，在 iOS 原生 adapter 为网络媒体接入独立下载/缓存和 PCM 读取。
- 使用有界 `OperationQueue`、Swift `Task` 或 `DispatchQueue`，配合 QoS、取消令牌和 `AVAssetReader.cancelReading()`；循环 PCM 处理加入 `autoreleasepool`。
- 不实现 CPU 核绑定或绝对 CPU 配额；记录设备核心数、配置的识别线程数、排队延迟、内存警告、前后台转换和热量表现。
- 覆盖 iOS 网络授权、临时 URL、暂停、seek、换片、后台限制和播放器/识别管线隔离。

完成条件：iOS 实现相同的连续前瞻和非阻塞控制语义，并明确记录平台无法保证的调度边界。

### Step 7：回归、打包与结项

状态：`未开始`

- 自动化覆盖：旧 session 迟到回调、异步停止、seek 去抖、窗口重叠合并、水位恢复、队列上限、启动超时、翻译取消与完整/正式日志策略。
- 人工回归：短网络视频、5 分钟网络视频、约 1 小时网络视频、本地视频、正常/慢速网络、暂停、连续 seek、换片、立即播放、自动播放、原文/译文/双语。
- 记录启动等待、UI 控制延迟、识别/翻译领先、首窗/稳态耗时、缓存峰值、队列峰值、错误/取消次数和长视频稳定性。
- 执行 `flutter analyze`、`flutter test --concurrency=1`、native Release 构建、Windows `0.7.0` Release smoke；完成后更新 `NEW.md` 的实际结果，而不是把计划当作已完成。

完成条件：字幕优先的连续预取可用，网络播放控制正常可用，所有测试期完整日志只留本机，正式包遵从脱敏策略。

## 6. 本阶段范围边界

包含：当前支持的普通 HTTP(S) 网络媒体、本地媒体、持续领先识别、分段缓存、翻译 MVP、播放器内 Overlay、Windows 先行与 iOS 架构适配。

不包含：绕过 DRM/MSE/blob/受保护媒体；默认完整下载两份完整网络视频；无界缓存；按秒新建识别线程；以播放器实时速度人为限制字幕预取；iOS 核绑定或绝对 CPU 百分比保证；Phase 8 的多 Provider、字幕历史、术语表和完整离线缓存生态。

## 6A. 截至 2026-08-18 的实际进度总览

本节记录当前工作区的真实状态。`代码完成`、`已构建`、`已集成` 和 `已验收` 是不同层级，不能相互替代。

### 已完成并有自动验证的部分

- Phase 7 的核心架构已经落地：播放器与识别媒体消费者分离，识别/翻译使用持久 worker 和有界队列，字幕结果按媒体时间组织，不以播放器暂停或 seek 作为后台识别的停止条件。
- Windows decoder 的异步打开、异步回收、非阻塞 pause/stop 和 generation 隔离已经完成；相关 Dart/native 定向测试和静态检查曾通过。
- 诊断页已经分为左侧原始诊断日志、中间后台整理后的识别结果、右侧翻译结果三个独立区域；三栏不按播放器当前位置过滤，并支持各自复制/导出。
- `TranscriptDocument`、`TranscriptAssembler`、raw 识别证据、稳定 `segmentId`、临时 JSON 快照和翻译按 ID 回填已经落地；相关纯 Dart 测试已经覆盖窗口重叠、乱序、去重和会话隔离等场景。
- 默认识别策略已经改为“完整预识别”；“按需预取”仍保留为设置策略。两种策略都包含长距离前跳优先，前跳不在播放器控制路径中同步等待识别器。
- Step 5 的翻译队列和 Provider 契约已经落地：有界并发、超时、去重、取消/会话校验和按稳定片段回填已经接入；DeepL 与 OpenAI-compatible 文本 Provider 的设置入口和能力检测已存在。启动预备状态、10 秒超时降级、立即播放入口和首批译文自动播放也已接入，等待真实 Provider/媒体验收。
- Step 5B 的 Overlay 已接入普通播放器和全屏播放器：从内存 `TranscriptDocument` 按播放时间查询，译文优先、原文降级，并覆盖拖动预览和异步翻译回填刷新。

### 本地翻译模型路线（2026-08-18 更新）

当前主候选改为 Gemma 4 E2B IT + Google LiteRT-LM。NLLB 不再作为唯一
本地翻译正路；现有手写 ONNX decoder 技术尖峰已从源码和应用接入中移除，
后续如需要 NLLB，优先重新评估成熟的 CTranslate2 集成。

这次路线调整的边界很重要：Google 官方 runtime 已经覆盖 Windows 和 iOS，
但 Hugging Face 的 `model.safetensors` 不是 LiteRT-LM 的直接运行格式。必须
先验证官方 `.litertlm` 模型包在 Windows 和 iOS 的加载、文本生成、取消和
资源占用，再把 Gemma 标记为应用内可用。

#### Gemma + LiteRT-LM 主候选

| 层级 | 实际状态 | 位置/说明 |
|---|---|---|
| 原始模型 | 已核验仓库元数据 | `google/gemma-4-E2B-it-qat-mobile-transformers`；公开、Apache-2.0、`wNa8o8` 移动 QAT；不能直接交给任意 Transformers/ONNX loader |
| 官方部署包 | 已核验仓库元数据 | `litert-community/gemma-4-E2B-it-litert-lm`；公开、Apache-2.0；包含 `.litertlm` 文件，面向 LiteRT-LM |
| Windows runtime | 官方覆盖，待项目 spike | LiteRT-LM 官方 README 的 Windows 原生 CLI 支持 CPU/GPU；后续接入优先使用 C++/C API，不把 CLI 当最终 Flutter bridge |
| iOS runtime | 官方覆盖，待真机 spike | LiteRT-LM 官方 Swift API 为 Early Preview；预编译/构建资料覆盖 iOS，后续用 Swift/native bridge 验证 CPU/Metal |
| Flutter 接入 | 未开始 | 官方 Flutter API 标为 Community；项目先保留稳定的 Dart 翻译契约，优先通过 Windows C++ 和 iOS Swift 原生边界接入 |
| 模型安装 | 未完成 | 当前没有把大模型复制进 Windows 资源目录或 IPA |
| 真实文本生成 | 未验证 | 必须先完成 Windows 和 iOS 最小 prompt smoke test，不能把仓库存在或 runtime 编译称为可用 |

#### NLLB / CTranslate2 专业备选

| 层级 | 当前状态 | 位置/说明 |
|---|---|---|
| 手写 NLLB ONNX decoder | 已移除 | `native/translation_core` 的源码、CMake、脚本、测试、Dart FFI 和 Windows 安装接入已删除；不再作为应用依赖 |
| 本地生成缓存 | 仍在本机 | 旧的 `.cache` 和 `build-*` 目录未自动删除，因其包含大型模型/构建产物；它们被 `.gitignore` 忽略，不参与构建 |
| CTranslate2 | 未来重新评估 | 如需专业翻译质量或更广语言覆盖，单独验证成熟的 CTranslate2 Windows/iOS 集成、模型转换、许可证和内存占用 |

### 尚未完成且当前阻塞交付的项目

1. 建立独立 LiteRT-LM runtime spike：准备 `litert-community/gemma-4-E2B-it-litert-lm` 的 Windows 可用模型包，使用官方 LiteRT-LM CLI/C++ 边界加载并完成文本 prompt smoke test。
2. 建立 iOS Swift/native spike：在真实 iPhone 上加载同一 Gemma 4 E2B LiteRT-LM 变体，验证 CPU/Metal、取消、内存峰值和最小文本生成；Swift Early Preview 的限制必须记录清楚。
3. 设计 Flutter bridge：保持 `TranslationService` 不变，Windows 使用 LiteRT-LM C/C++ 边界，iOS 使用 LiteRT-LM Swift/native 边界；不要把 `.safetensors` 解析或 Gemma decoder 写进 Dart。
4. 只有 Windows+iOS smoke test 都通过后，才安装模型、接入翻译队列并决定是否默认启用 Gemma；在此之前状态必须显示“等待 runtime spike”。
5. 若需要专业翻译质量或语言覆盖，再独立评估 CTranslate2/NLLB；已移除的手写 ONNX decoder 不作为 Gemma 或未来专业路线的基础。
6. 完成临时 `transcript.json` 的换片/退出清理回归，以及 Step 5/5B 的真实 Provider、真实媒体验收。

### 当前不应宣称完成的内容

- 不能把 Gemma 仓库下载、LiteRT-LM CLI 可启动或模型包存在称为“本地翻译可用”；必须有 Windows+iOS 文本生成 smoke test。
- 不能把历史 NLLB 的模型下载、ONNX 转换或 DLL 编译称为“本地翻译可用”；这套手写实现当前已移除。
- 不能把 native 结构测试通过称为“真实翻译正确”。
- 不能把源码中的 iOS 构建脚本称为“iOS 已支持”。
- 不能把存在于 `.cache` 的模型包称为已进入 Release；当前应用资源目录仍未安装该包。
- 不能以当前未量化 ONNX 包的 7.38GB 直接推导最终 Release 体积，正式打包前还必须完成模型格式/量化决策。

## 7. 验收清单

- [ ] 网络媒体打开和自动启动字幕预备过程不冻结 UI。
- [x] pause/seek/换片的代码路径不再同步等待旧网络 decoder worker 的 `join`；等待真实网络回归确认体感延迟。
- [ ] 识别与播放器是独立媒体消费者，且授权、缓存、失败和资源用量均可诊断。
- [ ] 连续前瞻维持在高低水位内，窗口带重叠上下文，不产生突发批处理断层。
- [ ] 跨窗口 raw segment 使用唯一 ID；本地约 12 条、网络约 30 条原始输出不会因窗口局部索引冲突而覆盖丢失。
- [ ] `TranscriptAssembler` 能将重叠窗口整理为可追溯的稳定时间轴片段，且不将不确定边界错误合并或吞掉。
- [ ] 当前媒体的内存 `TranscriptDocument` 与临时 JSON 快照一致；JSON 写入不阻塞 UI，换片/退出后旧目录和迟到写入不会残留。
- [ ] 5 分钟和 1 小时视频均保持字幕时间连续，播放控制可用。
- [ ] 启动预备达标后自动播放，超时或失败可立即播放并可见降级状态。
- [ ] 原文、译文和双语 Overlay 均按权威媒体时间从内存时间索引显示；seek 不增加 decoder `open()` 次数，已整理字幕可立即查询。
- [ ] 播放暂停期间 `recognizedThrough` 可继续推进；诊断识别栏和翻译栏不因暂停或 seek 回退。
- [ ] 测试构建保存完整本机日志，Release 构建默认脱敏；二者均不自动上传、不进入 Git。
- [ ] Windows Release `0.7.0` 和 iOS 构建/真机抽样均有记录。

## 8. 本轮执行记录

| 日期 | 项目 | 状态 | 说明 |
|---|---|---|---|
| 2026-08-18 | 本地模型身份更正 | 已完成登记；NLLB 已下载/转换，Gemma 未下载 | Gemma 目标更正为 `google/gemma-4-E2B-it-qat-mobile-transformers`（移动优化 QAT `wNa8o8`），本轮暂不实现其 runtime；NLLB 使用 `facebook/nllb-200-distilled-600M`，官方源文件已下载并转换为本机缓存中的未量化 ONNX 包，但真实推理、应用安装和 Release 仍未完成。 |
| 2026-08-17 | 网络 URL 输入映射修复 | 已完成 | HTTPS URL 不再错误转换为本地路径，网络 PCM 链路已恢复。 |
| 2026-08-17 | 网络视频真实回归 | 已完成 | 可识别，并确认识别可领先播放；同时暴露打开、pause 和 seek 被同步停止拖住的问题。 |
| 2026-08-17 | Phase 7 修复计划重订 | 已完成 | 确定字幕优先、连续前瞻、双媒体消费者、有限常驻 worker、测试完整日志与 Release 脱敏策略。 |
| 2026-08-17 | Step 2 非阻塞 decoder 控制 | 代码完成 | Windows decoder 改为异步打开与异步回收；pause/stop 不再 join，seek 的初始定位也移入打开 worker；会话切换不等待旧 Whisper stop。 |
| 2026-08-17 | Step 2 并发边界收口与自动验证 | 已完成 | native decoder 的 reader、格式与回调状态已改为短锁发布；打开 worker 使用局部 reader，解码 worker 使用本地快照，不在锁内执行网络 I/O。`dart analyze lib test`、`flutter test --concurrency=1`（36/36）及 `/W4 /WX` native Windows Release 构建均通过。 |
| 2026-08-17 | Step 1 诊断日志基线 | 代码完成 | 测试/开发构建保留 URL、请求头、Cookie 等完整本机上下文；Release 自动脱敏。已记录播放器打开/播放/暂停/seek 调用耗时，以及 decoder 打开、首 PCM、首条字幕和 worker 退出时间。 |
| 2026-08-17 | Windows 0.7.0 Release 验证包 | 已完成 | 已生成 `phase-7-nonblocking-decoder-20260817-163625`，构建时间 `2026-08-17 16:36:25 +08:00`。输出包含应用、`ai_audio_decoder.dll`、`speech_core.dll`、模型和 Flutter data；待真实网络媒体回归。 |
| 2026-08-17 | 诊断三栏与后台结果仓库 | 已完成 | 诊断页分为日志、后台 final 识别、未来翻译三栏；结果按媒体时间独立复制、导出和移动端分享，不随播放器位置筛选。 |
| 2026-08-17 | 识别处理/字幕覆盖游标拆分 | 已完成 | `processedThrough` 覆盖成功、静音和失败窗口；`recognizedThrough` 只覆盖实际 final 字幕；新增静音/失败水位回归。 |
| 2026-08-17 | 独立识别网络代理与分段缓存 | 代码完成 | 识别 decoder 已改读 session loopback 代理；代理独立拥有 HTTP client、浏览器授权头、Range 转发与已读字节段缓存，播放器仍读原 URL。定向测试验证鉴权转发与重复 Range 缓存命中；等待真实网络长视频验收。 |
| 2026-08-17 | 跨窗口字幕结果覆盖诊断 | 已确认，待修复 | Whisper 每个窗口从零开始的 `segment_index` 被拼为全局 ID，导致诊断结果 Map 相互覆盖；原始输出实际持续产生，下一步先修全局 ID 与会话字幕文档。 |
| 2026-08-17 | 会话临时字幕文档计划 | 已制定 | 新增 Step 4A-4D、5B、5C：raw 证据、时间轴整理、内存索引与临时 JSON、翻译回填、Overlay 查询和会话清理。 |
| 2026-08-17 | Step 4A 跨窗口 raw ID 与证据快照 | 代码完成 | 原始 ID 现由 `windowId + segmentIndex` 组成；测试/开发构建在当前会话目录写入 `transcript.raw.json`，记录 raw ID、窗口、窗口内编号、绝对毫秒时间、文本、语言、置信度和来源。Release 默认不保留此 raw 文件。 |
| 2026-08-17 | Step 4B 会话临时 TranscriptDocument | 代码完成 | 运行期内存文档为诊断/导出的唯一结果源；后台防抖串行写入临时 `transcript.json`，换片时通过 generation 隔离并删除旧会话目录。 |
| 2026-08-17 | Step 4C/4D 时间轴汇总与诊断迁移 | 第一版完成 | 新增纯 Dart `TranscriptAssembler`：按媒体时间重排 raw final 事件，收敛有时间重叠且文本相似的重复窗口结果，保留 `sourceWindows`，生成稳定 `seg-000001` ID；诊断识别栏和导出改读汇总后的 `TranscriptDocument`，不再直接展示 raw 窗口事件。 |
| 2026-08-17 | Step 4/4E 完整预识别与前跳优先 | 代码完成 | 默认完整预识别处理至 EOF，按需预取保留为可配置模式；长距离前跳由后台同 session decoder 游标切换优先覆盖当前位置、回填缺口后恢复顺序处理。定向 Flutter 回归 `16/16` 通过，等待本地/网络真实长视频验收。 |
| 2026-08-17 | Flutter 测试工具链复核 | 阻塞 | 设置 `NO_PROXY=localhost,127.0.0.1,::1` 后，`flutter test --no-pub --concurrency=1` 启动超过 90 秒仍无 runner 输出，已停止；`dart analyze lib test` 通过。 |
| 2026-08-18 | Step 1/3 网络分段代理与容器预热 | 真实验收失败，已局部回退 | 大网络视频日志显示首 PCM/首字幕显著晚于基线，而 Whisper 首窗仅约 `80ms`，瓶颈确认在网络读取/容器打开。新增预热请求在首字节前被取消，默认 2 MB 分段又改变了 Media Foundation 的开放 Range 流式语义。保留独立识别消费者、缓存、seek 优先与完整诊断；默认恢复透明 `Range` 转发，实验分段/预热关闭。新增“实际上游 Range”、HTTP 状态与 Content-Range 诊断；全量 Flutter 测试 `72/72` 与静态分析通过，等待新包真实网络验收。 |
| 2026-08-18 | 网络性能实验冻结与验收二进制回退 | 已完成 | 用户确认恢复 `phase-7-network-proxy-full-prefetch-20260817-234000` Windows Release。该包保留短视频立即响应、长网络视频短暂落后后追赶的已验收表现；当前 Release 目录已从该包恢复并校验核心文件摘要。此为二进制回退，未用 Git 覆盖或重置现有源码。其后的网络代理性能实验不再继续调参，源码不宣称已验收。未来重新诊断须从该可运行基线和重新设计的生命周期汇总日志开始。 |
| 2026-08-18 | Step 5 翻译 MVP | 核心代码完成，等待真实 Provider/媒体验收 | 稳定 `TranscriptDocument` 片段已接入会话级、有界、超时、去重、会话隔离的翻译队列；已接入 OpenAI-compatible Chat Completions 文本 Provider，并在诊断右栏显示等待、进行、成功和失败状态。翻译请求只发送文本与语言元数据，绝不发送音频、媒体 URL、Cookie、Referer 或浏览器授权头。启动预备 UI、10 秒超时降级、立即播放入口与首批译文自动播放已实现。 |
| 2026-08-19 | Step 5B 播放器字幕 Overlay | 代码完成，定向测试与完整测试通过，等待真实媒体验收 | 新增内存时间查询 Overlay：译文优先、原文降级，普通播放器与全屏播放器均按权威播放位置显示；拖动预览和异步翻译回填会立即刷新。`flutter analyze` 无问题，完整 Flutter 测试 `100/100` 通过。 |
| 待定 | Step 1 真实网络性能日志 | 进行中 | 补齐诊断字段，并用短视频、5 分钟和约 1 小时媒体记录 UI 延迟、worker 退出与字幕领先。 |
| 2026-08-18 | NLLB native runtime 技术尖峰 | 模型转换、runtime 编译和 Dart 接口草稿完成；真实推理与端到端未验收 | 已准备 `facebook/nllb-200-distilled-600M` 官方源文件并转换为未量化 ONNX external-data 包（约 7.38GB）；已准备 ONNX Runtime 1.29.0、SentencePiece v0.2.2，建立独立 `native/translation_core` C ABI，与 Whisper `speech_core` 分离；Windows DLL/测试 EXE 已生成，定向结构/ABI CTest 通过，Flutter 已接入 FFI 和持久 worker 草稿。实际模型翻译 smoke test、Dart 静态/运行验证、应用模型安装、Windows Release 和 iOS 静态库/真机验证均未完成。 |
| 待定 | 网络性能重新诊断 | 已冻结 | 在 Step 5 翻译 MVP 完成前不继续修改网络代理、容器预热、分段缓存或 seek 性能策略，避免与翻译链路变更交叉干扰。 |
| 2026-08-18 | Gemma/LiteRT-LM 跨平台路线核验 | 已完成资料核验；runtime spike 待真实运行 | 通过 `127.0.0.1:10808` 代理核验 Google AI Edge LiteRT-LM 官方 README、GitHub 仓库和 Hugging Face 模型元数据。LiteRT-LM 明确覆盖 Desktop/Windows 和 iOS；Windows CLI 支持 CPU/GPU，Swift API 为 Early Preview；官方 `litert-community/gemma-4-E2B-it-litert-lm` 提供 `.litertlm` 包。结论：Gemma 成为本地翻译主候选，NLLB/CTranslate2 仅作为未来专业备选，手写 NLLB ONNX decoder 已移除。 |
| 2026-08-18 | 手写 NLLB 路线清理 | 已完成 | 删除 `native/translation_core` 源码、CMake、转换脚本、测试、iOS 构建入口、Dart FFI、Dart worker 和 Windows ONNX Runtime/模型安装接入；历史本机缓存和构建目录保留但不参与 Git 或应用构建。 |
| 2026-08-18 | LiteRT-LM runtime spike 入口 | 已完成脚手架；等待官方 runtime/模型包 | 新增独立 `native/litert_lm` 目录和标准库 Python 检查工具；工具可通过 `127.0.0.1:10808` 查询官方模型仓库清单，并检查本地 `.litertlm` 文件。当前机器尚无 LiteRT-LM CLI/C++ runtime 和 Gemma 模型包，因此尚未宣称 Windows/iOS 真实文本生成通过。 |
| 2026-08-18 | Dart/文档路线一致性检查 | 静态分析通过；Flutter 定向测试未完成 | `dart analyze lib test` 无问题；`dart test` 不适用于 Flutter 测试依赖，`flutter test --no-pub test/domain/local_translation_model_test.dart` 启动后无 runner 输出，已停止。已修正旧的 `M2M100` 测试断言；需在 Flutter 测试工具链恢复后重跑。 |
