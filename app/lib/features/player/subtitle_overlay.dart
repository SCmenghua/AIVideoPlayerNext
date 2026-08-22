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

ActiveSubtitle? subtitleAt(
  TranscriptDocument? document,
  Duration position, {
  String targetLanguage = 'zh-CN',
}) {
  if (document == null) return null;
  final activeSegments = document.at(position);
  if (activeSegments.isEmpty) return null;

  // Prefer the latest segment if adjacent recognition windows overlap briefly.
  final segment = activeSegments.last;
  TranscriptTranslation? translation;
  for (final candidate in document.translations) {
    if (candidate.segmentId == segment.id &&
        candidate.targetLanguage == targetLanguage &&
        candidate.status == TranscriptTranslationStatus.translated &&
        candidate.text.trim().isNotEmpty) {
      translation = candidate;
      break;
    }
  }
  return ActiveSubtitle(
    sourceText: segment.text,
    translationText: translation?.text,
  );
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
