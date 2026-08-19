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
  std::thread open_worker;
  std::thread decode_worker;
  std::thread seek_worker;
  std::atomic<bool> cancel{false};
  std::atomic<bool> opening{false};
  std::atomic<bool> seeking{false};
  std::atomic<bool> running{false};
  std::atomic<uint64_t> control_epoch{0};
  ComPtr<IMFSourceReader> reader;
  std::string path;
  DWORD stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  UINT32 sample_rate = 0;
  UINT32 channels = 0;
  bool com_initialized = false;
  ai_audio_decoder_chunk_callback callback = nullptr;
  void* callback_user_data = nullptr;
  bool callback_active = false;
  std::atomic<bool> realtime{false};
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

struct OpenResult {
  ai_audio_decoder_status status = AI_AUDIO_DECODER_OPEN_FAILED;
  ComPtr<IMFSourceReader> reader;
  UINT32 sample_rate = 0;
  UINT32 channels = 0;
};

OpenResult open_reader(const std::wstring& wide_path,
                       int64_t start_position_ms = 0) {
  OpenResult result;
  ComPtr<IMFMediaType> type;
  ComPtr<IMFAttributes> attributes;
  if (FAILED(MFCreateAttributes(&attributes, 2)) ||
      FAILED(attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS,
                                   TRUE)) ||
      FAILED(MFCreateSourceReaderFromURL(wide_path.c_str(), attributes.Get(),
                                         &result.reader))) {
    result.status = AI_AUDIO_DECODER_OPEN_FAILED;
    return result;
  }
  if (!set_float_output(result.reader.Get()) ||
      FAILED(result.reader->GetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), &type))) {
    result.reader.Reset();
    result.status = AI_AUDIO_DECODER_NO_AUDIO;
    return result;
  }
  if (FAILED(type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                             &result.sample_rate)) ||
      FAILED(type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &result.channels)) ||
      result.sample_rate == 0 || result.channels == 0) {
    result.reader.Reset();
    result.status = AI_AUDIO_DECODER_NO_AUDIO;
    return result;
  }
  if (start_position_ms > 0) {
    PROPVARIANT position;
    PropVariantInit(&position);
    position.vt = VT_I8;
    position.hVal.QuadPart = start_position_ms * 10000;
    const HRESULT seek_result = result.reader->SetCurrentPosition(GUID_NULL,
                                                                   position);
    PropVariantClear(&position);
    if (FAILED(seek_result)) {
      result.reader.Reset();
      result.status = AI_AUDIO_DECODER_INTERNAL_ERROR;
      return result;
    }
  }
  result.status = AI_AUDIO_DECODER_OK;
  return result;
}

void join_open_worker(ai_audio_decoder* decoder) {
  if (decoder->open_worker.joinable()) decoder->open_worker.join();
}

void join_decode_worker(ai_audio_decoder* decoder) {
  if (decoder->decode_worker.joinable()) decoder->decode_worker.join();
}

void join_seek_worker(ai_audio_decoder* decoder) {
  if (decoder->seek_worker.joinable()) decoder->seek_worker.join();
}

void join_workers(ai_audio_decoder* decoder) {
  join_open_worker(decoder);
  join_decode_worker(decoder);
  join_seek_worker(decoder);
}

void notify_stopped(ai_audio_decoder* decoder) {
  ai_audio_decoder_chunk_callback callback = nullptr;
  void* user_data = nullptr;
  UINT32 sample_rate = 0;
  UINT32 channels = 0;
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    if (!decoder->callback_active) return;
    decoder->callback_active = false;
    callback = decoder->callback;
    user_data = decoder->callback_user_data;
    sample_rate = decoder->sample_rate;
    channels = decoder->channels;
    decoder->callback = nullptr;
    decoder->callback_user_data = nullptr;
  }
  if (callback == nullptr) return;
  auto* last = new (std::nothrow) ai_audio_decoder_chunk{
      0, sample_rate, channels, 0, nullptr, 1};
  if (last != nullptr) callback(last, user_data);
}

