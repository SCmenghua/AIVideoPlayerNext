import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/translation/translation_service.dart';
import 'package:ai_video_player_next/features/translation/openai_compatible_translation_service.dart';

TranslationRequest _request() => const TranslationRequest(
      segmentId: 'seg-000001',
      text: 'Hello, world.',
      sourceLanguage: 'en',
      targetLanguage: 'zh-CN',
    );

HttpClient _directClient() => HttpClient()..findProxy = (_) => 'DIRECT';

Future<HttpServer> _serverWithContent(String content) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  server.listen((request) async {
    await request.drain();
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'choices': [
          {
            'message': {'content': content},
          },
        ],
      }));
    await request.response.close();
  });
  return server;
}

OpenAiCompatibleTranslationService _serviceFor(
  HttpServer server, {
  HttpClient Function()? clientFactory,
}) =>
    OpenAiCompatibleTranslationService(
      endpoint: Uri.parse(
          'http://${server.address.address}:${server.port}/v1/chat/completions'),
      apiKey: 'test-secret',
      model: 'test-model',
      clientFactory: clientFactory ?? _directClient,
    );

void main() {
  test('normalizes common OpenAI-compatible base URLs', () {
    expect(
      normalizeOpenAiCompatibleEndpoint(Uri.parse('https://example.test')),
      Uri.parse('https://example.test/v1/chat/completions'),
    );
    expect(
      normalizeOpenAiCompatibleEndpoint(Uri.parse('https://example.test/')),
      Uri.parse('https://example.test/v1/chat/completions'),
    );
    expect(
      normalizeOpenAiCompatibleEndpoint(Uri.parse('https://example.test/v1')),
      Uri.parse('https://example.test/v1/chat/completions'),
    );
    expect(
      normalizeOpenAiCompatibleEndpoint(
          Uri.parse('https://example.test/v1/chat/completions')),
      Uri.parse('https://example.test/v1/chat/completions'),
    );
  });

  test('reports missing endpoint or API key without a network request', () {
    final missingEndpoint = OpenAiCompatibleTranslationService(
      endpoint: null,
      apiKey: 'test-key',
      model: 'test-model',
    );
    final missingKey = OpenAiCompatibleTranslationService(
      endpoint: Uri.parse('https://example.invalid/v1/chat/completions'),
      apiKey: null,
      model: 'test-model',
    );

    expect(missingEndpoint.status.available, isFalse);
    expect(
        missingEndpoint.status.message, '未配置 AI_VIDEO_TRANSLATION_ENDPOINT。');
    expect(missingKey.status.available, isFalse);
    expect(missingKey.status.message, '未配置 AI_VIDEO_TRANSLATION_API_KEY。');
  });

  test('sends only text and language metadata to the configured endpoint',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = Completer<_CapturedRequest>();
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      received.complete(_CapturedRequest(
        path: request.uri.path,
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
        body: jsonDecode(body) as Map<String, Object?>,
      ));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'choices': [
            {
              'message': {'content': '你好，世界。'},
            },
          ],
        }));
      await request.response.close();
    });
    final service = _serviceFor(server);

    final result = await service.translate(_request());
    final request = await received.future;

    expect(result.segmentId, 'seg-000001');
    expect(result.text, '你好，世界。');
    expect(result.provider, 'openai-compatible');
    expect(request.path, '/v1/chat/completions');
    expect(request.authorization, 'Bearer test-secret');
    expect(request.body['model'], 'test-model');
    expect(request.body['messages'],
        isA<List>().having((messages) => messages.length, 'length', 2));
    expect(request.body.toString(), contains('Hello, world.'));
    expect(request.body.toString(), contains('Source language: en'));
    expect(request.body.toString(), contains('Target language: zh-CN'));
    expect(request.body.toString(), isNot(contains('http://')));
    expect(request.body.toString(), isNot(contains('Cookie')));
    expect(request.body.toString(), isNot(contains('seg-000001')));
  });

  test('renders context lines with explicit markers around the target line',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    String? userContent;
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final messages = body['messages'] as List;
      userContent = (messages.last as Map)['content'] as String;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'choices': [
            {
              'message': {'content': '它很快。'},
            },
          ],
        }));
      await request.response.close();
    });
    final service = _serviceFor(server);

    final result = await service.translate(const TranslationRequest(
      segmentId: 'seg-000003',
      text: 'It is fast.',
      sourceLanguage: 'en',
      targetLanguage: 'zh-CN',
      context: [
        TranslationContextLine(text: 'Look at this car.'),
        TranslationContextLine(text: 'What a car!', translation: '多棒的车！'),
      ],
    ));

    expect(result.text, '它很快。');
    expect(userContent, isNotNull);
    expect(userContent, contains('<<<CONTEXT'));
    expect(userContent, contains('Look at this car.'));
    expect(userContent, contains('[已定译法：多棒的车！]'));
    expect(userContent, contains('CONTEXT>>>'));
    expect(userContent, contains('Translate only this line:'));
    expect(userContent, contains('<<<TEXT'));
    expect(userContent, contains('It is fast.'));
    expect(userContent, contains('TEXT>>>'));
  });

  test('rejects a multi-line answer to a single-line source', () async {
    final server = await _serverWithContent('看这辆车。' '\n' '多棒的车！');
    final service = _serviceFor(server);

    expect(service.translate(_request()), throwsA(isA<FormatException>()));
  });

  test('rejects an answer far longer than any reasonable translation',
      () async {
    final longText = List.filled(40, '这不是一句字幕能装下的内容').join();
    final server = await _serverWithContent(longText);
    final service = _serviceFor(server);

    expect(service.translate(_request()), throwsA(isA<FormatException>()));
  });

  test('accepts a multi-line answer when the source has line breaks', () async {
    final server = await _serverWithContent('你好。' '\n' '世界。');
    final service = _serviceFor(server);

    final result = await service.translate(const TranslationRequest(
      segmentId: 'seg-000002',
      text: 'Hello.' '\n' 'World.',
      sourceLanguage: 'en',
      targetLanguage: 'zh-CN',
    ));

    expect(result.text, '你好。' '\n' '世界。');
  });

  test('rejects an empty compatible response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'choices': []}));
      await request.response.close();
    });
    final service = _serviceFor(server);

    expect(service.translate(_request()), throwsA(isA<FormatException>()));
  });

  test('strips markdown fences from a single response', () async {
    final server = await _serverWithContent('```\n你好，世界。\n```');
    final service = _serviceFor(server);

    final result = await service.translate(_request());
    expect(result.text, '你好，世界。');
  });

  test('strips symmetric wrapping quotes from a single response', () async {
    final server = await _serverWithContent('“你好，世界。”');
    final service = _serviceFor(server);

    final result = await service.translate(_request());
    expect(result.text, '你好，世界。');
  });

  test('rejects a null content response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'choices': [
            {
              'message': {'content': null},
            },
          ],
        }));
      await request.response.close();
    });
    final service = _serviceFor(server);

    expect(service.translate(_request()), throwsA(isA<FormatException>()));
  });

  test('maps HTTP 429 with Retry-After to a retryable provider error',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.tooManyRequests
        ..headers.set(HttpHeaders.retryAfterHeader, '7')
        ..write('{}');
      await request.response.close();
    });
    final service = _serviceFor(server);

    await expectLater(
      service.translate(_request()),
      throwsA(isA<TranslationProviderException>()
          .having((error) => error.retryable, 'retryable', isTrue)
          .having((error) => error.statusCode, 'statusCode', 429)
          .having((error) => error.retryAfter, 'retryAfter',
              const Duration(seconds: 7))),
    );
  });

  test('maps HTTP 500 without Retry-After to a retryable provider error',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('{}');
      await request.response.close();
    });
    final service = _serviceFor(server);

    await expectLater(
      service.translate(_request()),
      throwsA(isA<TranslationProviderException>()
          .having((error) => error.retryable, 'retryable', isTrue)
          .having((error) => error.retryAfter, 'retryAfter', isNull)),
    );
  });

  test('maps HTTP 401 to a fatal provider error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..write('{}');
      await request.response.close();
    });
    final service = _serviceFor(server);

    await expectLater(
      service.translate(_request()),
      throwsA(isA<TranslationProviderException>()
          .having((error) => error.retryable, 'retryable', isFalse)),
    );
  });

  test('reuses one HttpClient across sequential requests', () async {
    final server = await _serverWithContent('你好。');
    var factoryCalls = 0;
    HttpClient countingFactory() {
      factoryCalls++;
      return _directClient();
    }

    final service = _serviceFor(server, clientFactory: countingFactory);

    final first = await service.translate(_request());
    final second = await service.translate(_request());

    expect(first.text, '你好。');
    expect(second.text, '你好。');
    expect(factoryCalls, 1);
  });

  test('keeps the shared client after a timeout abort', () async {
    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requestCount++;
      await request.drain();
      if (requestCount == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'choices': [
            {
              'message': {'content': '你好。'},
            },
          ],
        }));
      await request.response.close();
    });
    var factoryCalls = 0;
    HttpClient countingFactory() {
      factoryCalls++;
      return _directClient();
    }

    final service = _serviceFor(server, clientFactory: countingFactory);
    await expectLater(
      service.translateWithTimeout(
          _request(), const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
    final result = await service.translate(_request());

    expect(result.text, '你好。');
    expect(factoryCalls, 1, reason: '超时只中止单个请求，不应销毁共享连接池。');
  });

  test('cancelActiveRequests rebuilds the client for the next request',
      () async {
    final server = await _serverWithContent('你好。');
    var factoryCalls = 0;
    HttpClient countingFactory() {
      factoryCalls++;
      return _directClient();
    }

    final service = _serviceFor(server, clientFactory: countingFactory);
    await service.translate(_request());
    expect(factoryCalls, 1);

    service.cancelActiveRequests();
    final result = await service.translate(_request());

    expect(result.text, '你好。');
    expect(factoryCalls, 2);
  });

  test('closes the request and reports a timeout when the server stalls',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await request.response.close();
    });
    final service = _serviceFor(server);

    await expectLater(
      service.translateWithTimeout(
        _request(),
        const Duration(milliseconds: 50),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('sends the user glossary in the system prompt of every request',
      () async {
    final capturedBodies = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      capturedBodies.add(await utf8.decoder.bind(request).join());
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'choices': [
            {
              'message': {'content': '春日です。'},
            },
          ],
        }));
      await request.response.close();
    });
    final service = OpenAiCompatibleTranslationService(
      endpoint: Uri.parse(
          'http://${server.address.address}:${server.port}/v1/chat/completions'),
      apiKey: 'test-secret',
      model: 'test-model',
      glossary: const {'ハルヒ': '春日'},
      clientFactory: _directClient,
    );

    final result = await service.translate(_request());

    expect(result.text, '春日です。');
    expect(capturedBodies, hasLength(1));
    expect(capturedBodies.single, contains('Glossary'));
    expect(capturedBodies.single, contains('ハルヒ = 春日'));
    expect(service.diagnostics['术语表条数'], 1);
  });
}

class _CapturedRequest {
  const _CapturedRequest({
    required this.path,
    required this.authorization,
    required this.body,
  });

  final String path;
  final String? authorization;
  final Map<String, Object?> body;
}
