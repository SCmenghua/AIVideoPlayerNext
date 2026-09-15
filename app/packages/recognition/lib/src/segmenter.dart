import 'dart:typed_data';

import 'config.dart';
import 'pcm.dart';

/// One recognition window: speech bounded by pauses, with the VAD's own view
/// of where speech starts and ends inside it.
class SpeechWindow {
  const SpeechWindow({
    required this.id,
    required this.index,
    required this.samples,
    required this.mediaStart,
    required this.speechStart,
    required this.speechEnd,
    required this.speechRatio,
    required this.cutReason,
  });

  final String id;
  final int index;
  final Float32List samples;
  final Duration mediaStart;
  final Duration speechStart;
  final Duration speechEnd;
  final double speechRatio;
  final String cutReason;

  Duration get duration => Duration(
        microseconds:
            samples.length * Duration.microsecondsPerSecond ~/ speechSampleRate,
      );

  Duration get mediaEnd => mediaStart + duration;
}

sealed class SegmenterEvent {
  const SegmenterEvent();
}

class WindowReady extends SegmenterEvent {
  const WindowReady(this.window);

  final SpeechWindow window;
}

/// Audio without speech that was discarded; the range still counts as
/// processed so the lead watermark keeps moving through silence.
class RangeSkipped extends SegmenterEvent {
  const RangeSkipped(this.start, this.end);

  final Duration start;
  final Duration end;
}

class _Frame {
  _Frame(this.samples, this.probability, this.start, this.isSpeech);

  final Float32List samples;
  final double probability;
  final Duration start;
  final bool isSpeech;
}

/// Cuts a frame-aligned stream of audio plus VAD probabilities into windows.
///
/// Boundaries always fall inside a pause. Short windows are accepted after a
/// long pause, medium windows after a normal pause, long windows after any
/// pause, and a window that reaches [SegmenterOptions.maxWindow] is cut at the
/// quietest recent frame.
class SpeechSegmenter {
  SpeechSegmenter({
    required this.frameSamples,
    this.options = const SegmenterOptions(),
    this.forcedCutSearch = const Duration(seconds: 4),
  }) : frameDuration = Duration(
          microseconds: frameSamples * Duration.microsecondsPerSecond ~/ speechSampleRate,
        );

  final int frameSamples;
  final SegmenterOptions options;
  final Duration forcedCutSearch;
  final Duration frameDuration;

  final List<_Frame> _frames = [];
  bool _speechSeen = false;
  int _silenceRun = 0;
  int _lastSpeechIndex = -1;
  int _windowIndex = 0;
  String _sessionId = 'session';

  int get windowIndex => _windowIndex;
  Duration get bufferedDuration => _durationOf(_frames.length);
  Duration? get bufferStart => _frames.isEmpty ? null : _frames.first.start;

  void reset({String? sessionId, bool preserveIndex = true}) {
    _frames.clear();
    _speechSeen = false;
    _silenceRun = 0;
    _lastSpeechIndex = -1;
    if (sessionId != null) _sessionId = sessionId;
    if (!preserveIndex) _windowIndex = 0;
  }

  List<SegmenterEvent> addFrame(Float32List samples, double probability, Duration mediaStart) {
    if (samples.length != frameSamples) {
      throw ArgumentError('frame must have $frameSamples samples');
    }
    final isSpeech = probability >= options.speechThreshold;
    final events = <SegmenterEvent>[];
    _frames.add(_Frame(samples, probability, mediaStart, isSpeech));
    if (isSpeech) {
      if (!_speechSeen) {
        // Speech onset: keep only the padding before it as pre-roll.
        final drop = _frames.length - 1 - _framesFor(options.pad);
        if (drop > 0) {
          events.add(RangeSkipped(_frames.first.start, _frames[drop].start));
          _frames.removeRange(0, drop);
        }
      }
      _silenceRun = 0;
      _speechSeen = true;
      _lastSpeechIndex = _frames.length - 1;
    } else {
      _silenceRun++;
    }

    if (!_speechSeen) {
      if (bufferedDuration >= options.silenceFlush) {
        final keep = _framesFor(options.pad);
        final drop = _frames.length - keep;
        if (drop > 0) {
          events.add(RangeSkipped(_frames.first.start, _frames[drop].start));
          _frames.removeRange(0, drop);
        }
      }
      return events;
    }

    final duration = bufferedDuration;
    final silence = _durationOf(_silenceRun);
    if (duration >= options.maxWindow) {
      events.add(WindowReady(_forcedCut()));
    } else if (silence >= options.longSilence && duration >= options.minWindow) {
      events.add(WindowReady(_pauseCut('longSilence')));
    } else if (silence >= options.minSilence && duration >= options.minCutWindow) {
      events.add(WindowReady(_pauseCut('pause')));
    } else if (silence >= options.shortSilence && duration >= options.targetWindow) {
      events.add(WindowReady(_pauseCut('target')));
    }
    return events;
  }

