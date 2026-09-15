#include "speech_core.h"

#include <array>
#include <atomic>
#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <new>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#ifdef SPEECH_CORE_WITH_WHISPER
#include "ggml.h"
#include "ggml-backend.h"
#include "whisper.h"
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

struct speech_core_vad {
#ifdef SPEECH_CORE_WITH_WHISPER
  whisper_vad_context* context = nullptr;
#endif
  uint32_t frame_samples = 512;
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

void clear_diagnostics(speech_core_diagnostics* diagnostics) {
  if (diagnostics != nullptr) *diagnostics = {};
}

// Share of repeated 4-grams over the text's code points. Catches the
// degenerate loops Whisper produces on music and near-silence, which pass
// its own entropy check because every repeated token is highly probable.
float text_repetition(const char* text) {
  if (text == nullptr) return 0.0f;
  std::vector<char32_t> points;
  const auto* bytes = reinterpret_cast<const unsigned char*>(text);
  size_t index = 0;
  while (bytes[index] != 0) {
    const unsigned char lead = bytes[index];
    char32_t value = 0;
    size_t length = 1;
    if (lead < 0x80) {
      value = lead;
    } else if ((lead & 0xE0) == 0xC0) {
      value = lead & 0x1F;
      length = 2;
    } else if ((lead & 0xF0) == 0xE0) {
      value = lead & 0x0F;
      length = 3;
    } else if ((lead & 0xF8) == 0xF0) {
      value = lead & 0x07;
      length = 4;
    } else {
      ++index;
      continue;
    }
    bool valid = true;
    for (size_t k = 1; k < length; ++k) {
      const unsigned char follow = bytes[index + k];
      if ((follow & 0xC0) != 0x80) {
        valid = false;
        break;
      }
      value = (value << 6) | (follow & 0x3F);
    }
    if (!valid) {
      ++index;
      continue;
    }
    index += length;
    // Space, ideographic space, newline, tab.
    if (value == 0x20 || value == 0x3000 || value == 0x0A || value == 0x09) {
      continue;
    }
    points.push_back(value);
  }
  if (points.size() < 8) return 0.0f;
  std::set<std::array<char32_t, 4>> unique;
  const size_t total = points.size() - 3;
  for (size_t i = 0; i < total; ++i) {
    unique.insert({points[i], points[i + 1], points[i + 2], points[i + 3]});
  }
  return 1.0f - static_cast<float>(unique.size()) / static_cast<float>(total);
}

#ifdef SPEECH_CORE_WITH_WHISPER
void quiet_log(enum ggml_log_level, const char*, void*) {}

bool device_name_contains(ggml_backend_dev_t device, const char* needle) {
  if (device == nullptr) return false;
  const char* name = ggml_backend_dev_name(device);
  if (name == nullptr) return false;
  std::string lowered(name);
  std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return lowered.find(needle) != std::string::npos;
}

ggml_backend_dev_t find_device(const char* needle) {
  for (size_t index = 0; index < ggml_backend_dev_count(); ++index) {
    auto* device = ggml_backend_dev_get(index);
    if (device_name_contains(device, needle)) return device;
  }
  return nullptr;
}

const char* device_description(ggml_backend_dev_t device) {
  if (device == nullptr) return "";
  const char* description = ggml_backend_dev_description(device);
  if (description != nullptr && description[0] != '\0') return description;
  return ggml_backend_dev_name(device);
}

whisper_context* initialize_whisper_context(const char* model_path, bool use_gpu) {
  whisper_context_params params = whisper_context_default_params();
  params.use_gpu = use_gpu;
  return whisper_init_from_file_with_params(model_path, params);
}

bool whisper_abort_callback(void* user_data) {
  const auto* session = static_cast<const speech_core_session*>(user_data);
  return session->cancelled.load();
}

bool requested_metal(const speech_core_model* model) {
  return model->requested_backend == SPEECH_CORE_REQUESTED_BACKEND_METAL
#ifdef SPEECH_CORE_GGML_METAL
      || model->requested_backend == SPEECH_CORE_REQUESTED_BACKEND_AUTO
#endif
      ;
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
    case SPEECH_CORE_BUFFER_TOO_SMALL: return "buffer too small";
  }
  return "unknown error";
}