void decode_loop(ai_audio_decoder* decoder,
                 ai_audio_decoder_chunk_callback callback,
                 void* user_data) {
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool worker_com_initialized = SUCCEEDED(com_result);
  ComPtr<IMFSourceReader> reader;
  UINT32 sample_rate = 0;
  UINT32 channels = 0;
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    reader = decoder->reader;
    sample_rate = decoder->sample_rate;
    channels = decoder->channels;
  }
  if (reader == nullptr || sample_rate == 0 || channels == 0) {
    decoder->running = false;
    notify_stopped(decoder);
    if (worker_com_initialized) CoUninitialize();
    return;
  }
  decoder->running = true;
  const auto wall_started = std::chrono::steady_clock::now();
  int64_t first_media_ms = -1;
  while (!decoder->cancel.load()) {
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    const HRESULT result = reader->ReadSample(decoder->stream, 0, nullptr,
                                              &flags, &timestamp, &sample);
    if (FAILED(result)) break;
    if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) break;
    if (sample == nullptr) continue;

    if (first_media_ms < 0) first_media_ms = timestamp / 10000;
    if (decoder->realtime.load()) {
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
    const size_t frame_size = sizeof(float) * channels;
    const DWORD count = frame_size == 0
        ? 0
        : static_cast<DWORD>(length / frame_size);
    if (callback != nullptr && count > 0) {
      auto* owned_samples = new (std::nothrow) float[
          static_cast<size_t>(count) * channels];
      auto* owned_chunk = new (std::nothrow) ai_audio_decoder_chunk;
      if (owned_samples == nullptr || owned_chunk == nullptr) {
        delete[] owned_samples;
        delete owned_chunk;
        buffer->Unlock();
        break;
      }
      std::copy_n(reinterpret_cast<const float*>(data),
                  static_cast<size_t>(count) * channels,
                  owned_samples);
      *owned_chunk = {
          static_cast<int64_t>(timestamp / 10000), sample_rate, channels, count,
          owned_samples, 0};
      callback(owned_chunk, user_data);
    }
    buffer->Unlock();
    if (callback == nullptr || count == 0) {
      // No callback owns this sample buffer in the empty/non-callback path.
      continue;
    }
  }
  decoder->running = false;
  // The terminal callback is deliberately emitted by the worker after the
  // blocking ReadSample loop has returned. pause/stop can therefore request
  // cancellation without synchronously joining a slow network reader.
  notify_stopped(decoder);
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
  join_workers(decoder);
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    decoder->reader.Reset();
    decoder->callback = nullptr;
    decoder->callback_user_data = nullptr;
    decoder->callback_active = false;
  }
  const bool com_initialized = decoder->com_initialized;
  delete decoder;
  MFShutdown();
  if (com_initialized) CoUninitialize();
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_open(ai_audio_decoder* decoder, const char* path) {
  if (decoder == nullptr || path == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  ai_audio_decoder_stop(decoder);
  join_workers(decoder);
  const auto wide_path = utf8_to_wide(path);
  if (wide_path.empty()) return AI_AUDIO_DECODER_OPEN_FAILED;
  decoder->cancel = false;
  const auto result = open_reader(wide_path);
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    decoder->reader = result.reader;
    decoder->sample_rate = result.sample_rate;
    decoder->channels = result.channels;
    decoder->path = path;
  }
  return result.status;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_open_async(ai_audio_decoder* decoder, const char* path,
                            int64_t start_position_ms,
                            ai_audio_decoder_open_callback callback,
                            void* user_data) {
  if (decoder == nullptr || path == nullptr || callback == nullptr) {
    return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  }
  if (decoder->opening.load() || decoder->seeking.load() ||
      decoder->running.load()) {
    return AI_AUDIO_DECODER_NOT_READY;
  }
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    if (decoder->reader != nullptr) return AI_AUDIO_DECODER_NOT_READY;
  }
  // A completed failed/cancelled open leaves a joinable thread but no reader.
  // Reaping it here is immediate because opening is already false.
  join_open_worker(decoder);
  join_seek_worker(decoder);
  const auto wide_path = utf8_to_wide(path);
  if (wide_path.empty()) return AI_AUDIO_DECODER_OPEN_FAILED;
  const std::string input(path);
  decoder->cancel = false;
  decoder->opening = true;
  decoder->open_worker = std::thread([decoder, wide_path, input,
                                      start_position_ms, callback, user_data]() {
    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool worker_com_initialized = SUCCEEDED(com_result);
    ai_audio_decoder_status status = AI_AUDIO_DECODER_CANCELLED;
    if (!decoder->cancel.load()) {
      auto result = open_reader(wide_path, start_position_ms);
      status = result.status;
      if (decoder->cancel.load()) {
        status = AI_AUDIO_DECODER_CANCELLED;
      } else if (status == AI_AUDIO_DECODER_OK) {
        std::lock_guard<std::mutex> lock(decoder->mutex);
        decoder->reader = result.reader;
        decoder->sample_rate = result.sample_rate;
        decoder->channels = result.channels;
        decoder->path = input;
      }
      result.reader.Reset();
    }
    decoder->opening = false;
    UINT32 sample_rate = 0;
    UINT32 channels = 0;
    {
      std::lock_guard<std::mutex> lock(decoder->mutex);
      sample_rate = decoder->sample_rate;
      channels = decoder->channels;
    }
    callback(status, sample_rate, channels, user_data);
    if (worker_com_initialized) CoUninitialize();
  });
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
  if (decoder->seeking.load()) return AI_AUDIO_DECODER_NOT_READY;
  join_open_worker(decoder);
  ComPtr<IMFSourceReader> reader;
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    reader = decoder->reader;
  }
  if (reader == nullptr) return AI_AUDIO_DECODER_NOT_READY;
  if (decoder->running.load()) return AI_AUDIO_DECODER_OK;
  // A finished decode worker remains joinable until it is reaped. Joining it
  // here only follows its terminal callback, so this is not a network-read
  // wait and prevents assigning over a joinable std::thread on resume.
  join_decode_worker(decoder);
  decoder->cancel = false;
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    decoder->callback = callback;
    decoder->callback_user_data = user_data;
    decoder->callback_active = true;
  }
  decoder->decode_worker = std::thread(decode_loop, decoder, callback, user_data);
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_pause(ai_audio_decoder* decoder) {
  if (decoder == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  decoder->cancel = true;
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_seek(ai_audio_decoder* decoder, int64_t position_ms) {
  if (decoder == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    if (decoder->reader == nullptr) return AI_AUDIO_DECODER_NOT_READY;
  }
  const uint64_t command_epoch = ++decoder->control_epoch;
  decoder->cancel = true;
  join_decode_worker(decoder);
  notify_stopped(decoder);
  PROPVARIANT position;
  PropVariantInit(&position);
  position.vt = VT_I8;
  position.hVal.QuadPart = position_ms * 10000;
  ComPtr<IMFSourceReader> reader;
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    reader = decoder->reader;
  }
  const HRESULT result = reader == nullptr
      ? E_UNEXPECTED
      : reader->SetCurrentPosition(GUID_NULL, position);
  PropVariantClear(&position);
  if (decoder->control_epoch.load() == command_epoch) decoder->cancel = false;
  return SUCCEEDED(result) ? AI_AUDIO_DECODER_OK : AI_AUDIO_DECODER_INTERNAL_ERROR;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_seek_async(ai_audio_decoder* decoder, int64_t position_ms,
                            ai_audio_decoder_open_callback callback,
                            void* user_data) {
  if (decoder == nullptr || callback == nullptr) {
    return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  }
  if (decoder->opening.load() || decoder->seeking.exchange(true)) {
    return AI_AUDIO_DECODER_NOT_READY;
  }
  {
    std::lock_guard<std::mutex> lock(decoder->mutex);
    if (decoder->reader == nullptr) {
      decoder->seeking = false;
      return AI_AUDIO_DECODER_NOT_READY;
    }
  }
  // A previous completed seek keeps a joinable worker until its next command.
  join_seek_worker(decoder);
  const uint64_t command_epoch = ++decoder->control_epoch;
  decoder->cancel = true;
  decoder->seek_worker = std::thread([decoder, position_ms, callback,
                                      user_data, command_epoch]() {
    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool worker_com_initialized = SUCCEEDED(com_result);
    join_decode_worker(decoder);
    notify_stopped(decoder);

    ai_audio_decoder_status status = AI_AUDIO_DECODER_CANCELLED;
    UINT32 sample_rate = 0;
    UINT32 channels = 0;
    ComPtr<IMFSourceReader> reader;
    {
      std::lock_guard<std::mutex> lock(decoder->mutex);
      reader = decoder->reader;
      sample_rate = decoder->sample_rate;
      channels = decoder->channels;
    }
    if (decoder->control_epoch.load() == command_epoch && reader != nullptr) {
      PROPVARIANT position;
      PropVariantInit(&position);
      position.vt = VT_I8;
      position.hVal.QuadPart = position_ms * 10000;
      const HRESULT result = reader->SetCurrentPosition(GUID_NULL, position);
      PropVariantClear(&position);
      if (decoder->control_epoch.load() == command_epoch) {
        status = SUCCEEDED(result) ? AI_AUDIO_DECODER_OK
                                   : AI_AUDIO_DECODER_INTERNAL_ERROR;
        decoder->cancel = false;
      }
    }
    decoder->seeking = false;
    callback(status, sample_rate, channels, user_data);
    if (worker_com_initialized) CoUninitialize();
  });
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API ai_audio_decoder_status
ai_audio_decoder_stop(ai_audio_decoder* decoder) {
  if (decoder == nullptr) return AI_AUDIO_DECODER_INVALID_ARGUMENT;
  ++decoder->control_epoch;
  decoder->cancel = true;
  return AI_AUDIO_DECODER_OK;
}

extern "C" AI_AUDIO_DECODER_API void
ai_audio_decoder_wait(ai_audio_decoder* decoder) {
  if (decoder == nullptr) return;
  join_workers(decoder);
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
