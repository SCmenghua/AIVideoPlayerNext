import 'dart:async';

import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../domain/audio/recognition_media_source.dart';
import '../../domain/player/player_service.dart';
import '../audio/recognition_media_cache_worker.dart';
import '../player/shared_network_media_broker.dart';

class ResolvedRecognitionMedia {
  const ResolvedRecognitionMedia({required this.uri, required this.viaProxy});

  final Uri uri;

  /// True when the decoder reads through a loopback proxy; if the platform
  /// decoder cannot open that, [RecognitionMediaResolver.resolveFullCache] is
  /// the fallback.
  final bool viaProxy;
}

typedef RecognitionMediaCacheWorkerFactory = RecognitionMediaCacheWorker Function({
  required RecognitionMediaSource source,
  required String sessionId,
});

/// Turns a player media source into something the recognition decoder can
/// open: local files as-is, network media through the shared loopback cache
/// (or a private one), and as a last resort a fully downloaded local copy.
class RecognitionMediaResolver {
  RecognitionMediaResolver({
    SharedNetworkMediaBroker? broker,
    DiagnosticLogService? logs,
    RecognitionMediaCacheWorkerFactory? workerFactory,
  })  : _broker = broker,
        _logs = logs,
        _workerFactory = workerFactory ?? _defaultFactory;

  static RecognitionMediaCacheWorker _defaultFactory({
    required RecognitionMediaSource source,
    required String sessionId,
  }) =>
      RecognitionMediaCacheWorker(source: source, sessionId: sessionId);

  static const _requestInfoBudget = 12;

  final SharedNetworkMediaBroker? _broker;
  final DiagnosticLogService? _logs;
  final RecognitionMediaCacheWorkerFactory _workerFactory;

  RecognitionMediaCacheWorker? _worker;
  bool _ownsWorker = false;
  StreamSubscription<RecognitionMediaCacheSnapshot>? _snapshotSubscription;
  StreamSubscription<RecognitionMediaCacheRequestEvent>? _requestSubscription;
  DateTime? _lastSnapshotLogAt;
  int _infoBudget = _requestInfoBudget;
  int _sessionCounter = 0;

  String? get preparationState => _worker?.snapshot.state.name;
  String? get preparationMessage => _worker?.snapshot.message;

  Future<ResolvedRecognitionMedia> resolve(MediaSource source) async {
    final recognitionSource = RecognitionMediaSource.fromPlayerSource(source);
    if (!recognitionSource.isNetwork) {
      await release();
      return ResolvedRecognitionMedia(uri: source.uri, viaProxy: false);
    }
    final sessionId = 'recognition-${DateTime.now().microsecondsSinceEpoch}-${++_sessionCounter}';

    final broker = _broker;
    if (broker != null) {
      final borrowed = await broker.borrowFor(recognitionSource);
      final proxyUri = borrowed?.snapshot.proxyUri;
      if (borrowed != null &&
          proxyUri != null &&
          borrowed.snapshot.state != RecognitionMediaCacheState.failed) {
        await release();
        _attach(borrowed, owns: false);
        _logs?.info('识别媒体缓存', '识别已接入共享缓存源', {
          '会话 ID': sessionId,
          '原始地址': source.uri,
          '代理地址': proxyUri,
        });
        return ResolvedRecognitionMedia(uri: proxyUri, viaProxy: true);
      }
    }

    await release();
    final worker = _workerFactory(source: recognitionSource, sessionId: sessionId)
      ..proxyPathCarriesExtension = true;
    _attach(worker, owns: true);
    final snapshot = await worker.startProxy();
    if (!identical(worker, _worker)) {
      return ResolvedRecognitionMedia(uri: source.uri, viaProxy: false);
    }
    final proxyUri = snapshot.proxyUri;
    if (snapshot.state == RecognitionMediaCacheState.failed || proxyUri == null) {
      _logs?.warning('识别媒体缓存', '流式识别代理启动失败，回退完整缓存', {
        '会话 ID': sessionId,
        '原始地址': source.uri,
        '说明': snapshot.message,
      });
      final uri = await resolveFullCache(source);
      return ResolvedRecognitionMedia(uri: uri, viaProxy: false);
    }
    _logs?.info('识别媒体缓存', '流式识别代理已启动', {
      '会话 ID': sessionId,
      '原始地址': source.uri,
      '代理地址': proxyUri,
      '缓存上限字节': worker.policy.maxBytes,
    });
    return ResolvedRecognitionMedia(uri: proxyUri, viaProxy: true);
  }

