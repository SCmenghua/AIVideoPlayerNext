# Local translation model assets

This directory is reserved for the local translation runtime and model package.
The model is not included in the repository.

## Primary candidate: Gemma 4 E2B IT

Use the official LiteRT-LM runtime with the converted model package:

- Model source: `google/gemma-4-E2B-it-qat-mobile-transformers`
- Runtime: `google-ai-edge/LiteRT-LM`
- Deployment package: `litert-community/gemma-4-E2B-it-litert-lm`
- File format: `.litertlm`, not a directly loadable Transformers
  `model.safetensors` file
- License: Apache-2.0

LiteRT-LM officially documents desktop/Windows and native iOS support. The
Windows path has CPU/GPU CLI support; the iOS path has a Swift API in early
preview. A runtime spike must still prove the exact Windows C++/C API loading
path and the iOS Swift loading path with a short text prompt before this model
is marked usable by the app.

The Hugging Face `mobile-transformers` checkpoint and the LiteRT-LM package are
related model representations, but they are not interchangeable file formats.
Do not copy the raw `model.safetensors` into this directory and assume that
LiteRT-LM can load it directly.

## Specialist fallback

If professional translation quality or broader language coverage is required,
evaluate a mature CTranslate2 integration separately. The removed handwritten
NLLB ONNX decoder is not an application dependency.

Neither local model is currently declared usable by the application. Model
installation, runtime loading, a text smoke test, and release packaging remain
separate acceptance gates.
