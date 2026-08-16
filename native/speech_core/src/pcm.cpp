#include "speech_core_pcm.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

namespace {

constexpr uint32_t kOutputRate = 16000;
constexpr uint64_t kMaxOutputSamples = static_cast<uint64_t>(kOutputRate) * 2 * 60 * 60;

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
  const uint64_t output_frames = (static_cast<uint64_t>(input_frames) * kOutputRate +
                                  format.sample_rate - 1) / format.sample_rate;
  if (output_frames == 0) return SPEECH_CORE_EMPTY_AUDIO;
  if (output_frames > kMaxOutputSamples) return SPEECH_CORE_AUDIO_TOO_LONG;

  std::vector<float> mono(input_frames, 0.0f);
  for (size_t frame = 0; frame < input_frames; ++frame) {
    const uint8_t* frame_data = data + format.data_offset + frame * frame_bytes;
    float sum = 0.0f;
    for (uint16_t channel = 0; channel < format.channels; ++channel) {
      sum += decode_sample(frame_data + channel * bytes_per_sample,
                           format.bits, format.format);
    }
    const float value = sum / static_cast<float>(format.channels);
    if (!std::isfinite(value)) return SPEECH_CORE_AUDIO_FORMAT_ERROR;
    mono[frame] = std::clamp(value, -1.0f, 1.0f);
  }

  float* samples = new (std::nothrow) float[static_cast<size_t>(output_frames)];
  if (samples == nullptr) return SPEECH_CORE_INTERNAL_ERROR;
  if (input_frames == 1) {
    std::fill_n(samples, static_cast<size_t>(output_frames), mono[0]);
  } else {
    const double scale = static_cast<double>(input_frames - 1) /
                         static_cast<double>(output_frames - 1);
    for (size_t index = 0; index < static_cast<size_t>(output_frames); ++index) {
      const double source = static_cast<double>(index) * scale;
      const size_t left = static_cast<size_t>(source);
      const size_t right = std::min(left + 1, input_frames - 1);
      const float weight = static_cast<float>(source - static_cast<double>(left));
      samples[index] = mono[left] * (1.0f - weight) + mono[right] * weight;
    }
  }

  output->samples = samples;
  output->sample_count = static_cast<size_t>(output_frames);
  output->sample_rate = kOutputRate;
  output->channels = 1;
  if (diagnostics != nullptr) {
    diagnostics->input_sample_rate = format.sample_rate;
    diagnostics->input_channels = format.channels;
    diagnostics->input_samples = input_frames;
    diagnostics->output_sample_rate = kOutputRate;
    diagnostics->output_channels = 1;
    diagnostics->audio_samples = output_frames;
  }
  return SPEECH_CORE_OK;
}

extern "C" void speech_core_pcm_buffer_free(speech_core_pcm_buffer* buffer) {
  if (buffer == nullptr) return;
  delete[] buffer->samples;
  *buffer = {};
}