  /// Downloads the whole media through a private cache worker and returns the
  /// completed local file.
  Future<Uri> resolveFullCache(MediaSource source) async {
    await release();
    final sessionId = 'recognition-full-${DateTime.now().microsecondsSinceEpoch}-${++_sessionCounter}';
    final worker = _workerFactory(
      source: RecognitionMediaSource.fromPlayerSource(source),
      sessionId: sessionId,
    );
    _attach(worker, owns: true);
    _logs?.info('识别媒体缓存', '网络媒体开始完整缓存', {
      '会话 ID': sessionId,
      '原始地址': source.uri,
      '缓存上限字节': worker.policy.maxBytes,
    });
    final snapshot = await worker.prepare();
    if (!identical(worker, _worker)) throw StateError('识别媒体缓存已被替换。');
    if (snapshot.state != RecognitionMediaCacheState.complete || snapshot.path == null) {
      throw StateError(snapshot.message ?? '识别媒体缓存未完成。');
    }
    final localUri = Uri.file(snapshot.path!);
    _logs?.info('识别媒体缓存', '识别媒体缓存完成', {
      '会话 ID': sessionId,
      '本地地址': localUri,
      '媒体总字节': snapshot.contentLength,
      '顺序下载回退': snapshot.usedSequentialDownload,
    });
    return localUri;
  }

  Future<void> release() async {
    final requestSubscription = _requestSubscription;
    _requestSubscription = null;
    await requestSubscription?.cancel();
    final snapshotSubscription = _snapshotSubscription;
    _snapshotSubscription = null;
    await snapshotSubscription?.cancel();
    final worker = _worker;
    _worker = null;
    _lastSnapshotLogAt = null;
    // A borrowed shared-session worker belongs to the broker.
    if (_ownsWorker) await worker?.dispose();
    _ownsWorker = false;
  }

  Future<void> dispose() => release();

  void _attach(RecognitionMediaCacheWorker worker, {required bool owns}) {
    _worker = worker;
    _ownsWorker = owns;
    _lastSnapshotLogAt = null;
    _infoBudget = _requestInfoBudget;
    _snapshotSubscription = worker.snapshots.listen(_onSnapshot);
    _requestSubscription = worker.requestEvents.listen(_onRequestEvent);
  }

  void _onSnapshot(RecognitionMediaCacheSnapshot snapshot) {
    final now = DateTime.now();
    final shouldLog = snapshot.state != RecognitionMediaCacheState.downloading ||
        _lastSnapshotLogAt == null ||
        now.difference(_lastSnapshotLogAt!) >= const Duration(seconds: 1);
    if (!shouldLog) return;
    _lastSnapshotLogAt = now;
    _logs?.debug('识别媒体缓存', '识别缓存状态', {
      '会话 ID': snapshot.sessionId,
      '状态': snapshot.state.name,
      '模式': snapshot.mode.name,
      '连续可用字节': snapshot.cursor.downloadedThrough,
      '已缓存字节': snapshot.cursor.downloadedBytes,
      '缓存段数': snapshot.cursor.segments.length,
      '媒体总字节': snapshot.contentLength,
      '顺序下载回退': snapshot.usedSequentialDownload,
      '说明': snapshot.message,
    });
  }

  void _onRequestEvent(RecognitionMediaCacheRequestEvent event) {
    final details = <String, Object?>{
      '请求 ID': event.requestId,
      'Range': event.range,
      '实际上游 Range': event.upstreamRange,
      '请求角色': event.requestRole,
      '优先序号': event.priorityEpoch,
      '播放器目标位置': event.playbackPosition,
      '传输字节': event.bytesTransferred,
      '耗时': event.elapsed,
      '首字节耗时': event.timeToFirstByte,
      '平均字节每秒': event.averageBytesPerSecond,
      '响应状态': event.responseStatusCode,
      '响应 Content-Range': event.responseContentRange,
      '说明': event.message,
    };
    switch (event.kind) {
      case RecognitionMediaCacheRequestEventKind.priorityIntent:
        _logs?.debug('识别媒体缓存', '网络目标区域优先意图已登记', details);
      case RecognitionMediaCacheRequestEventKind.cacheHit:
        _logBudgeted('代理 Range 命中识别缓存', details);
      case RecognitionMediaCacheRequestEventKind.upstreamStarted:
        _logBudgeted('上游 Range 请求已开始', details);
      case RecognitionMediaCacheRequestEventKind.upstreamResponse:
        _logBudgeted('上游实际 Range 已响应', details);
      case RecognitionMediaCacheRequestEventKind.upstreamFirstByte:
        _logBudgeted('上游 Range 首字节已到达', details);
      case RecognitionMediaCacheRequestEventKind.upstreamCompleted:
        _logBudgeted('上游 Range 请求已完成', details);
      case RecognitionMediaCacheRequestEventKind.upstreamCancelled:
        _logs?.debug('识别媒体缓存', '旧上游 Range 已为新位置取消', details);
      case RecognitionMediaCacheRequestEventKind.upstreamFailed:
        _logs?.error('识别媒体缓存', '上游 Range 请求失败', details);
    }
  }

  // Proxy traffic is logged at info level until the per-session budget is
  // spent, then at debug so steady streaming does not flood the default log.
  void _logBudgeted(String action, Map<String, Object?> details) {
    if (_infoBudget > 0) {
      _infoBudget--;
      _logs?.info('识别媒体缓存', action, details);
    } else {
      _logs?.debug('识别媒体缓存', action, details);
    }
  }
}
