#ifndef SPEECH_CORE_PCM_H
#define SPEECH_CORE_PCM_H

#include <stddef.h>
#include <stdint.h>

#include "speech_core.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct speech_core_pcm_buffer {
  float* samples;
  size_t sample_count;
  uint32_t sample_rate;
  uint32_t channels;
} speech_core_pcm_buffer;

SPEECH_CORE_API speech_core_status speech_core_wav_to_pcm_f32(
    const uint8_t* data,
    size_t size,
    speech_core_pcm_buffer* output,
    speech_core_diagnostics* diagnostics);

SPEECH_CORE_API void speech_core_pcm_buffer_free(speech_core_pcm_buffer* buffer);

#ifdef __cplusplus
}
#endif

#endif
