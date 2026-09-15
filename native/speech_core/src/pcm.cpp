#include "speech_core_pcm.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

namespace {

constexpr uint32_t kOutputRate = SPEECH_CORE_SAMPLE_RATE;
constexpr uint64_t kMaxOutputSamples =
    static_cast<uint64_t>(kOutputRate) * 2 * 60 * 60;
constexpr double kPi = 3.14159265358979323846;
constexpr double kKaiserBeta = 8.0;
constexpr int kZeroCrossingsPerSide = 12;

double bessel_i0(double x) {
  double sum = 1.0;
  double term = 1.0;
  const double half_x = x / 2.0;
  for (int k = 1; k < 40; ++k) {
    term *= (half_x / k) * (half_x / k);
    sum += term;
    if (term < sum * 1e-12) break;
  }
  return sum;
}

}  // namespace

struct speech_core_resampler {
  uint32_t input_rate = 0;
  uint32_t channels = 0;
  double ratio = 1.0;
  bool passthrough = false;
  int half = 0;
  double cutoff = 0.0;
  double kaiser_denominator = 1.0;
  std::vector<float> history;
  int64_t base = 0;
  int64_t received = 0;
  int64_t padded = 0;
  int64_t next_output = 0;
  bool flushed = false;

  double kernel(double t) const {
    const double x = t / half;
    if (x <= -1.0 || x >= 1.0) return 0.0;
    const double window =
        bessel_i0(kKaiserBeta * std::sqrt(1.0 - x * x)) / kaiser_denominator;
    if (std::fabs(t) < 1e-9) return 2.0 * cutoff * window;
    return std::sin(2.0 * kPi * cutoff * t) / (kPi * t) * window;
  }

  void append_mono(const float* interleaved, size_t frames) {
    history.reserve(history.size() + frames);
    for (size_t frame = 0; frame < frames; ++frame) {
      float sum = 0.0f;
      for (uint32_t channel = 0; channel < channels; ++channel) {
        sum += interleaved[frame * channels + channel];
      }
      const float value = sum / static_cast<float>(channels);
      history.push_back(std::isfinite(value) ? std::clamp(value, -1.0f, 1.0f) : 0.0f);
    }
    received += static_cast<int64_t>(frames);
    padded += static_cast<int64_t>(frames);
  }

  // Emits every output sample whose filter support is fully available.
  speech_core_status produce(float* output, size_t capacity, size_t* count,
                             int64_t output_limit) {
    while (true) {
      const double t = static_cast<double>(next_output) / ratio;
      if (output_limit >= 0 && t >= static_cast<double>(output_limit)) break;
      const int64_t k_hi = static_cast<int64_t>(std::floor(t + half));
      if (k_hi > padded - 1) break;
      if (*count >= capacity) return SPEECH_CORE_BUFFER_TOO_SMALL;
      const int64_t k_lo = static_cast<int64_t>(std::ceil(t - half));
      double acc = 0.0;
      double weight_sum = 0.0;
      for (int64_t k = k_lo; k <= k_hi; ++k) {
        const double w = kernel(static_cast<double>(k) - t);
        weight_sum += w;
        if (k < base) continue;
        const int64_t index = k - base;
        if (index >= static_cast<int64_t>(history.size())) continue;
        acc += history[static_cast<size_t>(index)] * w;
      }
      const double value = weight_sum > 1e-6 ? acc / weight_sum : 0.0;
      output[(*count)++] = static_cast<float>(std::clamp(value, -1.0, 1.0));
      ++next_output;
    }
    const double t_next = static_cast<double>(next_output) / ratio;
    const int64_t keep_from = static_cast<int64_t>(std::ceil(t_next - half));
    if (keep_from > base) {
      const int64_t drop = std::min(keep_from - base, static_cast<int64_t>(history.size()));
      history.erase(history.begin(), history.begin() + drop);
      base += drop;
    }
    return SPEECH_CORE_OK;
  }
};

