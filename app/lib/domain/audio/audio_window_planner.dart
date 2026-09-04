import 'dart:collection';

import 'audio_models.dart';

class AudioWindowPlanner {
  /// Width of the pause a window boundary may be moved onto. Whisper segments
  /// carry no speaker information, so the only signal available for keeping one
  /// speaker's line inside one window is the silence between utterances.
  static const Duration _defaultPauseSearch = Duration(milliseconds: 400);

  /// Frame used when scanning for a pause. Short enough to locate a breath
  /// between two lines, long enough not to trigger on individual quiet samples.
  static const Duration _pauseFrame = Duration(milliseconds: 50);

  /// Audio replayed from the end of the previous window.
  ///
  /// Off by default. Replaying audio does let a line cut by a boundary be
  /// heard whole, but whisper reports its first segment as starting at the
  /// window's first sample, so every window's opening subtitle then began
  /// inside the span the previous window had already filled - two subtitles
  /// covering the same second of media. The cross-window context that overlap
  /// was there to provide is carried by the decoder prompt instead, which
  /// costs no timeline. The mechanism stays available for callers that want
  /// it.

  AudioWindowPlanner({
    this.targetWindow = const Duration(seconds: 8),
    this.minimumSpeechWindow = const Duration(milliseconds: 400),
    this.tailSilence = const Duration(milliseconds: 650),
    this.maximumWindow = const Duration(seconds: 10),
    this.silenceRmsThreshold = 0.012,
    this.minimumSpeechFrames = 2,
    this.pauseSearch = _defaultPauseSearch,
    this.windowOverlap = Duration.zero,
    PcmStandardizer? standardizer,
  }) : _standardizer = standardizer ?? const PcmStandardizer() {
    if (targetWindow <= Duration.zero || maximumWindow < targetWindow) {
      throw ArgumentError('Window durations must be positive and ordered');
    }
    if (windowOverlap < Duration.zero || windowOverlap >= targetWindow) {
      throw ArgumentError('Overlap must be shorter than the target window');
    }
  }

  final Duration targetWindow;
  final Duration minimumSpeechWindow;
  final Duration tailSilence;
  final Duration maximumWindow;
  final double silenceRmsThreshold;
  final int minimumSpeechFrames;

  /// How far before and after the nominal window end the planner may look for
  /// a pause to cut on. Zero restores the previous fixed-length behaviour.
  final Duration pauseSearch;

  /// How much of the previous window is prepended to the next one. Zero emits
  /// strictly consecutive windows, which is the default.
  final Duration windowOverlap;
  final PcmStandardizer _standardizer;

  final Queue<NormalizedPcm> _pending = Queue<NormalizedPcm>();
  int _pendingSamples = 0;
  int _sourceChunkCount = 0;
  String? _sessionId;
  Duration? _nextStart;
  int _windowIndex = 0;
  List<double> _carry = const [];

