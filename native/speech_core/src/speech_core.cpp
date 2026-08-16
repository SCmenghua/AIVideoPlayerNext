#include "speech_core.h"

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <new>
#include <string>
#include <string_view>

#ifdef SPEECH_CORE_WITH_WHISPER
#include "whisper.h"
#include "ggml-backend.h"
#endif

struct speech_core_model {
  enum class Backend { test, whisper } backend = Backend::test;
  speech_core_requested_backend requested_backend =
      SPEECH_CORE_REQUESTED_BACKEND_CPU;
  speech_core_actual_backend actual_backend = SPEECH_CORE_ACTUAL_BACKEND_CPU;
  speech_core_fallback_reason fallback_reason = SPEECH_CORE_FALLBACK_NONE;
  bool gpu_enabled = false;
  std::string device_name;
  std::string backend_message;
  std::string model_path;
#ifdef SPEECH_CORE_WITH_WHISPER
  whisper_context* whisper = nullptr;
#endif
};

struct speech_core_session {
  speech_core_model* model = nullptr;
  std::string session_id;
  std::atomic<bool> cancelled{false};
};

namespace {

constexpr char kTestModelHeader[] = "SPEECH_CORE_TEST_MODEL_V1\n";

bool file_exists(const char* path) {
  std::ifstream file(path, std::ios::binary);
  return file.good();
}

bool is_test_model(const char* path) {
  std::ifstream file(path, std::ios::binary);
  std::string header(sizeof(kTestModelHeader) - 1, '\0');
  file.read(header.data(), static_cast<std::streamsize>(header.size()));
  return file.good() && header == kTestModelHeader;
}

#ifdef SPEECH_CORE_WITH_WHISPER
bool is_vulkan_device(ggml_backend_dev_t device) {
  if (device == nullptr) return false;
  const char* name = ggml_backend_dev_name(device);
  if (name == nullptr) return false;
  const std::string_view value(name);
  return value.find("Vulkan") != std::string_view::npos ||
      value.find("vulkan") != std::string_view::npos;
}

bool is_metal_device(ggml_backend_dev_t device) {
  if (device == nullptr) return false;
  const char* name = ggml_backend_dev_name(device);
  if (name == nullptr) return false;
  const std::string_view value(name);
  return value.find("Metal") != std::string_view::npos ||
      value.find("metal") != std::string_view::npos;
}

const char* vulkan_device_description(ggml_backend_dev_t device) {
  if (device == nullptr) return "";
  const char* description = ggml_backend_dev_description(device);
  if (description != nullptr && description[0] != '\0') return description;
  return ggml_backend_dev_name(device);
}

const char* backend_device_description(ggml_backend_dev_t device) {
  return vulkan_device_description(device);
}

ggml_backend_dev_t find_vulkan_device() {
  for (size_t index = 0; index < ggml_backend_dev_count(); ++index) {
    auto* device = ggml_backend_dev_get(index);
    if (is_vulkan_device(device)) return device;
  }
  return nullptr;
}

ggml_backend_dev_t find_metal_device() {
  for (size_t index = 0; index < ggml_backend_dev_count(); ++index) {
    auto* device = ggml_backend_dev_get(index);
    if (is_metal_device(device)) return device;
  }
  return nullptr;
}

whisper_context* initialize_whisper_context(
    const char* model_path,
    bool use_gpu) {
  whisper_context_params params = whisper_context_default_params();
  params.use_gpu = use_gpu;
  return whisper_init_from_file_with_params(model_path, params);
}
#endif

void clear_diagnostics(speech_core_diagnostics* diagnostics) {
  if (diagnostics != nullptr) *diagnostics = {};
}

#ifdef SPEECH_CORE_WITH_WHISPER
bool whisper_abort_callback(void* user_data) {
  const auto* session = static_cast<const speech_core_session*>(user_data);
  return session->cancelled.load();
}
#endif

}  // namespace

