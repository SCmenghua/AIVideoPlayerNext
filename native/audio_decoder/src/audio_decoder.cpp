#include "audio_decoder.h"

#ifdef _WIN32

#include <windows.h>
#include <algorithm>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;

struct ai_audio_decoder {
  std::mutex mutex;
  std::thread worker;
  std::atomic<bool> cancel{false};
  std::atomic<bool> running{false};
  ComPtr<IMFSourceReader> reader;
  std::string path;
  DWORD stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  UINT32 sample_rate = 0;
  UINT32 channels = 0;
  bool com_initialized = false;
  ai_audio_decoder_chunk_callback callback = nullptr;
  void* callback_user_data = nullptr;
  std::atomic<bool> callback_active{false};
  bool realtime = false;
};

namespace {

std::wstring utf8_to_wide(const char* value) {
  if (value == nullptr || *value == '\0') return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value,
                                         -1, nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1,
                      result.data(), length);
  result.resize(static_cast<size_t>(length - 1));
  return result;
}

bool set_float_output(IMFSourceReader* reader) {
  if (reader == nullptr) return false;
  ComPtr<IMFMediaType> type;
  if (FAILED(MFCreateMediaType(&type))) return false;
  if (FAILED(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio)) ||
      FAILED(type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float))) {
    return false;
  }
  return SUCCEEDED(reader->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
      type.Get()));
}

bool read_format(ai_audio_decoder* decoder) {
  ComPtr<IMFMediaType> type;
  if (FAILED(decoder->reader->GetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), &type))) {
    return false;
  }
  UINT32 rate = 0;
  UINT32 channels = 0;
  if (FAILED(type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate)) ||
      FAILED(type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels)) ||
      rate == 0 || channels == 0) {
    return false;
  }
  decoder->sample_rate = rate;
  decoder->channels = channels;
  return true;
}

void join_worker(ai_audio_decoder* decoder) {
  if (decoder->worker.joinable()) decoder->worker.join();
}

void notify_stopped(ai_audio_decoder* decoder) {
  if (!decoder->callback_active.exchange(false)) return;
  const auto callback = decoder->callback;
  void* const user_data = decoder->callback_user_data;
  decoder->callback = nullptr;
  decoder->callback_user_data = nullptr;
  decoder->callback_active = false;
  if (callback == nullptr) return;
  auto* last = new (std::nothrow) ai_audio_decoder_chunk{
      0, decoder->sample_rate, decoder->channels, 0, nullptr, 1};
  if (last != nullptr) callback(last, user_data);
}

void decode_loop(ai_audio_decoder* decoder,
                 ai_audio_decoder_chunk_callback callback,
                 void* user_data) {
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool worker_com_initialized = SUCCEEDED(com_result);
  decoder->running = true;
  const auto wall_started = std::chrono::steady_clock::now();
  int64_t first_media_ms = -1;
  while (!decoder->cancel.load()) {
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    const HRESULT result = decoder->reader->ReadSample(
        decoder->stream, 0, nullptr, &flags, &timestamp, &sample);
    if (FAILED(result)) break;
    if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
      if (callback != nullptr) {
        auto* last = new (std::nothrow) ai_audio_decoder_chunk{
            0, decoder->sample_rate, decoder->channels, 0, nullptr, 1};
        if (last != nullptr) callback(last, user_data);
      }
      decoder->callback_active = false;
      break;
    }
    if (sample == nullptr) continue;

    if (first_media_ms < 0) first_media_ms = timestamp / 10000;
    if (decoder->realtime) {
      const auto target = wall_started + std::chrono::milliseconds(
          (timestamp / 10000) - first_media_ms);
      while (!decoder->cancel.load()) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= target) break;
        const auto remaining = target - now;
        const auto max_sleep =
            std::chrono::steady_clock::duration(std::chrono::milliseconds(10));
        const auto sleep_for = remaining < max_sleep ? remaining : max_sleep;
        std::this_thread::sleep_for(sleep_for);
      }
      if (decoder->cancel.load()) break;
    }

    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) break;
    BYTE* data = nullptr;
    DWORD length = 0;
    if (FAILED(buffer->Lock(&data, nullptr, &length))) break;
    const size_t frame_size = sizeof(float) * decoder->channels;
    const DWORD count = frame_size == 0
        ? 0
        : static_cast<DWORD>(length / frame_size);
    if (callback != nullptr && count > 0) {
      auto* owned_samples = new (std::nothrow) float[
          static_cast<size_t>(count) * decoder->channels];
      auto* owned_chunk = new (std::nothrow) ai_audio_decoder_chunk;
      if (owned_samples == nullptr || owned_chunk == nullptr) {
        delete[] owned_samples;
        delete owned_chunk;
        buffer->Unlock();
        break;
      }
      std::copy_n(reinterpret_cast<const float*>(data),
                  static_cast<size_t>(count) * decoder->channels,
                  owned_samples);
      *owned_chunk = {
          static_cast<int64_t>(timestamp / 10000), decoder->sample_rate,
          decoder->channels, count, owned_samples, 0};
      callback(owned_chunk, user_data);
    }
    buffer->Unlock();
    if (callback == nullptr || count == 0) {
      // No callback owns this sample buffer in the empty/non-callback path.
      continue;
    }
  }
  decoder->running = false;
  if (worker_com_initialized) CoUninitialize();
}

}  // namespace

