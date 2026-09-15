// Low-level smoke tool: decodes one WAV, runs one recognition call through the
// C ABI and prints JSONL. The end-to-end regression (VAD segmenter, prompts,
// CER) lives in app/packages/recognition/bin/regression.dart.
#include "speech_core.h"
#include "speech_core_pcm.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

void usage() {
  std::cerr << "usage: speech_regression --model PATH --audio PATH "
               "[--backend auto|cpu|vulkan|metal] [--language LANG] [--threads N] "
               "[--beam N] [--prompt TEXT] [--no-token-timestamps] "
               "[--vad-model PATH] [--output PATH]\n";
}

bool parse_backend(const std::string& value,
                   speech_core_requested_backend* backend) {
  if (value == "auto") {
    *backend = SPEECH_CORE_REQUESTED_BACKEND_AUTO;
    return true;
  }
  if (value == "cpu") {
    *backend = SPEECH_CORE_REQUESTED_BACKEND_CPU;
    return true;
  }
  if (value == "vulkan") {
    *backend = SPEECH_CORE_REQUESTED_BACKEND_VULKAN;
    return true;
  }
  if (value == "metal") {
    *backend = SPEECH_CORE_REQUESTED_BACKEND_METAL;
    return true;
  }
  return false;
}

const char* requested_backend_name(speech_core_requested_backend backend) {
  switch (backend) {
    case SPEECH_CORE_REQUESTED_BACKEND_AUTO: return "Auto";
    case SPEECH_CORE_REQUESTED_BACKEND_CPU: return "CPU";
    case SPEECH_CORE_REQUESTED_BACKEND_VULKAN: return "Vulkan";
    case SPEECH_CORE_REQUESTED_BACKEND_METAL: return "Metal";
  }
  return "Unknown";
}

const char* actual_backend_name(speech_core_actual_backend backend) {
  switch (backend) {
    case SPEECH_CORE_ACTUAL_BACKEND_UNKNOWN: return "Unknown";
    case SPEECH_CORE_ACTUAL_BACKEND_CPU: return "CPU";
    case SPEECH_CORE_ACTUAL_BACKEND_VULKAN: return "Vulkan";
    case SPEECH_CORE_ACTUAL_BACKEND_METAL: return "Metal";
    case SPEECH_CORE_ACTUAL_BACKEND_UNAVAILABLE: return "Unavailable";
  }
  return "Unknown";
}

std::string json_escape(const char* text) {
  std::string output;
  if (text == nullptr) return output;
  for (const unsigned char c : std::string(text)) {
    switch (c) {
      case '\\': output += "\\\\"; break;
      case '"': output += "\\\""; break;
      case '\n': output += "\\n"; break;
      case '\r': output += "\\r"; break;
      case '\t': output += "\\t"; break;
      default:
        if (c < 0x20) {
          std::ostringstream escaped;
          escaped << "\\u00" << std::hex << static_cast<int>(c);
          output += escaped.str();
        } else {
          output += static_cast<char>(c);
        }
    }
  }
  return output;
}

bool read_file(const std::string& path, std::vector<uint8_t>* data) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file) return false;
  const std::streamsize size = file.tellg();
  if (size <= 0) return false;
  data->resize(static_cast<size_t>(size));
  file.seekg(0);
  return file.read(reinterpret_cast<char*>(data->data()), size).good();
}

struct OutputContext {
  std::ostream* output;
  uint32_t count = 0;
};

void on_segment(const speech_core_segment* segment, void* user_data) {
  auto* context = static_cast<OutputContext*>(user_data);
  *context->output << "{\"type\":\"segment\",\"index\":" << segment->segment_index
                   << ",\"startMs\":" << segment->start_ms
                   << ",\"endMs\":" << segment->end_ms
                   << ",\"text\":\"" << json_escape(segment->text)
                   << "\",\"language\":\"" << json_escape(segment->language)
                   << "\",\"avgLogprob\":" << segment->avg_logprob
                   << ",\"noSpeechProb\":" << segment->no_speech_prob
                   << ",\"repetition\":" << segment->repetition
                   << ",\"tokenCount\":" << segment->token_count << "}\n";
  ++context->count;
}

