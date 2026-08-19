import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/speech/speech_models.dart';
import '../../domain/subtitles/transcript_assembler.dart';
import '../../domain/subtitles/transcript_document.dart';
import '../app_build_info.dart';
import '../subtitles/transcript_session_store.dart';

enum RecognitionResultKind { recognition, translation }

/// Session-scoped results for the diagnostics workspace.
///
/// These results are intentionally independent from the player's current
/// position. A seek changes what the overlay selects, not what recognition has
/// already produced in the background.
class RecognitionResultStore extends ChangeNotifier {
  RecognitionResultStore({TranscriptSessionStore? transcriptStore})
      : _transcriptStore = transcriptStore ?? TranscriptSessionStore() {
    _documentSubscription = _transcriptStore.documents.listen((_) {
      notifyListeners();
    });
  }

  final TranscriptSessionStore _transcriptStore;
  final TranscriptAssembler _assembler = TranscriptAssembler();
  late final StreamSubscription<TranscriptDocument?> _documentSubscription;

  String? get sessionId => _transcriptStore.sessionId;
  TranscriptDocument? get document => _transcriptStore.document;

  List<RecognitionEvent> get recognitions => List.unmodifiable(
        _transcriptStore.document?.orderedSegments
                .map((segment) => _eventFromSegment(
                      segment,
                      _transcriptStore.document!.sessionId,
                    ))
                .toList(growable: false) ??
            const <RecognitionEvent>[],
      );

  Map<String, String> get translations => UnmodifiableMapView<String, String>(
        {
          for (final translation
              in _transcriptStore.document?.translations ?? const [])
            translation.segmentId: translation.text,
        },
      );

  List<RecognitionTranslationResult> get translationResults =>
      (_transcriptStore.document?.translations
              .map((translation) {
                final segment = _transcriptStore.document!.segments
                    .where((segment) => segment.id == translation.segmentId)
                    .firstOrNull;
                return segment == null
                    ? null
                    : RecognitionTranslationResult(
                        _eventFromSegment(
                          segment,
                          _transcriptStore.document!.sessionId,
                        ),
                        translation,
                      );
              })
              .whereType<RecognitionTranslationResult>()
              .toList() ??
          <RecognitionTranslationResult>[]
        ..sort((left, right) => _compareEvents(left.event, right.event)));

  void reset({required String sessionId}) {
    if (this.sessionId == sessionId) return;
    _assembler.reset(sessionId: sessionId);
    unawaited(_transcriptStore.beginSession(sessionId));
  }

  void clear() {
    _assembler.reset(sessionId: 'cleared');
    unawaited(_transcriptStore.endSession());
  }

  void addRecognition(RecognitionEvent event) {
    if (event.kind == RecognitionKind.partial || event.text.trim().isEmpty) {
      return;
    }
    if (sessionId != event.sessionId) reset(sessionId: event.sessionId);
    _transcriptStore.recordRawRecognition(event);
    _transcriptStore.replaceSegments(_assembler.add(event));
  }

  bool upsertTranslation(TranscriptTranslation translation) =>
      _transcriptStore.upsertTranslation(translation);

  bool clearTranslationsForTargetLanguage(String targetLanguage) {
    final document = _transcriptStore.document;
    if (document == null) return false;
    final next = document.removeTranslationsForTargetLanguage(targetLanguage);
    if (identical(document, next)) return false;
    return _transcriptStore.replaceTranslations(next.translations);
  }

  void addTranslation(String segmentId, String text) {
    if (text.trim().isEmpty) return;
    final segment =
        document?.segments.where((value) => value.id == segmentId).firstOrNull;
    if (segment == null) return;
    upsertTranslation(TranscriptTranslation(
      segmentId: segmentId,
      targetLanguage: 'zh-CN',
      text: text,
      status: TranscriptTranslationStatus.translated,
      sourceText: segment.text,
      sourceLanguage: segment.language,
      provider: 'manual',
    ));
  }

  @override
  void dispose() {
    unawaited(_documentSubscription.cancel());
    unawaited(_transcriptStore.dispose());
    super.dispose();
  }

