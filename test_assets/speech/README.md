# Speech regression assets

This directory is intentionally empty of audio and model files. Prepare only
owned or explicitly licensed material locally, then record its metadata in
`manifest.json`. The files are ignored by the repository-level rules. The
checked-in manifest describes the project-owned Windows SAPI English fixture
used for the first real-model regression, but does not reveal its local path
or include the WAV.

The Phase 5 reference format is 16 kHz, mono, Float32 PCM after normalization.
Input WAV files may use supported PCM integer formats and are normalized by
`speech_core_wav_to_pcm_f32`.
