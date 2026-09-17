import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:recognition/recognition.dart';

import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../domain/player/player_service.dart';
import 'recognition_media_resolver.dart';
import 'recognition_settings.dart';
import 'transcript_store.dart';
import 'whisper_model_catalog.dart';
import 'whisper_model_store.dart';

enum RecognitionAvailability { checking, ready, modelMissing, unavailable }

class RecognitionStatus {
  const RecognitionStatus({
    required this.availability,
    this.message,
    this.missingModel,
    this.download,
  });

  final RecognitionAvailability availability;
  final String? message;
  final WhisperModelSpec? missingModel;
  final ModelDownloadProgress? download;
}

/// Application-level owner of the recognition pipeline: builds engine, VAD
/// and session from settings, resolves media through the network cache, and
/// mirrors the transcript into the [TranscriptStore] for translation and UI.
class RecognitionService extends ChangeNotifier {
  RecognitionService({
    required this.logs,
    required this.store,
    required Future<WhisperModelStore> modelStore,
    required this.resolver,
    required this.sourceFactory,
    required this.libraryPath,
    RecognitionSettings settings = const RecognitionSettings(),
    int? threads,
  })  : _modelStoreFuture = modelStore,
        _settings = settings,
        _threads = threads ?? (Platform.isIOS ? 4 : 8);

  final DiagnosticLogService logs;
  final TranscriptStore store;
  final Future<WhisperModelStore> _modelStoreFuture;
  final RecognitionMediaResolver resolver;
  final PcmSource Function() sourceFactory;

  /// Path of speech_core, or null when the native runtime is missing.
  final String? libraryPath;
  final int _threads;

  RecognitionSettings _settings;
  RecognitionStatus _status = const RecognitionStatus(
    availability: RecognitionAvailability.checking,
  );
  RecognitionDiagnostics _diagnostics = const RecognitionDiagnostics();
  final StreamController<RecognitionDiagnostics> _diagnosticsController =
      StreamController<RecognitionDiagnostics>.broadcast();
  WhisperEngine? _engine;
  String? _enginePath;
  VadDetector? _vad;
  RecognitionSession? _session;
  PcmSource? _source;
  StreamSubscription<Transcript>? _transcriptSubscription;
  StreamSubscription<RecognitionDiagnostics>? _diagnosticsSubscription;
  MediaSource? _media;
  Duration _playbackPosition = Duration.zero;
  int _openGeneration = 0;
  bool _disposed = false;

  RecognitionSettings get settings => _settings;
  RecognitionStatus get status => _status;
  RecognitionDiagnostics get diagnostics => _diagnostics;
  Stream<RecognitionDiagnostics> get diagnosticsStream => _diagnosticsController.stream;
  Transcript get transcript => _session?.transcript ?? Transcript.empty;
  MediaSource? get media => _media;

  /// Loads the runtime for the current settings so the first media opens
  /// without a model-load delay. Safe to call repeatedly.
  Future<void> warmUp() async {
    if (_disposed) return;
    await _ensureRuntime();
  }

  Future<void> applySettings(RecognitionSettings next) async {
    if (_disposed || next == _settings) return;
    final restart = _media != null;
    final position = _playbackPosition;
    _settings = next;
    notifyListeners();
    logs.info('识别', '识别设置已更新', {
      '语言': next.language,
      '模型': next.model.fileName,
      'VAD': next.vadEnabled ? '开' : '关',
      '识别上下文': next.effectiveContextEnabled ? '开' : '关',
    });
    if (restart) {
      final media = _media!;
      await open(media, start: position);
    } else {
      await _ensureRuntime();
    }
  }

  Future<WhisperModelStore> get modelStore => _modelStoreFuture;

  /// Installs a model file obtained outside the app after verifying it.
  Future<void> importModel(WhisperModelSpec spec, String path) async {
    final modelStore = await _modelStoreFuture;
    await modelStore.importFile(spec, path);
    logs.info('识别', '模型已从文件导入', {'模型': spec.fileName});
    _setStatus(const RecognitionStatus(availability: RecognitionAvailability.checking));
    await _ensureRuntime();
    final media = _media;
    if (media != null && _session == null) await open(media, start: _playbackPosition);
  }

