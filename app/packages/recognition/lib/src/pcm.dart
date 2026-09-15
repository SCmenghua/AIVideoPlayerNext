import 'dart:typed_data';

const int speechSampleRate = 16000;

/// Interleaved float PCM as produced by a platform decoder, at its native
/// sample rate and channel count.
class RawPcmChunk {
  const RawPcmChunk({
    required this.samples,
    required this.sampleRate,
    required this.channels,
    required this.mediaStart,
    this.isLast = false,
  });

  final Float32List samples;
  final int sampleRate;
  final int channels;
  final Duration mediaStart;
  final bool isLast;

  int get frameCount => channels == 0 ? 0 : samples.length ~/ channels;

  Duration get duration => Duration(
        microseconds: sampleRate == 0
            ? 0
            : frameCount * Duration.microsecondsPerSecond ~/ sampleRate,
      );
}

/// 16 kHz mono float PCM with its position on the media timeline.
class PcmChunk {
  const PcmChunk({
    required this.samples,
    required this.mediaStart,
    this.isLast = false,
  });

  final Float32List samples;
  final Duration mediaStart;
  final bool isLast;

  Duration get duration => Duration(
        microseconds:
            samples.length * Duration.microsecondsPerSecond ~/ speechSampleRate,
      );

  Duration get mediaEnd => mediaStart + duration;
}

enum PcmSourceState { idle, opening, running, paused, ended, stopped, error }

class PcmSourceStatus {
  const PcmSourceStatus({
    required this.state,
    this.message,
    this.sampleRate,
    this.channels,
  });

  const PcmSourceStatus.idle() : this(state: PcmSourceState.idle);

  final PcmSourceState state;
  final String? message;
  final int? sampleRate;
  final int? channels;

  PcmSourceStatus copyWith({
    PcmSourceState? state,
    String? message,
    int? sampleRate,
    int? channels,
  }) =>
      PcmSourceStatus(
        state: state ?? this.state,
        message: message ?? this.message,
        sampleRate: sampleRate ?? this.sampleRate,
        channels: channels ?? this.channels,
      );
}

/// A decoder that streams a media file's audio with media timestamps.
///
/// Implementations may emit any sample rate and channel layout; the session
/// normalises to 16 kHz mono. After [seek] the next chunk's [RawPcmChunk.mediaStart]
/// must reflect the new position.
abstract interface class PcmSource {
  Stream<RawPcmChunk> get chunks;
  Stream<PcmSourceStatus> get statuses;
  PcmSourceStatus get status;
  Future<void> open(Uri uri, {Duration start = Duration.zero});
  Future<void> start();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> dispose();
}
