import 'package:flutter/material.dart';

import '../../domain/subtitles/transcript_document.dart';
import '../settings/app_settings.dart';

const subtitleHold = Duration(milliseconds: 2500);

class ActiveSubtitle {
  const ActiveSubtitle({
    required this.segment,
    this.translation,
    this.translationPending = false,
  });

  final TranscriptSegment segment;
  final String? translation;
  final bool translationPending;
}

/// The line to show at [position]: the latest segment that has started, kept
/// on screen for [hold] after it ends unless a later one has begun.
ActiveSubtitle? subtitleAt(
  TranscriptDocument? document,
  Duration position, {
  required String targetLanguage,
  Duration hold = subtitleHold,
}) {
  if (document == null) return null;
  final ms = position.inMilliseconds;
  TranscriptSegment? latest;
  for (final segment in document.orderedSegments) {
    if (segment.startMs > ms) break;
    latest = segment;
  }
  if (latest == null) return null;
  if (ms >= latest.endMs && ms - latest.endMs >= hold.inMilliseconds) return null;
  TranscriptTranslation? translation;
  for (final candidate in document.translations) {
    if (candidate.segmentId == latest.id && candidate.targetLanguage == targetLanguage) {
      translation = candidate;
      break;
    }
  }
  final translated = translation != null &&
      translation.status == TranscriptTranslationStatus.translated &&
      translation.text.trim().isNotEmpty;
  return ActiveSubtitle(
    segment: latest,
    translation: translated ? translation.text : null,
    translationPending: translation != null &&
        (translation.status == TranscriptTranslationStatus.pending ||
            translation.status == TranscriptTranslationStatus.translating),
  );
}

class SubtitleLayer extends StatelessWidget {
  const SubtitleLayer({
    super.key,
    required this.document,
    required this.position,
    required this.targetLanguage,
    required this.displayMode,
    this.fontScale = 1.0,
    this.bottomPadding = 24,
  });

  final TranscriptDocument? document;
  final Duration position;
  final String targetLanguage;
  final SubtitleDisplayMode displayMode;
  final double fontScale;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final subtitle = subtitleAt(document, position, targetLanguage: targetLanguage);
    if (subtitle == null) return const SizedBox.shrink();
    final width = MediaQuery.sizeOf(context).width;
    final primarySize = (width < 600 ? 16.0 : 22.0) * fontScale;
    final secondarySize = (width < 600 ? 12.0 : 15.0) * fontScale;
    final original = subtitle.segment.text;
    final translation = subtitle.translation;

    final String primary;
    String? secondary;
    switch (displayMode) {
      case SubtitleDisplayMode.original:
        primary = original;
      case SubtitleDisplayMode.translation:
        primary = translation ?? original;
      case SubtitleDisplayMode.bilingual:
        primary = translation ?? original;
        if (translation != null) secondary = original;
    }

    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, bottomPadding),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width * 0.9),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SubtitleText(
                  key: const Key('subtitle-primary'),
                  text: primary,
                  fontSize: primarySize,
                  emphasized: true,
                ),
                if (secondary != null) ...[
                  const SizedBox(height: 4),
                  _SubtitleText(
                    key: const Key('subtitle-source'),
                    text: secondary,
                    fontSize: secondarySize,
                    emphasized: false,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SubtitleText extends StatelessWidget {
  const _SubtitleText({
    super.key,
    required this.text,
    required this.fontSize,
    required this.emphasized,
  });

  final String text;
  final double fontSize;
  final bool emphasized;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: emphasized ? Colors.white : const Color(0xFFD8DDE1),
              fontSize: fontSize,
              height: 1.3,
              fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
              shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
            ),
          ),
        ),
      );
}
