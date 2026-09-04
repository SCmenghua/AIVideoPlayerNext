import '../speech/speech_models.dart';

const int transcriptSchemaVersion = 1;

enum TranscriptSegmentStatus { timelineFinal }

enum TranscriptTranslationStatus { pending, translating, translated, failed }

class TranscriptSegment {
  const TranscriptSegment({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.language,
    required this.status,
    required this.sourceWindows,
    this.speaker,
    this.confidence,
  })  : assert(startMs >= 0),
        assert(endMs >= startMs);

  factory TranscriptSegment.fromRecognitionEvent(RecognitionEvent event) {
    final sourceWindowId = event.sourceWindowId ??
        '${event.sessionId}-window-${event.start.inMilliseconds.toString().padLeft(12, '0')}';
    return TranscriptSegment(
      id: event.segmentId,
      startMs: event.start.inMilliseconds,
      endMs: event.end.inMilliseconds,
      text: event.text,
      language: event.language,
      confidence: event.confidence,
      status: TranscriptSegmentStatus.timelineFinal,
      sourceWindows: [sourceWindowId],
    );
  }

  factory TranscriptSegment.fromJson(Map<String, Object?> json) =>
      TranscriptSegment(
        id: json['id']! as String,
        startMs: json['startMs']! as int,
        endMs: json['endMs']! as int,
        speaker: json['speaker'] as String?,
        text: json['text']! as String,
        language: json['language']! as String,
        confidence: (json['confidence'] as num?)?.toDouble(),
        status: TranscriptSegmentStatus.values.byName(
          json['status']! as String,
        ),
        sourceWindows: List<String>.from(
          json['sourceWindows']! as List<Object?>,
        ),
      );

  final String id;
  final int startMs;
  final int endMs;
  final String? speaker;
  final String text;
  final String language;
  final double? confidence;
  final TranscriptSegmentStatus status;
  final List<String> sourceWindows;

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);

  Map<String, Object?> toJson() => {
        'id': id,
        'startMs': startMs,
        'endMs': endMs,
        'speaker': speaker,
        'text': text,
        'language': language,
        if (confidence != null) 'confidence': confidence,
        'status': status.name,
        'sourceWindows': sourceWindows,
      };
}

class TranscriptTranslation {
  const TranscriptTranslation({
    required this.segmentId,
    required this.targetLanguage,
    required this.text,
    required this.status,
    this.sourceText,
    this.sourceLanguage,
    this.provider,
    this.error,
  });

  factory TranscriptTranslation.fromJson(Map<String, Object?> json) =>
      TranscriptTranslation(
        segmentId: json['segmentId']! as String,
        targetLanguage: json['targetLanguage']! as String,
        text: json['text']! as String,
        status: TranscriptTranslationStatus.values.byName(
          json['status']! as String,
        ),
        sourceText: json['sourceText'] as String?,
        sourceLanguage: json['sourceLanguage'] as String?,
        provider: json['provider'] as String?,
        error: json['error'] as String?,
      );

  final String segmentId;
  final String targetLanguage;
  final String text;
  final TranscriptTranslationStatus status;
  final String? sourceText;
  final String? sourceLanguage;
  final String? provider;
  final String? error;

  Map<String, Object?> toJson() => {
        'segmentId': segmentId,
        'targetLanguage': targetLanguage,
        'text': text,
        'status': status.name,
        if (sourceText != null) 'sourceText': sourceText,
        if (sourceLanguage != null) 'sourceLanguage': sourceLanguage,
        if (provider != null) 'provider': provider,
        if (error != null) 'error': error,
      };
}

/// The session-scoped, final subtitle state shared by diagnostics, translation
/// and the future overlay. Runtime consumers query this in memory; JSON is a
/// temporary snapshot and export format, never a per-frame rendering source.
class TranscriptDocument {
  const TranscriptDocument({
    required this.sessionId,
    required this.revision,
    required this.segments,
    required this.translations,
    this.schemaVersion = transcriptSchemaVersion,
  });

  factory TranscriptDocument.empty({required String sessionId}) =>
      TranscriptDocument(
        sessionId: sessionId,
        revision: 0,
        segments: const [],
        translations: const [],
      );

