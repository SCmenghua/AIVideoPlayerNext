#!/bin/sh
set -eu

# Builds a device or simulator archive which Runner force-loads so the C ABI is
# visible through Dart's DynamicLibrary.process(). Third-party source,
# generated archives, models and Metal tools remain outside Git.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
WHISPER_SOURCE="${AI_VIDEO_WHISPER_CPP_SOURCE_DIR:-${WHISPER_CPP_SOURCE_DIR:-}}"
PLATFORM="${PLATFORM_NAME:-iphoneos}"
ARCHS="${ARCHS:-arm64}"

if [ -z "$WHISPER_SOURCE" ] || [ ! -f "$WHISPER_SOURCE/CMakeLists.txt" ]; then
  echo "Set AI_VIDEO_WHISPER_CPP_SOURCE_DIR to whisper.cpp v1.7.6 before building iOS speech_core." >&2
  exit 1
fi

case "$PLATFORM" in
  iphoneos) SDK="iphoneos" ;;
  iphonesimulator) SDK="iphonesimulator" ;;
  *) echo "Unsupported iOS platform: $PLATFORM" >&2; exit 1 ;;
esac

BUILD_DIR="$ROOT/native/speech_core/build-ios/$PLATFORM"
SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
cmake -S "$ROOT/native/speech_core" -B "$BUILD_DIR" -G Xcode \
  -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DSPEECH_CORE_WITH_WHISPER=ON \
  -DWHISPER_CPP_SOURCE_DIR="$WHISPER_SOURCE" \
  -DGGML_METAL=ON \
  -DGGML_VULKAN=OFF \
  -DGGML_CUDA=OFF \
  -DSPEECH_CORE_BUILD_SHARED=OFF \
  -DSPEECH_CORE_BUILD_TOOLS=OFF \
  -DBUILD_TESTING=OFF
cmake --build "$BUILD_DIR" --config Release --target speech_core

RAW_ARCHIVE="$(find "$BUILD_DIR" -path '*Release*' -name libspeech_core.a -print -quit)"
if [ -z "$RAW_ARCHIVE" ] || [ ! -f "$RAW_ARCHIVE" ]; then
  echo "speech_core archive was not produced under: $BUILD_DIR" >&2
  exit 1
fi

# A static archive does not absorb its own whisper.cpp/ggml dependencies. Merge
# the generated archives so Runner can force-load one explicit artifact.
ARCHIVE_DIR="$BUILD_DIR/Release"
ARCHIVE="$ARCHIVE_DIR/libspeech_core.a"
RAW_COPY="$ARCHIVE_DIR/libspeech_core_raw.a"
mkdir -p "$ARCHIVE_DIR"
if [ "$RAW_ARCHIVE" != "$RAW_COPY" ]; then
  cp "$RAW_ARCHIVE" "$RAW_COPY"
fi
DEPENDENCIES="$(find "$BUILD_DIR" -path '*Release*' -name '*.a' \
  ! -name libspeech_core.a ! -name libspeech_core_raw.a -print)"
if [ -z "$DEPENDENCIES" ]; then
  echo "whisper.cpp/ggml static archives were not produced under: $BUILD_DIR" >&2
  exit 1
fi
rm -f "$ARCHIVE"
# shellcheck disable=SC2086
xcrun --sdk "$SDK" libtool -static -o "$ARCHIVE" "$RAW_COPY" $DEPENDENCIES
