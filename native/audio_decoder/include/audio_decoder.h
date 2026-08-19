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

typedef void (*ai_audio_decoder_open_callback)(
    ai_audio_decoder_status status,
    uint32_t sample_rate,
    uint32_t channels,
    void* user_data);

AI_AUDIO_DECODER_API const char* ai_audio_decoder_status_message(
    ai_audio_decoder_status status);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_create(
    ai_audio_decoder** out_decoder);
AI_AUDIO_DECODER_API void ai_audio_decoder_destroy(ai_audio_decoder* decoder);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_open(
    ai_audio_decoder* decoder,
    const char* path);
// Opens a media source on a native worker. The callback is delivered after the
// reader is ready or opening has failed/cancelled.
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_open_async(
    ai_audio_decoder* decoder,
    const char* path,
    int64_t start_position_ms,
    ai_audio_decoder_open_callback callback,
    void* user_data);
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
// Repositions an already-open reader on a native worker. The callback is
// delivered after the previous decode read has exited and the position has
// been applied, so callers never block a UI thread on network I/O.
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_seek_async(
    ai_audio_decoder* decoder,
    int64_t position_ms,
    ai_audio_decoder_open_callback callback,
    void* user_data);
AI_AUDIO_DECODER_API ai_audio_decoder_status ai_audio_decoder_stop(
    ai_audio_decoder* decoder);
// Waits for a previously cancelled worker to exit. This may block on network
// I/O and must be called off the UI thread.
AI_AUDIO_DECODER_API void ai_audio_decoder_wait(ai_audio_decoder* decoder);
AI_AUDIO_DECODER_API void ai_audio_decoder_chunk_free(
    const ai_audio_decoder_chunk* chunk);

#ifdef __cplusplus
}
#endif

#endif
