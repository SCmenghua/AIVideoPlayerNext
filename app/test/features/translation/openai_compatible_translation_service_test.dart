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
