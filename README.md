# AI Video Player Next

Independent Flutter application for a local-first video player with timestamped speech recognition and replaceable translation providers.

This repository starts at Phase 1. It has no source, asset, configuration, CI, model, or test dependency on `D:\code\Player`.

## Phase 1 status

- Flutter application shell and responsive desktop/mobile workbench
- Pure Dart service contracts for playback, recognition, and translation
- Mock providers for deterministic UI and unit tests
- Dependency injection through Riverpod
- Test asset manifest and architecture notes
- Windows, Android, and iOS targets reserved in the project layout

## Local commands

Run these commands from `app/` after installing the Flutter SDK and Windows desktop prerequisites:

```text
flutter pub get
flutter analyze
flutter test
flutter build windows
```

The repository intentionally does not contain downloaded models or media. Add only licensed test assets and record them in `test_assets/manifest.json`.
