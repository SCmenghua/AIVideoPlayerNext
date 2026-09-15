# AI Video Player Next

本地优先的视频播放器：播放本地 / 网络视频，用 whisper.cpp 在本机做带时间戳的语音识别，接可替换的翻译 Provider 输出双语字幕。目标平台 Windows 与 iOS。

当前处于重构阶段，计划与进度见 `PLAN.md`。

## 目录

```text
app/                 Flutter 应用（Windows / iOS）
app/packages/        纯 Dart 包（识别管线，不依赖 Flutter）
native/speech_core/  whisper.cpp C ABI（识别、VAD、重采样）
native/audio_decoder Windows Media Foundation 音频解码器
native/tools/        speech_regression 等命令行工具
test_assets/         测试素材清单（素材本身不入 Git）
docs/                架构说明
```

## 构建与验证

模型权重、VAD 模型与回归素材不入 Git，由 CI 下载并校验 SHA-256。

| Workflow | 触发 | 作用 |
|---|---|---|
| `windows.yml` | push `main` / `refactor`，PR | analyze、test、原生构建、CTest、识别回归、Windows 包 |
| `ios.yml` | push `main` / `refactor`，PR | analyze、test、iOS 编译（含 speech_core） |
| `build-windows-release.yml` | 手动 | Windows 发布包 |
| `build-unsigned-ios-ipa.yml` | 手动 | 未签名 IPA |

本地开发（需 Flutter SDK）：

```text
cd app
flutter pub get
flutter analyze
flutter test
```
