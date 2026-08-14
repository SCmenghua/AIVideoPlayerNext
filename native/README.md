# Native boundaries

Platform-specific implementations live below this directory and are consumed through Flutter plugins or FFI. Phase 1 keeps these directories empty of platform code so the contracts can be tested with mocks first.

- `speech_core`: future C ABI wrapper around the independently reviewed speech engine
- `plugins/ios`: future Swift adapters for Apple platform services
- `plugins/android`: future Kotlin adapters for Android media and lifecycle services
- `plugins/windows`: future C++ adapters for Windows playback and optional system captions
- `tools`: future command-line regression tools
