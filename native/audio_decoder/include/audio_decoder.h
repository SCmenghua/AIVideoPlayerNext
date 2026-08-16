#ifndef AI_VIDEO_AUDIO_DECODER_H
#define AI_VIDEO_AUDIO_DECODER_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(AI_AUDIO_DECODER_BUILD)
#define AI_AUDIO_DECODER_API __declspec(dllexport)
#elif defined(_WIN32)
#define AI_AUDIO_DECODER_API __declspec(dllimport)
#else
#define AI_AUDIO_DECODER_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ai_audio_decoder ai_audio_decoder;

typedef enum ai_audio_decoder_status {
  AI_AUDIO_DECODER_OK = 0,
  AI_AUDIO_DECODER_INVALID_ARGUMENT = 1,
  AI_AUDIO_DECODER_OPEN_FAILED = 2,
  AI_AUDIO_DECODER_NO_AUDIO = 3,
  AI_AUDIO_DECODER_NOT_READY = 4,
  AI_AUDIO_DECODER_CANCELLED = 5,
  AI_AUDIO_DECODER_INTERNAL_ERROR = 6,
} ai_audio_decoder_status;

typedef struct ai_audio_decoder_chunk {
  int64_t media_start_ms;
  uint32_t sample_rate;
  uint32_t channels;
  uint32_t sample_count;
  const float* samples;
  uint8_t is_last;
} ai_audio_decoder_chunk;

typedef void (*ai_audio_decoder_chunk_callback)(
    const ai_audio_decoder_chunk* chunk,
    void* user_data);

AI_AUDIO_DECODER_API const char* ai_audio_decoder_status_message(
    ai_audio_decoder_status status);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_create(
    ai_audio_decoder** out_decoder);
AI_AUDIO_DECODER_API void ai_audio_decoder_destroy(ai_audio_decoder* decoder);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_open(
    ai_audio_decoder* decoder,
    const char* path);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_set_realtime(
    ai_audio_decoder* decoder,
    uint8_t enabled);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_start(
    ai_audio_decoder* decoder,
    ai_audio_decoder_chunk_callback callback,
    void* user_data);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_pause(
    ai_audio_decoder* decoder);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_seek(
    ai_audio_decoder* decoder,
    int64_t position_ms);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_stop(
    ai_audio_decoder* decoder);
AI_AUDIO_DECODER_API void ai_audio_decoder_chunk_free(
    const ai_audio_decoder_chunk* chunk);

#ifdef __cplusplus
}
#endif

#endif