  Future<void> installModel(WhisperModelSpec spec) async {
    final modelStore = await _modelStoreFuture;
    await for (final progress in modelStore.download(spec)) {
      _setStatus(RecognitionStatus(
        availability: progress.isFailed
            ? RecognitionAvailability.modelMissing
            : RecognitionAvailability.checking,
        missingModel: spec,
        download: progress,
        message: progress.error,
      ));
      if (progress.isFailed) {
        logs.error('识别', '模型下载失败', {'模型': spec.fileName, '错误': progress.error});
        return;
      }
    }
    logs.info('识别', '模型已安装', {'模型': spec.fileName});
    await _ensureRuntime();
    final media = _media;
    if (media != null && _session == null) await open(media, start: _playbackPosition);
  }

  Future<void> open(MediaSource source, {Duration start = Duration.zero}) async {
    if (_disposed) return;
    final generation = ++_openGeneration;
    _media = source;
    _playbackPosition = start;
    await _closeSession();
    store.beginSession('media-${DateTime.now().microsecondsSinceEpoch}');
    store.applyTranscript(Transcript.empty);
    final ready = await _ensureRuntime();
    if (generation != _openGeneration) return;
    if (!ready) return;

    final session = _createSession();
    _session = session;
    final ResolvedRecognitionMedia resolved;
    try {
      resolved = await resolver.resolve(source);
    } on Object catch (error) {
      if (generation != _openGeneration) return;
      logs.error('识别', '识别媒体准备失败', {'错误': error.toString()});
      _setStatus(RecognitionStatus(
        availability: RecognitionAvailability.ready,
        message: '识别媒体准备失败：$error',
      ));
      return;
    }
    if (generation != _openGeneration) return;
    var opened = await session.open(resolved.uri, start: start);
    if (generation != _openGeneration) return;
    if (!opened && resolved.viaProxy) {
      logs.warning('识别', '流式识别解码打开失败，回退完整缓存', {
        '错误': session.diagnostics.message,
      });
      try {
        final fallback = await resolver.resolveFullCache(source);
        if (generation != _openGeneration) return;
        opened = await session.open(fallback, start: start);
      } on Object catch (error) {
        if (generation != _openGeneration) return;
        logs.error('识别', '识别媒体完整缓存失败', {'错误': error.toString()});
      }
    }
    if (!opened) {
      logs.error('识别', '识别解码器无法打开媒体', {'错误': session.diagnostics.message});
    }
  }

  Future<void> seek(Duration position) async {
    _playbackPosition = position;
    await _session?.seek(position);
  }

  void updatePlaybackPosition(Duration position) {
    _playbackPosition = position;
    _session?.updatePlaybackPosition(position);
  }

