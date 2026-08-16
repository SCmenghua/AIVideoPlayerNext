# Windows Whisper Model

Place `ggml-large-v3-turbo-q5_0.bin` in this directory before creating a
Windows Release build. CMake installs it beside the executable as
`models/ggml-large-v3-turbo-q5_0.bin`, and the application only loads that
published copy (unless the explicit `AI_VIDEO_WHISPER_MODEL` override is set).

The model binary is intentionally ignored by ordinary Git because it is about
547 MB and exceeds common Git hosting file limits. Use a release asset or Git
LFS when a repository-hosted distribution is required.