extern "C" speech_core_status speech_core_resampler_create(
    uint32_t input_sample_rate,
    uint32_t input_channels,
    speech_core_resampler** out_resampler) {
  if (out_resampler == nullptr || input_sample_rate == 0 || input_channels == 0 ||
      input_channels > 32) {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  *out_resampler = nullptr;
  auto* resampler = new (std::nothrow) speech_core_resampler();
  if (resampler == nullptr) return SPEECH_CORE_INTERNAL_ERROR;
  resampler->input_rate = input_sample_rate;
  resampler->channels = input_channels;
  resampler->ratio = static_cast<double>(kOutputRate) / input_sample_rate;
  resampler->passthrough = input_sample_rate == kOutputRate;
  if (!resampler->passthrough) {
    resampler->cutoff = 0.45 * std::min(1.0, resampler->ratio);
    resampler->half = static_cast<int>(
        std::ceil(kZeroCrossingsPerSide / (2.0 * resampler->cutoff)));
    resampler->kaiser_denominator = bessel_i0(kKaiserBeta);
  }
  *out_resampler = resampler;
  return SPEECH_CORE_OK;
}

extern "C" void speech_core_resampler_destroy(speech_core_resampler* resampler) {
  delete resampler;
}

extern "C" size_t speech_core_resampler_max_output(
    const speech_core_resampler* resampler,
    size_t input_frames) {
  if (resampler == nullptr) return 0;
  if (resampler->passthrough) return input_frames;
  const double pending = static_cast<double>(resampler->history.size()) +
      static_cast<double>(input_frames) + 2.0 * resampler->half + 2.0;
  return static_cast<size_t>(std::ceil(pending * resampler->ratio)) + 2;
}

extern "C" speech_core_status speech_core_resampler_process(
    speech_core_resampler* resampler,
    const float* interleaved,
    size_t input_frames,
    float* output,
    size_t output_capacity,
    size_t* output_count) {
  if (resampler == nullptr || output_count == nullptr ||
      (input_frames > 0 && interleaved == nullptr) ||
      (output_capacity > 0 && output == nullptr)) {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  *output_count = 0;
  if (resampler->flushed) return SPEECH_CORE_INVALID_ARGUMENT;
  if (input_frames == 0) return SPEECH_CORE_OK;
  if (resampler->passthrough) {
    if (output_capacity < input_frames) return SPEECH_CORE_BUFFER_TOO_SMALL;
    for (size_t frame = 0; frame < input_frames; ++frame) {
      float sum = 0.0f;
      for (uint32_t channel = 0; channel < resampler->channels; ++channel) {
        sum += interleaved[frame * resampler->channels + channel];
      }
      const float value = sum / static_cast<float>(resampler->channels);
      output[frame] = std::isfinite(value) ? std::clamp(value, -1.0f, 1.0f) : 0.0f;
    }
    *output_count = input_frames;
    resampler->received += static_cast<int64_t>(input_frames);
    return SPEECH_CORE_OK;
  }
  resampler->append_mono(interleaved, input_frames);
  return resampler->produce(output, output_capacity, output_count, -1);
}

extern "C" speech_core_status speech_core_resampler_flush(
    speech_core_resampler* resampler,
    float* output,
    size_t output_capacity,
    size_t* output_count) {
  if (resampler == nullptr || output_count == nullptr ||
      (output_capacity > 0 && output == nullptr)) {
    return SPEECH_CORE_INVALID_ARGUMENT;
  }
  *output_count = 0;
  if (resampler->flushed) return SPEECH_CORE_INVALID_ARGUMENT;
  resampler->flushed = true;
  if (resampler->passthrough) return SPEECH_CORE_OK;
  const size_t padding = static_cast<size_t>(resampler->half) + 1;
  resampler->history.insert(resampler->history.end(), padding, 0.0f);
  resampler->padded += static_cast<int64_t>(padding);
  return resampler->produce(output, output_capacity, output_count,
                            resampler->received);
}

namespace {

uint16_t read_u16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0]) |
         static_cast<uint16_t>(p[1] << 8);
}

uint32_t read_u32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) |
         (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

int32_t read_i24(const uint8_t* p) {
  int32_t value = static_cast<int32_t>(p[0]) |
                  (static_cast<int32_t>(p[1]) << 8) |
                  (static_cast<int32_t>(p[2]) << 16);
  if ((value & 0x00800000) != 0) value |= ~0x00ffffff;
  return value;
}

float decode_sample(const uint8_t* p, uint16_t bits, uint16_t format) {
  if (format == 3 && bits == 32) {
    float value;
    std::memcpy(&value, p, sizeof(value));
    return value;
  }
  switch (bits) {
    case 8:
      return (static_cast<float>(p[0]) - 128.0f) / 128.0f;
    case 16:
      return static_cast<float>(static_cast<int16_t>(read_u16(p))) / 32768.0f;
    case 24:
      return static_cast<float>(read_i24(p)) / 8388608.0f;
    case 32: {
      const int32_t value = static_cast<int32_t>(read_u32(p));
      return static_cast<float>(value) / 2147483648.0f;
    }
    default:
      return std::numeric_limits<float>::quiet_NaN();
  }
}

struct WavFormat {
  uint16_t format = 0;
  uint16_t channels = 0;
  uint32_t sample_rate = 0;
  uint16_t bits = 0;
  size_t data_offset = 0;
  size_t data_size = 0;
};

bool parse_wav(const uint8_t* data, size_t size, WavFormat* format) {
  if (data == nullptr || format == nullptr || size < 12 ||
      std::memcmp(data, "RIFF", 4) != 0 || std::memcmp(data + 8, "WAVE", 4) != 0) {
    return false;
  }
  size_t offset = 12;
  bool has_format = false;
  bool has_data = false;
  while (offset + 8 <= size) {
    const uint32_t chunk_size = read_u32(data + offset + 4);
    const size_t chunk_start = offset + 8;
    if (chunk_size > size - chunk_start) return false;
    if (std::memcmp(data + offset, "fmt ", 4) == 0) {
      if (chunk_size < 16) return false;
      format->format = read_u16(data + chunk_start);
      format->channels = read_u16(data + chunk_start + 2);
      format->sample_rate = read_u32(data + chunk_start + 4);
      format->bits = read_u16(data + chunk_start + 14);
      // WAVE_FORMAT_EXTENSIBLE carries the real format in the sub-format GUID.
      if (format->format == 0xFFFE && chunk_size >= 26) {
        format->format = read_u16(data + chunk_start + 24);
      }
      has_format = true;
    } else if (std::memcmp(data + offset, "data", 4) == 0) {
      format->data_offset = chunk_start;
      format->data_size = chunk_size;
      has_data = true;
    }
    const size_t padded = static_cast<size_t>(chunk_size) + (chunk_size & 1u);
    if (padded > size - chunk_start) return false;
    offset = chunk_start + padded;
  }
  return has_format && has_data;
}

}  // namespace

