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

#define SPEECH_CORE_ABI_VERSION 3
#define SPEECH_CORE_SAMPLE_RATE 16000

typedef struct speech_core_model speech_core_model;
typedef struct speech_core_session speech_core_session;
typedef struct speech_core_vad speech_core_vad;

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
  SPEECH_CORE_INTERNAL_ERROR = 10,
  SPEECH_CORE_BUFFER_TOO_SMALL = 11
} speech_core_status;

typedef enum speech_core_requested_backend {
  SPEECH_CORE_REQUESTED_BACKEND_AUTO = 0,
  SPEECH_CORE_REQUESTED_BACKEND_CPU = 1,
  SPEECH_CORE_REQUESTED_BACKEND_VULKAN = 2,
  SPEECH_CORE_REQUESTED_BACKEND_METAL = 3
} speech_core_requested_backend;

typedef enum speech_core_actual_backend {
  SPEECH_CORE_ACTUAL_BACKEND_UNKNOWN = 0,
  SPEECH_CORE_ACTUAL_BACKEND_CPU = 1,
  SPEECH_CORE_ACTUAL_BACKEND_VULKAN = 2,
  SPEECH_CORE_ACTUAL_BACKEND_METAL = 3,
  SPEECH_CORE_ACTUAL_BACKEND_UNAVAILABLE = 4
} speech_core_actual_backend;

typedef enum speech_core_fallback_reason {
  SPEECH_CORE_FALLBACK_NONE = 0,
  SPEECH_CORE_FALLBACK_BACKEND_NOT_BUILT = 1,
  SPEECH_CORE_FALLBACK_LOADER_MISSING = 2,
  SPEECH_CORE_FALLBACK_DEVICE_UNAVAILABLE = 3,
  SPEECH_CORE_FALLBACK_INIT_FAILED = 4,
  SPEECH_CORE_FALLBACK_RUNTIME_FAILED = 5,
  SPEECH_CORE_FALLBACK_MEMORY_ERROR = 6,
  SPEECH_CORE_FALLBACK_MODEL_ERROR = 7
} speech_core_fallback_reason;

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
  uint32_t dropped_segment_count;
} speech_core_diagnostics;

/* Decoder parameters for one recognition call. Initialise with
 * speech_core_recognize_options_init and override individual fields. */
typedef struct speech_core_recognize_options {
  const char* language;        /* NULL or "" selects automatic detection */
  const char* initial_prompt;  /* NULL disables the prompt */
  int32_t n_threads;
  int32_t beam_size;           /* <= 1 selects greedy decoding */
  int32_t audio_context;       /* 0 keeps the model's full encoder context */
  float temperature;
  float temperature_increment; /* <= 0 disables temperature fallback */
  float entropy_threshold;     /* <= 0 disables the compression-ratio check */
  float logprob_threshold;     /* > 0 disables the log-probability check */
  float no_speech_threshold;   /* segments above this probability are dropped */
  uint8_t token_timestamps;
  uint8_t suppress_non_speech_tokens;
  uint8_t suppress_blank;
} speech_core_recognize_options;

typedef struct speech_core_segment {
  uint32_t segment_index;
  int64_t start_ms;
  int64_t end_ms;
  const char* text;
  const char* language;
  float avg_logprob;      /* mean log-probability of the text tokens */
  float no_speech_prob;
  float repetition;       /* share of repeated 4-grams in the text, 0..1 */
  uint32_t token_count;
} speech_core_segment;

typedef void (*speech_core_segment_callback)(
    const speech_core_segment* segment,
    void* user_data);

SPEECH_CORE_API const char* speech_core_status_message(speech_core_status status);

SPEECH_CORE_API uint32_t speech_core_abi_version(void);

SPEECH_CORE_API void speech_core_recognize_options_init(
    speech_core_recognize_options* options);

SPEECH_CORE_API speech_core_status speech_core_model_create_with_backend(
    const char* model_path,
    speech_core_requested_backend requested_backend,
    speech_core_model** out_model);

SPEECH_CORE_API speech_core_status speech_core_model_create(
    const char* model_path,
    speech_core_model** out_model);
SPEECH_CORE_API void speech_core_model_destroy(speech_core_model* model);

SPEECH_CORE_API speech_core_requested_backend speech_core_model_requested_backend(
    const speech_core_model* model);
SPEECH_CORE_API speech_core_actual_backend speech_core_model_actual_backend(
    const speech_core_model* model);
SPEECH_CORE_API uint8_t speech_core_model_gpu_enabled(
    const speech_core_model* model);
SPEECH_CORE_API const char* speech_core_model_device_name(
    const speech_core_model* model);
SPEECH_CORE_API speech_core_fallback_reason speech_core_model_fallback_reason(
    const speech_core_model* model);
SPEECH_CORE_API const char* speech_core_model_backend_message(
    const speech_core_model* model);

SPEECH_CORE_API speech_core_status speech_core_session_create(
    speech_core_model* model,
    const char* session_id,
    speech_core_session** out_session);
SPEECH_CORE_API void speech_core_session_destroy(speech_core_session* session);
SPEECH_CORE_API speech_core_status speech_core_session_cancel(
    speech_core_session* session);

/* Recognises one window of 16 kHz mono float samples. Segments are reported
 * through the callback with window-relative timestamps. */
SPEECH_CORE_API speech_core_status speech_core_session_recognize(
    speech_core_session* session,
    const float* samples,
    size_t sample_count,
    uint32_t sample_rate,
    const speech_core_recognize_options* options,
    speech_core_segment_callback callback,
    void* user_data,
    speech_core_diagnostics* diagnostics);

/* Silero voice activity detection through whisper.cpp. */
SPEECH_CORE_API speech_core_status speech_core_vad_create(
    const char* model_path,
    int32_t n_threads,
    speech_core_vad** out_vad);
SPEECH_CORE_API void speech_core_vad_destroy(speech_core_vad* vad);

/* Number of 16 kHz samples covered by one probability. */
SPEECH_CORE_API uint32_t speech_core_vad_frame_samples(const speech_core_vad* vad);

/* Writes one speech probability per frame. The detector state is reset on
 * every call, so callers streaming audio should overlap successive calls by a
 * few frames and discard the overlapped probabilities. */
SPEECH_CORE_API speech_core_status speech_core_vad_probabilities(
    speech_core_vad* vad,
    const float* samples,
    size_t sample_count,
    float* out_probabilities,
    size_t out_capacity,
    size_t* out_count);

#ifdef __cplusplus
}
#endif

#endif
