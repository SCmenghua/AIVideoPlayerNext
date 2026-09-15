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

typedef struct speech_core_resampler speech_core_resampler;

/* Streaming converter from interleaved float PCM at any sample rate to
 * 16 kHz mono. Downmixes by channel average and resamples with an
 * anti-aliased windowed-sinc filter; state carries across process calls so
 * chunk boundaries do not produce discontinuities. */
SPEECH_CORE_API speech_core_status speech_core_resampler_create(
    uint32_t input_sample_rate,
    uint32_t input_channels,
    speech_core_resampler** out_resampler);
SPEECH_CORE_API void speech_core_resampler_destroy(
    speech_core_resampler* resampler);

/* Upper bound on the output samples produced by process for input_frames
 * frames, including any samples still held back for the filter. */
SPEECH_CORE_API size_t speech_core_resampler_max_output(
    const speech_core_resampler* resampler,
    size_t input_frames);

SPEECH_CORE_API speech_core_status speech_core_resampler_process(
    speech_core_resampler* resampler,
    const float* interleaved,
    size_t input_frames,
    float* output,
    size_t output_capacity,
    size_t* output_count);

/* Emits the samples held back by the filter delay. The resampler must not be
 * used afterwards except to destroy it. */
SPEECH_CORE_API speech_core_status speech_core_resampler_flush(
    speech_core_resampler* resampler,
    float* output,
    size_t output_capacity,
    size_t* output_count);

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
