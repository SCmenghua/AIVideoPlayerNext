import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/audio/recognition_media_source.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/features/audio/recognition_media_cache_worker.dart';

void main() {
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
        uri: Uri.file(
          Platform.isWindows ? r'C:\media\clip.mp4' : '/media/clip.mp4',
        ),
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
    const media = 'abcdefghij';
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var upstreamRequests = 0;
    String? authorization;
    final transferredIntervals = <({int start, int end})>[];
    upstream.listen((request) async {
      ++upstreamRequests;
      authorization = request.headers.value(HttpHeaders.authorizationHeader);
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      // The transparent engine asks a closed range; the single-flight filler
      // streams open-ended from its planning start.
      expect(range, anyOf('bytes=2-5', 'bytes=2-'));
      final start = int.parse(RegExp(r'^bytes=(\d+)-').firstMatch(range)!.group(1)!);
      final body = media.substring(start);
      transferredIntervals.add((start: start, end: media.length));
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-${media.length - 1}/${media.length}')
        ..headers.contentLength = body.length
        ..add(body.codeUnits);
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
    await _settleFill(worker);
    final beforeRepeat = upstreamRequests;
    final second = await _readProxyRange(uri, 'bytes=2-5');

    expect(first, 'cdef');
    expect(second, 'cdef');
    expect(authorization, 'Bearer test-token');
    // The repeat is served entirely from the byte cache.
    expect(upstreamRequests, beforeRepeat);
    // Background opportunistic fill never re-downloads an overlapping span.
    var coveredEnd = 0;
    for (final interval in transferredIntervals..sort((a, b) => a.start.compareTo(b.start))) {
      if (interval.start > coveredEnd && transferredIntervals.length > 1) {
        fail('upstream requests left an unplanned gap at ${interval.start}');
      }
      coveredEnd =
          interval.end > coveredEnd ? interval.end : coveredEnd;
    }
    expect(coveredEnd <= media.length, isTrue);

    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test('transparent passthrough streams an open decoder range when opted out',
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
      policy: const RecognitionMediaCachePolicy(
        maxBytes: 32,
        useSingleFlightFiller: false,
      ),
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

  test('single-flight filler serves two clients over one upstream connection',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('filler-multiplex-');
    const media = '0123456789abcdef';
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var connections = 0;
    var maxConcurrent = 0;
    var active = 0;
    upstream.listen((request) async {
      ++connections;
      ++active;
      if (active > maxConcurrent) {
        maxConcurrent = active;
      }
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader,
            'bytes 0-${media.length - 1}/${media.length}')
        ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
        ..headers.contentLength = media.length;
      for (final chunk in ['0123', '4567', '89ab']) {
        request.response.add(chunk.codeUnits);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      request.response.add('cdef'.codeUnits);
      await request.response.close();
      --active;
    });
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('http://127.0.0.1:${upstream.port}/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-engine',
      cacheDirectory: directory,
    );
    final proxy = await worker.startProxy();
    final uri = proxy.proxyUri!;

    final firstClient = _readProxyRange(uri, 'bytes=0-');
    while (worker.snapshot.cursor.downloadedThrough < 4) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final secondClient = _readProxyRange(uri, 'bytes=4-7');
    expect(await firstClient, media);
    expect(await secondClient, '4567');

    await _settleFill(worker);
    expect(connections, 1);
    expect(maxConcurrent, 1);
    expect(worker.snapshot.cursor.downloadedThrough, media.length);

    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test('single-flight jump prioritizes the demanded region then refills',
      () async {
    final directory = await Directory.systemTemp.createTemp('filler-jump-');
    const mediaLength = 200;
    int mediaByte(int offset) => offset ~/ 2 % 251;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestedRanges = <String>[];
    final slowLegBegan = Completer<void>();
    final releaseSlowLeg = Completer<void>();
    final farDemandBegan = Completer<void>();
    upstream.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      requestedRanges.add(range);
      if (range == 'bytes=16-') {
        slowLegBegan.complete();
        // Park the first leg before committing headers so the demand-side
        // jump below is fully deterministic.
        await releaseSlowLeg.future;
      }
      if (range == 'bytes=4-') {
        farDemandBegan.complete();
      }
      final start =
          int.parse(RegExp(r'^bytes=(\d+)-').firstMatch(range)!.group(1)!);
      final remaining = mediaLength - start;
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-${mediaLength - 1}/$mediaLength')
        ..headers.contentLength = remaining
        ..add(List<int>.generate(remaining, (i) => mediaByte(start + i)));
      try {
        await request.response.close();
      } on Object {
        // The filler deliberately aborts the superseded first leg.
      }
    });
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('http://127.0.0.1:${upstream.port}/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-jump',
      policy: const RecognitionMediaCachePolicy(
        clientWaitTimeout: Duration(seconds: 10),
      ),
      cacheDirectory: directory,
    );
    final proxy = await worker.startProxy();
    final uri = proxy.proxyUri!;
    final slowTail = _readProxyRange(uri, 'bytes=16-');
    await slowLegBegan.future;

    // A far-backward player seek into an uncovered area must preempt the
    // running fill immediately: the demand region is answered while the old
    // leg is still parked at the origin.
    final backwardDemand = _readProxyRange(uri, 'bytes=4-11');
    await farDemandBegan.future;
    if (!releaseSlowLeg.isCompleted) releaseSlowLeg.complete();
    expect(await backwardDemand,
        String.fromCharCodes(List<int>.generate(8, (i) => mediaByte(4 + i))));
    expect(await slowTail,
        String.fromCharCodes(List<int>.generate(184, (i) => mediaByte(16 + i))));

    // The pre-jump head gap is refilled by the next explicit demand.
    final headFill = await _readProxyRange(uri, 'bytes=0-4');
    expect(
        headFill.codeUnits,
        List<int>.generate(5, (i) => mediaByte(i)));
    await _settleFill(worker);
    expect(requestedRanges[0], 'bytes=16-');
    expect(requestedRanges[1], 'bytes=4-');
    expect(worker.snapshot.cursor.downloadedThrough, mediaLength);
    expect(worker.snapshot.state, RecognitionMediaCacheState.complete);

    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test('single-flight filler answers HEAD probes with the media size',
      () async {
    final directory = await Directory.systemTemp.createTemp('filler-head-');
    const media = 'abcdefgh';
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader,
            'bytes 0-7/${media.length}')
        ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
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
      sessionId: 'session-head',
      cacheDirectory: directory,
    );
    final proxy = await worker.startProxy();

    final head = await _readProxyHead(proxy.proxyUri!);
    expect(head.statusCode, HttpStatus.partialContent);
    expect(head.contentRange, endsWith('/8'));

    await _settleFill(worker);
    final body = await _readProxyRange(proxy.proxyUri!, 'bytes=0-');
    expect(body, media);

    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test('cached bytes survive later writes to the same cache file', () async {
    // Regression: per-write opens with a truncating FileMode wiped earlier
    // chunks while the cursor still reported them cached.
    final directory =
        await Directory.systemTemp.createTemp('filler-no-truncate-');
    const media = 'abcdefghij';
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader,
            'bytes 0-${media.length - 1}/${media.length}')
        ..headers.contentLength = media.length;
      request.response.add('abcde'.codeUnits);
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      request.response.add('fghij'.codeUnits);
      await request.response.close();
    });
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('http://127.0.0.1:${upstream.port}/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-no-truncate',
      cacheDirectory: directory,
    );
    final proxy = await worker.startProxy();
    await _settleFill(worker);

    expect(await _readProxyRange(proxy.proxyUri!, 'bytes=0-4'), 'abcde');
    expect(await _readProxyRange(proxy.proxyUri!, 'bytes=5-9'), 'fghij');
    expect(await _readProxyRange(proxy.proxyUri!, 'bytes=0-'), media);

    await worker.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test('bounded range probe completes without waiting for the size probe',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('filler-probe-commit-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final headersReleased = Completer<void>();
    upstream.listen((request) async {
      await headersReleased.future;
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-7/8')
        ..headers.contentLength = 8
        ..add('abcdefgh'.codeUnits);
      await request.response.close();
    });
    final worker = RecognitionMediaCacheWorker(
      source: RecognitionMediaSource(
        uri: Uri.parse('http://127.0.0.1:${upstream.port}/media.mp4'),
        title: 'media.mp4',
        kind: MediaSourceKind.browserHandoff,
      ),
      sessionId: 'session-probe-commit',
      policy: const RecognitionMediaCachePolicy(
        clientWaitTimeout: Duration(seconds: 5),
      ),
      cacheDirectory: directory,
    );
    final proxy = await worker.startProxy();

    // A bounded probe must not depend on the total size: it is answered as
    // soon as its bytes reach the cache, with '*' while the size is unknown.
    final client = HttpClient();
    final request = await client.getUrl(proxy.proxyUri!);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
    final probe = request.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    headersReleased.complete();
    final response = await probe;
    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-1/*');
    final body = await response.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    expect(body, 'ab'.codeUnits);
    client.close(force: true);

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
        useSingleFlightFiller: false,
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

Future<({int statusCode, String? contentRange})> _readProxyHead(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl('HEAD', uri);
    final response = await request.close();
    await response.drain<void>();
    return (
      statusCode: response.statusCode,
      contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
    );
  } finally {
    client.close(force: true);
  }
}

/// Waits until the single-flight filler stops making progress or completes.
Future<void> _settleFill(RecognitionMediaCacheWorker worker) async {
  var lastSeen = -1;
  var idlePolls = 0;
  for (var i = 0; i < 2000; i++) {
    final snapshot = worker.snapshot;
    if (snapshot.state == RecognitionMediaCacheState.complete &&
        snapshot.cursor.downloadedThrough ==
            (snapshot.contentLength ?? -1)) {
      return;
    }
    final through = snapshot.cursor.downloadedThrough;
    if (through == lastSeen) {
      idlePolls++;
      if (idlePolls > 100) return;
    } else {
      idlePolls = 0;
      lastSeen = through;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
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
