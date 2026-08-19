# iOS local translation model assets

This directory is reserved for local translation model resources used through
the LiteRT-LM Swift/native bridge. The model is not copied into the IPA yet.

The primary candidate is the Apache-2.0 Gemma 4 E2B IT mobile model:

- Source checkpoint: `google/gemma-4-E2B-it-qat-mobile-transformers`
- Runtime: Google LiteRT-LM
- Deployment package: `litert-community/gemma-4-E2B-it-litert-lm`
- Runtime format: `.litertlm`

LiteRT-LM officially covers iOS and desktop/Windows, but its Swift API is early
preview. The iOS runtime spike must prove model installation, Metal/CPU
backend selection, text generation and memory behavior on a real device before
the model is included in an IPA.

If professional translation quality or broader language coverage is required,
evaluate a mature CTranslate2 integration separately. Do not add raw Gemma
`model.safetensors` files to the IPA; packaging must use a validated LiteRT-LM
runtime package and an explicit license/release-size decision.
