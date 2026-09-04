#include "speech_core.h"
#include "speech_core_pcm.h"

#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

namespace {

void check(bool condition) {
  if (!condition) std::abort();
}

void write_u16(std::vector<uint8_t>* data, uint16_t value) {
  data->push_back(static_cast<uint8_t>(value));
  data->push_back(static_cast<uint8_t>(value >> 8));
}

void write_u32(std::vector<uint8_t>* data, uint32_t value) {
  for (int i = 0; i < 4; ++i) data->push_back(static_cast<uint8_t>(value >> (i * 8)));
}

std::vector<uint8_t> make_wav(uint32_t rate, uint16_t channels,
                              const std::vector<int16_t>& samples) {
  const uint32_t data_size = static_cast<uint32_t>(samples.size() * sizeof(int16_t));
  std::vector<uint8_t> wav;
  wav.insert(wav.end(), {'R', 'I', 'F', 'F'});
  write_u32(&wav, 36 + data_size);
  wav.insert(wav.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
  write_u32(&wav, 16);
  write_u16(&wav, 1);
  write_u16(&wav, channels);
  write_u32(&wav, rate);
  write_u32(&wav, rate * channels * 2);
  write_u16(&wav, channels * 2);
  write_u16(&wav, 16);
  wav.insert(wav.end(), {'d', 'a', 't', 'a'});
  write_u32(&wav, data_size);
  for (const int16_t sample : samples) write_u16(&wav, static_cast<uint16_t>(sample));
  return wav;
}

struct CapturedSegment {
  int count = 0;
  int64_t end_ms = 0;
};

void capture(const speech_core_segment* segment, void* user_data) {
  auto* captured = static_cast<CapturedSegment*>(user_data);
  ++captured->count;
  captured->end_ms = segment->end_ms;
  check(segment->is_final == 1);
}

}  // namespace

int main() {
  check(speech_core_abi_version() == 3);
  check(speech_core_model_actual_backend(nullptr) ==
        SPEECH_CORE_ACTUAL_BACKEND_UNAVAILABLE);
  check(speech_core_model_gpu_enabled(nullptr) == 0);
  check(speech_core_model_fallback_reason(nullptr) ==
        SPEECH_CORE_FALLBACK_MODEL_ERROR);
  const auto wav = make_wav(8000, 2, {0, 32767, -32768, 0, 16384, -16384, 0, 0});
  speech_core_pcm_buffer pcm;
  speech_core_diagnostics diagnostics{};
  check(speech_core_wav_to_pcm_f32(wav.data(), wav.size(), &pcm, &diagnostics) ==
        SPEECH_CORE_OK);
  check(pcm.sample_rate == 16000);
  check(pcm.channels == 1);
  check(pcm.sample_count == 8);
  check(diagnostics.input_sample_rate == 8000);
  check(diagnostics.input_channels == 2);
  check(std::fabs(pcm.samples[0] - 0.5f) < 0.01f);
  speech_core_pcm_buffer_free(&pcm);
  check(pcm.samples == nullptr);
  check(speech_core_wav_to_pcm_f32(nullptr, 0, &pcm, nullptr) ==
        SPEECH_CORE_AUDIO_FORMAT_ERROR);

  const std::string model_path = "speech_core_test_model.bin";
  {
    std::ofstream model(model_path, std::ios::binary);
    model << "SPEECH_CORE_TEST_MODEL_V1\n";
  }
  speech_core_model* model = nullptr;
  check(speech_core_model_create(model_path.c_str(), &model) == SPEECH_CORE_OK);
  check(speech_core_model_requested_backend(model) ==
        SPEECH_CORE_REQUESTED_BACKEND_CPU);
  check(speech_core_model_actual_backend(model) ==
        SPEECH_CORE_ACTUAL_BACKEND_CPU);
  check(speech_core_model_gpu_enabled(model) == 0);
  check(speech_core_model_fallback_reason(model) == SPEECH_CORE_FALLBACK_NONE);
  check(std::string(speech_core_model_backend_message(model)) ==
        "deterministic test model");
  speech_core_session* session = nullptr;
  check(speech_core_session_create(model, "test-session", &session) == SPEECH_CORE_OK);
  const float samples[1600] = {};
  CapturedSegment captured;
  check(speech_core_session_recognize(
            session, samples, 1600, 16000, "en", nullptr, 1, capture, &captured,
            &diagnostics) == SPEECH_CORE_OK);
  check(captured.count == 1);
  check(captured.end_ms == 100);
  check(diagnostics.segment_count == 1);
  check(speech_core_session_cancel(session) == SPEECH_CORE_OK);
  speech_core_session_destroy(session);
  speech_core_model_destroy(model);
  std::remove(model_path.c_str());
  check(speech_core_model_create("missing-model.bin", &model) ==
        SPEECH_CORE_MODEL_NOT_FOUND);
  return 0;
}
