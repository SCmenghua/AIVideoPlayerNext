import '../../domain/player/player_service.dart';
import '../../domain/subtitles/transcript_document.dart';
import '../settings/app_settings.dart';
import 'playback_start_policy.dart';

enum GateAction { none, play, pause }

class GateEvaluation {
  const GateEvaluation(this.action, {this.reason, this.waitingForStart = false});

  final GateAction action;
  final String? reason;
  final bool waitingForStart;
}

/// Decides when playback may start and when it should pause to let subtitles
/// catch up. Pure state machine: the shell feeds it player and transcript
/// state and applies the returned action.
class PlaybackGate {
  PlaybackGate({
    required this.now,
    this.startupTimeout = const Duration(seconds: 10),
    this.strategy = PlaybackStartStrategy.subtitlePriority,
    this.waitForPreparation = true,
  });

  final DateTime Function() now;
  final Duration startupTimeout;
  PlaybackStartStrategy strategy;
  bool waitForPreparation;

  DateTime? _startupBeganAt;
  bool _startReleased = true;
  bool _policyPaused = false;
  DateTime? _contentWaitStartedAt;
  bool _suppressed = false;
  DateTime? _progressAt;
  Duration? _lastProcessedThrough;

  bool get waitingForStart => !_startReleased;
  bool get policyPaused => _policyPaused;

  /// Time spent waiting for content at the current position.
  Duration get waited => _contentWaitStartedAt == null
      ? Duration.zero
      : now().difference(_contentWaitStartedAt!);

  void beginMedia() {
    _policyPaused = false;
    _contentWaitStartedAt = null;
    _suppressed = false;
    _progressAt = null;
    _lastProcessedThrough = null;
    final gated = waitForPreparation && strategy != PlaybackStartStrategy.playbackPriority;
    _startReleased = !gated;
    _startupBeganAt = gated ? now() : null;
  }

  void onSeek() {
    _contentWaitStartedAt = null;
  }

  /// The user pressed play: releases the startup wait and, during a content
  /// wait, overrides the gate until content catches up.
  void userPlay() {
    _startReleased = true;
    if (_policyPaused) _suppressed = true;
    _policyPaused = false;
  }

  void userPause() {
    _policyPaused = false;
    _contentWaitStartedAt = null;
  }

  void noteRecognitionProgress(Duration processedThrough) {
    if (processedThrough != _lastProcessedThrough) {
      _lastProcessedThrough = processedThrough;
      _progressAt = now();
    }
  }

  GateEvaluation evaluate({
    required PlaybackStatus status,
    required Duration position,
    required TranscriptDocument? document,
    required String targetLanguage,
    required bool translationExpected,
    required bool recognitionAlive,
  }) {
    final next = _nextSegment(document, position);
    final subtitleReady = next != null;
    final translationReady = !translationExpected ||
        (next != null && _translationResolved(document!, next, targetLanguage));

    if (!_startReleased) {
      final wanted = strategy == PlaybackStartStrategy.translationPriority
          ? translationReady && subtitleReady
          : subtitleReady;
      final timedOut = _startupBeganAt != null &&
          now().difference(_startupBeganAt!) >= startupTimeout;
      if (wanted || timedOut || !recognitionAlive) {
        _startReleased = true;
        return const GateEvaluation(GateAction.play, reason: '字幕已准备好');
      }
      return GateEvaluation(
        GateAction.none,
        reason: strategy == PlaybackStartStrategy.translationPriority ? '等待首条翻译' : '等待首条字幕',
        waitingForStart: true,
      );
    }

    if (status != PlaybackStatus.playing && status != PlaybackStatus.paused) {
      return const GateEvaluation(GateAction.none);
    }
    final contentMissing =
        (strategy == PlaybackStartStrategy.subtitlePriority && !subtitleReady) ||
            (strategy == PlaybackStartStrategy.translationPriority && !translationReady);
    if (!contentMissing || !recognitionAlive) {
      _contentWaitStartedAt = null;
      _suppressed = false;
    } else {
      _contentWaitStartedAt ??= now();
    }
    final progressing =
        _progressAt != null && now().difference(_progressAt!) <= const Duration(seconds: 2);
    final decision = evaluatePlaybackContent(
      strategy: strategy,
      subtitleReadyAtPosition: subtitleReady || !recognitionAlive,
      translationReadyAtPosition: translationReady || !recognitionAlive,
      recognitionProgressing: progressing,
      waited: waited,
      suppressWait: _suppressed,
    );
    if (status == PlaybackStatus.playing && !decision.canContinue) {
      if (_policyPaused) return GateEvaluation(GateAction.none, reason: decision.reason);
      _policyPaused = true;
      return GateEvaluation(GateAction.pause, reason: decision.reason);
    }
    if (status == PlaybackStatus.paused && _policyPaused && decision.canContinue) {
      _policyPaused = false;
      return GateEvaluation(GateAction.play, reason: decision.reason);
    }
    return GateEvaluation(
      GateAction.none,
      reason: _policyPaused ? decision.reason : null,
    );
  }

  static TranscriptSegment? _nextSegment(TranscriptDocument? document, Duration position) {
    if (document == null) return null;
    final ms = position.inMilliseconds;
    for (final segment in document.orderedSegments) {
      if (segment.endMs > ms) return segment;
    }
    return null;
  }

  static bool _translationResolved(
    TranscriptDocument document,
    TranscriptSegment segment,
    String targetLanguage,
  ) {
    for (final translation in document.translations) {
      if (translation.segmentId != segment.id || translation.targetLanguage != targetLanguage) {
        continue;
      }
      if (translation.status == TranscriptTranslationStatus.translated &&
          translation.text.trim().isNotEmpty) {
        return true;
      }
      return translation.status == TranscriptTranslationStatus.failed;
    }
    return false;
  }
}