  Future<void> stop() async {
    ++_openGeneration;
    _media = null;
    await _closeSession();
    await resolver.release();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _engine?.dispose();
    await _vad?.dispose();
    await _source?.dispose();
    await _diagnosticsController.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------

  Future<bool> _ensureRuntime() async {
    final library = libraryPath;
    if (library == null) {
      _setStatus(const RecognitionStatus(
        availability: RecognitionAvailability.unavailable,
        message: '未找到 speech_core 运行时。',
      ));
      return false;
    }
    final spec = _settings.model;
    final modelStore = await _modelStoreFuture;
    final modelFile = await modelStore.installedFile(spec);
    if (modelFile == null) {
      _setStatus(RecognitionStatus(
        availability: RecognitionAvailability.modelMissing,
        missingModel: spec,
        message: '识别模型 ${spec.label} 尚未安装。',
      ));
      return false;
    }
    if (_engine != null && _enginePath != modelFile.path) {
      final old = _engine!;
      _engine = null;
      await old.dispose();
    }
    if (_engine == null) {
      _setStatus(const RecognitionStatus(availability: RecognitionAvailability.checking));
      final engine = WhisperEngine(
        libraryPath: library,
        modelPath: modelFile.path,
        backend: SpeechBackend.auto,
      );
      logs.info('识别', 'Whisper 开始加载模型', {'模型': spec.fileName});
      try {
        await engine.load();
      } on Object catch (error) {
        logs.error('识别', 'Whisper 模型加载失败', {'模型': spec.fileName, '错误': error.toString()});
        _setStatus(RecognitionStatus(
          availability: RecognitionAvailability.unavailable,
          message: 'Whisper 模型加载失败：$error',
        ));
        await engine.dispose();
        return false;
      }
      _engine = engine;
      _enginePath = modelFile.path;
      logs.info('识别', 'Whisper 模型加载成功', {
        '模型': spec.fileName,
        '后端': engine.backendInfo?.toString(),
      });
    }
    if (_settings.vadEnabled && _vad == null) {
      final vadFile = await modelStore.installedFile(WhisperModelCatalog.sileroVad);
      if (vadFile != null) {
        final vad = VadDetector(libraryPath: library, modelPath: vadFile.path, threads: 2);
        try {
          await vad.load();
          _vad = vad;
          logs.info('识别', 'VAD 模型已加载', {'帧样本数': vad.frameSamples});
        } on Object catch (error) {
          logs.warning('识别', 'VAD 模型加载失败，改用能量门控', {'错误': error.toString()});
          await vad.dispose();
        }
      } else {
        logs.warning('识别', 'VAD 模型未安装，改用能量门控', {
          '模型': WhisperModelCatalog.sileroVad.fileName,
        });
        unawaited(modelStore.download(WhisperModelCatalog.sileroVad).drain<void>());
      }
    }
    _setStatus(const RecognitionStatus(availability: RecognitionAvailability.ready));
    return true;
  }

  RecognitionSession _createSession() {
    _source ??= sourceFactory();
    final config = RecognitionConfig(
      modelPath: _enginePath!,
      vadModelPath: null,
      language: _settings.language,
      backend: SpeechBackend.auto,
      threads: _threads,
      contextEnabled: _settings.effectiveContextEnabled,
    );
    final session = RecognitionSession(
      source: _source!,
      engine: _engine!,
      vad: _settings.vadEnabled ? _vad : null,
      config: config,
      libraryPath: libraryPath,
      onLog: _onSessionLog,
    );
    _transcriptSubscription = session.transcripts.listen(store.applyTranscript);
    _diagnosticsSubscription = session.diagnosticsStream.listen((value) {
      _diagnostics = value;
      if (!_diagnosticsController.isClosed) _diagnosticsController.add(value);
    });
    return session;
  }

  Future<void> _closeSession() async {
    await _transcriptSubscription?.cancel();
    _transcriptSubscription = null;
    await _diagnosticsSubscription?.cancel();
    _diagnosticsSubscription = null;
    final session = _session;
    _session = null;
    if (session != null) await session.dispose();
    _diagnostics = const RecognitionDiagnostics();
    if (!_diagnosticsController.isClosed) _diagnosticsController.add(_diagnostics);
  }

  void _onSessionLog(RecognitionLogEvent event) {
    switch (event.level) {
      case RecognitionLogLevel.debug:
        logs.debug('识别', event.message, event.details);
      case RecognitionLogLevel.info:
        logs.info('识别', event.message, event.details);
      case RecognitionLogLevel.warning:
        logs.warning('识别', event.message, event.details);
      case RecognitionLogLevel.error:
        logs.error('识别', event.message, event.details);
    }
  }

  void _setStatus(RecognitionStatus value) {
    _status = value;
    if (!_disposed) notifyListeners();
  }
}

/// Stands in for a platform decoder whose native runtime is missing, so the
/// session reports a clear error instead of crashing at open.
class UnavailablePcmSource implements PcmSource {
  UnavailablePcmSource({required this.message});

  final String message;
  final StreamController<PcmSourceStatus> _statuses = StreamController.broadcast();
  final StreamController<RawPcmChunk> _chunks = StreamController.broadcast();
  PcmSourceStatus _status = const PcmSourceStatus.idle();

  @override
  Stream<RawPcmChunk> get chunks => _chunks.stream;
  @override
  Stream<PcmSourceStatus> get statuses => _statuses.stream;
  @override
  PcmSourceStatus get status => _status;

  @override
  Future<void> open(Uri uri, {Duration start = Duration.zero}) async {
    _status = PcmSourceStatus(state: PcmSourceState.error, message: message);
    _statuses.add(_status);
    throw StateError(message);
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _statuses.close();
    await _chunks.close();
  }
}
