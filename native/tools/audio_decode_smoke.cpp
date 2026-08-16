#include "audio_decoder.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <mutex>
#include <string>
#include <vector>

struct Context {
  uint64_t chunks = 0;
  uint64_t source_samples = 0;
  int64_t first_ms = 0;
  int64_t last_ms = 0;
  uint32_t rate = 0;
  uint32_t channels = 0;
  std::mutex mutex;
  std::condition_variable condition;
  bool finished = false;
  std::atomic<bool> reached_limit{false};
  int64_t maximum_ms = 0;
  std::vector<float> samples;
};

void on_chunk(const ai_audio_decoder_chunk* chunk, void* user_data) {
  auto* context = static_cast<Context*>(user_data);
  if (chunk == nullptr) return;
  if (chunk->is_last != 0) {
    {
      std::lock_guard<std::mutex> lock(context->mutex);
      context->finished = true;
    }
    context->condition.notify_one();
    ai_audio_decoder_chunk_free(chunk);
    return;
  }
  if (context->reached_limit.load()) {
    ai_audio_decoder_chunk_free(chunk);
    return;
  }
  if (context->chunks == 0) context->first_ms = chunk->media_start_ms;
  context->last_ms = chunk->media_start_ms;
  context->rate = chunk->sample_rate;
  context->channels = chunk->channels;
  context->source_samples += chunk->sample_count;
  ++context->chunks;
  const int64_t end_ms = chunk->media_start_ms +
      static_cast<int64_t>(chunk->sample_count) * 1000 / chunk->sample_rate;
  const int64_t remaining_ms = context->maximum_ms - chunk->media_start_ms;
  const uint64_t frames_to_copy = remaining_ms <= 0 ? 0 : std::min<uint64_t>(
      chunk->sample_count,
      static_cast<uint64_t>(remaining_ms) * chunk->sample_rate / 1000);
  if (frames_to_copy > 0) {
    context->samples.insert(context->samples.end(), chunk->samples,
        chunk->samples + frames_to_copy * chunk->channels);
  }
  if (end_ms >= context->maximum_ms) {
    context->reached_limit = true;
    {
      std::lock_guard<std::mutex> lock(context->mutex);
      context->finished = true;
    }
    context->condition.notify_one();
  }
  ai_audio_decoder_chunk_free(chunk);
}

uint32_t read_u32(const std::string& value) {
  try {
    const auto parsed = std::stoul(value);
    if (parsed == 0 || parsed > 600) return 0;
    return static_cast<uint32_t>(parsed);
  } catch (...) {
    return 0;
  }
}

void write_u16(std::ofstream* output, uint16_t value) {
  output->write(reinterpret_cast<const char*>(&value), sizeof(value));
}

void write_u32(std::ofstream* output, uint32_t value) {
  output->write(reinterpret_cast<const char*>(&value), sizeof(value));
}

bool write_wav(const std::string& path, const Context& context) {
  if (context.rate == 0 || context.channels == 0 || context.samples.empty()) {
    return false;
  }
  const uint64_t input_frames = context.samples.size() / context.channels;
  const uint64_t output_frames = input_frames * 16000 / context.rate;
  if (output_frames == 0 || output_frames > UINT32_MAX / sizeof(float)) {
    return false;
  }
  std::vector<float> mono(static_cast<size_t>(output_frames));
  for (uint64_t index = 0; index < output_frames; ++index) {
    const double source = static_cast<double>(index) * context.rate / 16000;
    const uint64_t left = std::min<uint64_t>(
        static_cast<uint64_t>(source), input_frames - 1);
    const uint64_t right = std::min<uint64_t>(left + 1, input_frames - 1);
    const double weight = source - left;
    double left_value = 0;
    double right_value = 0;
    for (uint32_t channel = 0; channel < context.channels; ++channel) {
      left_value += context.samples[left * context.channels + channel];
      right_value += context.samples[right * context.channels + channel];
    }
    mono[static_cast<size_t>(index)] = static_cast<float>(
        (left_value * (1 - weight) + right_value * weight) / context.channels);
  }

  std::ofstream output(path, std::ios::binary);
  if (!output) return false;
  const uint32_t data_size = static_cast<uint32_t>(mono.size() * sizeof(float));
  output.write("RIFF", 4);
  write_u32(&output, 36 + data_size);
  output.write("WAVEfmt ", 8);
  write_u32(&output, 16);
  write_u16(&output, 3);
  write_u16(&output, 1);
  write_u32(&output, 16000);
  write_u32(&output, 16000 * sizeof(float));
  write_u16(&output, sizeof(float));
  write_u16(&output, 32);
  output.write("data", 4);
  write_u32(&output, data_size);
  output.write(reinterpret_cast<const char*>(mono.data()),
      static_cast<std::streamsize>(data_size));
  return output.good();
}

