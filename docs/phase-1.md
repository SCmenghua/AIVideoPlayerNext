# Phase 1: Repository and Windows Toolchain

## Scope

Phase 1 establishes a clean Flutter application boundary and deterministic test doubles. It does not implement media decoding or speech inference.

## Boundaries

- UI depends on domain interfaces, never on a platform player or recognition engine.
- Mock services provide the first executable behavior and are replaceable through Riverpod overrides.
- Domain models remain Flutter-independent where practical.
- Models and media are intentionally excluded from Git.

## Acceptance checklist

- [x] `flutter analyze` (2026-08-15)
- [x] `flutter test` (6 tests, 2026-08-15)
- [x] `flutter build windows --debug` (2026-08-15)
- [x] `flutter build windows --release` (2026-08-15)
- [x] Flutter Windows support, Visual Studio 2026 C++ workload, CMake, and Windows SDK installed
- [x] New Git history created independently

## Verification record

- Flutter 3.47.0 and Dart 3.13.0
- Visual Studio Community 2026 18.9.0, MSVC 14.51, CMake, and Windows SDK 10.0.26100.0
- Debug artifact: `app/build/windows/x64/runner/Debug/ai_video_player_next.exe`
- Release artifact: `app/build/windows/x64/runner/Release/ai_video_player_next.exe`

Android SDK is not installed yet. That prevents Android builds only; it does not affect the completed Windows Phase 1 acceptance.

## Next phase

Phase 2 should replace only the player implementation behind `PlayerService`, add file selection, and preserve the `PlaybackSnapshot` contract.
