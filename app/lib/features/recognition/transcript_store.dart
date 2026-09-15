import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:recognition/recognition.dart' as rec;
import 'package:share_plus/share_plus.dart';

import '../../core/app_build_info.dart';
import '../../domain/subtitles/transcript_document.dart';

enum TranscriptExportKind { recognition, translation }

/// The current media's subtitle document: recognised segments mirrored from
/// the recognition session plus the translations attached to them.
class TranscriptStore extends ChangeNotifier {
  TranscriptDocument? _document;

  TranscriptDocument? get document => _document;
  String? get sessionId => _document?.sessionId;
  List<TranscriptTranslation> get translations =>
      _document?.translations ?? const <TranscriptTranslation>[];

  void beginSession(String sessionId) {
    if (_document?.sessionId == sessionId) return;
    _document = TranscriptDocument.empty(sessionId: sessionId);
    notifyListeners();
  }

  void clear() {
    if (_document == null) return;
    _document = null;
    notifyListeners();
  }

  /// Mirrors the session transcript; translations survive when their segment
  /// keeps the same id and text.
  void applyTranscript(rec.Transcript transcript) {
    final document = _document;
    if (document == null) return;
    _document = document.replaceSegments(transcript.segments.map(
      (segment) => TranscriptSegment(
        id: segment.id,
        startMs: segment.startMs,
        endMs: segment.endMs,
        text: segment.text,
        language: segment.language,
        status: TranscriptSegmentStatus.timelineFinal,
        sourceWindows: [segment.windowId],
      ),
    ));
    notifyListeners();
  }

  bool upsertTranslation(TranscriptTranslation translation) {
    final document = _document;
    if (document == null) return false;
    final next = document.upsertTranslation(translation);
    if (identical(next, document)) return false;
    _document = next;
    notifyListeners();
    return true;
  }

  bool clearTranslationsForTargetLanguage(String targetLanguage) {
    final document = _document;
    if (document == null) return false;
    final next = document.removeTranslationsForTargetLanguage(targetLanguage);
    if (identical(next, document)) return false;
    _document = next;
    notifyListeners();
    return true;
  }

  TranscriptTranslation? translationFor(String segmentId, String targetLanguage) {
    final document = _document;
    if (document == null) return null;
    for (final translation in document.translations) {
      if (translation.segmentId == segmentId && translation.targetLanguage == targetLanguage) {
        return translation;
      }
    }
    return null;
  }

  String formatForExport(TranscriptExportKind kind, {String targetLanguage = 'zh-CN'}) {
    final document = _document;
    final isTranslation = kind == TranscriptExportKind.translation;
    final segments = document?.orderedSegments ?? const <TranscriptSegment>[];
    final buffer = StringBuffer()
      ..writeln(isTranslation ? '# AI 视频播放器翻译结果' : '# AI 视频播放器识别结果')
      ..writeln('应用版本：${AppBuildInfo.version}')
      ..writeln('构建时间：${AppBuildInfo.buildTime}')
      ..writeln('构建编号：${AppBuildInfo.buildId}')
      ..writeln('导出时间：${_formatTime(DateTime.now())}')
      ..writeln('会话 ID：${sessionId ?? '无'}')
      ..writeln('结果条数：${segments.length}')
      ..writeln();
    for (final segment in segments) {
      final range = '[${_formatDuration(segment.start)} - ${_formatDuration(segment.end)}]';
      if (isTranslation) {
        final translation = translationFor(segment.id, targetLanguage);
        if (translation == null ||
            translation.status != TranscriptTranslationStatus.translated) {
          continue;
        }
        buffer.writeln('$range ${translation.text}');
      } else {
        buffer.writeln('$range ${segment.text}');
      }
    }
    return buffer.toString();
  }

  Future<void> copyToClipboard(TranscriptExportKind kind) =>
      Clipboard.setData(ClipboardData(text: formatForExport(kind)));

  Future<String?> saveAsTextFile(TranscriptExportKind kind) async {
    final label = kind == TranscriptExportKind.translation ? 'translation' : 'recognition';
    if (Platform.isIOS) {
      final directory = await getApplicationDocumentsDirectory();
      final path = '${directory.path}${Platform.pathSeparator}'
          'ai-video-player-$label-${_timestamp()}.txt';
      await File(path).writeAsString(formatForExport(kind), encoding: utf8);
      return path;
    }
    final location = await getSaveLocation(
      acceptedTypeGroups: const [XTypeGroup(label: '文本文件', extensions: ['txt'])],
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

  Future<ShareResult> share(TranscriptExportKind kind, {Rect? sharePositionOrigin}) {
    final label = kind == TranscriptExportKind.translation ? '翻译结果' : '识别结果';
    final fileName = 'ai-video-player-${kind.name}-${_timestamp()}.txt';
    final file = XFile.fromData(
      Uint8List.fromList(utf8.encode(formatForExport(kind))),
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

  static String _formatDuration(Duration value) =>
      '${value.inMinutes.toString().padLeft(2, '0')}:'
      '${(value.inSeconds % 60).toString().padLeft(2, '0')}.'
      '${(value.inMilliseconds % 1000).toString().padLeft(3, '0')}';

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
