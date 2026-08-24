import 'dart:async';
import 'dart:io';

import '../../domain/audio/recognition_media_source.dart';

enum RecognitionMediaCacheState {
  idle,
  downloading,
  complete,
  directFallback,
  failed,
  cancelled,
}

class RecognitionMediaCachePolicy {
  const RecognitionMediaCachePolicy({
    this.chunkBytes = 2 * 1024 * 1024,
    this.maxBytes = 256 * 1024 * 1024,
    this.maxSegments = 128,
    // These optimizations need per-site capability evidence. Media Foundation
    // has already been validated against a transparent streaming proxy, so it
    // remains the production default while segmented reads stay experimental.
    this.enableSegmentedProxyStreaming = false,
    this.enableContainerWarmup = false,
    this.warmupHeadBytes = 512 * 1024,
    this.warmupTailBytes = 2 * 1024 * 1024,
  });

  final int chunkBytes;
  final int maxBytes;
  final int maxSegments;
  final bool enableSegmentedProxyStreaming;
  final bool enableContainerWarmup;
  final int warmupHeadBytes;
  final int warmupTailBytes;
}

class RecognitionMediaCacheSnapshot {
  const RecognitionMediaCacheSnapshot({
    required this.sessionId,
    required this.mode,
    required this.state,
    required this.cursor,
    this.path,
    this.proxyUri,
    this.contentLength,
    this.usedSequentialDownload = false,
    this.message,
  });

  factory RecognitionMediaCacheSnapshot.idle({
    required String sessionId,
    required RecognitionMediaReadMode mode,
  }) =>
      RecognitionMediaCacheSnapshot(
        sessionId: sessionId,
        mode: mode,
        state: RecognitionMediaCacheState.idle,
        cursor: RecognitionMediaCursor(sessionId: sessionId, mode: mode),
      );

  final String sessionId;
  final RecognitionMediaReadMode mode;
  final RecognitionMediaCacheState state;
  final RecognitionMediaCursor cursor;
  final String? path;
  final Uri? proxyUri;
  final int? contentLength;
  final bool usedSequentialDownload;
  final String? message;
}

enum RecognitionMediaCacheRequestEventKind {
  priorityIntent,
  cacheHit,
  upstreamStarted,
  upstreamResponse,
  upstreamFirstByte,
  upstreamCompleted,
  upstreamCancelled,
  upstreamFailed,
}

/// Detailed per-request network diagnostics for the test build.
///
/// The worker never maps a media time to bytes: VBR containers make that
/// approximation unreliable. Instead, a seek creates an intent, then the
/// decoder's actual loopback Range request becomes the high-priority request.
class RecognitionMediaCacheRequestEvent {
  const RecognitionMediaCacheRequestEvent({
    required this.kind,
    required this.at,
    this.requestId,
    this.range,
    this.upstreamRange,
    this.priorityEpoch,
    this.playbackPosition,
    this.requestRole = 'decoder',
    this.bytesTransferred,
    this.elapsed,
    this.timeToFirstByte,
    this.averageBytesPerSecond,
    this.responseStatusCode,
    this.responseContentRange,
    this.message,
  });

  final RecognitionMediaCacheRequestEventKind kind;
  final DateTime at;
  final int? requestId;

  /// Range requested by the decoder from the loopback proxy.
  final String? range;

  /// Range actually sent to the remote server. This can differ only when an
  /// explicitly enabled experimental proxy strategy rewrites the request.
  final String? upstreamRange;
  final int? priorityEpoch;
  final Duration? playbackPosition;
  final String requestRole;
  final int? bytesTransferred;
  final Duration? elapsed;
  final Duration? timeToFirstByte;
  final double? averageBytesPerSecond;
  final int? responseStatusCode;
  final String? responseContentRange;
  final String? message;
}

/// A small HTTP seam keeps the cache worker deterministic in Dart tests while
/// the production implementation owns its own HttpClient and response body.
abstract interface class RecognitionMediaHttpTransport {
  Future<RecognitionMediaHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  });

  Future<void> close();
}

class RecognitionMediaHttpResponse {
  const RecognitionMediaHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
}

class IoRecognitionMediaHttpTransport implements RecognitionMediaHttpTransport {
  IoRecognitionMediaHttpTransport({HttpClient? client})
      : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<RecognitionMediaHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  }) async {
    final request = await _client.getUrl(uri);
    headers.forEach(request.headers.set);
    final response = await request.close();
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      responseHeaders[name.toLowerCase()] = values.join(',');
    });
    return RecognitionMediaHttpResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      body: response,
    );
  }

  @override
  Future<void> close() async => _client.close(force: true);
}

/// Owns the recognition-side network read lifecycle.
///
/// The worker deliberately returns a completed local file only after the
/// source is fully available. A growing partial file is not handed to a
/// platform decoder, because Media Foundation and AVAssetReader do not share a
/// portable contract for reading a file while another worker appends to it.
class RecognitionMediaCacheWorker {
  RecognitionMediaCacheWorker({
    required this.source,
    required this.sessionId,
    this.policy = const RecognitionMediaCachePolicy(),
    Directory? cacheDirectory,
    RecognitionMediaHttpTransport? transport,
  })  : _cacheDirectory = cacheDirectory ?? Directory.systemTemp,
        _transport = transport ?? IoRecognitionMediaHttpTransport(),
        _cursor = RecognitionMediaCursor(
          sessionId: sessionId,
          mode: source.isNetwork
              ? RecognitionMediaReadMode.progressiveSegmentCache
              : RecognitionMediaReadMode.localFile,
          maxBytes: policy.maxBytes,
          maxSegments: policy.maxSegments,
        );

