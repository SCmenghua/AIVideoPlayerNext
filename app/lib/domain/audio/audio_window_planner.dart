import 'dart:collection';

import 'audio_models.dart';

class AudioWindowPlanner {
  AudioWindowPlanner({
    this.targetWindow = const Duration(seconds: 4),
    this.minimumSpeechWindow = const Duration(milliseconds: 400),
    this.tailSilence = const Duration(milliseconds: 650),
    this.maximumWindow = const Duration(seconds: 6),
    this.silenceRmsThreshold = 0.012,
    this.minimumSpeechFrames = 2,
    PcmStandardizer? standardizer,
  }) : _standardizer = standardizer ?? const PcmStandardizer() {
    if (targetWindow <= Duration.zero || maximumWindow < targetWindow) {
      throw ArgumentError('Window durations must be positive and ordered');
    }
  }

  final Duration targetWindow;
  final Duration minimumSpeechWindow;
  final Duration tailSilence;
  final Duration maximumWindow;
  final double silenceRmsThreshold;
  final int minimumSpeechFrames;
  final PcmStandardizer _standardizer;

  final Queue<NormalizedPcm> _pending = Queue<NormalizedPcm>();
  int _pendingSamples = 0;
  int _sourceChunkCount = 0;
  String? _sessionId;
  Duration? _nextStart;
  int _windowIndex = 0;

  void reset({required String sessionId}) {
    _pending.clear();
    _pendingSamples = 0;
    _sourceChunkCount = 0;
    _sessionId = sessionId;
    _nextStart = null;
    _windowIndex = 0;
  }

  List<WindowPlanResult> add(AudioChunk chunk) {
    if (_sessionId != chunk.sessionId) reset(sessionId: chunk.sessionId);
    final normalized = _standardizer.normalize(chunk);
    if (normalized.samples.isEmpty) {
      return chunk.isLast ? _drain(complete: true) : const [];
    }
    _pending.add(normalized);
    _pendingSamples += normalized.samples.length;
    _sourceChunkCount++;
    _nextStart ??= normalized.mediaStart;
    return _drain(complete: chunk.isLast);
  }

  List<WindowPlanResult> finish() => _drain(complete: true);

  List<WindowPlanResult> _drain({required bool complete}) {
    final results = <WindowPlanResult>[];
    if (_pending.isEmpty) return results;
    final rate = _standardizer.outputSampleRate;
    final targetSamples = targetWindow.inMicroseconds * rate ~/ 1000000;
    final maxSamples = maximumWindow.inMicroseconds * rate ~/ 1000000;
    final minimumSamples = minimumSpeechWindow.inMicroseconds * rate ~/ 1000000;

    while (
        _pendingSamples >= targetSamples || (complete && _pendingSamples > 0)) {
      final take = _pendingSamples >= targetSamples
          ? targetSamples
          : _pendingSamples.clamp(0, maxSamples);
      if (take <= 0) break;
      final rawSamples = _takeSamples(take);
      final start = _nextStart ?? Duration.zero;
      final rawEnd = start +
          Duration(
              microseconds:
                  rawSamples.length * Duration.microsecondsPerSecond ~/ rate);
      _nextStart = rawEnd;
      final chunkCount = _sourceChunkCount;
      _sourceChunkCount = 0;

      // Only trim a trailing pause at EOF. While decoding is still active,
      // keeping the raw boundary avoids dropping speech that follows a pause.
      if (!_hasEnoughSpeechEnergy(rawSamples)) {
        results.add(WindowPlanResult.skipped(
          mediaStart: start,
          mediaEnd: rawEnd,
          reason: WindowSkipReason.silence,
        ));
        continue;
      }
      final samples =
          complete ? _trimTrailingSilence(rawSamples, rate) : rawSamples;

      if (samples.length < minimumSamples) {
        results.add(WindowPlanResult.skipped(
          mediaStart: start,
          mediaEnd: rawEnd,
          reason: WindowSkipReason.tooShort,
        ));
        continue;
      }
      if (!_hasEnoughSpeechEnergy(samples)) {
        results.add(WindowPlanResult.skipped(
          mediaStart: start,
          mediaEnd: rawEnd,
          reason: WindowSkipReason.silence,
        ));
        continue;
      }
      results.add(WindowPlanResult.window(RecognitionWindow(
        windowId: '${_sessionId ?? 'session'}-window-${_windowIndex++}',
        sessionId: _sessionId ?? 'session',
        mediaStart: start,
        sampleRate: rate,
        samples: samples,
        sourceChunkCount: chunkCount,
      )));
      if (_pendingSamples < targetSamples) break;
    }
    return results;
  }

  List<double> _takeSamples(int count) {
    final output = <double>[];
    var remaining = count;
    while (remaining > 0 && _pending.isNotEmpty) {
      final first = _pending.first;
      final take = remaining.clamp(0, first.samples.length);
      output.addAll(first.samples.take(take));
      remaining -= take;
      _pendingSamples -= take;
      if (take == first.samples.length) {
        _pending.removeFirst();
      } else {
        _pending.removeFirst();
        _pending.addFirst(NormalizedPcm(
          sessionId: first.sessionId,
          mediaStart: first.mediaStart +
              Duration(
                microseconds:
                    take * Duration.microsecondsPerSecond ~/ first.sampleRate,
              ),
          sampleRate: first.sampleRate,
          samples: first.samples.sublist(take),
        ));
      }
    }
    return output;
  }

  bool _hasEnoughSpeechEnergy(List<double> samples) {
    if (samples.isEmpty) return false;

    // A whole 8-second window can have a short spoken line surrounded by
    // quiet audio. Gate on short frames so that line is not averaged away.
    const gateFrame = Duration(milliseconds: 200);
    final frameSamples =
        gateFrame.inMicroseconds * _standardizer.outputSampleRate ~/ 1000000;
    final thresholdSquared = silenceRmsThreshold * silenceRmsThreshold;
    var consecutiveSpeechFrames = 0;
    for (var start = 0; start < samples.length; start += frameSamples) {
      final end = (start + frameSamples).clamp(0, samples.length);
      var energy = 0.0;
      for (var index = start; index < end; index++) {
        energy += samples[index] * samples[index];
      }
      final count = end - start;
      if (count > 0 && energy / count > thresholdSquared) {
        consecutiveSpeechFrames++;
        if (consecutiveSpeechFrames >= minimumSpeechFrames) return true;
      } else {
        consecutiveSpeechFrames = 0;
      }
    }
    return false;
  }

  List<double> _trimTrailingSilence(List<double> samples, int rate) {
    if (tailSilence <= Duration.zero || samples.isEmpty) return samples;
    final required = tailSilence.inMicroseconds * rate ~/ 1000000;
    var end = samples.length;
    while (end > 0 && samples[end - 1].abs() <= silenceRmsThreshold) {
      end--;
    }
    if (samples.length - end < required) return samples;
    return samples.sublist(0, end);
  }
}