extern "C" uint32_t speech_core_abi_version(void) { return SPEECH_CORE_ABI_VERSION; }

extern "C" void speech_core_recognize_options_init(
    speech_core_recognize_options* options) {
  if (options == nullptr) return;
  *options = {};
  options->language = nullptr;
  options->initial_prompt = nullptr;
  options->n_threads = 4;
  options->beam_size = 5;
  options->audio_context = 0;
  options->temperature = 0.0f;
  options->temperature_increment = 0.2f;
  options->entropy_threshold = 2.4f;
  options->logprob_threshold = -1.0f;
  options->no_speech_threshold = 0.6f;
  options->token_timestamps = 1;
  options->suppress_non_speech_tokens = 1;
  options->suppress_blank = 1;
}

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
  whisper_log_set(quiet_log, nullptr);
  ggml_backend_load_all();
  const bool request_metal = requested_metal(model.get());
  const bool request_vulkan =
      requested_backend == SPEECH_CORE_REQUESTED_BACKEND_VULKAN
#ifndef SPEECH_CORE_GGML_METAL
      || requested_backend == SPEECH_CORE_REQUESTED_BACKEND_AUTO
#endif
      ;
  auto* metal_device = request_metal ? find_device("metal") : nullptr;
  auto* vulkan_device = request_vulkan ? find_device("vulkan") : nullptr;
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
    model->device_name = device_description(
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
    const speech_core_recognize_options* options,
    speech_core_segment_callback callback,
    void* user_data,
    speech_core_diagnostics* diagnostics) {
  clear_diagnostics(diagnostics);
  if (session == nullptr || samples == nullptr || options == nullptr ||
      sample_rate != SPEECH_CORE_SAMPLE_RATE || callback == nullptr ||
      options->n_threads <= 0) {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  if (sample_count == 0) return SPEECH_CORE_EMPTY_AUDIO;
  if (sample_count > static_cast<size_t>(SPEECH_CORE_SAMPLE_RATE) * 30 * 2) {
    return SPEECH_CORE_AUDIO_TOO_LONG;
  }
  session->cancelled.store(false);
  for (size_t i = 0; i < sample_count; ++i) {
    if (!std::isfinite(samples[i])) return SPEECH_CORE_AUDIO_FORMAT_ERROR;
  }
  const auto started = std::chrono::steady_clock::now();
  const int64_t audio_duration_ms =
      static_cast<int64_t>((sample_count * 1000) / sample_rate);
  const char* language = (options->language == nullptr || options->language[0] == '\0')
      ? "auto"
      : options->language;

  if (session->model->backend == speech_core_model::Backend::test) {
    if (session->cancelled.load()) return SPEECH_CORE_CANCELLED;
    const char* output_language = std::strcmp(language, "auto") == 0 ? "en" : language;
    const char* text = "speech_core test transcript";
    const speech_core_segment segment = {
        0, 0, audio_duration_ms, text, output_language,
        -0.1f, 0.05f, text_repetition(text), 4};
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
    const bool beam = options->beam_size > 1;
    whisper_full_params params = whisper_full_default_params(
        beam ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
    params.n_threads = options->n_threads;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = false;
    params.single_segment = false;
    params.audio_ctx = options->audio_context > 0 ? options->audio_context : 0;
    params.suppress_blank = options->suppress_blank != 0;
    params.suppress_nst = options->suppress_non_speech_tokens != 0;
    params.token_timestamps = options->token_timestamps != 0;
    params.language = language;
    // "auto" selects a language and then continues transcription. In whisper.cpp,
    // detect_language=true is a detect-only mode that returns before decoding text.
    params.detect_language = false;
    if (options->initial_prompt != nullptr && options->initial_prompt[0] != '\0') {
      params.initial_prompt = options->initial_prompt;
    }
    params.temperature = options->temperature;
    params.temperature_inc =
        options->temperature_increment > 0.0f ? options->temperature_increment : 0.0f;
    params.entropy_thold =
        options->entropy_threshold > 0.0f ? options->entropy_threshold : -1.0f;
    params.logprob_thold =
        options->logprob_threshold <= 0.0f ? options->logprob_threshold : -1e9f;
    params.no_speech_thold = options->no_speech_threshold;
    if (beam) params.beam_search.beam_size = options->beam_size;
    params.abort_callback = whisper_abort_callback;
    params.abort_callback_user_data = session;

    int result = whisper_full(session->model->whisper, params, samples,
                              static_cast<int>(sample_count));
    if (session->cancelled.load()) return SPEECH_CORE_CANCELLED;
    if (result != 0) {
      if (session->model->gpu_enabled) {
        session->model->fallback_reason = SPEECH_CORE_FALLBACK_RUNTIME_FAILED;
        const bool was_metal = session->model->actual_backend ==
            SPEECH_CORE_ACTUAL_BACKEND_METAL || requested_metal(session->model);
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
      session->model->actual_backend = requested_metal(session->model)
          ? SPEECH_CORE_ACTUAL_BACKEND_METAL
          : SPEECH_CORE_ACTUAL_BACKEND_VULKAN;
      session->model->backend_message =
          session->model->actual_backend == SPEECH_CORE_ACTUAL_BACKEND_METAL
              ? "Metal recognition completed"
              : "Vulkan recognition completed";
    }
    whisper_context* ctx = session->model->whisper;
    const int count = whisper_full_n_segments(ctx);
    const int language_id = whisper_full_lang_id(ctx);
    const char* detected = whisper_lang_str(language_id);
    const whisper_token eot = whisper_token_eot(ctx);
    uint32_t emitted_segments = 0;
    uint32_t dropped_segments = 0;
    for (int i = 0; i < count; ++i) {
      if (session->cancelled.load()) return SPEECH_CORE_CANCELLED;
      const int64_t segment_start_ms = whisper_full_get_segment_t0(ctx, i) * 10;
      const int64_t segment_end_ms = whisper_full_get_segment_t1(ctx, i) * 10;
      const char* text = whisper_full_get_segment_text(ctx, i);
      const float no_speech_prob = whisper_full_get_segment_no_speech_prob(ctx, i);

      const int token_total = whisper_full_n_tokens(ctx, i);
      double logprob_sum = 0.0;
      uint32_t text_tokens = 0;
      int64_t first_token_start_ms = -1;
      int64_t last_token_end_ms = -1;
      for (int j = 0; j < token_total; ++j) {
        const whisper_token_data token = whisper_full_get_token_data(ctx, i, j);
        if (token.id >= eot) continue;
        logprob_sum += token.plog;
        ++text_tokens;
        if (params.token_timestamps) {
          if (first_token_start_ms < 0) first_token_start_ms = token.t0 * 10;
          last_token_end_ms = token.t1 * 10;
        }
      }
      const float avg_logprob = text_tokens == 0
          ? 0.0f
          : static_cast<float>(logprob_sum / text_tokens);

      int64_t start_ms = segment_start_ms;
      int64_t end_ms = segment_end_ms;
      if (first_token_start_ms >= segment_start_ms && last_token_end_ms <= segment_end_ms &&
          last_token_end_ms > first_token_start_ms) {
        start_ms = first_token_start_ms;
        end_ms = last_token_end_ms;
      }
      start_ms = std::clamp(start_ms, int64_t{0}, audio_duration_ms);
      end_ms = std::clamp(end_ms, start_ms, audio_duration_ms);

      // OpenAI's reference pipeline treats a segment as silence only when the
      // no-speech head and the decoder both agree that nothing was said.
      const bool no_speech = no_speech_prob >= options->no_speech_threshold &&
          avg_logprob < options->logprob_threshold;
      if (text == nullptr || text[0] == '\0' || text_tokens == 0 ||
          end_ms <= start_ms || no_speech) {
        ++dropped_segments;
        continue;
      }
      const speech_core_segment segment = {
          static_cast<uint32_t>(i), start_ms, end_ms, text,
          detected == nullptr ? "" : detected,
          avg_logprob, no_speech_prob, text_repetition(text), text_tokens};
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
      diagnostics->dropped_segment_count = dropped_segments;
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

extern "C" speech_core_status speech_core_vad_create(
    const char* model_path,
    int32_t n_threads,
    speech_core_vad** out_vad) {
  if (model_path == nullptr || model_path[0] == '\0' || out_vad == nullptr ||
      n_threads <= 0) {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  *out_vad = nullptr;
  if (!file_exists(model_path)) return SPEECH_CORE_MODEL_NOT_FOUND;
#ifdef SPEECH_CORE_WITH_WHISPER
  whisper_log_set(quiet_log, nullptr);
  whisper_vad_context_params params = whisper_vad_default_context_params();
  params.n_threads = n_threads;
  params.use_gpu = false;
  whisper_vad_context* context =
      whisper_vad_init_from_file_with_params(model_path, params);
  if (context == nullptr) return SPEECH_CORE_MODEL_LOAD_FAILED;
  auto vad = std::unique_ptr<speech_core_vad>(new (std::nothrow) speech_core_vad());
  if (!vad) {
    whisper_vad_free(context);
    return SPEECH_CORE_INTERNAL_ERROR;
  }
  vad->context = context;
  // The model header defines the analysis window; derive it from a probe run
  // instead of assuming Silero's 512 samples.
  const std::vector<float> probe(4096, 0.0f);
  if (!whisper_vad_detect_speech(context, probe.data(), static_cast<int>(probe.size()))) {
    whisper_vad_free(context);
    return SPEECH_CORE_MODEL_LOAD_FAILED;
  }
  const int probe_frames = whisper_vad_n_probs(context);
  if (probe_frames <= 0 || probe.size() % static_cast<size_t>(probe_frames) != 0) {
    whisper_vad_free(context);
    return SPEECH_CORE_MODEL_LOAD_FAILED;
  }
  vad->frame_samples = static_cast<uint32_t>(probe.size() / probe_frames);
  *out_vad = vad.release();
  return SPEECH_CORE_OK;
#else
  return SPEECH_CORE_BACKEND_UNAVAILABLE;
#endif
}

extern "C" void speech_core_vad_destroy(speech_core_vad* vad) {
  if (vad == nullptr) return;
#ifdef SPEECH_CORE_WITH_WHISPER
  if (vad->context != nullptr) whisper_vad_free(vad->context);
#endif
  delete vad;
}

extern "C" uint32_t speech_core_vad_frame_samples(const speech_core_vad* vad) {
  return vad == nullptr ? 0 : vad->frame_samples;
}

extern "C" speech_core_status speech_core_vad_probabilities(
    speech_core_vad* vad,
    const float* samples,
    size_t sample_count,
    float* out_probabilities,
    size_t out_capacity,
    size_t* out_count) {
  if (vad == nullptr || samples == nullptr || out_count == nullptr ||
      (out_capacity > 0 && out_probabilities == nullptr)) {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  *out_count = 0;
  if (sample_count == 0) return SPEECH_CORE_EMPTY_AUDIO;
  if (sample_count > static_cast<size_t>(SPEECH_CORE_SAMPLE_RATE) * 60) {
    return SPEECH_CORE_AUDIO_TOO_LONG;
  }
#ifdef SPEECH_CORE_WITH_WHISPER
  const size_t expected = (sample_count + vad->frame_samples - 1) / vad->frame_samples;
  *out_count = expected;
  if (expected > out_capacity) return SPEECH_CORE_BUFFER_TOO_SMALL;
  if (!whisper_vad_detect_speech(vad->context, samples, static_cast<int>(sample_count))) {
    return SPEECH_CORE_RECOGNITION_FAILED;
  }
  const int produced = whisper_vad_n_probs(vad->context);
  if (produced <= 0) return SPEECH_CORE_RECOGNITION_FAILED;
  const float* probabilities = whisper_vad_probs(vad->context);
  const size_t copy = std::min(static_cast<size_t>(produced), out_capacity);
  std::copy_n(probabilities, copy, out_probabilities);
  *out_count = copy;
  return SPEECH_CORE_OK;
#else
  return SPEECH_CORE_BACKEND_UNAVAILABLE;
#endif
}