extern "C" AI_AUDIO_DECODER_API const char*
ai_audio_decoder_status_message(ai_audio_decoder_status status) {
  switch (status) {
    case AI_AUDIO_DECODER_OK: return "ok";
    case AI_AUDIO_DECODER_INVALID_ARGUMENT: return "invalid argument";
    case AI_AUDIO_DECODER_OPEN_FAILED: return "open failed";
    case AI_AUDIO_DECODER_NO_AUDIO: return "no audio stream";
    case AI_AUDIO_DECODER_NOT_READY: return "decoder not ready";
    case AI_AUDIO_DECODER_CANCELLED: return "cancelled";
    case AI_AUDIO_DECODER_INTERNAL_ERROR: return "internal error";
  }
  return "unknown error";
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_create(ai_audio_decoder** out_decoder) {
  if (out_decoder == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  *out_decoder = nullptr;
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(com_result) && com_result != RPC_E_CHANGED_MODE) {
    return AI_AUDIO_DECODER_INTERNAL_ERROR;
  }
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    if (SUCCEEDED(com_result)) CoUninitialize();
    return AI_AUDIO_DECODER_INTERNAL_ERROR;
  }
  auto* decoder = new (std::nothrow) ai_audio_decoder();
  if (decoder == nullptr) {
    MFShutdown();
    if (SUCCEEDED(com_result)) CoUninitialize();
    return AI_AUDIO_DECODER_INTERNAL_ERROR;
  }
  decoder->com_initialized = SUCCEEDED(com_result);
  *out_decoder = decoder;
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API void
ai_audio_decoder_destroy(ai_audio_decoder* decoder) {
  if (decoder == nullptr) return;
  ai_audio_decoder_stop(decoder);
  decoder->reader.Reset();
  decoder->callback = nullptr;
  decoder->callback_user_data = nullptr;
  const bool com_initialized = decoder->com_initialized;
  delete decoder;
  MFShutdown();
  if (com_initialized) CoUninitialize();
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_open(ai_audio_decoder* decoder, const char* path) {
  if (decoder == nullptr || path == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  ai_audio_decoder_stop(decoder);
  const auto wide_path = utf8_to_wide(path);
  if (wide_path.empty()) return AI_AUDIO_DECODER_OPEN_FAILED;
  ComPtr<IMFAttributes> attributes;
  if (FAILED(MFCreateAttributes(&attributes, 2)) ||
      FAILED(attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE)) ||
      FAILED(MFCreateSourceReaderFromURL(wide_path.c_str(), attributes.Get(),
                                         &decoder->reader))) {
    decoder->reader.Reset();
    return AI_AUDIO_DECODER_OPEN_FAILED;
  }
  if (!set_float_output(decoder->reader.Get()) || !read_format(decoder)) {
    decoder->reader.Reset();
    return AI_AUDIO_DECODER_NO_AUDIO;
  }
  decoder->path = path;
  decoder->cancel = false;
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_set_realtime(ai_audio_decoder* decoder, uint8_t enabled) {
  if (decoder == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  decoder->realtime = enabled != 0;
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_start(ai_audio_decoder* decoder,
                       ai_audio_decoder_chunk_callback callback,
                       void* user_data) {
  if (decoder == nullptr || callback == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  if (decoder->reader == nullptr) return AI_AUDIO_DECODER_NOT_READY;
  if (decoder->running.load()) return AI_AUDIO_DECODER_OK;
  join_worker(decoder);
  decoder->cancel = false;
  decoder->callback = callback;
  decoder->callback_user_data = user_data;
  decoder->callback_active = true;
  decoder->worker = std::thread(decode_loop, decoder, callback, user_data);
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_pause(ai_audio_decoder* decoder) {
  if (decoder == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  decoder->cancel = true;
  join_worker(decoder);
  notify_stopped(decoder);
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_seek(ai_audio_decoder* decoder, int64_t position_ms) {
  if (decoder == nullptr || decoder->reader == nullptr) return AI_AUDIO_DECODER_NOT_READY;
  decoder->cancel = true;
  join_worker(decoder);
  notify_stopped(decoder);
  PROPVARIANT position;
  PropVariantInit(&position);
  position.vt = VT_I8;
  position.hVal.QuadPart = position_ms * 10000;
  const HRESULT result = decoder->reader->SetCurrentPosition(GUID_NULL, position);
  PropVariantClear(&position);
  decoder->cancel = false;
  return SUCCEEDED(result) ? AI_AUDIO_DECODER_OK : AI_AUDIO_DECODER_INTERNAL_ERROR;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_stop(ai_audio_decoder* decoder) {
  if (decoder == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  decoder->cancel = true;
  join_worker(decoder);
  decoder->running = false;
  notify_stopped(decoder);
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API void ai_audio_decoder_chunk_free(
    const ai_audio_decoder_chunk* chunk) {
  if (chunk == nullptr) return;
  delete[] chunk->samples;
  delete chunk;
}

#else

extern "C" const char* ai_audio_decoder_status_message(
    ai_audio_decoder_status) { return "Windows audio decoder unavailable"; }

#endif
