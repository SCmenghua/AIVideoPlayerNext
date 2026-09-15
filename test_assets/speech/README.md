# Speech regression assets

This directory holds no audio or model files. `manifest.json` records the
models the application can install (with SHA-256 and size) and how the CI
recognition regression is sourced.

- Models are downloaded by CI and by the application; they never enter Git.
- The CI regression uses the first 20 clips of the public JSUT basic5000 set
  (CC-BY-SA 4.0) via `app/packages/recognition/bin/regression.dart`.
- Local regression on private material: write a directory with `manifest.json`
  (`{"clips":[{"file":"0001.wav","text":"..."}]}`) and WAV files, then run the
  same runner with `--dataset` pointing at it. Keep such material out of Git.

Pipeline input is normalised to 16 kHz, mono, Float32 PCM by speech_core's
anti-aliased resampler; WAV inputs may use any supported PCM integer or float
format.
