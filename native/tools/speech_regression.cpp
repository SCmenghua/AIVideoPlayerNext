#include "speech_core.h"
#include "speech_core_pcm.h"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

void usage() {
  std::cerr << "usage: speech_regression --model PATH --audio PATH "
               "[--backend auto|cpu|vulkan] [--language LANG] [--threads N] "
               "[--manifest PATH] [--output PATH]\n";
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
  const char* session_id;
  uint32_t count = 0;
};

void on_segment(const speech_core_segment* segment, void* user_data) {
  auto* context = static_cast<OutputContext*>(user_data);
  *context->output << "{\"type\":\"segment\",\"sessionId\":\""
                   << json_escape(context->session_id)
                   << "\",\"segmentId\":\"segment-"
                   << segment->segment_index << "\",\"startMs\":"
                   << segment->start_ms << ",\"endMs\":" << segment->end_ms
                   << ",\"text\":\"" << json_escape(segment->text)
                   << "\",\"language\":\"" << json_escape(segment->language)
                   << "\",\"confidence\":" << segment->confidence
                   << ",\"avgLogprob\":" << segment->avg_logprob
                   << ",\"noSpeechProb\":" << segment->no_speech_prob
                   << ",\"repetition\":" << segment->repetition
                   << ",\"kind\":\"final\",\"source\":\"whisperCpp\"}\n";
  ++context->count;
}

}  // namespace

int main(int argc, char** argv) {
  std::string model_path;
  std::string audio_path;
  std::string language = "auto";
  std::string initial_prompt;
  std::string manifest_path;
  std::string output_path;
  speech_core_requested_backend requested_backend =
      SPEECH_CORE_REQUESTED_BACKEND_AUTO;
  int32_t threads = 4;
  for (int i = 1; i < argc; ++i) {
    const std::string argument = argv[i];
    if (argument == "--model" && i + 1 < argc) model_path = argv[++i];
    else if (argument == "--audio" && i + 1 < argc) audio_path = argv[++i];
    else if (argument == "--backend" && i + 1 < argc) {
      if (!parse_backend(argv[++i], &requested_backend)) {
        usage();
        return 2;
      }
    }
    else if (argument == "--language" && i + 1 < argc) language = argv[++i];
    else if (argument == "--prompt" && i + 1 < argc) initial_prompt = argv[++i];
    else if (argument == "--manifest" && i + 1 < argc) manifest_path = argv[++i];
    else if (argument == "--output" && i + 1 < argc) output_path = argv[++i];
    else if (argument == "--threads" && i + 1 < argc) {
      try {
        threads = std::stoi(argv[++i]);
      } catch (...) {
        usage();
        return 2;
      }
      if (threads <= 0) {
        usage();
        return 2;
      }
    } else {
      usage();
      return 2;
    }
  }
  if (model_path.empty() || audio_path.empty()) {
    usage();
    return 2;
  }

  if (!manifest_path.empty()) {
    std::vector<uint8_t> manifest;
    if (!read_file(manifest_path, &manifest)) return 2;
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
  OutputContext context{output, "regression"};
  status = speech_core_session_recognize(
      session, pcm.samples, pcm.sample_count, pcm.sample_rate,
      language.c_str(), initial_prompt.empty() ? nullptr : initial_prompt.c_str(),
      threads, on_segment, &context, &diagnostics);
  if (status == SPEECH_CORE_OK) {
    *output << "{\"type\":\"backend\",\"sessionId\":\"regression\","
            << "\"requestedBackend\":\""
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
    *output << "{\"type\":\"diagnostic\",\"sessionId\":\"regression\","
            << "\"audioSamples\":" << diagnostics.audio_samples
            << ",\"inputSampleRate\":" << diagnostics.input_sample_rate
            << ",\"inputChannels\":" << diagnostics.input_channels
            << ",\"inputSamples\":" << diagnostics.input_samples
            << ",\"outputSampleRate\":" << diagnostics.output_sample_rate
            << ",\"outputChannels\":" << diagnostics.output_channels
            << ",\"inferenceMs\":" << diagnostics.inference_ms
            << ",\"realtimeFactor\":" << diagnostics.realtime_factor
            << ",\"segmentCount\":" << context.count << "}\n";
  }
  speech_core_session_destroy(session);
  speech_core_model_destroy(model);
  speech_core_pcm_buffer_free(&pcm);
  if (status == SPEECH_CORE_OK) return 0;
  if (status == SPEECH_CORE_CANCELLED) return 6;
  return 5;
}