extern "C" const char* speech_core_status_message(speech_core_status status) {
  switch (status) {
    case SPEECH_CORE_OK: return "ok";
    case SPEECH_CORE_INVALID_ARGUMENT: return "invalid argument";
    case SPEECH_CORE_MODEL_NOT_FOUND: return "model not found";
    case SPEECH_CORE_MODEL_LOAD_FAILED: return "model load failed";
    case SPEECH_CORE_AUDIO_FORMAT_ERROR: return "audio format error";
    case SPEECH_CORE_EMPTY_AUDIO: return "empty audio";
    case SPEECH_CORE_AUDIO_TOO_LONG: return "audio too long";
    case SPEECH_CORE_RECOGNITION_FAILED: return "recognition failed";
    case SPEECH_CORE_CANCELLED: return "cancelled";
    case SPEECH_CORE_BACKEND_UNAVAILABLE: return "recognition backend unavailable";
    case SPEECH_CORE_INTERNAL_ERROR: return "internal error";
  }
  return "unknown error";
}

extern "C" uint32_t speech_core_abi_version(void) { return 2; }

extern "C" speech_core_status speech_core_model_create_with_backend(
    const char* model_path,
    speech_core_requested_backend requested_backend,
    speech_core_model** out_model) {
  if (model_path == nullptr || out_model == nullptr || model_path[0] == '\0') {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  if (requested_backend < SPEECH_CORE_REQUESTED_BACKEND_AUTO ||
      requested_backend > SPEECH_CORE_REQUESTED_BACKEND_METAL) {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  *out_model = nullptr;
  if (!file_exists(model_path)) return SPEECH_CORE_MODEL_NOT_FOUND;

  auto model = std::unique_ptr<speech_core_model>(new (std::nothrow) speech_core_model());
  if (!model) return SPEECH_CORE_INTERNAL_ERROR;
  model->requested_backend = requested_backend;
  model->model_path = model_path;
  if (is_test_model(model_path)) {
    model->backend = speech_core_model::Backend::test;
    model->actual_backend = SPEECH_CORE_ACTUAL_BACKEND_CPU;
    model->backend_message = "deterministic test model";
    *out_model = model.release();
    return SPEECH_CORE_OK;
  }
#ifdef SPEECH_CORE_WITH_WHISPER
  ggml_backend_load_all();
  const bool request_metal =
      requested_backend == SPEECH_CORE_REQUESTED_BACKEND_METAL
#ifdef SPEECH_CORE_GGML_METAL
      || requested_backend == SPEECH_CORE_REQUESTED_BACKEND_AUTO
#endif
      ;
  const bool request_vulkan =
      requested_backend == SPEECH_CORE_REQUESTED_BACKEND_VULKAN
#ifndef SPEECH_CORE_GGML_METAL
      || requested_backend == SPEECH_CORE_REQUESTED_BACKEND_AUTO
#endif
      ;
  auto* metal_device = request_metal ? find_metal_device() : nullptr;
  auto* vulkan_device = request_vulkan ? find_vulkan_device() : nullptr;
  if (request_vulkan && vulkan_device == nullptr) {
    model->fallback_reason = SPEECH_CORE_FALLBACK_DEVICE_UNAVAILABLE;
    model->backend_message = "Vulkan device unavailable";
  }
#ifndef SPEECH_CORE_GGML_METAL
  if (request_metal) {
    model->fallback_reason = SPEECH_CORE_FALLBACK_BACKEND_NOT_BUILT;
    model->backend_message = "Metal backend is not built";
  }
#else
  if (request_metal && metal_device == nullptr) {
    model->fallback_reason = SPEECH_CORE_FALLBACK_DEVICE_UNAVAILABLE;
    model->backend_message = "Metal device unavailable";
  }
#endif
  bool use_gpu = (request_vulkan && vulkan_device != nullptr) ||
      (request_metal && metal_device != nullptr);
  if (use_gpu) {
    model->device_name = backend_device_description(
        metal_device != nullptr ? metal_device : vulkan_device);
    model->actual_backend = SPEECH_CORE_ACTUAL_BACKEND_UNKNOWN;
  } else {
    model->actual_backend = SPEECH_CORE_ACTUAL_BACKEND_CPU;
    if (model->backend_message.empty()) model->backend_message = "CPU backend";
  }
  model->whisper = initialize_whisper_context(model_path, use_gpu);
  if (model->whisper == nullptr) {
    if (use_gpu) {
      model->fallback_reason = SPEECH_CORE_FALLBACK_INIT_FAILED;
      model->backend_message = metal_device != nullptr
          ? "Metal initialization failed; retrying with CPU"
          : "Vulkan initialization failed; retrying with CPU";
      use_gpu = false;
      model->whisper = initialize_whisper_context(model_path, false);
      model->actual_backend = SPEECH_CORE_ACTUAL_BACKEND_CPU;
      model->gpu_enabled = false;
    }
    if (model->whisper == nullptr) {
      if (model->fallback_reason == SPEECH_CORE_FALLBACK_NONE) {
        model->fallback_reason = SPEECH_CORE_FALLBACK_MODEL_ERROR;
      }
      model->backend_message = "Whisper context initialization failed";
      return SPEECH_CORE_MODEL_LOAD_FAILED;
    }
  }
  model->gpu_enabled = use_gpu;
  if (use_gpu) {
    model->actual_backend = SPEECH_CORE_ACTUAL_BACKEND_UNKNOWN;
    model->backend_message = metal_device != nullptr
        ? "Metal backend initialized; awaiting inference"
        : "Vulkan backend initialized; awaiting inference";
  }
  model->backend = speech_core_model::Backend::whisper;
  *out_model = model.release();
  return SPEECH_CORE_OK;
#else
  if (requested_backend != SPEECH_CORE_REQUESTED_BACKEND_CPU) {
    model->fallback_reason = SPEECH_CORE_FALLBACK_BACKEND_NOT_BUILT;
  }
  return SPEECH_CORE_BACKEND_UNAVAILABLE;
#endif
}

extern "C" speech_core_status speech_core_model_create(
    const char* model_path,
    speech_core_model** out_model) {
  return speech_core_model_create_with_backend(
      model_path, SPEECH_CORE_REQUESTED_BACKEND_CPU, out_model);
}

extern "C" void speech_core_model_destroy(speech_core_model* model) {
  if (model == nullptr) return;
#ifdef SPEECH_CORE_WITH_WHISPER
  if (model->whisper != nullptr) whisper_free(model->whisper);
#endif
  delete model;
}

extern "C" speech_core_requested_backend speech_core_model_requested_backend(
    const speech_core_model* model) {
  return model == nullptr ? SPEECH_CORE_REQUESTED_BACKEND_AUTO : model->requested_backend;
}

extern "C" speech_core_actual_backend speech_core_model_actual_backend(
    const speech_core_model* model) {
  return model == nullptr ? SPEECH_CORE_ACTUAL_BACKEND_UNAVAILABLE : model->actual_backend;
}

extern "C" uint8_t speech_core_model_gpu_enabled(const speech_core_model* model) {
  return model != nullptr && model->gpu_enabled ? 1 : 0;
}

extern "C" const char* speech_core_model_device_name(const speech_core_model* model) {
  return model == nullptr ? "" : model->device_name.c_str();
}

extern "C" speech_core_fallback_reason speech_core_model_fallback_reason(
    const speech_core_model* model) {
  return model == nullptr ? SPEECH_CORE_FALLBACK_MODEL_ERROR : model->fallback_reason;
}

extern "C" const char* speech_core_model_backend_message(
    const speech_core_model* model) {
  return model == nullptr ? "model unavailable" : model->backend_message.c_str();
}

extern "C" speech_core_status speech_core_session_create(
    speech_core_model* model,
    const char* session_id,
    speech_core_session** out_session) {
  if (model == nullptr || session_id == nullptr || session_id[0] == '\0' ||
      out_session == nullptr) {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  *out_session = nullptr;
  auto session = std::unique_ptr<speech_core_session>(new (std::nothrow) speech_core_session());
  if (!session) return SPEECH_CORE_INTERNAL_ERROR;
  session->model = model;
  session->session_id = session_id;
  *out_session = session.release();
  return SPEECH_CORE_OK;
}

extern "C" void speech_core_session_destroy(speech_core_session* session) {
  delete session;
}

extern "C" speech_core_status speech_core_session_cancel(speech_core_session* session) {
  if (session == nullptr) return SPEECH_CORE_INVALID_ARGUMENT;
  session->cancelled.store(true);
  return SPEECH_CORE_OK;
}

extern "C" speech_core_status speech_core_session_recognize(
    speech_core_session* session,
    const float* samples,
    size_t sample_count,
    uint32_t sample_rate,
    const char* language,
    int32_t n_threads,
    speech_core_segment_callback callback,
    void* user_data,
    speech_core_diagnostics* diagnostics) {
  clear_diagnostics(diagnostics);
  if (session == nullptr || samples == nullptr || sample_rate != 16000 ||
      callback == nullptr || n_threads <= 0) {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  if (sample_count == 0) return SPEECH_CORE_EMPTY_AUDIO;
  session->cancelled.store(false);
  for (size_t i = 0; i < sample_count; ++i) {
    if (!std::isfinite(samples[i])) return SPEECH_CORE_AUDIO_FORMAT_ERROR;
  }
  const auto started = std::chrono::steady_clock::now();

  if (session->model->backend == speech_core_model::Backend::test) {
    if (session->cancelled.load()) return SPEECH_CORE_CANCELLED;
    const char* output_language = (language == nullptr || language[0] == '\0') ? "en" : language;
    const speech_core_segment segment = {
        0, 0, static_cast<int64_t>((sample_count * 1000) / sample_rate),
        "speech_core test transcript", output_language, 1.0f, 1};
    callback(&segment, user_data);
    if (diagnostics != nullptr) {
      diagnostics->audio_samples = sample_count;
      diagnostics->input_sample_rate = sample_rate;
      diagnostics->input_channels = 1;
      diagnostics->input_samples = sample_count;
      diagnostics->output_sample_rate = sample_rate;
      diagnostics->output_channels = 1;
      diagnostics->segment_count = 1;
    }
  } else {
#ifdef SPEECH_CORE_WITH_WHISPER
    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = n_threads;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.no_context = true;
    // The live recognizer submits short windows. A smaller encoder context
    // avoids processing the unused tail of Whisper's ten-second input frame.
    params.audio_ctx = 512;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.language = (language == nullptr || language[0] == '\0') ? "auto" : language;
    // "auto" selects a language and then continues transcription. In whisper.cpp,
    // detect_language=true is a detect-only mode that returns before decoding text.
    params.detect_language = false;
    params.abort_callback = whisper_abort_callback;
    params.abort_callback_user_data = session;
    int result = whisper_full(session->model->whisper, params, samples,
                              static_cast<int>(sample_count));
    if (session->cancelled.load()) return SPEECH_CORE_CANCELLED;
    if (result != 0) {
      if (session->model->gpu_enabled) {
        session->model->fallback_reason = SPEECH_CORE_FALLBACK_RUNTIME_FAILED;
        const bool was_metal = session->model->actual_backend ==
            SPEECH_CORE_ACTUAL_BACKEND_METAL ||
            (session->model->requested_backend == SPEECH_CORE_REQUESTED_BACKEND_METAL
#ifdef SPEECH_CORE_GGML_METAL
             || session->model->requested_backend == SPEECH_CORE_REQUESTED_BACKEND_AUTO
#endif
            );
        session->model->backend_message = was_metal
            ? "Metal runtime failed; rebuilding CPU context"
            : "Vulkan runtime failed; rebuilding CPU context";
        whisper_free(session->model->whisper);
        session->model->whisper = initialize_whisper_context(
            session->model->model_path.c_str(), false);
        if (session->model->whisper == nullptr) {
          session->model->gpu_enabled = false;
          session->model->actual_backend = SPEECH_CORE_ACTUAL_BACKEND_UNAVAILABLE;
          session->model->backend_message = was_metal
              ? "Metal runtime failed and CPU fallback initialization failed"
              : "Vulkan runtime failed and CPU fallback initialization failed";
          return SPEECH_CORE_BACKEND_UNAVAILABLE;
        }
        session->model->gpu_enabled = false;
        session->model->actual_backend = SPEECH_CORE_ACTUAL_BACKEND_CPU;
        result = whisper_full(session->model->whisper, params, samples,
                              static_cast<int>(sample_count));
        if (session->cancelled.load()) return SPEECH_CORE_CANCELLED;
      }
      if (result != 0) return SPEECH_CORE_RECOGNITION_FAILED;
    }
    if (session->model->actual_backend == SPEECH_CORE_ACTUAL_BACKEND_UNKNOWN) {
      session->model->actual_backend =
          session->model->requested_backend == SPEECH_CORE_REQUESTED_BACKEND_METAL
#ifdef SPEECH_CORE_GGML_METAL
              || session->model->requested_backend == SPEECH_CORE_REQUESTED_BACKEND_AUTO
#endif
              ? SPEECH_CORE_ACTUAL_BACKEND_METAL
              : SPEECH_CORE_ACTUAL_BACKEND_VULKAN;
      session->model->backend_message =
          session->model->actual_backend == SPEECH_CORE_ACTUAL_BACKEND_METAL
              ? "Metal recognition completed"
              : "Vulkan recognition completed";
    }
    const int count = whisper_full_n_segments(session->model->whisper);
    if (count <= 0) return SPEECH_CORE_RECOGNITION_FAILED;
    const int language_id = whisper_full_lang_id(session->model->whisper);
    const char* detected = whisper_lang_str(language_id);
    uint32_t emitted_segments = 0;
    for (int i = 0; i < count; ++i) {
      if (session->cancelled.load()) return SPEECH_CORE_CANCELLED;
      const int64_t audio_duration_ms =
          static_cast<int64_t>((sample_count * 1000) / sample_rate);
      const int64_t raw_start_ms =
          whisper_full_get_segment_t0(session->model->whisper, i) * 10;
      const int64_t raw_end_ms =
          whisper_full_get_segment_t1(session->model->whisper, i) * 10;
      const int64_t start_ms = std::clamp(raw_start_ms, int64_t{0}, audio_duration_ms);
      const int64_t end_ms = std::clamp(raw_end_ms, start_ms, audio_duration_ms);
      const char* text = whisper_full_get_segment_text(session->model->whisper, i);
      const float no_speech_probability =
          whisper_full_get_segment_no_speech_prob(session->model->whisper, i);
      if (text == nullptr || text[0] == '\0' || end_ms <= start_ms ||
          no_speech_probability >= 0.6f) {
        continue;
      }
      const speech_core_segment segment = {
          static_cast<uint32_t>(i), start_ms, end_ms, text,
          detected == nullptr ? "" : detected,
          1.0f - no_speech_probability, 1};
      callback(&segment, user_data);
      ++emitted_segments;
    }
    if (diagnostics != nullptr) {
      diagnostics->audio_samples = sample_count;
      diagnostics->input_sample_rate = sample_rate;
      diagnostics->input_channels = 1;
      diagnostics->input_samples = sample_count;
      diagnostics->output_sample_rate = sample_rate;
      diagnostics->output_channels = 1;
      diagnostics->segment_count = emitted_segments;
    }
#else
    return SPEECH_CORE_BACKEND_UNAVAILABLE;
#endif
  }

  if (diagnostics != nullptr) {
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    diagnostics->inference_ms = static_cast<uint64_t>(elapsed);
    diagnostics->realtime_factor =
        elapsed == 0 ? 0.0 : static_cast<double>(elapsed) /
                                 (static_cast<double>(sample_count) / sample_rate * 1000.0);
  }
  return SPEECH_CORE_OK;
}
