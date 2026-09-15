import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_bindings.dart';
import 'pcm.dart';

/// Converts decoder output to 16 kHz mono through the native anti-aliased
/// resampler and keeps the media timeline continuous across chunks.
///
/// Call [reset] after a seek or whenever the source restarts; a discontinuity
/// in [RawPcmChunk.mediaStart] larger than [discontinuityTolerance] resets
/// automatically.
class PcmNormalizer {
  PcmNormalizer(
    this._bindings, {
    this.discontinuityTolerance = const Duration(milliseconds: 60),
  });

  final SpeechCoreBindings _bindings;
  final Duration discontinuityTolerance;

  Pointer<Void> _resampler = nullptr;
  int _rate = 0;
  int _channels = 0;
  Duration _streamStart = Duration.zero;
  int _producedSamples = 0;
  Duration _expectedNext = Duration.zero;
  bool _disposed = false;

  Duration get producedThrough => _outputTime(_producedSamples);

  void reset() {
    _destroyResampler();
    _producedSamples = 0;
    _streamStart = Duration.zero;
    _expectedNext = Duration.zero;
  }

  /// Returns the normalised chunk, or `null` when the filter is still holding
  /// every sample back. A chunk flagged [RawPcmChunk.isLast] flushes.
  PcmChunk? process(RawPcmChunk raw) {
    if (_disposed) throw StateError('normalizer disposed');
    final formatChanged = raw.sampleRate != _rate || raw.channels != _channels;
    final gap = (raw.mediaStart - _expectedNext).abs();
    if (_resampler == nullptr || formatChanged || gap > discontinuityTolerance) {
      _destroyResampler();
      _create(raw.sampleRate, raw.channels);
      _streamStart = raw.mediaStart;
      _producedSamples = 0;
    }
    _expectedNext = raw.mediaStart + raw.duration;

    final frames = raw.frameCount;
    final capacity = _bindings.resamplerMaxOutput(_resampler, frames) + 1;
    final input = frames == 0 ? nullptr : calloc<Float>(raw.samples.length);
    final output = calloc<Float>(capacity);
    final count = calloc<Size>();
    try {
      var total = 0;
      if (frames > 0) {
        input.asTypedList(raw.samples.length).setAll(0, raw.samples);
        _bindings.check(
          _bindings.resamplerProcess(_resampler, input, frames, output, capacity, count),
          'resample',
        );
        total = count.value;
      }
      if (raw.isLast) {
        final tail = Pointer<Float>.fromAddress(output.address + total * sizeOf<Float>());
        _bindings.check(
          _bindings.resamplerFlush(_resampler, tail, capacity - total, count),
          'resample flush',
        );
        total += count.value;
      }
      if (total == 0 && !raw.isLast) return null;
      final samples = Float32List.fromList(output.asTypedList(total));
      final chunk = PcmChunk(
        samples: samples,
        mediaStart: _outputTime(_producedSamples),
        isLast: raw.isLast,
      );
      _producedSamples += total;
      if (raw.isLast) _destroyResampler();
      return chunk;
    } finally {
      if (input != nullptr) calloc.free(input);
      calloc.free(output);
      calloc.free(count);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _destroyResampler();
  }

  Duration _outputTime(int samples) =>
      _streamStart +
      Duration(microseconds: samples * Duration.microsecondsPerSecond ~/ speechSampleRate);

  void _create(int rate, int channels) {
    final out = calloc<Pointer<Void>>();
    try {
      _bindings.check(_bindings.resamplerCreate(rate, channels, out), 'resampler');
      _resampler = out.value;
    } finally {
      calloc.free(out);
    }
    _rate = rate;
    _channels = channels;
  }

  void _destroyResampler() {
    if (_resampler != nullptr) {
      _bindings.resamplerDestroy(_resampler);
      _resampler = nullptr;
    }
    _rate = 0;
    _channels = 0;
  }
}
