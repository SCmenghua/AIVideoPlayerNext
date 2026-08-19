import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/speech/speech_models.dart';
import '../../domain/subtitles/transcript_document.dart';

/// Holds the current media's transcript in memory and mirrors it to a
/// session-temporary JSON snapshot. Consumers should use [document] or
/// [documents] for rendering; the file is for diagnostics and export.
class TranscriptSessionStore {
  TranscriptSessionStore({
    Directory? rootDirectory,
    this.writeDebounce = const Duration(milliseconds: 250),
    bool? retainRawEvidence,
  })  : _rootDirectory = rootDirectory ??
            Directory(
              '${Directory.systemTemp.path}${Platform.pathSeparator}'
              'ai-video-player${Platform.pathSeparator}sessions',
            ),
        retainRawEvidence = retainRawEvidence ?? !kReleaseMode;

  final Directory _rootDirectory;
  final Duration writeDebounce;
  final bool retainRawEvidence;
  final StreamController<TranscriptDocument?> _documents =
      StreamController<TranscriptDocument?>.broadcast();
  Future<void> _writes = Future<void>.value();
  Timer? _writeTimer;
  TranscriptDocument? _document;
  final Map<String, RecognitionEvent> _rawEvents = {};
  Directory? _sessionDirectory;
  int _generation = 0;
  bool _disposed = false;

  TranscriptDocument? get document => _document;
  String? get sessionId => _document?.sessionId;
  Stream<TranscriptDocument?> get documents => _documents.stream;
  File? get snapshotFile => _sessionDirectory == null
      ? null
      : File(
          '${_sessionDirectory!.path}${Platform.pathSeparator}transcript.json');
  File? get rawSnapshotFile => !retainRawEvidence || _sessionDirectory == null
      ? null
      : File(
          '${_sessionDirectory!.path}${Platform.pathSeparator}transcript.raw.json');

  Future<void> beginSession(String sessionId) async {
    _ensureUsable();
    final oldDirectory = _sessionDirectory;
    final generation = ++_generation;
    _writeTimer?.cancel();
    _writeTimer = null;
    final directory = Directory(
      '${_rootDirectory.path}${Platform.pathSeparator}$sessionId',
    );
    _sessionDirectory = directory;
    _document = TranscriptDocument.empty(sessionId: sessionId);
    _rawEvents.clear();
    _documents.add(_document);
    _scheduleSnapshot();
    await _writes;
    if (oldDirectory != null && oldDirectory.path != directory.path) {
      if (await oldDirectory.exists()) {
        await oldDirectory.delete(recursive: true);
      }
    }
    if (_disposed || generation != _generation) {
      return;
    }
  }

  bool upsertSegment(TranscriptSegment segment) {
    final document = _document;
    if (_disposed || document == null) return false;
    _replaceDocument(document.upsertSegment(segment));
    return true;
  }

  bool replaceSegments(Iterable<TranscriptSegment> segments) {
    final document = _document;
    if (_disposed || document == null) return false;
    _replaceDocument(document.replaceSegments(segments));
    return true;
  }

  bool recordRawRecognition(RecognitionEvent event) {
    if (!retainRawEvidence || _disposed || event.sessionId != sessionId) {
      return false;
    }
    _rawEvents[event.segmentId] = event;
    _scheduleSnapshot();
    return true;
  }

  bool upsertTranslation(TranscriptTranslation translation) {
    final document = _document;
    if (_disposed || document == null) return false;
    final next = document.upsertTranslation(translation);
    if (identical(next, document)) return false;
    _replaceDocument(next);
    return true;
  }

  bool replaceTranslations(Iterable<TranscriptTranslation> translations) {
    final document = _document;
    if (_disposed || document == null) return false;
    _replaceDocument(document.replaceTranslations(translations));
    return true;
  }

  Future<void> flush() async {
    if (_disposed || _document == null) return;
    _writeTimer?.cancel();
    _writeTimer = null;
    _enqueueSnapshot(_generation);
    await _writes;
  }

  /// Deletes the temporary document. The generation changes before waiting for
  /// old writes, so a late recognition or translation callback cannot recreate
  /// the previous media's directory.
  Future<void> endSession() async {
    final oldDirectory = _sessionDirectory;
    ++_generation;
    _writeTimer?.cancel();
    _writeTimer = null;
    _document = null;
    _rawEvents.clear();
    _sessionDirectory = null;
    if (!_documents.isClosed) _documents.add(null);
    await _writes;
    if (oldDirectory != null && await oldDirectory.exists()) {
      await oldDirectory.delete(recursive: true);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await endSession();
    await _documents.close();
  }

  void _replaceDocument(TranscriptDocument value) {
    _document = value;
    _documents.add(value);
    _scheduleSnapshot();
  }

  void _scheduleSnapshot() {
    _writeTimer?.cancel();
    final generation = _generation;
    _writeTimer = Timer(writeDebounce, () {
      _writeTimer = null;
      _enqueueSnapshot(generation);
    });
  }

  void _enqueueSnapshot(int generation) {
    final document = _document;
    final directory = _sessionDirectory;
    if (document == null || directory == null) return;
    _writes = _writes.then((_) => _writeSnapshot(
          generation: generation,
          directory: directory,
          document: document,
        ));
  }

  Future<void> _writeSnapshot({
    required int generation,
    required Directory directory,
    required TranscriptDocument document,
  }) async {
    if (_disposed || generation != _generation || _document != document) {
      return;
    }
    await directory.create(recursive: true);
    if (_disposed || generation != _generation || _document != document) {
      return;
    }
    final target =
        File('${directory.path}${Platform.pathSeparator}transcript.json');
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(document.toJson()),
      encoding: utf8,
      flush: true,
    );
    if (_disposed || generation != _generation || _document != document) {
      if (await temporary.exists()) await temporary.delete();
      return;
    }
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    await temporary.rename(target.path);
    await _writeRawSnapshotIfCurrent(generation, directory, document.sessionId);
  }

  Future<void> _writeRawSnapshotIfCurrent(
    int generation,
    Directory directory,
    String sessionId,
  ) async {
    if (!retainRawEvidence ||
        _disposed ||
        generation != _generation ||
        _document?.sessionId != sessionId) {
      return;
    }
    final target = File(
      '${directory.path}${Platform.pathSeparator}transcript.raw.json',
    );
    final temporary = File('${target.path}.tmp');
    final records = _rawEvents.values.toList()
      ..sort((left, right) => left.start.compareTo(right.start));
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': transcriptSchemaVersion,
        'sessionId': sessionId,
        'events': records.map(_rawEventJson).toList(growable: false),
      }),
      encoding: utf8,
      flush: true,
    );
    if (_disposed ||
        generation != _generation ||
        _document?.sessionId != sessionId) {
      if (await temporary.exists()) await temporary.delete();
      return;
    }
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  Map<String, Object?> _rawEventJson(RecognitionEvent event) => {
        'sessionId': event.sessionId,
        'rawId': event.segmentId,
        'sourceWindowId': event.sourceWindowId,
        'sourceSegmentIndex': event.sourceSegmentIndex,
        'startMs': event.start.inMilliseconds,
        'endMs': event.end.inMilliseconds,
        'text': event.text,
        'language': event.language,
        if (event.confidence != null) 'confidence': event.confidence,
        'kind': event.kind.name,
        'source': event.source.name,
      };

  void _ensureUsable() {
    if (_disposed) throw StateError('transcript session store is disposed');
  }
}