  void reset({
    required String sessionId,
    bool preserveWindowIndex = false,
  }) {
    _pending.clear();
    _pendingSamples = 0;
    _sourceChunkCount = 0;
    _sessionId = sessionId;
    _nextStart = null;
    _carry = const [];
    if (!preserveWindowIndex) _windowIndex = 0;
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
      // The final window of a session has no following audio to search, and its
      // trailing pause is trimmed explicitly below, so pause alignment only
      // applies while decoding continues.
      final take = _pendingSamples >= targetSamples
          ? (complete
              ? targetSamples
              : _pauseAlignedTake(
                  rate, targetSamples, maxSamples, minimumSamples))
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
      // The energy gate reads only the new audio: replayed overlap would
      // otherwise carry a silent window through on the previous window's
      // speech.
      if (!_hasEnoughSpeechEnergy(rawSamples)) {
        _carry = const [];
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
        _carry = const [];
        results.add(WindowPlanResult.skipped(
          mediaStart: start,
          mediaEnd: rawEnd,
          reason: WindowSkipReason.tooShort,
        ));
        continue;
      }
      if (!_hasEnoughSpeechEnergy(samples)) {
        _carry = const [];
        results.add(WindowPlanResult.skipped(
          mediaStart: start,
          mediaEnd: rawEnd,
          reason: WindowSkipReason.silence,
        ));
        continue;
      }
      final carry = _carry;
      final carryStart = start -
          Duration(
              microseconds:
                  carry.length * Duration.microsecondsPerSecond ~/ rate);
      results.add(WindowPlanResult.window(RecognitionWindow(
        windowId: '${_sessionId ?? 'session'}-window-${_windowIndex++}',
        sessionId: _sessionId ?? 'session',
        mediaStart: carryStart.isNegative ? Duration.zero : carryStart,
        sampleRate: rate,
        samples: carry.isEmpty ? samples : <double>[...carry, ...samples],
        sourceChunkCount: chunkCount,
        contextLead: start - (carryStart.isNegative ? Duration.zero : carryStart),
      )));
      _carry = _overlapTail(rawSamples, rate);
      if (_pendingSamples < targetSamples) break;
    }
    return results;
  }

  /// Trailing audio of an emitted window, replayed at the head of the next one.
  List<double> _overlapTail(List<double> samples, int rate) {
    if (windowOverlap <= Duration.zero) return const [];
    final count = windowOverlap.inMicroseconds * rate ~/ 1000000;
    if (count <= 0 || samples.isEmpty) return const [];
    if (samples.length <= count) return List<double>.of(samples);
    return samples.sublist(samples.length - count);
  }

  /// Sample count for the next window, nudged so the boundary lands on a pause
  /// near [targetSamples]. Falls back to [targetSamples] when the search range
  /// holds no pause, which keeps window cadence and the back-pressure
  /// watermarks stable during continuous speech.
  int _pauseAlignedTake(
    int rate,
    int targetSamples,
    int maxSamples,
    int minimumSamples,
  ) {
    if (pauseSearch <= Duration.zero) return targetSamples;
    final search = pauseSearch.inMicroseconds * rate ~/ 1000000;
    final frame = _pauseFrame.inMicroseconds * rate ~/ 1000000;
    if (search <= 0 || frame <= 0) return targetSamples;

    final lower = minimumSamples < targetSamples ? minimumSamples : targetSamples;
    final start = (targetSamples - search).clamp(lower, targetSamples);
    final available = maxSamples < _pendingSamples ? maxSamples : _pendingSamples;
    final end = (targetSamples + search).clamp(0, available);
    if (end <= start) return targetSamples;

    final lookahead = _peekSamples(end);
    if (lookahead.length < end) return targetSamples;

    // Among the pauses found, take the one closest to the nominal boundary so
    // window lengths keep hovering around the target.
    var bestOffset = -1;
    var bestDistance = -1;
    for (var offset = start; offset + frame <= end; offset += frame) {
      if (!_isQuiet(lookahead, offset, offset + frame)) continue;
      final distance = (offset - targetSamples).abs();
      if (bestOffset < 0 || distance < bestDistance) {
        bestOffset = offset;
        bestDistance = distance;
      }
    }
    return bestOffset < 0 ? targetSamples : bestOffset;
  }

  /// True when the sample range sits at or below the silence threshold.
  bool _isQuiet(List<double> samples, int from, int to) {
    if (to <= from) return false;
    var energy = 0.0;
    for (var index = from; index < to && index < samples.length; index++) {
      energy += samples[index] * samples[index];
    }
    final count = to - from;
    return energy / count <= silenceRmsThreshold * silenceRmsThreshold;
  }

  /// Reads the first [count] pending samples without consuming them.
  List<double> _peekSamples(int count) {
    final output = <double>[];
    var remaining = count;
    for (final chunk in _pending) {
      if (remaining <= 0) break;
      final take = remaining.clamp(0, chunk.samples.length);
      output.addAll(chunk.samples.take(take));
      remaining -= take;
    }
    return output;
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