  static RecognitionEvent _eventFromSegment(
    TranscriptSegment segment,
    String sessionId,
  ) =>
      RecognitionEvent(
        sessionId: sessionId,
        segmentId: segment.id,
        start: segment.start,
        end: segment.end,
        text: segment.text,
        language: segment.language,
        kind: RecognitionKind.finalResult,
        source: RecognitionSource.whisperCpp,
        confidence: segment.confidence,
        sourceWindowId:
            segment.sourceWindows.isEmpty ? null : segment.sourceWindows.first,
      );

  String formatForExport(RecognitionResultKind kind) {
    final isTranslation = kind == RecognitionResultKind.translation;
    final buffer = StringBuffer()
      ..writeln(isTranslation ? '# AI 视频播放器翻译结果' : '# AI 视频播放器识别结果')
      ..writeln('应用版本：${AppBuildInfo.version}')
      ..writeln('构建时间：${AppBuildInfo.buildTime}')
      ..writeln('构建编号：${AppBuildInfo.buildId}')
      ..writeln('导出时间：${_formatTime(DateTime.now())}')
      ..writeln('会话 ID：${sessionId ?? '无'}')
      ..writeln(
          '结果条数：${isTranslation ? _translationEntries.length : recognitions.length}')
      ..writeln();
    if (isTranslation) {
      for (final entry in _translationEntries) {
        if (entry.translation.status !=
            TranscriptTranslationStatus.translated) {
          continue;
        }
        buffer.writeln(
          '[${_formatDuration(entry.event.start)} - ${_formatDuration(entry.event.end)}] '
          '${entry.translation.text}',
        );
      }
    } else {
      for (final event in recognitions) {
        buffer.writeln(
          '[${_formatDuration(event.start)} - ${_formatDuration(event.end)}] '
          '${event.text}',
        );
      }
    }
    return buffer.toString();
  }

  Future<void> copyToClipboard(RecognitionResultKind kind) async {
    await Clipboard.setData(ClipboardData(text: formatForExport(kind)));
  }

  Future<String?> saveAsTextFile(RecognitionResultKind kind) async {
    final label = kind == RecognitionResultKind.translation
        ? 'translation'
        : 'recognition';
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: '文本文件', extensions: ['txt']),
      ],
      suggestedName: 'ai-video-player-$label-${_timestamp()}.txt',
      confirmButtonText: '保存',
    );
    if (location == null) return null;
    final path = location.path.toLowerCase().endsWith('.txt')
        ? location.path
        : '${location.path}.txt';
    await File(path).writeAsString(formatForExport(kind), encoding: utf8);
    return path;
  }

  Future<ShareResult> export(
    RecognitionResultKind kind, {
    Rect? sharePositionOrigin,
  }) async {
    final label = kind == RecognitionResultKind.translation ? '翻译结果' : '识别结果';
    final fileName = 'ai-video-player-${kind.name}-${_timestamp()}.txt';
    final content = formatForExport(kind);
    final file = XFile.fromData(
      Uint8List.fromList(utf8.encode(content)),
      name: fileName,
      mimeType: 'text/plain',
    );
    return Share.shareXFiles(
      [file],
      subject: 'AI 视频播放器$label',
      sharePositionOrigin: sharePositionOrigin,
      fileNameOverrides: [fileName],
    );
  }

  List<RecognitionTranslationResult> get _translationEntries =>
      translationResults;

  static int _compareEvents(RecognitionEvent left, RecognitionEvent right) {
    final byStart = left.start.compareTo(right.start);
    if (byStart != 0) return byStart;
    final byEnd = left.end.compareTo(right.end);
    if (byEnd != 0) return byEnd;
    return left.segmentId.compareTo(right.segmentId);
  }

  static String _formatDuration(Duration value) =>
      '${value.inMinutes.toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}.${(value.inMilliseconds % 1000).toString().padLeft(3, '0')}';

  static String _formatTime(DateTime value) =>
      value.toLocal().toIso8601String().replaceFirst('T', ' ').split('.').first;

  static String _timestamp() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

class RecognitionTranslationResult {
  const RecognitionTranslationResult(this.event, this.translation);

  final RecognitionEvent event;
  final TranscriptTranslation translation;
}