  List<SegmenterEvent> flush() {
    final events = <SegmenterEvent>[];
    if (_frames.isEmpty) return events;
    if (_speechSeen) {
      events.add(WindowReady(_pauseCut('flush')));
      if (_frames.isNotEmpty) {
        events.add(RangeSkipped(_frames.first.start, _endOf(_frames.length - 1)));
      }
    } else {
      events.add(RangeSkipped(_frames.first.start, _endOf(_frames.length - 1)));
    }
    _frames.clear();
    _speechSeen = false;
    _silenceRun = 0;
    _lastSpeechIndex = -1;
    return events;
  }

  // Cuts after the last speech frame plus padding; trailing silence stays as
  // pre-roll for the next window.
  SpeechWindow _pauseCut(String reason) {
    final end = (_lastSpeechIndex + 1 + _framesFor(options.pad)).clamp(1, _frames.length).toInt();
    return _emit(end, reason);
  }

  // Cuts at the quietest frame within the search span, but never inside the
  // padding after the last speech frame if that frame is nearby.
  SpeechWindow _forcedCut() {
    final searchFrames = _framesFor(forcedCutSearch).clamp(1, _frames.length - 1).toInt();
    final minEnd = _framesFor(options.minWindow).clamp(1, _frames.length - 1).toInt();
    var best = _frames.length - 1;
    var bestProbability = double.infinity;
    for (var i = _frames.length - searchFrames; i < _frames.length; i++) {
      if (i < minEnd) continue;
      if (_frames[i].probability < bestProbability) {
        bestProbability = _frames[i].probability;
        best = i;
      }
    }
    return _emit(best.clamp(1, _frames.length).toInt(), 'forced');
  }

  SpeechWindow _emit(int end, String reason) {
    final windowFrames = _frames.sublist(0, end);
    final remainder = _frames.sublist(end);
    final samples = Float32List(windowFrames.length * frameSamples);
    var offset = 0;
    var speechFrames = 0;
    Duration? speechStart;
    Duration speechEnd = windowFrames.first.start;
    for (final frame in windowFrames) {
      samples.setAll(offset, frame.samples);
      offset += frameSamples;
      if (frame.isSpeech) {
        speechFrames++;
        speechStart ??= frame.start;
        speechEnd = frame.start + frameDuration;
      }
    }
    final window = SpeechWindow(
      id: '$_sessionId-w${_windowIndex.toString().padLeft(5, '0')}',
      index: _windowIndex++,
      samples: samples,
      mediaStart: windowFrames.first.start,
      speechStart: speechStart ?? windowFrames.first.start,
      speechEnd: speechEnd,
      speechRatio: speechFrames / windowFrames.length,
      cutReason: reason,
    );
    _frames
      ..clear()
      ..addAll(remainder);
    _speechSeen = false;
    _silenceRun = 0;
    _lastSpeechIndex = -1;
    for (var i = 0; i < _frames.length; i++) {
      if (_frames[i].isSpeech) {
        _speechSeen = true;
        _lastSpeechIndex = i;
        _silenceRun = 0;
      } else {
        _silenceRun++;
      }
    }
    return window;
  }

  int _framesFor(Duration duration) {
    if (frameDuration <= Duration.zero) return 0;
    return (duration.inMicroseconds + frameDuration.inMicroseconds - 1) ~/
        frameDuration.inMicroseconds;
  }

  Duration _durationOf(int frames) =>
      Duration(microseconds: frames * frameDuration.inMicroseconds);

  Duration _endOf(int index) => _frames[index].start + frameDuration;
}
