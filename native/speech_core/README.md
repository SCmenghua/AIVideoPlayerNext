# speech_core

This directory owns the narrow C ABI used by Dart FFI. It accepts normalized
16 kHz, mono, Float32 PCM and returns timestamped final segments through a C
callback. C++ types, exceptions, STL containers, and whisper.cpp handles never
cross the public boundary.

## Current status

- WAV parsing supports PCM integer 8/16/24/32-bit and IEEE Float32 input.
- Resampling uses deterministic linear interpolation and downmixes channels by
  averaging, clipping samples to `[-1.0, 1.0]`.
- The deterministic test model is an ABI/lifecycle fixture only. It is never a
  speech recognizer and must not be used for product recognition.
- The whisper.cpp backend is opt-in and is not enabled by the default build.
- `language = "auto"` performs automatic language selection and transcription.
  It must not enable whisper.cpp's `detect_language` flag, because that flag is
  detect-only and intentionally returns no text segments.

## Toolchain and build

The verified Windows toolchain is Flutter 3.47.0, Dart 3.13.0, Visual Studio
Community 2026 18.9.0, MSVC 14.51, CMake 4.3.1, Ninja, and Windows SDK
10.0.26100.0. Android SDK is not installed in the current environment.

```powershell
$cmake = 'D:\Software\Visual Studio 2026\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
& $cmake -S native/speech_core -B native/speech_core/build -G Ninja
& $cmake --build native/speech_core/build
& $cmake --build native/speech_core/build --target test
```

For the real backend, prepare whisper.cpp outside the repository at the pinned
tag `v1.7.6` (commit `a8d002cfd879315632a579e73f0148d06959de36`) and verify its
MIT license and notices before distribution:

```powershell
& $cmake -S native/speech_core -B native/speech_core/build-whisper -G Ninja `
  -DSPEECH_CORE_WITH_WHISPER=ON `
  -DWHISPER_CPP_SOURCE_DIR='C:\path\to\whisper.cpp-v1.7.6'
```

Whisper model files and speech recordings are local-only. Their licenses must
be recorded in `test_assets/speech/manifest.json`; no model, audio, full local
path, PCM content, cookies, or authorization headers belong in Git or default
diagnostic output.

The first real-model verification used `ggml-large-v3-turbo-q5_0` with the
metadata and SHA-256 recorded in the manifest. On the Windows CPU backend,
the local English fixture produced seven final segments with automatic language
detection. This is a regression baseline, not a device-performance target.

## iOS Phase 6.5 integration

iOS uses the same C ABI as Windows, with a static `speech_core` archive linked
into the Runner executable. The archive is built on macOS by the Xcode build
phase from `ios/build_speech_core_ios.sh`; set
`AI_VIDEO_WHISPER_CPP_SOURCE_DIR` to the repository-external whisper.cpp
v1.7.6 checkout before opening Xcode. The script uses the `iphoneos` or
`iphonesimulator` SDK selected by Xcode, enables `GGML_METAL`, and merges the
whisper.cpp/ggml static archives before Runner force-loads the result.

The iOS app looks for `ggml-large-v3-turbo-q5_0.bin` in
`Application Support/models/`. The Flutter MethodChannel also exposes a
controlled `installModel` operation for an import/settings flow; a model may
instead be supplied as an explicitly bundled release asset. No model binary,
Metal SDK, generated archive, or Xcode build directory is committed.

Windows cannot validate this path. A macOS/Xcode build must still verify the
Swift bridge, archive link, model load, and actual Metal or CPU fallback on a
real iPhone before Phase 6 and Phase 6.5 iOS acceptance can be closed.

## Exit codes

`speech_regression.exe` returns `0` for success, `2` for argument/output
errors, `3` for WAV/material errors, `4` for model errors or an unavailable
backend, `5` for recognition/lifecycle errors, and `6` for cancellation.
