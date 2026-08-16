#ifndef SPEECH_CORE_H
#define SPEECH_CORE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(SPEECH_CORE_BUILD)
#define SPEECH_CORE_API __declspec(dllexport)
#elif defined(_WIN32)
#define SPEECH_CORE_API __declspec(dllimport)
#else
#define SPEECH_CORE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct speech_core_model speech_core_model;
typedef struct speech_core_session speech_core_session;

typedef enum speech_core_status {
  SPEECH_CORE_OK = 0,
  SPEECH_CORE_INVALID_ARGUMENT = 1,
  SPEECH_CORE_MODEL_NOT_FOUND = 2,
  SPEECH_CORE_MODEL_LOAD_FAILED = 3,
  SPEECH_CORE_AUDIO_FORMAT_ERROR = 4,
  SPEECH_CORE_EMPTY_AUDIO = 5,
  SPEECH_CORE_AUDIO_TOO_LONG = 6,
  SPEECH_CORE_RECOGNITION_FAILED = 7,
  SPEECH_CORE_CANCELLED = 8,
  SPEECH_CORE_BACKEND_UNAVAILABLE = 9,
  SPEECH_CORE_INTERNAL_ERROR = 10
} speech_core_status;

typedef struct speech_core_diagnostics {
  uint64_t audio_samples;
  uint32_t input_sample_rate;
  uint32_t input_channels;
  uint64_t input_samples;
  uint32_t output_sample_rate;
  uint32_t output_channels;
  uint64_t inference_ms;
  double realtime_factor;
  uint32_t segment_count;
} speech_core_diagnostics;

typedef struct speech_core_segment {
  uint32_t segment_index;
  int64_t start_ms;
  int64_t end_ms;
  const char* text;
  const char* language;
  float confidence;
  uint8_t is_final;
} speech_core_segment;

typedef void (*speech_core_segment_callback)(
    const speech_core_segment* segment,
    void* user_data);

SPEECH_CORE_API const char* speech_core_status_message(speech_core_status status);

SPEECH_CORE_API speech_core_status speech_core_model_create(
    const char* model_path,
    speech_core_model** out_model);
SPEECH_CORE_API void speech_core_model_destroy(speech_core_model* model);

SPEECH_CORE_API speech_core_status speech_core_session_create(
    speech_core_model* model,
    const char* session_id,
    speech_core_session** out_session);
SPEECH_CORE_API void speech_core_session_destroy(speech_core_session* session);
SPEECH_CORE_API speech_core_status speech_core_session_cancel(
    speech_core_session* session);

SPEECH_CORE_API speech_core_status speech_core_session_recognize(
    speech_core_session* session,
    const float* samples,
    size_t sample_count,
    uint32_t sample_rate,
    const char* language,
    int32_t n_threads,
    speech_core_segment_callback callback,
    void* user_data,
    speech_core_diagnostics* diagnostics);

#ifdef __cplusplus
}
#endif

#endif