int run_vad(const std::string& vad_model, const speech_core_pcm_buffer& pcm,
            std::ostream& output) {
  speech_core_vad* vad = nullptr;
  if (speech_core_vad_create(vad_model.c_str(), 2, &vad) != SPEECH_CORE_OK) {
    std::cerr << "vad model failed to load\n";
    return 4;
  }
  const uint32_t frame = speech_core_vad_frame_samples(vad);
  const size_t chunk = static_cast<size_t>(frame) * 32 * 30;  // ~30 s
  size_t offset = 0;
  size_t speech_frames = 0;
  size_t total_frames = 0;
  std::vector<float> probabilities(chunk / frame + 1);
  while (offset < pcm.sample_count) {
    const size_t take = std::min(chunk, pcm.sample_count - offset);
    size_t produced = 0;
    if (speech_core_vad_probabilities(vad, pcm.samples + offset, take,
                                      probabilities.data(), probabilities.size(),
                                      &produced) != SPEECH_CORE_OK) {
      speech_core_vad_destroy(vad);
      return 5;
    }
    for (size_t i = 0; i < produced; ++i) {
      if (probabilities[i] >= 0.5f) ++speech_frames;
    }
    total_frames += produced;
    offset += take;
  }
  speech_core_vad_destroy(vad);
  output << "{\"type\":\"vad\",\"frameSamples\":" << frame
         << ",\"frames\":" << total_frames
         << ",\"speechFrames\":" << speech_frames << "}\n";
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  std::string model_path;
  std::string audio_path;
  std::string vad_model_path;
  std::string language = "auto";
  std::string prompt;
  std::string output_path;
  speech_core_requested_backend requested_backend =
      SPEECH_CORE_REQUESTED_BACKEND_AUTO;
  speech_core_recognize_options options;
  speech_core_recognize_options_init(&options);
  for (int i = 1; i < argc; ++i) {
    const std::string argument = argv[i];
    if (argument == "--model" && i + 1 < argc) model_path = argv[++i];
    else if (argument == "--audio" && i + 1 < argc) audio_path = argv[++i];
    else if (argument == "--vad-model" && i + 1 < argc) vad_model_path = argv[++i];
    else if (argument == "--backend" && i + 1 < argc) {
      if (!parse_backend(argv[++i], &requested_backend)) {
        usage();
        return 2;
      }
    }
    else if (argument == "--language" && i + 1 < argc) language = argv[++i];
    else if (argument == "--prompt" && i + 1 < argc) prompt = argv[++i];
    else if (argument == "--output" && i + 1 < argc) output_path = argv[++i];
    else if (argument == "--no-token-timestamps") options.token_timestamps = 0;
    else if ((argument == "--threads" || argument == "--beam") && i + 1 < argc) {
      int value = 0;
      try {
        value = std::stoi(argv[++i]);
      } catch (...) {
        usage();
        return 2;
      }
      if (value <= 0) {
        usage();
        return 2;
      }
      if (argument == "--threads") options.n_threads = value;
      else options.beam_size = value;
    } else {
      usage();
      return 2;
    }
  }
  if (model_path.empty() || audio_path.empty()) {
    usage();
    return 2;
  }

  std::ofstream file_output;
  std::ostream* output = &std::cout;
  if (!output_path.empty()) {
    file_output.open(output_path, std::ios::binary);
    if (!file_output) return 2;
    output = &file_output;
  }
  std::vector<uint8_t> wav;
  if (!read_file(audio_path, &wav)) return 3;
  speech_core_pcm_buffer pcm{};
  speech_core_diagnostics diagnostics{};
  speech_core_status status = speech_core_wav_to_pcm_f32(
      wav.data(), wav.size(), &pcm, &diagnostics);
  if (status != SPEECH_CORE_OK) return 3;

  if (!vad_model_path.empty()) {
    const int vad_result = run_vad(vad_model_path, pcm, *output);
    if (vad_result != 0) {
      speech_core_pcm_buffer_free(&pcm);
      return vad_result;
    }
  }

  speech_core_model* model = nullptr;
  status = speech_core_model_create_with_backend(
      model_path.c_str(), requested_backend, &model);
  if (status != SPEECH_CORE_OK) {
    speech_core_pcm_buffer_free(&pcm);
    return status == SPEECH_CORE_MODEL_NOT_FOUND ||
                   status == SPEECH_CORE_MODEL_LOAD_FAILED ||
                   status == SPEECH_CORE_BACKEND_UNAVAILABLE ? 4 : 5;
  }
  speech_core_session* session = nullptr;
  status = speech_core_session_create(model, "regression", &session);
  if (status != SPEECH_CORE_OK) {
    speech_core_model_destroy(model);
    speech_core_pcm_buffer_free(&pcm);
    return 5;
  }
  options.language = language.c_str();
  options.initial_prompt = prompt.empty() ? nullptr : prompt.c_str();

  // Feed at most 30 seconds per call so the tool exercises the same window
  // contract as the application.
  const size_t window = static_cast<size_t>(SPEECH_CORE_SAMPLE_RATE) * 30;
  OutputContext context{output};
  uint64_t inference_ms = 0;
  size_t offset = 0;
  while (offset < pcm.sample_count && status == SPEECH_CORE_OK) {
    const size_t take = std::min(window, pcm.sample_count - offset);
    status = speech_core_session_recognize(
        session, pcm.samples + offset, take, pcm.sample_rate, &options,
        on_segment, &context, &diagnostics);
    inference_ms += diagnostics.inference_ms;
    offset += take;
  }
  if (status == SPEECH_CORE_OK) {
    *output << "{\"type\":\"backend\",\"requestedBackend\":\""
            << requested_backend_name(speech_core_model_requested_backend(model))
            << "\",\"actualBackend\":\""
            << actual_backend_name(speech_core_model_actual_backend(model))
            << "\",\"gpuEnabled\":"
            << (speech_core_model_gpu_enabled(model) != 0 ? "true" : "false")
            << ",\"deviceName\":\""
            << json_escape(speech_core_model_device_name(model))
            << "\",\"fallbackReason\":"
            << static_cast<int>(speech_core_model_fallback_reason(model))
            << ",\"backendMessage\":\""
            << json_escape(speech_core_model_backend_message(model))
            << "\"}\n";
    const double seconds = static_cast<double>(pcm.sample_count) / pcm.sample_rate;
    *output << "{\"type\":\"diagnostic\",\"audioSamples\":" << pcm.sample_count
            << ",\"inputSampleRate\":" << diagnostics.input_sample_rate
            << ",\"inputChannels\":" << diagnostics.input_channels
            << ",\"inferenceMs\":" << inference_ms
            << ",\"realtimeFactor\":"
            << (seconds > 0 ? inference_ms / 1000.0 / seconds : 0.0)
            << ",\"segmentCount\":" << context.count << "}\n";
  }
  speech_core_session_destroy(session);
  speech_core_model_destroy(model);
  speech_core_pcm_buffer_free(&pcm);
  if (status == SPEECH_CORE_OK) return 0;
  if (status == SPEECH_CORE_CANCELLED) return 6;
  return 5;
}