  factory TranscriptDocument.fromJson(Map<String, Object?> json) =>
      TranscriptDocument(
        schemaVersion: json['schemaVersion']! as int,
        revision: json['revision']! as int,
        sessionId: json['sessionId']! as String,
        segments: (json['segments']! as List<Object?>)
            .map((value) => TranscriptSegment.fromJson(
                  Map<String, Object?>.from(value! as Map),
                ))
            .toList(growable: false),
        translations: (json['translations']! as List<Object?>)
            .map((value) => TranscriptTranslation.fromJson(
                  Map<String, Object?>.from(value! as Map),
                ))
            .toList(growable: false),
      );

  final int schemaVersion;
  final int revision;
  final String sessionId;
  final List<TranscriptSegment> segments;
  final List<TranscriptTranslation> translations;

  List<TranscriptSegment> get orderedSegments => List<TranscriptSegment>.of(
        segments,
      )..sort((left, right) {
          final byStart = left.startMs.compareTo(right.startMs);
          if (byStart != 0) return byStart;
          final byEnd = left.endMs.compareTo(right.endMs);
          return byEnd != 0 ? byEnd : left.id.compareTo(right.id);
        });

  /// True when a segment with the same ID and text still exists in the
  /// timeline. Used by schedulers to drop jobs whose input was re-assembled.
  bool hasSegment(TranscriptSegment candidate) => segments.any(
        (segment) =>
            segment.id == candidate.id && segment.text == candidate.text,
      );

  TranscriptDocument upsertSegment(TranscriptSegment segment) {    final next = <TranscriptSegment>[...segments];
    final index = next.indexWhere((value) => value.id == segment.id);
    if (index == -1) {
      next.add(segment);
    } else {
      next[index] = segment;
    }
    return _copyWith(segments: next);
  }

  /// Replaces the assembled timeline while retaining translations whose stable
  /// segment IDs are still present. Raw Whisper window events never enter this
  /// document directly.
  TranscriptDocument replaceSegments(Iterable<TranscriptSegment> values) {
    final nextSegments = List<TranscriptSegment>.unmodifiable(values);
    final sourceTextById = {
      for (final segment in nextSegments) segment.id: segment.text,
    };
    final nextTranslations = translations.where((translation) {
      final sourceText = sourceTextById[translation.segmentId];
      return sourceText != null &&
          (translation.sourceText == null ||
              translation.sourceText == sourceText);
    }).toList(growable: false);
    return _copyWith(
      segments: nextSegments,
      translations: nextTranslations,
    );
  }

  TranscriptDocument upsertTranslation(TranscriptTranslation translation) {
    TranscriptSegment? segment;
    for (final value in segments) {
      if (value.id == translation.segmentId) {
        segment = value;
        break;
      }
    }
    if (segment == null ||
        (translation.sourceText != null &&
            translation.sourceText != segment.text)) {
      return this;
    }
    final next = <TranscriptTranslation>[...translations];
    final index = next.indexWhere(
      (value) =>
          value.segmentId == translation.segmentId &&
          value.targetLanguage == translation.targetLanguage,
    );
    if (index == -1) {
      next.add(translation);
    } else {
      next[index] = translation;
    }
    return _copyWith(translations: next);
  }

  TranscriptDocument removeTranslationsForTargetLanguage(
      String targetLanguage) {
    final next = translations
        .where((translation) => translation.targetLanguage != targetLanguage)
        .toList(growable: false);
    return next.length == translations.length
        ? this
        : _copyWith(translations: next);
  }

  TranscriptDocument replaceTranslations(
          Iterable<TranscriptTranslation> values) =>
      _copyWith(translations: List<TranscriptTranslation>.unmodifiable(values));

  List<TranscriptSegment> at(Duration position) {
    final ms = position.inMilliseconds;
    return orderedSegments
        .where((segment) => segment.startMs <= ms && ms < segment.endMs)
        .toList(growable: false);
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'revision': revision,
        'sessionId': sessionId,
        'segments': orderedSegments.map((segment) => segment.toJson()).toList(),
        'translations':
            translations.map((translation) => translation.toJson()).toList(),
      };

  TranscriptDocument _copyWith({
    List<TranscriptSegment>? segments,
    List<TranscriptTranslation>? translations,
  }) =>
      TranscriptDocument(
        schemaVersion: schemaVersion,
        revision: revision + 1,
        sessionId: sessionId,
        segments: segments ?? this.segments,
        translations: translations ?? this.translations,
      );
}