  final RecognitionMediaSource source;
  final String sessionId;
  final RecognitionMediaCachePolicy policy;
  final Directory _cacheDirectory;
  final RecognitionMediaHttpTransport _transport;
  final RecognitionMediaCursor _cursor;
  final StreamController<RecognitionMediaCacheSnapshot> _snapshots =
      StreamController<RecognitionMediaCacheSnapshot>.broadcast();
  final StreamController<RecognitionMediaCacheRequestEvent> _requestEvents =
      StreamController<RecognitionMediaCacheRequestEvent>.broadcast();
  RecognitionMediaCacheState _state = RecognitionMediaCacheState.idle;
  String? _path;
  String? _tailPath;
  int? _tailCacheStart;
  int? _tailCacheEndExclusive;
  Uri? _proxyUri;
  HttpServer? _proxyServer;
  int? _contentLength;
  String? _message;
  bool _usedSequentialDownload = false;
  bool _cancelled = false;
  bool _disposed = false;
  int _priorityEpoch = 0;
  int _nextRequestId = 0;

  /// Shared keep-alive upstream client. Per-request HttpClient instances paid
  /// a full TCP+TLS handshake for every decoder range (measured TTFB 2.5-4 s
  /// on real sites); reusing one connection pool removes that cost from all
  /// but the first request of a session.
  HttpClient? _sharedUpstreamClient;
  HttpClient get _upstreamClient =>
      _sharedUpstreamClient ??= HttpClient()
        ..maxConnectionsPerHost = 4
        ..idleTimeout = const Duration(seconds: 30);
  final Map<int, _ActiveProxyRequest> _activeProxyRequests = {};
  final Map<int, _ActiveProxyRequest> _warmupRequests = {};
  Future<void> _cacheWrites = Future<void>.value();

  Stream<RecognitionMediaCacheSnapshot> get snapshots => _snapshots.stream;
  Stream<RecognitionMediaCacheRequestEvent> get requestEvents =>
      _requestEvents.stream;

  RecognitionMediaCacheSnapshot get snapshot => RecognitionMediaCacheSnapshot(
        sessionId: sessionId,
        mode: _cursor.mode,
        state: _state,
        cursor: _cursor,
        path: _path,
        proxyUri: _proxyUri,
        contentLength: _contentLength,
        usedSequentialDownload: _usedSequentialDownload,
        message: _message,
      );

  Future<RecognitionMediaCacheSnapshot> prepare() async {
    _ensureUsable();
    if (source.isLocalFile) {
      _path = source.uri.toFilePath(windows: Platform.isWindows);
      _state = RecognitionMediaCacheState.complete;
      _emit();
      return snapshot;
    }
    if (!source.isNetwork) {
      return _fail('仅支持本地文件和 HTTP(S) 识别媒体。');
    }

    _state = RecognitionMediaCacheState.downloading;
    _emit();
    try {
      await _cacheDirectory.create(recursive: true);
      final directory = Directory(
        '${_cacheDirectory.path}${Platform.pathSeparator}ai-video-recognition-$sessionId',
      );
      await directory.create(recursive: true);
      final temporary = File(
        '${directory.path}${Platform.pathSeparator}media.partial',
      );
      final output = await temporary.open(mode: FileMode.write);
      try {
        await _download(output);
      } finally {
        await output.close();
      }
      if (_cancelled) return _cancelledSnapshot();
      if (_state == RecognitionMediaCacheState.directFallback) return snapshot;
      _path = await _promoteCompletedCache(temporary, directory.path);
      _state = RecognitionMediaCacheState.complete;
      _emit();
      return snapshot;
    } on Object catch (error) {
      if (_cancelled) return _cancelledSnapshot();
      return _fail(error.toString());
    }
  }

  /// Carries a real container extension in the loopback proxy path (for
  /// example `/media.mp4`). Windows keeps the extensionless `/media` default;
  /// iOS experimental streaming opts in because AVFoundation prefers a
  /// format hint when the upstream Content-Type is generic. Set before
  /// [startProxy]; the source URL extension decides, defaulting to `mp4`.
  bool proxyPathCarriesExtension = false;

