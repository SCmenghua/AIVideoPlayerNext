import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/recognition_media_source.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/features/audio/recognition_media_cache_worker.dart';

void main() {
  test('customSchemeProxyUri keeps host, port, path and query', () {
    final proxy = Uri.parse(
      'http://127.0.0.1:52638/media.mp4?a=1&b=2',
    );
    final mapped = RecognitionMediaCacheWorker.customSchemeProxyUri(proxy);
    expect(mapped.scheme, 'aivpmedia');
    expect(mapped.host, '127.0.0.1');
    expect(mapped.port, 52638);
    expect(mapped.path, '/media.mp4');
    expect(mapped.query, 'a=1&b=2');
    // The inverse mapping must still address the same loopback endpoint.
    expect(mapped.replace(scheme: 'http'), proxy);
  });

  test('downloads contiguous ranges into a session-owned media file', () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-cache-');
    final transport = _FakeTransport((_, headers) {
      final range = headers['Range'];
      return switch (range) {
        'bytes=0-3' => _response(206, 'abcd', {'content-range': 'bytes 0-3/8'}),
        'bytes=4-7' => _response(206, 'efgh', {'content-range': 'bytes 4-7/8'}),
        _ => throw StateError('unexpected range: $range'),
      };
    });
    final worker = RecognitionMediaCacheWorker(
      source: _networkSource(),
      sessionId: 'session-range',
      policy: const RecognitionMediaCachePolicy(
        chunkBytes: 4,
        maxBytes: 32,
      ),
      cacheDirectory: directory,
      transport: transport,
    );

    final result = await worker.prepare();

    expect(result.state, RecognitionMediaCacheState.complete);
    expect(result.cursor.downloadedThrough, 8);
    expect(result.cursor.downloadedBytes, 8);
    expect(result.path, isNotNull);
    expect(await File(result.path!).readAsString(), 'abcdefgh');
    expect(transport.headers, hasLength(2));
    expect(transport.headers.first['Cookie'], 'session-cookie');

    await worker.dispose();
    await directory.delete(recursive: true);
  });

  test('falls back to one sequential response when Range is rejected',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-cache-');
    final transport = _FakeTransport((_, headers) {
      expect(headers['Range'], startsWith('bytes=0-'));
      return _response(200, 'full-media', {'content-length': '10'});
    });
    final worker = RecognitionMediaCacheWorker(
      source: _networkSource(),
      sessionId: 'session-sequential',
      policy: const RecognitionMediaCachePolicy(chunkBytes: 4, maxBytes: 32),
      cacheDirectory: directory,
      transport: transport,
    );

    final result = await worker.prepare();

    expect(result.state, RecognitionMediaCacheState.complete);
    expect(result.cursor.downloadedThrough, 10);
    expect(await File(result.path!).readAsString(), 'full-media');
    expect(transport.headers, hasLength(1));

    await worker.dispose();
    await directory.delete(recursive: true);
  });

  test('local sources do not create a network cache request', () async {
    final transport = _FakeTransport((_, __) => throw StateError('network'));
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.file(r'C:\media\clip.mp4'),
        title: 'clip.mp4',
        kind: MediaSourceKind.localFile,
      ),
      sessionId: 'session-local',
      transport: transport,
    );

    final result = await worker.prepare();

    expect(result.state, RecognitionMediaCacheState.complete);
    expect(result.path, isNotNull);
    expect(transport.headers, isEmpty);
    await worker.dispose();
  });

  test('completed cache keeps an MP4 container extension for AVFoundation',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-cache-');
    // Real MP4 header: size, 'ftyp', 'isom' brand.
    final mp4Header = [
      0, 0, 0, 24, ...'ftyp'.codeUnits, ...'isom'.codeUnits,
      ...'mp42'.codeUnits,
    ];
    final transport = _FakeTransport(
      (_, __) => _response(200, String.fromCharCodes(mp4Header), const {}),
    );
    final worker = RecognitionMediaCacheWorker(
      source: _networkSource(),
      sessionId: 'session-mp4',
      policy: const RecognitionMediaCachePolicy(chunkBytes: 64, maxBytes: 256),
      cacheDirectory: directory,
      transport: transport,
    );

    final result = await worker.prepare();

    expect(result.state, RecognitionMediaCacheState.complete);
    expect(result.path, endsWith('media.mp4'));

    await worker.dispose();
    await directory.delete(recursive: true);
  });

  test('completed cache falls back to the URL extension without magic bytes',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-cache-');
    final transport =
        _FakeTransport((_, __) => _response(200, 'plain-bytes', const {}));
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('https://example.test/get/clip.webm'),
        title: 'clip.webm',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-webm',
      policy: const RecognitionMediaCachePolicy(chunkBytes: 64, maxBytes: 256),
      cacheDirectory: directory,
      transport: transport,
    );

    final result = await worker.prepare();

    expect(result.state, RecognitionMediaCacheState.complete);
    expect(result.path, endsWith('media.webm'));

    await worker.dispose();
    await directory.delete(recursive: true);
  });

  test('completed cache defaults to mp4 when nothing identifies the container',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-cache-');
    final transport =
        _FakeTransport((_, __) => _response(200, 'plain-bytes', const {}));
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('https://example.test/get_file/34461?token=1'),
        title: 'untitled media',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-unknown',
      policy: const RecognitionMediaCachePolicy(chunkBytes: 64, maxBytes: 256),
      cacheDirectory: directory,
      transport: transport,
    );

    final result = await worker.prepare();

    expect(result.state, RecognitionMediaCacheState.complete);
    expect(result.path, endsWith('media.mp4'));

    await worker.dispose();
    await directory.delete(recursive: true);
  });

  test('proxy path stays extensionless unless explicitly opted in', () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-proxy-path-');
    final worker = RecognitionMediaCacheWorker(
      source: _networkSource(),
      sessionId: 'session-path-default',
      cacheDirectory: directory,
    );

    final proxy = await worker.startProxy();

    expect(proxy.proxyUri!.path, '/media');

    await worker.dispose();
    await directory.delete(recursive: true);
  });

  test('opted-in proxy path carries the container extension', () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-proxy-ext-');
    final worker = RecognitionMediaCacheWorker(
      source: _networkSource(),
      sessionId: 'session-path-ext',
      cacheDirectory: directory,
    );
    worker.proxyPathCarriesExtension = true;

    final proxy = await worker.startProxy();

    expect(proxy.proxyUri!.path, '/media.mp4');

    await worker.dispose();
    await directory.delete(recursive: true);
  });

  test('proxy forwards authorization and serves a repeated range from cache',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-proxy-cache-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var upstreamRequests = 0;
    String? authorization;
    upstream.listen((request) async {
      ++upstreamRequests;
      authorization = request.headers.value(HttpHeaders.authorizationHeader);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      expect(range, 'bytes=2-5');
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 2-5/10')
        ..headers.contentLength = 4
        ..add('cdef'.codeUnits);
      await request.response.close();
    });
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('http://127.0.0.1:${upstream.port}/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
        requestHeaders: const {'Authorization': 'Bearer test-token'},
      ),
      sessionId: 'session-proxy',
      policy: const RecognitionMediaCachePolicy(
        maxBytes: 32,
        enableContainerWarmup: false,
      ),
      cacheDirectory: directory,
    );
    final proxy = await worker.startProxy();
    final uri = proxy.proxyUri!;
    final first = await _readProxyRange(uri, 'bytes=2-5');
    final second = await _readProxyRange(uri, 'bytes=2-5');

    expect(first, 'cdef');
    expect(second, 'cdef');
    expect(authorization, 'Bearer test-token');
    expect(upstreamRequests, 1);

    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test('proxy transparently forwards an open decoder range by default',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-proxy-stream-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestedRanges = <String>[];
    const media = 'abcdefghijkl';
    upstream.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      requestedRanges.add(range);
      expect(range, 'bytes=0-');
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-11/12')
        ..headers.contentLength = media.length
        ..add(media.codeUnits);
      await request.response.close();
    });
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('http://127.0.0.1:${upstream.port}/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-stream',
      policy: const RecognitionMediaCachePolicy(maxBytes: 32),
      cacheDirectory: directory,
    );
    final events = <RecognitionMediaCacheRequestEvent>[];
    final subscription = worker.requestEvents.listen(events.add);

    final proxy = await worker.startProxy();
    final received = await _readProxyRange(proxy.proxyUri!, 'bytes=0-');

    expect(received, media);
    expect(requestedRanges, ['bytes=0-']);
    expect(worker.snapshot.cursor.downloadedThrough, media.length);
    expect(
      events.any(
        (event) =>
            event.kind ==
                RecognitionMediaCacheRequestEventKind.upstreamResponse &&
            event.range == 'bytes=0-' &&
            event.upstreamRange == 'bytes=0-',
      ),
      isTrue,
    );

    await subscription.cancel();
    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
      'experimental proxy mode splits an open decoder range into bounded upstream ranges',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-proxy-segments-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestedRanges = <String>[];
    const media = 'abcdefghijkl';
    upstream.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      requestedRanges.add(range);
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      final bytes = media.codeUnits.sublist(start, end + 1);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${media.length}',
        )
        ..headers.contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('http://127.0.0.1:${upstream.port}/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-segments',
      policy: const RecognitionMediaCachePolicy(
        chunkBytes: 4,
        maxBytes: 32,
        enableSegmentedProxyStreaming: true,
        enableContainerWarmup: false,
      ),
      cacheDirectory: directory,
    );

    final proxy = await worker.startProxy();
    final received = await _readProxyRange(proxy.proxyUri!, 'bytes=0-');

    expect(received, media);
    expect(requestedRanges, ['bytes=0-3', 'bytes=4-7', 'bytes=8-11']);
    expect(worker.snapshot.cursor.downloadedThrough, media.length);

    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test('container warmup yields to the first decoder request', () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-proxy-warmup-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestedRanges = <String>[];
    final headStarted = Completer<void>();
    final releaseHead = Completer<void>();
    upstream.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      requestedRanges.add(range);
      if (range == 'bytes=0-3') {
        headStarted.complete();
        await releaseHead.future;
      }
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      final length = end - start + 1;
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/64')
        ..headers.contentLength = length
        ..add(List<int>.filled(length, 1));
      try {
        await request.response.close();
      } on Object {
        // Decoder priority deliberately interrupts the speculative warmup.
      }
    });
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('http://127.0.0.1:${upstream.port}/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-warmup',
      policy: const RecognitionMediaCachePolicy(
        chunkBytes: 4,
        maxBytes: 32,
        enableContainerWarmup: true,
        warmupHeadBytes: 4,
        warmupTailBytes: 4,
      ),
      cacheDirectory: directory,
    );
    final events = <RecognitionMediaCacheRequestEvent>[];
    final subscription = worker.requestEvents.listen(events.add);

    final proxy = await worker.startProxy();
    await headStarted.future;
    final decoderRead = _readProxyRange(proxy.proxyUri!, 'bytes=12-15');
    if (!releaseHead.isCompleted) releaseHead.complete();
    await decoderRead;

    expect(requestedRanges, contains('bytes=12-15'));
    expect(
      events.any(
        (event) =>
            event.requestRole == 'containerHeadWarmup' &&
            event.kind ==
                RecognitionMediaCacheRequestEventKind.upstreamCancelled,
      ),
      isTrue,
    );

    await subscription.cancel();
    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test('priority intent waits for decoder seek before cancelling old range',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('recognition-proxy-priority-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestedRanges = <String>[];
    final firstRangeStarted = Completer<void>();
    final releaseFirstRange = Completer<void>();
    upstream.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      requestedRanges.add(range);
      if (range == 'bytes=0-3') {
        firstRangeStarted.complete();
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-3/256')
          ..headers.contentLength = 4
          ..add('abcd'.codeUnits);
        await releaseFirstRange.future;
        try {
          request.response.add('late'.codeUnits);
          await request.response.close();
        } on Object {
          // The proxy deliberately closes this upstream request on preemption.
        }
        return;
      }
      expect(range, 'bytes=100-103');
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 100-103/256')
        ..headers.contentLength = 4
        ..add('targ'.codeUnits);
      await request.response.close();
    });
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('http://127.0.0.1:${upstream.port}/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-priority',
      policy: const RecognitionMediaCachePolicy(
        maxBytes: 1024,
        enableContainerWarmup: false,
      ),
      cacheDirectory: directory,
    );
    final events = <RecognitionMediaCacheRequestEvent>[];
    final subscription = worker.requestEvents.listen(events.add);
    final proxy = await worker.startProxy();

    unawaited(
      _readProxyRange(proxy.proxyUri!, 'bytes=0-3').then<void>(
        (_) {},
        onError: (_, __) {},
      ),
    );
    await firstRangeStarted.future;
    worker.prioritizePlaybackRange(
      playbackPosition: const Duration(minutes: 11),
      context: const Duration(seconds: 2),
      lead: const Duration(seconds: 45),
      epoch: 1,
    );
    expect(
      events.any(
        (event) =>
            event.kind ==
                RecognitionMediaCacheRequestEventKind.upstreamCancelled &&
            event.range == 'bytes=0-3',
      ),
      isFalse,
    );
    worker.activatePlaybackPriority(epoch: 1);
    final target = await _readProxyRange(proxy.proxyUri!, 'bytes=100-103');

    expect(target, 'targ');
    expect(requestedRanges, ['bytes=0-3', 'bytes=100-103']);
    expect(
      events.any(
        (event) =>
            event.kind ==
                RecognitionMediaCacheRequestEventKind.upstreamCancelled &&
            event.range == 'bytes=0-3',
      ),
      isTrue,
    );

    if (!releaseFirstRange.isCompleted) releaseFirstRange.complete();
    await subscription.cancel();
    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });
}

