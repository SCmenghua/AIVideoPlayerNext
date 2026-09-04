import 'package:flutter/material.dart';

import '../../domain/subtitles/transcript_document.dart';
import '../settings/app_settings.dart';

class ActiveSubtitle {
  const ActiveSubtitle({
    required this.sourceText,
    this.translationText,
  });

  final String sourceText;
  final String? translationText;

  bool get hasTranslation => translationText != null;
}

/// How long a finished line stays on screen once nothing has replaced it.
///
/// Recognition of the first window races the playhead: the decoder's lead over
/// playback starts at zero and only grows to the watermark afterwards, so every
/// later window lands tens of seconds ahead of where it will be needed while
/// the first one can land after its own span has already gone by. Without a
/// hold, a segment that arrives late is never shown at all - the lookup is
/// `start <= position < end` and nothing revisits it.
const Duration subtitleHold = Duration(milliseconds: 2500);

ActiveSubtitle? subtitleAt(
  TranscriptDocument? document,
  Duration position, {
  String targetLanguage = 'zh-CN',
}) {
  if (document == null) return null;
  final activeSegments = document.at(position);

  // Prefer the latest segment if adjacent recognition windows overlap briefly.
  final segment =
      activeSegments.isNotEmpty ? activeSegments.last : _heldSegment(document, position);
  if (segment == null) return null;
  TranscriptTranslation? translation;
  for (final candidate in document.translations) {
    if (candidate.segmentId == segment.id &&
        candidate.targetLanguage == targetLanguage &&
        candidate.status == TranscriptTranslationStatus.translated &&
        candidate.text.trim().isNotEmpty &&
        // A re-assembled segment can reuse a stable ID with new text; only a
        // translation of that text may be shown for it.
        (candidate.sourceText == null ||
            candidate.sourceText == segment.text)) {
      translation = candidate;
      break;
    }
  }
  return ActiveSubtitle(
    sourceText: segment.text,
    translationText: translation?.text,
  );
}

/// The most recently finished segment, while it is still worth showing.
///
/// Only segments that ended within [subtitleHold] qualify, and only while
/// nothing has started since: a long silence clears the screen rather than
/// leaving the previous speaker's line under it.
TranscriptSegment? _heldSegment(TranscriptDocument document, Duration position) {
  final ms = position.inMilliseconds;
  TranscriptSegment? held;
  for (final segment in document.orderedSegments) {
    if (segment.startMs > ms) break;
    if (segment.endMs > ms) continue;
    if (held == null || segment.endMs > held.endMs) held = segment;
  }
  if (held == null) return null;
  return ms - held.endMs <= subtitleHold.inMilliseconds ? held : null;
}

class SubtitleOverlay extends StatelessWidget {
  const SubtitleOverlay({
    super.key,
    required this.document,
    required this.position,
    this.targetLanguage = 'zh-CN',
    this.displayMode = SubtitleDisplayMode.bilingual,
  });

  final TranscriptDocument? document;
  final Duration position;
  final String targetLanguage;
  final SubtitleDisplayMode displayMode;

  @override
  Widget build(BuildContext context) {
    final subtitle = subtitleAt(
      document,
      position,
      targetLanguage: targetLanguage,
    );
    if (subtitle == null) return const SizedBox.shrink();

    final primaryText = switch (displayMode) {
      SubtitleDisplayMode.bilingual =>
        subtitle.translationText ?? subtitle.sourceText,
      SubtitleDisplayMode.original => subtitle.sourceText,
      SubtitleDisplayMode.translation => subtitle.translationText ?? '翻译准备中...',
    };
    final showSource =
        displayMode == SubtitleDisplayMode.bilingual && subtitle.hasTranslation;
    return IgnorePointer(
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 920),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xB8000000),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                primaryText,
                key: const Key('subtitle-primary'),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                ),
              ),
              if (showSource) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle.sourceText,
                  key: const Key('subtitle-source'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFE0E0E0),
                    fontSize: 13,
                    height: 1.25,
                    shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