  /// Starts an HTTP loopback endpoint owned by this recognition session.
  ///
  /// Media Foundation reads the loopback URL instead of the original remote
  /// URL. Requests are forwarded with the browser authorization context,
  /// streamed immediately, and retained as bounded byte ranges for repeated
  /// decoder reads. This avoids relying on Media Foundation's opaque HTTP
  /// stack while also avoiding a full-media download before recognition.
  Future<RecognitionMediaCacheSnapshot> startProxy() async {
    _ensureUsable();
    if (source.isLocalFile) {
      _path = source.uri.toFilePath(windows: Platform.isWindows);
      _state = RecognitionMediaCacheState.complete;
      _emit();
      return snapshot;
    }
    if (!source.isNetwork) return _fail('仅支持本地文件和 HTTP(S) 识别媒体。');
    if (_proxyServer != null) return snapshot;

    try {
      await _cacheDirectory.create(recursive: true);
      final directory = Directory(
        '${_cacheDirectory.path}${Platform.pathSeparator}ai-video-recognition-$sessionId',
      );
      await directory.create(recursive: true);
      _path = '${directory.path}${Platform.pathSeparator}media.cache';
      await File(_path!).writeAsBytes(const []);
      _tailPath = '${directory.path}${Platform.pathSeparator}media.tail.cache';
      await File(_tailPath!).writeAsBytes(const []);
      _proxyServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _proxyServer!.listen((request) {
        unawaited(_serveProxyRequest(request));
      });
      final proxyPath = proxyPathCarriesExtension
          ? 'media.${containerExtensionFromUri(source.uri) ?? 'mp4'}'
          : 'media';
      _proxyUri = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _proxyServer!.port,
        path: proxyPath,
      );
      _state = RecognitionMediaCacheState.downloading;
      _emit();
      if (policy.enableContainerWarmup) unawaited(_warmContainer());
      return snapshot;
    } on Object catch (error) {
      return _fail(error.toString());
    }
  }

  /// Promotes the decoder request caused by a long player seek.
  ///
  /// This is intentionally synchronous and never performs network I/O on the
  /// player call path. It only records intent: Media Foundation can issue
  /// multiple metadata/index requests while it repositions, so cancelling an
  /// active response before the decoder has been told to seek can interrupt
  /// its own initialization.
  void prioritizePlaybackRange({
    required Duration playbackPosition,
    required Duration context,
    required Duration lead,
    required int epoch,
  }) {
    if (_disposed || _cancelled || !source.isNetwork) return;
    _priorityEpoch = epoch;
    _emitRequestEvent(
      RecognitionMediaCacheRequestEvent(
        kind: RecognitionMediaCacheRequestEventKind.priorityIntent,
        at: DateTime.now(),
        priorityEpoch: epoch,
        playbackPosition: playbackPosition,
        message: '上下文 $context，目标领先 $lead',
      ),
    );
  }

  /// Interrupts reads owned by the old decoder cursor after the decoder has
  /// accepted a seek command. At this point the next Range requests belong to
  /// the retained reader's new media position rather than to a fresh open.
  void activatePlaybackPriority({required int epoch}) {
    if (_disposed || _cancelled || !source.isNetwork) return;
    if (epoch != _priorityEpoch) return;
    for (final request in _activeProxyRequests.values.toList()) {
      if (request.priorityEpoch < epoch) {
        request.cancel('player_seek_priority_after_decoder_seek');
      }
    }
  }

  Future<void> cancel() async {
    if (_disposed || _cancelled) return;
    _cancelled = true;
    final server = _proxyServer;
    _proxyServer = null;
    _proxyUri = null;
    await server?.close(force: true);
    for (final request in _activeProxyRequests.values.toList()) {
      request.cancel('worker_cancelled');
    }
    for (final request in _warmupRequests.values.toList()) {
      request.cancel('worker_cancelled');
    }
    await _transport.close();
    // The shared pool outlives individual requests; it is torn down with the
    // session that owns it.
    _sharedUpstreamClient?.close(force: true);
    _sharedUpstreamClient = null;
    _state = RecognitionMediaCacheState.cancelled;
    _emit();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await cancel();
    _disposed = true;
    await _snapshots.close();
    await _requestEvents.close();
  }

  /// Renames the completed download from its `.partial` working name to
  /// `media.<container>`. AVFoundation resolves a local container through the
  /// file extension (UTI), so an internal name like `media.media` makes the
  /// decoder fail with "Cannot Open" even though the bytes are a valid MP4.
  Future<String> _promoteCompletedCache(
    File temporary,
    String directoryPath,
  ) async {
    final extension = await _detectContainerExtension(temporary);
    final target =
        '$directoryPath${Platform.pathSeparator}media.$extension';
    await temporary.rename(target);
    return target;
  }

  /// Content sniffing wins over the URL because handoff URLs frequently end
  /// in extensionless segments or query strings; `mp4` is the final fallback
  /// because it dominates browser media handoffs.
  Future<String> _detectContainerExtension(File file) async {
    List<int>? header;
    try {
      final handle = await file.open(mode: FileMode.read);
      try {
        header = await handle.read(32);
      } finally {
        await handle.close();
      }
    } on Object {
      header = null;
    }
    if (header != null) {
      final sniffed = containerExtensionFromBytes(header);
      if (sniffed != null) return sniffed;
    }
    return containerExtensionFromUri(source.uri) ?? 'mp4';
  }

  static String? containerExtensionFromBytes(List<int> bytes) {
    bool ascii(int offset, String text) {
      if (offset + text.length > bytes.length) return false;
      for (var index = 0; index < text.length; index++) {
        if (bytes[offset + index] != text.codeUnitAt(index)) return false;
      }
      return true;
    }

    if (ascii(4, 'ftyp')) {
      if (ascii(8, 'qt')) return 'mov';
      if (ascii(8, 'M4A')) return 'm4a';
      return 'mp4';
    }
    if (ascii(0, 'RIFF') && ascii(8, 'WAVE')) return 'wav';
    if (ascii(0, 'FLV')) return 'flv';
    if (ascii(0, 'OggS')) return 'ogg';
    if (ascii(0, 'ID3')) return 'mp3';
    if (ascii(0, 'fLaC')) return 'flac';
    if (bytes.length >= 4 &&
        bytes[0] == 0x1A && bytes[1] == 0x45 &&
        bytes[2] == 0xDF && bytes[3] == 0xA3) {
      return 'webm';
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF) {
      if (bytes[1] == 0xF1 || bytes[1] == 0xF9) return 'aac';
      if (bytes[1] & 0xE0 == 0xE0) return 'mp3';
    }
    return null;
  }

  static const knownMediaExtensions = <String>{
    'mp4', 'm4v', 'mov', 'm4a', 'mp3', 'aac', 'wav', 'webm', 'mkv', 'flv',
    'ogg', 'ogv', 'flac', 'ts', 'mpeg', 'mpg', 'avi', 'wmv', 'opus',
  };

  static String? containerExtensionFromUri(Uri uri) {
    if (uri.pathSegments.isEmpty) return null;
    final segment = uri.pathSegments.last;
    final dot = segment.lastIndexOf('.');
    if (dot <= 0 || dot == segment.length - 1) return null;
    final extension = segment.substring(dot + 1).toLowerCase();
    return knownMediaExtensions.contains(extension) ? extension : null;
  }

  /// Maps a loopback proxy URI to the custom scheme consumed by the iOS
  /// AVAssetResourceLoader decoder. Host, port, path and query are preserved
  /// verbatim so the native loader restores an http request that still hits
  /// this same HttpServer; only the scheme changes. Windows keeps plain http.
  static Uri customSchemeProxyUri(
    Uri proxyUri, {
    String scheme = 'aivpmedia',
  }) =>
      proxyUri.replace(scheme: scheme);

  Future<void> _download(RandomAccessFile output) async {
    var offset = 0;
    while (!_cancelled) {
      final end = offset + policy.chunkBytes - 1;
      final headers = Map<String, String>.of(source.requestHeaders)
        ..['Range'] = 'bytes=$offset-$end';
      final response = await _transport.get(source.uri, headers: headers);
      _contentLength ??= _contentLengthFrom(response.headers, offset);
      if (response.statusCode == 200) {
        // A server without Range support is still safe to consume, but this
        // is one sequential response rather than random-access caching.
        _usedSequentialDownload = true;
        _state = RecognitionMediaCacheState.downloading;
        await _writeBody(output, response.body, offset);
        break;
      }
      if (response.statusCode != 206) {
        throw HttpException(
          '识别媒体下载返回 HTTP ${response.statusCode}。',
          uri: source.uri,
        );
      }
      await _writeBody(output, response.body, offset);
      final written = _cursor.downloadedThrough - offset;
      if (written <= 0) throw const FormatException('识别媒体响应为空。');
      offset += written;
      if (_contentLength != null && offset >= _contentLength!) break;
      if (written < policy.chunkBytes) break;
    }
  }

  Future<void> _writeBody(
    RandomAccessFile output,
    Stream<List<int>> body,
    int offset,
  ) async {
    var position = offset;
    await for (final chunk in body) {
      if (_cancelled) return;
      if (chunk.isEmpty) continue;
      if (position + chunk.length > policy.maxBytes) {
        throw const FileSystemException('识别媒体缓存超过大小上限。');
      }
      await output.setPosition(position);
      await output.writeFrom(chunk);
      _cursor.recordDownloadedSegment(
        start: position,
        endExclusive: position + chunk.length,
      );
      position += chunk.length;
      _emit();
    }
  }

  Future<void> _serveProxyRequest(HttpRequest request) async {
    _ActiveProxyRequest? active;
    try {
      if (_cancelled || request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode =
            _cancelled ? 503 : HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final cached = _cachedRange(range);
      if (cached != null) {
        _emitRequestEvent(
          RecognitionMediaCacheRequestEvent(
            kind: RecognitionMediaCacheRequestEventKind.cacheHit,
            at: DateTime.now(),
            range: range,
            priorityEpoch: _priorityEpoch,
          ),
        );
        await _serveCachedRange(request, cached);
        return;
      }

      // Container warmup is deliberately best effort. Once the decoder asks
      // for bytes, its request owns the recognition connection and warmup
      // yields immediately so startup cannot be delayed by speculative I/O.
      for (final warmup in _warmupRequests.values.toList()) {
        warmup.cancel('decoder_request_priority');
      }

      active = _ActiveProxyRequest(
        id: ++_nextRequestId,
        range: range,
        priorityEpoch: _priorityEpoch,
        requestRole: 'decoder',
      );
      _activeProxyRequests[active.id] = active;
      _emitRequestEvent(
        RecognitionMediaCacheRequestEvent(
          kind: RecognitionMediaCacheRequestEventKind.upstreamStarted,
          at: active.startedAt,
          requestId: active.id,
          range: range,
          priorityEpoch: active.priorityEpoch,
          requestRole: active.requestRole,
        ),
      );
      final requested = _parseRange(range);
      final upstreamRange = policy.enableSegmentedProxyStreaming
          ? _segmentRange(requested, requested?.start ?? 0)
          : range;
      final response =
          await _openUpstream(request.method, upstreamRange, active);
      _contentLength ??=
          _contentLengthFrom(response.headers, requested?.start ?? 0);
      final upstreamHonoredRange =
          response.statusCode == HttpStatus.partialContent;
      if (!upstreamHonoredRange && range != null) {
        // A 200 response to a Range request is a sequential fallback. Record
        // it explicitly: treating it as a random-access segment corrupts the
        // byte offset and makes real-network regressions impossible to trace.
        _usedSequentialDownload = true;
        _message = '上游未接受 Range，识别代理改为顺序流式读取。';
        _emit();
      }
      request.response.statusCode = response.statusCode;
      _copyResponseHeaders(
        response.headers,
        request.response.headers,
        preserveRangeHeaders: !policy.enableSegmentedProxyStreaming,
      );
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (policy.enableSegmentedProxyStreaming &&
          response.statusCode == HttpStatus.partialContent &&
          requested != null &&
          _contentLength != null) {
        final end = requested.endInclusive ?? (_contentLength! - 1);
        request.response.headers
          ..set(HttpHeaders.contentRangeHeader,
              'bytes ${requested.start}-$end/$_contentLength')
          ..set(HttpHeaders.contentLengthHeader,
              end >= requested.start ? end - requested.start + 1 : 0);
      }
      if (request.method == 'HEAD') {
        await request.response.close();
      } else if (response.statusCode == HttpStatus.ok ||
          response.statusCode == HttpStatus.partialContent) {
        if (policy.enableSegmentedProxyStreaming) {
          await _streamSegmentedProxyResponse(
            response,
            request.response,
            requested,
            active,
          );
        } else {
          await _streamProxyResponse(
            response,
            request.response,
            active,
            start: upstreamHonoredRange
                ? _responseStart(response.headers, range)
                : 0,
          );
        }
      } else {
        await request.response.close();
      }
      _emitRequestEvent(
        RecognitionMediaCacheRequestEvent(
          kind: active.cancelled
              ? RecognitionMediaCacheRequestEventKind.upstreamCancelled
              : RecognitionMediaCacheRequestEventKind.upstreamCompleted,
          at: DateTime.now(),
          requestId: active.id,
          range: range,
          priorityEpoch: active.priorityEpoch,
          requestRole: active.requestRole,
          bytesTransferred: active.bytesTransferred,
          elapsed: active.elapsed,
          timeToFirstByte: active.timeToFirstByte,
          averageBytesPerSecond: active.averageBytesPerSecond,
          responseStatusCode: active.responseStatusCode,
          responseContentRange: active.responseContentRange,
          message: active.cancelReason,
        ),
      );
    } on Object catch (error) {
      if (active?.cancelled ?? false) {
        _emitRequestEvent(
          RecognitionMediaCacheRequestEvent(
            kind: RecognitionMediaCacheRequestEventKind.upstreamCancelled,
            at: DateTime.now(),
            requestId: active!.id,
            range: active.range,
            priorityEpoch: active.priorityEpoch,
            requestRole: active.requestRole,
            bytesTransferred: active.bytesTransferred,
            elapsed: active.elapsed,
            timeToFirstByte: active.timeToFirstByte,
            averageBytesPerSecond: active.averageBytesPerSecond,
            responseStatusCode: active.responseStatusCode,
            responseContentRange: active.responseContentRange,
            message: active.cancelReason,
          ),
        );
        try {
          await request.response.close();
        } on Object {
          // The connection is deliberately interrupted during preemption.
        }
        return;
      }
      if (active != null) {
        _emitRequestEvent(
          RecognitionMediaCacheRequestEvent(
            kind: RecognitionMediaCacheRequestEventKind.upstreamFailed,
            at: DateTime.now(),
            requestId: active.id,
            range: active.range,
            priorityEpoch: active.priorityEpoch,
            requestRole: active.requestRole,
            bytesTransferred: active.bytesTransferred,
            elapsed: active.elapsed,
            timeToFirstByte: active.timeToFirstByte,
            averageBytesPerSecond: active.averageBytesPerSecond,
            responseStatusCode: active.responseStatusCode,
            responseContentRange: active.responseContentRange,
            message: error.runtimeType.toString(),
          ),
        );
      }
      try {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.headers.contentType = ContentType.text;
        request.response.write('recognition media proxy failed: $error');
        await request.response.close();
      } on Object {
        // A streamed response may have committed headers before an upstream
        // socket error. In that case the client observes the interrupted body.
      }
      if (!_cancelled) {
        _message = error.toString();
        _emit();
      }
    } finally {
      if (active != null) {
        _activeProxyRequests.remove(active.id);
        // The shared upstream pool is worker-owned; nothing to close per request.
      }
    }
  }

  Future<RecognitionMediaHttpResponse> _openUpstream(
    String method,
    String? range,
    _ActiveProxyRequest active,
  ) async {
    if (_transport is! IoRecognitionMediaHttpTransport) {
      // The test transport has no HTTP server semantics. Production always
      // owns an HttpClient; keep this failure explicit rather than silently
      // falling back to Media Foundation's direct network reader.
      throw StateError('识别媒体代理需要 IO HTTP transport。');
    }
    final upstream = await _upstreamClient.openUrl(method, source.uri);
    source.requestHeaders
        .forEach((name, value) => upstream.headers.set(name, value));
    if (range != null && range.isNotEmpty) {
      upstream.headers.set(HttpHeaders.rangeHeader, range);
    }
    // Remember the in-flight request so a superseded decoder position can
    // abort its socket promptly instead of draining the old response.
    active.upstreamRequest = upstream;
    final origin = await upstream.close();
    active.upstreamResponse = origin;
    if (active.cancelled) {
      upstream.abort();
      throw StateError('识别媒体上游请求已被取消。');
    }
    final headers = <String, String>{};
    origin.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(',');
    });
    active.responseStatusCode = origin.statusCode;
    active.responseContentRange = headers['content-range'];
    _emitRequestEvent(
      RecognitionMediaCacheRequestEvent(
        kind: RecognitionMediaCacheRequestEventKind.upstreamResponse,
        at: DateTime.now(),
        requestId: active.id,
        range: active.range,
        upstreamRange: range,
        priorityEpoch: active.priorityEpoch,
        requestRole: active.requestRole,
        responseStatusCode: active.responseStatusCode,
        responseContentRange: active.responseContentRange,
      ),
    );
    return RecognitionMediaHttpResponse(
      statusCode: origin.statusCode,
      headers: headers,
      body: origin,
    );
  }

  _CachedProxyRange? _cachedRange(String? range) {
    final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
    if (match == null) return null;
    final start = int.parse(match.group(1)!);
    final endExclusive = int.parse(match.group(2)!) + 1;
    final tailStart = _tailCacheStart;
    final tailEnd = _tailCacheEndExclusive;
    final tailPath = _tailPath;
    if (tailStart != null &&
        tailEnd != null &&
        tailPath != null &&
        tailStart <= start &&
        tailEnd >= endExclusive) {
      return _CachedProxyRange(
        sourcePath: tailPath,
        mediaStart: start,
        mediaEndExclusive: endExclusive,
        fileStart: start - tailStart,
      );
    }
    if (!_cursor.containsRange(start: start, endExclusive: endExclusive) ||
        _path == null) {
      return null;
    }
    return _CachedProxyRange(
      sourcePath: _path!,
      mediaStart: start,
      mediaEndExclusive: endExclusive,
      fileStart: start,
    );
  }

  ({int start, int? endInclusive})? _parseRange(String? range) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range ?? '');
    if (match == null) return null;
    return (
      start: int.parse(match.group(1)!),
      endInclusive: match.group(2)!.isEmpty ? null : int.parse(match.group(2)!),
    );
  }

  String _segmentRange(({int start, int? endInclusive})? requested, int start) {
    final requestedEnd = requested?.endInclusive;
    final candidate = start + policy.chunkBytes - 1;
    final end = requestedEnd == null || candidate <= requestedEnd
        ? candidate
        : requestedEnd;
    return 'bytes=$start-$end';
  }

  Future<void> _serveCachedRange(
    HttpRequest request,
    _CachedProxyRange range,
  ) async {
    final length = range.mediaEndExclusive - range.mediaStart;
    final file = File(range.sourcePath);
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentLengthHeader, length)
      ..set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.mediaStart}-${range.mediaEndExclusive - 1}/${_contentLength ?? '*'}',
      );
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    await request.response.addStream(
      file.openRead(range.fileStart, range.fileStart + length),
    );
    await request.response.close();
  }

  void _copyResponseHeaders(
      Map<String, String> headers, HttpHeaders destination,
      {bool preserveRangeHeaders = true}) {
    final skipped = <String>{'connection', 'transfer-encoding'};
    if (!preserveRangeHeaders) {
      skipped
        ..add(HttpHeaders.contentRangeHeader)
        ..add(HttpHeaders.contentLengthHeader);
    }
    headers.forEach((name, value) {
      if (!skipped.contains(name.toLowerCase())) destination.set(name, value);
    });
  }

  int _responseStart(Map<String, String> headers, String? requestedRange) {
    final range = headers['content-range'];
    final match = RegExp(r'^bytes\s+(\d+)-').firstMatch(range ?? '');
    if (match != null) return int.parse(match.group(1)!);
    final requested = RegExp(r'^bytes=(\d+)-').firstMatch(requestedRange ?? '');
    return requested == null ? 0 : int.parse(requested.group(1)!);
  }

  Future<void> _streamSegmentedProxyResponse(
    RecognitionMediaHttpResponse firstResponse,
    HttpResponse response,
    ({int start, int? endInclusive})? requested,
    _ActiveProxyRequest active,
  ) async {
    var upstreamResponse = firstResponse;
    var offset = _responseStart(firstResponse.headers, active.range);
    final requestedEnd = requested?.endInclusive ??
        (_contentLength == null ? null : _contentLength! - 1);
    try {
      while (!_cancelled && !active.cancelled) {
        final segmentStart = offset;
        final remaining = requestedEnd == null
            ? policy.chunkBytes
            : requestedEnd - offset + 1;
        final segmentBytes = await _streamBody(
          upstreamResponse.body,
          response,
          offset,
          active,
          limit: upstreamResponse.statusCode == HttpStatus.ok
              ? null
              : remaining > policy.chunkBytes
                  ? policy.chunkBytes
                  : remaining,
        );
        offset += segmentBytes;
        final segmentFinished = segmentBytes < policy.chunkBytes;
        if (requestedEnd != null && offset > requestedEnd) break;
        if (segmentFinished ||
            upstreamResponse.statusCode == HttpStatus.ok ||
            (requestedEnd != null && offset > requestedEnd)) {
          break;
        }
        if (_contentLength != null && offset >= _contentLength!) break;
        final nextRange = _segmentRange(requested, offset);
        upstreamResponse = await _openUpstream('GET', nextRange, active);
        if (upstreamResponse.statusCode != HttpStatus.partialContent &&
            upstreamResponse.statusCode != HttpStatus.ok) {
          throw HttpException(
              '识别媒体分段请求返回 HTTP '
              '${upstreamResponse.statusCode}。',
              uri: source.uri);
        }
        if (segmentStart == offset) break;
      }
    } finally {
      await response.close();
    }
  }

  Future<void> _streamProxyResponse(
    RecognitionMediaHttpResponse upstreamResponse,
    HttpResponse response,
    _ActiveProxyRequest active, {
    required int start,
  }) async {
    try {
      await _streamBody(
        upstreamResponse.body,
        response,
        start,
        active,
      );
    } finally {
      await response.close();
    }
  }

  Future<int> _streamBody(
    Stream<List<int>> body,
    HttpResponse response,
    int start,
    _ActiveProxyRequest active, {
    int? limit,
  }) async {
    var offset = start;
    await for (final bytes in body) {
      if (_cancelled || active.cancelled) break;
      if (bytes.isEmpty) continue;
      final remaining = limit == null ? bytes.length : limit - (offset - start);
      if (remaining <= 0) break;
      final allowed = limit == null || bytes.length <= remaining
          ? bytes
          : bytes.sublist(0, remaining);
      if (allowed.isEmpty) break;
      if (!active.hasFirstByte) {
        active.hasFirstByte = true;
        active.firstByteAt = DateTime.now();
        _emitRequestEvent(
          RecognitionMediaCacheRequestEvent(
            kind: RecognitionMediaCacheRequestEventKind.upstreamFirstByte,
            at: active.firstByteAt!,
            requestId: active.id,
            range: active.range,
            priorityEpoch: active.priorityEpoch,
            requestRole: active.requestRole,
          ),
        );
      }
      response.add(allowed);
      active.bytesTransferred += allowed.length;
      if (offset < policy.maxBytes && _path != null) {
        final writable = allowed.length > policy.maxBytes - offset
            ? allowed.sublist(0, policy.maxBytes - offset)
            : allowed;
        await _writeCached(offset, writable);
      }
      offset += allowed.length;
      if (limit != null && offset - start >= limit) break;
    }
    return offset - start;
  }

  Future<void> _warmContainer() async {
    _ActiveProxyRequest? head;
    var headCompleted = false;
    try {
      head = _newWarmupRequest(
          'containerHeadWarmup', 'bytes=0-${policy.warmupHeadBytes - 1}');
      final response = await _openUpstream(
        'GET',
        'bytes=0-${policy.warmupHeadBytes - 1}',
        head,
      );
      if (response.statusCode != HttpStatus.partialContent) {
        head.cancel('container_warmup_requires_range');
        _completeWarmup(head);
        headCompleted = true;
        return;
      }
      _contentLength ??= _contentLengthFrom(response.headers, 0);
      await _consumeWarmupBody(response.body, 0, head, cacheTail: false);
      _completeWarmup(head);
      headCompleted = true;
      if (_cancelled || head.cancelled || _contentLength == null) return;
      final total = _contentLength!;
      final tailStart = total - policy.warmupTailBytes < 0
          ? 0
          : total - policy.warmupTailBytes;
      if (tailStart == 0) return;
      final tail = _newWarmupRequest(
        'containerTailWarmup',
        'bytes=$tailStart-${total - 1}',
      );
      try {
        final tailResponse = await _openUpstream(
          'GET',
          'bytes=$tailStart-${total - 1}',
          tail,
        );
        if (tailResponse.statusCode != HttpStatus.partialContent) {
          tail.cancel('container_warmup_requires_range');
        } else {
          final tailBytes = await _consumeWarmupBody(
            tailResponse.body,
            tailStart,
            tail,
            cacheTail: true,
            tailCacheStart: tailStart,
          );
          if (!tail.cancelled && tailBytes == total - tailStart) {
            _tailCacheStart = tailStart;
            _tailCacheEndExclusive = total;
          }
        }
        _completeWarmup(tail);
      } finally {
        _warmupRequests.remove(tail.id);
      }
    } on Object catch (error) {
      if (!(head?.cancelled ?? false) && !_cancelled) {
        _message = '容器头尾预热失败：$error';
        _emit();
      }
    } finally {
      if (head != null) {
        if (!headCompleted) _completeWarmup(head);
        _warmupRequests.remove(head.id);
      }
    }
  }

  _ActiveProxyRequest _newWarmupRequest(String role, String range) {
    final active = _ActiveProxyRequest(
      id: ++_nextRequestId,
      range: range,
      priorityEpoch: _priorityEpoch,
      requestRole: role,
    );
    _warmupRequests[active.id] = active;
    _emitRequestEvent(
      RecognitionMediaCacheRequestEvent(
        kind: RecognitionMediaCacheRequestEventKind.upstreamStarted,
        at: active.startedAt,
        requestId: active.id,
        range: range,
        priorityEpoch: active.priorityEpoch,
        requestRole: role,
      ),
    );
    return active;
  }

  Future<int> _consumeWarmupBody(
    Stream<List<int>> body,
    int start,
    _ActiveProxyRequest active, {
    required bool cacheTail,
    int? tailCacheStart,
  }) async {
    var offset = start;
    await for (final bytes in body) {
      if (_cancelled || active.cancelled) break;
      if (bytes.isEmpty) continue;
      if (!active.hasFirstByte) {
        active.hasFirstByte = true;
        active.firstByteAt = DateTime.now();
        _emitRequestEvent(
          RecognitionMediaCacheRequestEvent(
            kind: RecognitionMediaCacheRequestEventKind.upstreamFirstByte,
            at: active.firstByteAt!,
            requestId: active.id,
            range: active.range,
            priorityEpoch: active.priorityEpoch,
            requestRole: active.requestRole,
          ),
        );
      }
      active.bytesTransferred += bytes.length;
      if (cacheTail) {
        await _writeTailCached(offset, bytes, tailCacheStart!);
      } else if (offset < policy.maxBytes && _path != null) {
        final writable = bytes.length > policy.maxBytes - offset
            ? bytes.sublist(0, policy.maxBytes - offset)
            : bytes;
        await _writeCached(offset, writable);
      }
      offset += bytes.length;
    }
    return offset - start;
  }

  void _completeWarmup(_ActiveProxyRequest active) {
    final now = DateTime.now();
    _emitRequestEvent(
      RecognitionMediaCacheRequestEvent(
        kind: active.cancelled
            ? RecognitionMediaCacheRequestEventKind.upstreamCancelled
            : RecognitionMediaCacheRequestEventKind.upstreamCompleted,
        at: now,
        requestId: active.id,
        range: active.range,
        priorityEpoch: active.priorityEpoch,
        requestRole: active.requestRole,
        bytesTransferred: active.bytesTransferred,
        elapsed: now.difference(active.startedAt),
        timeToFirstByte: active.firstByteAt?.difference(active.startedAt),
        averageBytesPerSecond: active.averageBytesPerSecondAt(now),
        responseStatusCode: active.responseStatusCode,
        responseContentRange: active.responseContentRange,
        message: active.cancelReason,
      ),
    );
  }

  Future<void> _writeCached(int offset, List<int> bytes) {
    final path = _path;
    if (path == null || bytes.isEmpty) return Future<void>.value();
    final write = _cacheWrites.then((_) async {
      final output = await File(path).open(mode: FileMode.writeOnly);
      try {
        await output.setPosition(offset);
        await output.writeFrom(bytes);
        _cursor.recordDownloadedSegment(
          start: offset,
          endExclusive: offset + bytes.length,
        );
        _emit();
      } finally {
        await output.close();
      }
    });
    _cacheWrites = write.catchError((Object error, StackTrace _) {
      _message = error.toString();
      _emit();
    });
    return write;
  }

  Future<void> _writeTailCached(
    int mediaOffset,
    List<int> bytes,
    int tailCacheStart,
  ) {
    final path = _tailPath;
    if (path == null || bytes.isEmpty) return Future<void>.value();
    final write = _cacheWrites.then((_) async {
      final output = await File(path).open(mode: FileMode.writeOnly);
      try {
        // This file stores only warmed tail bytes in a compact local layout;
        // it never seeks to the potentially multi-gigabyte media offset.
        await output.setPosition(mediaOffset - tailCacheStart);
        await output.writeFrom(bytes);
      } finally {
        await output.close();
      }
    });
    _cacheWrites = write.catchError((Object error, StackTrace _) {
      _message = error.toString();
      _emit();
    });
    return write;
  }

  int? _contentLengthFrom(Map<String, String> headers, int offset) {
    final contentRange = headers['content-range'];
    final slash = contentRange?.lastIndexOf('/');
    if (slash != null && slash >= 0) {
      return int.tryParse(contentRange!.substring(slash + 1));
    }
    final length = int.tryParse(headers['content-length'] ?? '');
    return length == null ? null : offset + length;
  }

  RecognitionMediaCacheSnapshot _fail(String message) {
    _state = RecognitionMediaCacheState.failed;
    _message = message;
    _emit();
    return snapshot;
  }

  RecognitionMediaCacheSnapshot _cancelledSnapshot() {
    _state = RecognitionMediaCacheState.cancelled;
    _emit();
    return snapshot;
  }

  void _emit() {
    if (!_snapshots.isClosed) _snapshots.add(snapshot);
  }

  void _emitRequestEvent(RecognitionMediaCacheRequestEvent event) {
    if (!_requestEvents.isClosed) _requestEvents.add(event);
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('recognition media cache is disposed');
  }
}