Future<String> _readProxyRange(Uri uri, String range) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    expect(response.statusCode, HttpStatus.partialContent);
    return utf8.decode(await response.fold<List<int>>(<int>[], (bytes, next) {
      return bytes..addAll(next);
    }));
  } finally {
    client.close(force: true);
  }
}

RecognitionMediaSource _networkSource() => RecognitionMediaSource(
      uri: Uri.parse('https://example.test/media.mp4'),
      title: 'media.mp4',
      kind: MediaSourceKind.browserHandoff,
      requestHeaders: const {
        'Cookie': 'session-cookie',
        'Referer': 'https://example.test/page',
      },
    );

RecognitionMediaHttpResponse _response(
  int status,
  String body,
  Map<String, String> headers,
) =>
    RecognitionMediaHttpResponse(
      statusCode: status,
      headers: headers,
      body: Stream<List<int>>.value(body.codeUnits),
    );

class _FakeTransport implements RecognitionMediaHttpTransport {
  _FakeTransport(this.handler);

  final FutureOr<RecognitionMediaHttpResponse> Function(
    Uri uri,
    Map<String, String> headers,
  ) handler;
  final List<Map<String, String>> headers = [];

  @override
  Future<RecognitionMediaHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  }) async {
    this.headers.add(Map<String, String>.of(headers));
    return handler(uri, headers);
  }

  @override
  Future<void> close() async {}
}
