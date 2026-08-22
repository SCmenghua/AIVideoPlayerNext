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

List<TranslationRequest> _batchRequests() => const [
      TranslationRequest(
        segmentId: 'seg-000001',
        text: 'Hello.',
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
      ),
      TranslationRequest(
        segmentId: 'seg-000002',
        text: 'Goodbye.',
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
      ),
    ];

HttpClient _directClient() => HttpClient()..findProxy = (_) => 'DIRECT';

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
    final service = OpenAiCompatibleTranslationService(
      endpoint: Uri.parse(
          'http://${server.address.address}:${server.port}/v1/chat/completions'),
      apiKey: 'test-secret',
      model: 'test-model',
      clientFactory: _directClient,
    );

    final result = await service.translate(_request());
    final request = await received.future;

    expect(result.segmentId, 'seg-000001');
    expect(result.text, '你好，世界。');
    expect(result.provider, 'openai-compatible');
    expect(request.path, '/v1/chat/completions');
    expect(request.authorization, 'Bearer test-secret');
    expect(request.body['model'], 'test-model');
    expect(request.body.toString(), contains('Hello, world.'));
    expect(request.body.toString(), contains('Source language: en'));
    expect(request.body.toString(), contains('Target language: zh-CN'));
    expect(request.body.toString(), isNot(contains('http://')));
    expect(request.body.toString(), isNot(contains('Cookie')));
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
    final service = OpenAiCompatibleTranslationService(
      endpoint: Uri.parse(
          'http://${server.address.address}:${server.port}/translate'),
      apiKey: 'test-secret',
      model: 'test-model',
      clientFactory: _directClient,
    );

    expect(service.translate(_request()), throwsA(isA<FormatException>()));
  });

  test('sends batches with stable IDs and maps JSON results by ID', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = Completer<Map<String, Object?>>();
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      received.complete(jsonDecode(body) as Map<String, Object?>);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode([
                  {'id': 'seg-000002', 'translation': '再见。'},
                  {'id': 'seg-000001', 'translation': '你好。'},
                ]),
              },
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
      clientFactory: _directClient,
    );

    final results = await service.translateBatch(_batchRequests());
    final body = await received.future;
    final messages = body['messages'] as List<Object?>;
    final system = messages.first as Map<String, Object?>;
    final user = messages.last as Map<String, Object?>;
    final systemContent = system['content'] as String;
    final content = user['content'] as String;
    expect(systemContent, contains('"id"'));
    expect(systemContent, contains('"translation"'));
    expect(systemContent, contains('Required shape'));
    expect(content, contains('seg-000001'));
    expect(content, contains('seg-000002'));
    expect(results.map((result) => result.segmentId),
        containsAllInOrder(['seg-000002', 'seg-000001']));
    expect(results.map((result) => result.text),
        containsAllInOrder(['再见。', '你好。']));
  });

  test('accepts common text aliases and JSON markdown fences in batch output',
      () async {
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
              'message': {
                'content': '```json\n${jsonEncode([
                  {'id': 'seg-000001', 'text': '你好。'},
                  {'id': 'seg-000002', 'translation': '再见。'},
                ])}\n```',
              },
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
      clientFactory: _directClient,
    );

    final results = await service.translateBatch(_batchRequests());

    expect(results.map((result) => result.segmentId),
        containsAllInOrder(['seg-000001', 'seg-000002']));
    expect(results.map((result) => result.text),
        containsAllInOrder(['你好。', '再见。']));
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
    final service = OpenAiCompatibleTranslationService(
      endpoint: Uri.parse(
          'http://${server.address.address}:${server.port}/v1/chat/completions'),
      apiKey: 'test-secret',
      model: 'test-model',
      clientFactory: _directClient,
    );

    await expectLater(
      service.translateBatchWithTimeout(
        [_request()],
        const Duration(milliseconds: 50),
      ),
      throwsA(isA<TimeoutException>()),
    );
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