extern "C" speech_core_status speech_core_wav_to_pcm_f32(
    const uint8_t* data,
    size_t size,
    speech_core_pcm_buffer* output,
    speech_core_diagnostics* diagnostics) {
  if (output == nullptr) return SPEECH_CORE_INVALID_ARGUMENT;
  *output = {};
  if (diagnostics != nullptr) *diagnostics = {};

  WavFormat format;
  if (!parse_wav(data, size, &format) || format.channels == 0 ||
      format.sample_rate == 0 || format.bits == 0 ||
      (format.format != 1 && format.format != 3) ||
      (format.format == 1 && format.bits != 8 && format.bits != 16 &&
       format.bits != 24 && format.bits != 32) ||
      (format.format == 3 && format.bits != 32)) {
    return SPEECH_CORE_AUDIO_FORMAT_ERROR;
  }
  const size_t bytes_per_sample = (format.bits + 7) / 8;
  const size_t frame_bytes = bytes_per_sample * format.channels;
  if (frame_bytes == 0 || format.data_size == 0 || format.data_size % frame_bytes != 0) {
    return SPEECH_CORE_AUDIO_FORMAT_ERROR;
  }
  const size_t input_frames = format.data_size / frame_bytes;
  if (input_frames == 0) return SPEECH_CORE_EMPTY_AUDIO;
  const uint64_t expected_frames =
      (static_cast<uint64_t>(input_frames) * kOutputRate + format.sample_rate - 1) /
      format.sample_rate;
  if (expected_frames > kMaxOutputSamples) return SPEECH_CORE_AUDIO_TOO_LONG;

  std::vector<float> interleaved(input_frames * format.channels, 0.0f);
  for (size_t frame = 0; frame < input_frames; ++frame) {
    const uint8_t* frame_data = data + format.data_offset + frame * frame_bytes;
    for (uint16_t channel = 0; channel < format.channels; ++channel) {
      const float value = decode_sample(frame_data + channel * bytes_per_sample,
                                        format.bits, format.format);
      if (!std::isfinite(value)) return SPEECH_CORE_AUDIO_FORMAT_ERROR;
      interleaved[frame * format.channels + channel] = value;
    }
  }

  speech_core_resampler* resampler = nullptr;
  speech_core_status status = speech_core_resampler_create(
      format.sample_rate, format.channels, &resampler);
  if (status != SPEECH_CORE_OK) return status;
  const size_t capacity = speech_core_resampler_max_output(resampler, input_frames);
  float* samples = new (std::nothrow) float[capacity];
  if (samples == nullptr) {
    speech_core_resampler_destroy(resampler);
    return SPEECH_CORE_INTERNAL_ERROR;
  }
  size_t produced = 0;
  status = speech_core_resampler_process(resampler, interleaved.data(),
                                         input_frames, samples, capacity, &produced);
  size_t flushed = 0;
  if (status == SPEECH_CORE_OK) {
    status = speech_core_resampler_flush(resampler, samples + produced,
                                         capacity - produced, &flushed);
  }
  speech_core_resampler_destroy(resampler);
  if (status != SPEECH_CORE_OK) {
    delete[] samples;
    return status;
  }
  const size_t total = produced + flushed;
  if (total == 0) {
    delete[] samples;
    return SPEECH_CORE_EMPTY_AUDIO;
  }

  output->samples = samples;
  output->sample_count = total;
  output->sample_rate = kOutputRate;
  output->channels = 1;
  if (diagnostics != nullptr) {
    diagnostics->input_sample_rate = format.sample_rate;
    diagnostics->input_channels = format.channels;
    diagnostics->input_samples = input_frames;
    diagnostics->output_sample_rate = kOutputRate;
    diagnostics->output_channels = 1;
    diagnostics->audio_samples = total;
  }
  return SPEECH_CORE_OK;
}

extern "C" void speech_core_pcm_buffer_free(speech_core_pcm_buffer* buffer) {
  if (buffer == nullptr) return;
  delete[] buffer->samples;
  *buffer = {};
}
