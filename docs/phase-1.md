# Phase 1: Repository and Windows Toolchain

## Scope

Phase 1 establishes a clean Flutter application boundary and deterministic test doubles. It does not implement media decoding or speech inference.

## Boundaries

- UI depends on domain interfaces, never on a platform player or recognition engine.
- Mock services provide the first executable behavior and are replaceable through Riverpod overrides.
- Domain models remain Flutter-independent where practical.
- Models and media are intentionally excluded from Git.

## Acceptance checklist

- [ ] `flutter analyze`
- [ ] `flutter test`
- [ ] `flutter build windows`
- [ ] Windows desktop workload, CMake, and Flutter Windows support installed
- [ ] New Git history created independently

## Next phase

Phase 2 should replace only the player implementation behind `PlayerService`, add file selection, and preserve the `PlaybackSnapshot` contract.
