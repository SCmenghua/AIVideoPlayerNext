import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../domain/audio/recognition_media_source.dart';
import '../audio/recognition_media_cache_worker.dart';

/// One shared loopback media session for the currently playing network media.
///
/// Both consumers — libmpv playback and the recognition audio decoder — are
/// pointed at the same `http://127.0.0.1:<port>` URL, so a possibly throttled
/// origin is asked exactly once for every byte (the cache worker's
/// single-flight filler guarantees at most one upstream GET). The session is
/// keyed by the original remote URI; opening different media replaces it.
class SharedNetworkMediaBroker {
  SharedNetworkMediaBroker({
    DiagnosticLogService? logs,
    RecognitionMediaCacheWorker Function({
      required RecognitionMediaSource source,
      required String sessionId,
    })? workerFactory,
  })  : _logs = logs,
        _workerFactory =
            workerFactory ?? _defaultWorkerFactory;

  static RecognitionMediaCacheWorker _defaultWorkerFactory({
    required RecognitionMediaSource source,
    required String sessionId,
  }) =>
      RecognitionMediaCacheWorker(source: source, sessionId: sessionId);

  final DiagnosticLogService? _logs;
  final RecognitionMediaCacheWorker Function({
    required RecognitionMediaSource source,
    required String sessionId,
  }) _workerFactory;

  RecognitionMediaCacheWorker? _worker;
  RecognitionMediaSource? _source;
  int _sessionCounter = 0;
  bool _disposed = false;

  /// Session operations run strictly one at a time: the player's
  /// [resolvePlaybackUri] and the recognition controller's borrow arrive in
  /// the same instant during a handoff, and without serialization both would
  /// observe "no session yet" and each start its own proxy.
  Future<void> _sessionChain = Future<void>.value();

  /// Network sources only. Returns the loopback playback URI after ensuring
  /// (or reusing) the matching session; null when playback should fall back
  /// to the original URL directly.
  Future<Uri?> resolvePlaybackUri(RecognitionMediaSource source) async {
    final worker = await _ensureSession(source);
    return worker?.snapshot.proxyUri;
  }

  /// Controller hook: returns the live worker when it already backs this
  /// exact source, so the recognition decoder joins a download already in
  /// flight instead of starting a competing one. Never transfers ownership —
  /// borrowers must not dispose the returned worker.
  Future<RecognitionMediaCacheWorker?> borrowFor(
    RecognitionMediaSource source,
  ) =>
      _ensureSession(source);

  Future<RecognitionMediaCacheWorker?> _ensureSession(
    RecognitionMediaSource source,
  ) {
    final result = _sessionChain.then((_) => _ensureSessionInner(source));
    _sessionChain = result.then<void>(
      (_) {},
      onError: (Object _) {},
    );
    return result;
  }

  Future<RecognitionMediaCacheWorker?> _ensureSessionInner(
    RecognitionMediaSource source,
  ) async {
    if (_disposed || !source.isNetwork) return null;
    final existing = _worker;
    if (existing != null && _source?.uri == source.uri) {
      final proxyUri = existing.snapshot.proxyUri;
      if (proxyUri != null &&
          existing.snapshot.state != RecognitionMediaCacheState.failed) {
        return existing;
      }
    }
    await reset('shared_media_replaced');
    final worker = _workerFactory(
      source: source,
      sessionId: 'shared-media-${DateTime.now().microsecondsSinceEpoch}'
          '-${++_sessionCounter}',
    );
    // AVAsset wants a container extension in the loopback path; harmless for
    // mpv and Media Foundation.
    worker.proxyPathCarriesExtension = true;
    final snapshot = await worker.startProxy();
    if (snapshot.state == RecognitionMediaCacheState.failed ||
        snapshot.proxyUri == null) {
      _logs?.warning('媒体源代理', '共享缓存源启动失败，回退直连播放', {
        '原始地址': source.uri,
        '说明': snapshot.message,
      });
      await worker.dispose();
      return null;
    }
    _worker = worker;
    _source = source;
    _logs?.info('媒体源代理', '共享缓存源已启动', {
      '原始地址': source.uri,
      '代理地址': snapshot.proxyUri,
      '缓存上限字节': worker.policy.maxBytes,
    });
    return worker;
  }

  Future<void> reset(String reason) async {
    final worker = _worker;
    _worker = null;
    _source = null;
    if (worker != null) {
      await worker.dispose();
      _logs?.debug('媒体源代理', '共享缓存源已释放', {'原因': reason});
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await reset('broker_disposed');
  }
}