void print_energy(const Context& context) {
  if (context.rate == 0 || context.channels == 0 || context.samples.empty()) {
    return;
  }
  const uint64_t frames = context.samples.size() / context.channels;
  const uint64_t frames_per_second = context.rate;
  for (uint64_t start = 0, second = 0; start < frames;
       start += frames_per_second, ++second) {
    const uint64_t end = std::min<uint64_t>(start + frames_per_second, frames);
    double energy = 0;
    double peak = 0;
    for (uint64_t frame = start; frame < end; ++frame) {
      double mono = 0;
      for (uint32_t channel = 0; channel < context.channels; ++channel) {
        mono += context.samples[frame * context.channels + channel];
      }
      mono /= context.channels;
      energy += mono * mono;
      peak = std::max(peak, std::abs(mono));
    }
    const double rms = std::sqrt(energy / (end - start));
    std::cout << "{\"second\":" << second << ",\"rms\":" << rms
              << ",\"peak\":" << peak << "}\n";
  }
}

int main(int argc, char** argv) {
  if (argc < 2) {
    std::cerr << "usage: audio_decode_smoke MEDIA_PATH [--seconds N] [--wav PATH]\n";
    return 2;
  }
  uint32_t seconds = 30;
  std::string wav_path;
  for (int index = 2; index < argc; ++index) {
    const std::string argument = argv[index];
    if (argument == "--seconds" && index + 1 < argc) {
      seconds = read_u32(argv[++index]);
      if (seconds == 0) return 2;
    } else if (argument == "--wav" && index + 1 < argc) {
      wav_path = argv[++index];
    } else {
      return 2;
    }
  }
  ai_audio_decoder* decoder = nullptr;
  auto status = ai_audio_decoder_create(&decoder);
  if (status != AI_AUDIO_DECODER_OK) return 3;
  status = ai_audio_decoder_open(decoder, argv[1]);
  if (status == AI_AUDIO_DECODER_OK) {
    Context context;
    context.maximum_ms = static_cast<int64_t>(seconds) * 1000;
    status = ai_audio_decoder_start(decoder, on_chunk, &context);
    if (status == AI_AUDIO_DECODER_OK) {
      std::unique_lock<std::mutex> lock(context.mutex);
      context.condition.wait(lock, [&context] { return context.finished; });
    }
    ai_audio_decoder_stop(decoder);
    std::cout << "{\"chunks\":" << context.chunks
              << ",\"samples\":" << context.source_samples
              << ",\"sampleRate\":" << context.rate
              << ",\"channels\":" << context.channels
              << ",\"firstMediaMs\":" << context.first_ms
              << ",\"lastMediaMs\":" << context.last_ms << "}\n";
    print_energy(context);
    if (!wav_path.empty()) {
      if (!write_wav(wav_path, context)) return 5;
      std::cout << "{\"wav\":\"" << wav_path << "\"}\n";
    }
  } else {
    std::cerr << ai_audio_decoder_status_message(status) << "\n";
  }
  ai_audio_decoder_destroy(decoder);
  return status == AI_AUDIO_DECODER_OK ? 0 : 4;
}
