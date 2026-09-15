#ifdef _MSC_VER
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "speech_core.h"
#include "speech_core_pcm.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;

void check(bool condition, const char* what) {
  if (!condition) {
    std::fprintf(stderr, "check failed: %s\n", what);
    std::abort();
  }
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

double rms(const float* samples, size_t count) {
  double energy = 0.0;
  for (size_t i = 0; i < count; ++i) energy += samples[i] * samples[i];
  return count == 0 ? 0.0 : std::sqrt(energy / count);
}

// Magnitude of one frequency relative to full scale, via Goertzel.
double tone_magnitude(const float* samples, size_t count, double frequency,
                      double sample_rate) {
  const double coefficient = 2.0 * std::cos(2.0 * kPi * frequency / sample_rate);
  double s0 = 0.0, s1 = 0.0, s2 = 0.0;
  for (size_t i = 0; i < count; ++i) {
    s0 = samples[i] + coefficient * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  const double power = s1 * s1 + s2 * s2 - coefficient * s1 * s2;
  return std::sqrt(std::fabs(power)) * 2.0 / count;
}

struct CapturedSegment {
  int count = 0;
  int64_t end_ms = 0;
  float repetition = -1.0f;
  uint32_t token_count = 0;
};

void capture(const speech_core_segment* segment, void* user_data) {
  auto* captured = static_cast<CapturedSegment*>(user_data);
  ++captured->count;
  captured->end_ms = segment->end_ms;
  captured->repetition = segment->repetition;
  captured->token_count = segment->token_count;
}

void test_resampler_filters_aliasing() {
  // 48 kHz stereo: left carries 1 kHz, right carries 14 kHz. After downmix and
  // a correct anti-aliased conversion to 16 kHz only the 1 kHz tone survives;
  // naive decimation would fold 14 kHz down to 2 kHz.
  const uint32_t rate = 48000;
  const size_t frames = rate;  // one second
  std::vector<float> interleaved(frames * 2);
  for (size_t i = 0; i < frames; ++i) {
    const double t = static_cast<double>(i) / rate;
    interleaved[i * 2] = static_cast<float>(0.2 * std::sin(2.0 * kPi * 1000.0 * t));
    interleaved[i * 2 + 1] = static_cast<float>(0.2 * std::sin(2.0 * kPi * 14000.0 * t));
  }
  speech_core_resampler* resampler = nullptr;
  check(speech_core_resampler_create(rate, 2, &resampler) == SPEECH_CORE_OK,
        "resampler create");
  const size_t capacity = speech_core_resampler_max_output(resampler, frames);
  std::vector<float> output(capacity);
  size_t produced = 0;
  check(speech_core_resampler_process(resampler, interleaved.data(), frames,
                                      output.data(), capacity, &produced) == SPEECH_CORE_OK,
        "resampler process");
  size_t flushed = 0;
  check(speech_core_resampler_flush(resampler, output.data() + produced,
                                    capacity - produced, &flushed) == SPEECH_CORE_OK,
        "resampler flush");
  speech_core_resampler_destroy(resampler);
  const size_t total = produced + flushed;
  check(total >= 15990 && total <= 16010, "resampler output count");

  // Skip the filter transient at both ends.
  const float* body = output.data() + 400;
  const size_t body_count = total - 800;
  const double expected_rms = 0.1 / std::sqrt(2.0);
  const double measured = rms(body, body_count);
  check(std::fabs(measured - expected_rms) < expected_rms * 0.05, "resampler rms");
  const double tone_1k = tone_magnitude(body, body_count, 1000.0, 16000.0);
  const double alias_2k = tone_magnitude(body, body_count, 2000.0, 16000.0);
  check(tone_1k > 0.09 && tone_1k < 0.11, "resampler keeps 1 kHz");
  check(alias_2k < tone_1k * 0.01, "resampler removes the 14 kHz alias");
}

void test_resampler_streaming_matches_one_shot() {
  const uint32_t rate = 44100;
  const size_t frames = 44100 / 2;
  std::vector<float> mono(frames);
  for (size_t i = 0; i < frames; ++i) {
    const double t = static_cast<double>(i) / rate;
    mono[i] = static_cast<float>(0.3 * std::sin(2.0 * kPi * 440.0 * t) +
                                 0.1 * std::sin(2.0 * kPi * 3000.0 * t));
  }
  auto convert = [&](const std::vector<size_t>& chunk_sizes) {
    speech_core_resampler* resampler = nullptr;
    check(speech_core_resampler_create(rate, 1, &resampler) == SPEECH_CORE_OK,
          "streaming create");
    std::vector<float> result;
    size_t offset = 0;
    for (const size_t size : chunk_sizes) {
      const size_t take = std::min(size, frames - offset);
      const size_t capacity = speech_core_resampler_max_output(resampler, take);
      std::vector<float> buffer(capacity);
      size_t produced = 0;
      check(speech_core_resampler_process(resampler, mono.data() + offset, take,
                                          buffer.data(), capacity, &produced) == SPEECH_CORE_OK,
            "streaming process");
      result.insert(result.end(), buffer.begin(), buffer.begin() + produced);
      offset += take;
    }
    const size_t capacity = speech_core_resampler_max_output(resampler, 0);
    std::vector<float> buffer(capacity);
    size_t flushed = 0;
    check(speech_core_resampler_flush(resampler, buffer.data(), capacity, &flushed) ==
              SPEECH_CORE_OK,
          "streaming flush");
    result.insert(result.end(), buffer.begin(), buffer.begin() + flushed);
    speech_core_resampler_destroy(resampler);
    return result;
  };
  const auto one_shot = convert({frames});
  const auto streamed = convert({1000, 7, 4096, 1, 20000, frames});
  check(one_shot.size() == streamed.size(), "streaming count matches");
  double max_difference = 0.0;
  for (size_t i = 0; i < one_shot.size(); ++i) {
    max_difference = std::max(max_difference,
                              static_cast<double>(std::fabs(one_shot[i] - streamed[i])));
  }
  check(max_difference < 1e-5, "streaming output matches one-shot");
  check(one_shot.size() >= 7990 && one_shot.size() <= 8010, "streaming output count");
}

void test_resampler_passthrough() {
  speech_core_resampler* resampler = nullptr;
  check(speech_core_resampler_create(16000, 2, &resampler) == SPEECH_CORE_OK,
        "passthrough create");
  const float interleaved[6] = {0.5f, -0.5f, 0.25f, 0.25f, 1.0f, 1.0f};
  float output[3] = {};
  size_t produced = 0;
  check(speech_core_resampler_process(resampler, interleaved, 3, output, 3, &produced) ==
            SPEECH_CORE_OK,
        "passthrough process");
  check(produced == 3, "passthrough count");
  check(std::fabs(output[0]) < 1e-6f && std::fabs(output[1] - 0.25f) < 1e-6f &&
            std::fabs(output[2] - 1.0f) < 1e-6f,
        "passthrough downmix");
  check(speech_core_resampler_process(resampler, interleaved, 3, output, 2, &produced) ==
            SPEECH_CORE_BUFFER_TOO_SMALL,
        "passthrough capacity");
  speech_core_resampler_destroy(resampler);
}

void test_wav_loader() {
  const auto wav = make_wav(8000, 2, {0, 32767, -32768, 0, 16384, -16384, 0, 0});
  speech_core_pcm_buffer pcm;
  speech_core_diagnostics diagnostics{};
  check(speech_core_wav_to_pcm_f32(wav.data(), wav.size(), &pcm, &diagnostics) ==
            SPEECH_CORE_OK,
        "wav decode");
  check(pcm.sample_rate == 16000, "wav rate");
  check(pcm.channels == 1, "wav channels");
  // Four stereo frames at 8 kHz become eight mono samples at 16 kHz.
  check(pcm.sample_count >= 7 && pcm.sample_count <= 9, "wav sample count");
  check(diagnostics.input_sample_rate == 8000, "wav input rate");
  check(diagnostics.input_channels == 2, "wav input channels");
  speech_core_pcm_buffer_free(&pcm);
  check(pcm.samples == nullptr, "wav free");
  check(speech_core_wav_to_pcm_f32(nullptr, 0, &pcm, nullptr) ==
            SPEECH_CORE_AUDIO_FORMAT_ERROR,
        "wav invalid");
}

void test_options_and_test_model() {
  speech_core_recognize_options options;
  speech_core_recognize_options_init(&options);
  check(options.beam_size == 5, "default beam");
  check(options.audio_context == 0, "default audio context");
  check(options.token_timestamps == 1, "default token timestamps");
  check(std::fabs(options.no_speech_threshold - 0.6f) < 1e-6f, "default no-speech");
  check(std::fabs(options.logprob_threshold + 1.0f) < 1e-6f, "default logprob");
  check(std::fabs(options.entropy_threshold - 2.4f) < 1e-6f, "default entropy");

  const std::string model_path = "speech_core_test_model.bin";
  {
    std::ofstream model(model_path, std::ios::binary);
    model << "SPEECH_CORE_TEST_MODEL_V1\n";
  }
  speech_core_model* model = nullptr;
  check(speech_core_model_create(model_path.c_str(), &model) == SPEECH_CORE_OK,
        "test model create");
  check(speech_core_model_requested_backend(model) == SPEECH_CORE_REQUESTED_BACKEND_CPU,
        "test model requested backend");
  check(speech_core_model_actual_backend(model) == SPEECH_CORE_ACTUAL_BACKEND_CPU,
        "test model actual backend");
  check(speech_core_model_gpu_enabled(model) == 0, "test model gpu");
  check(speech_core_model_fallback_reason(model) == SPEECH_CORE_FALLBACK_NONE,
        "test model fallback");
  check(std::string(speech_core_model_backend_message(model)) == "deterministic test model",
        "test model message");
  speech_core_session* session = nullptr;
  check(speech_core_session_create(model, "test-session", &session) == SPEECH_CORE_OK,
        "session create");
  const float samples[1600] = {};
  speech_core_diagnostics diagnostics{};
  CapturedSegment captured;
  options.n_threads = 1;
  options.language = "en";
  check(speech_core_session_recognize(session, samples, 1600, 16000, &options, capture,
                                      &captured, &diagnostics) == SPEECH_CORE_OK,
        "recognize");
  check(captured.count == 1, "recognize count");
  check(captured.end_ms == 100, "recognize end");
  check(captured.token_count == 4, "recognize tokens");
  check(captured.repetition >= 0.0f && captured.repetition <= 1.0f, "recognize repetition");
  check(diagnostics.segment_count == 1, "recognize diagnostics");
  options.n_threads = 0;
  check(speech_core_session_recognize(session, samples, 1600, 16000, &options, capture,
                                      &captured, &diagnostics) == SPEECH_CORE_INVALID_ARGUMENT,
        "recognize rejects zero threads");
  options.n_threads = 1;
  check(speech_core_session_recognize(session, samples, 1600, 44100, &options, capture,
                                      &captured, &diagnostics) == SPEECH_CORE_INVALID_ARGUMENT,
        "recognize rejects other rates");
  check(speech_core_session_cancel(session) == SPEECH_CORE_OK, "cancel");
  speech_core_session_destroy(session);
  speech_core_model_destroy(model);
  std::remove(model_path.c_str());
  check(speech_core_model_create("missing-model.bin", &model) == SPEECH_CORE_MODEL_NOT_FOUND,
        "missing model");
}

// Runs only when SPEECH_CORE_VAD_MODEL points at a Silero GGML model, which CI
// downloads; a plain developer build skips it.
void test_vad_with_model() {
  const char* model_path = std::getenv("SPEECH_CORE_VAD_MODEL");
  if (model_path == nullptr || model_path[0] == '\0') {
    std::printf("vad: skipped (SPEECH_CORE_VAD_MODEL not set)\n");
    return;
  }
  speech_core_vad* vad = nullptr;
  const speech_core_status status = speech_core_vad_create(model_path, 1, &vad);
  if (status == SPEECH_CORE_BACKEND_UNAVAILABLE) {
    std::printf("vad: skipped (whisper backend not built)\n");
    return;
  }
  check(status == SPEECH_CORE_OK, "vad create");
  const uint32_t frame = speech_core_vad_frame_samples(vad);
  check(frame > 0 && frame <= 2048, "vad frame size");

  // Silence must score low; a loud speech-band chirp must score noticeably
  // higher than silence.
  const size_t count = 16000;
  std::vector<float> silence(count, 0.0f);
  std::vector<float> probabilities(count / frame + 1);
  size_t produced = 0;
  check(speech_core_vad_probabilities(vad, silence.data(), count, probabilities.data(),
                                      probabilities.size(), &produced) == SPEECH_CORE_OK,
        "vad silence");
  check(produced == (count + frame - 1) / frame, "vad silence frame count");
  double silence_mean = 0.0;
  for (size_t i = 0; i < produced; ++i) silence_mean += probabilities[i];
  silence_mean /= produced;
  check(silence_mean < 0.2, "vad silence probability");

  std::vector<float> chirp(count);
  for (size_t i = 0; i < count; ++i) {
    const double t = static_cast<double>(i) / 16000.0;
    const double frequency = 120.0 + 900.0 * std::fmod(t * 4.0, 1.0);
    const double envelope = 0.5 + 0.5 * std::sin(2.0 * kPi * 3.0 * t);
    chirp[i] = static_cast<float>(0.6 * envelope * std::sin(2.0 * kPi * frequency * t));
  }
  check(speech_core_vad_probabilities(vad, chirp.data(), count, probabilities.data(),
                                      probabilities.size(), &produced) == SPEECH_CORE_OK,
        "vad chirp");
  double chirp_mean = 0.0;
  for (size_t i = 0; i < produced; ++i) chirp_mean += probabilities[i];
  chirp_mean /= produced;
  check(chirp_mean > silence_mean, "vad chirp scores above silence");
  check(speech_core_vad_probabilities(vad, chirp.data(), count, probabilities.data(), 1,
                                      &produced) == SPEECH_CORE_BUFFER_TOO_SMALL,
        "vad capacity");
  speech_core_vad_destroy(vad);
  std::printf("vad: silence %.3f chirp %.3f frame %u\n", silence_mean, chirp_mean, frame);
}

}  // namespace

int main() {
  check(speech_core_abi_version() == SPEECH_CORE_ABI_VERSION, "abi version");
  check(speech_core_model_actual_backend(nullptr) == SPEECH_CORE_ACTUAL_BACKEND_UNAVAILABLE,
        "null model backend");
  check(speech_core_model_gpu_enabled(nullptr) == 0, "null model gpu");
  check(speech_core_model_fallback_reason(nullptr) == SPEECH_CORE_FALLBACK_MODEL_ERROR,
        "null model fallback");
  test_wav_loader();
  test_resampler_passthrough();
  test_resampler_filters_aliasing();
  test_resampler_streaming_matches_one_shot();
  test_options_and_test_model();
  test_vad_with_model();
  std::printf("speech_core_tests: ok\n");
  return 0;
}
