# LiteRT-LM Gemma runtime spike

This directory is the isolated validation boundary for the primary local
translation candidate: Gemma 4 E2B IT with Google LiteRT-LM.

The spike deliberately has no Dart, Flutter, or NLLB decoder dependency. It
must answer these questions before the model is connected to the app:

1. Can the official `.litertlm` package load on Windows through the official
   LiteRT-LM CLI or C/C++ API?
2. Can the same model family load on iOS through the official Swift/native
   API on a real device?
3. Can both runtimes generate a short text response, cancel a request, and
   report load time, peak memory, and backend?

## Model package

- Source checkpoint: `google/gemma-4-E2B-it-qat-mobile-transformers`
- Runtime package: `litert-community/gemma-4-E2B-it-litert-lm`
- Runtime format: `.litertlm`
- Proxy for downloads and metadata: `http://127.0.0.1:10808`

The source checkpoint's `model.safetensors` is not an interchangeable input
for LiteRT-LM. Do not copy it here and do not add it to an app bundle.

## Windows procedure

Run the package checker first:

```powershell
python native/litert_lm/tools/litert_lm_spike.py list-remote
python native/litert_lm/tools/litert_lm_spike.py inspect path/to/gemma-4-E2B-it.litertlm
```

After installing or building the official LiteRT-LM Windows CLI, run the
official CLI command from that build with a short prompt and record the exact
command, runtime revision, backend, load time, peak working set, output, and
whether cancellation worked. The checker intentionally does not guess the
CLI flags because those are version-specific.

## iOS procedure

Use the official LiteRT-LM Swift/native package in a separate Xcode target.
On a real iPhone, record model installation, CPU/Metal selection, first-token
latency, peak memory, cancellation, and the same short prompt used on Windows.
Only after this target passes should a Flutter method-channel/FFI bridge be
introduced.

Until both smoke tests pass, the app must report Gemma as the primary
candidate but unavailable. NLLB/CTranslate2 remains a specialist fallback.