class _ActiveProxyRequest {
  _ActiveProxyRequest({
    required this.id,
    required this.range,
    required this.priorityEpoch,
    required this.requestRole,
  }) : startedAt = DateTime.now();

  final int id;
  final String? range;
  final int priorityEpoch;
  final String requestRole;
  final DateTime startedAt;
  HttpClientRequest? upstreamRequest;
  HttpClientResponse? upstreamResponse;
  bool cancelled = false;
  String? cancelReason;
  bool hasFirstByte = false;
  DateTime? firstByteAt;
  int bytesTransferred = 0;
  int? responseStatusCode;
  String? responseContentRange;

  Duration get elapsed => DateTime.now().difference(startedAt);

  Duration? get timeToFirstByte => firstByteAt?.difference(startedAt);

  double? get averageBytesPerSecond => averageBytesPerSecondAt(DateTime.now());

  double? averageBytesPerSecondAt(DateTime at) {
    final seconds = at.difference(startedAt).inMicroseconds /
        Duration.microsecondsPerSecond;
    return seconds <= 0 ? null : bytesTransferred / seconds;
  }

  /// Marks the logical request cancelled and aborts its in-flight socket so
  /// a superseded position stops consuming bandwidth. The shared pool is
  /// worker-owned; aborting one request's socket only recycles that socket.
  void cancel(String reason) {
    if (cancelled) return;
    cancelled = true;
    cancelReason = reason;
    upstreamRequest?.abort();
  }
}

class _CachedProxyRange {
  const _CachedProxyRange({
    required this.sourcePath,
    required this.mediaStart,
    required this.mediaEndExclusive,
    required this.fileStart,
  });

  final String sourcePath;
  final int mediaStart;
  final int mediaEndExclusive;
  final int fileStart;
}
