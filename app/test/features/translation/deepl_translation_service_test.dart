import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/translation/translation_service.dart';
import 'package:ai_video_player_next/features/translation/deepl_translation_service.dart';

HttpClient _directClient() => HttpClient()..findProxy = (_) => 'DIRECT';

const _request = TranslationRequest(
  segmentId: 'seg-000001',
  text: 'Hello, world.',
  sourceLanguage: 'en',
  targetLanguage: 'zh-CN',
);

void main() {
  test('reports missing DeepL API key without a network request', () {
    final service = DeepLTranslationService(
      endpoint: Uri.parse('https://api-free.deepl.com/v2/translate'),
      apiKey: null,
    );

    expect(service.status.available, isFalse);
    expect(service.status.message, '未配置 DeepL API Key。');
  });

  test('sends a DeepL text-only request and parses its result', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = Completer<_CapturedRequest>();
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      received.complete(_CapturedRequest(
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
        body: jsonDecode(body) as Map<String, Object?>,
      ));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'translations': [
            {'detected_source_language': 'EN', 'text': '你好，世界。'},
          ],
        }));
      await request.response.close();
    });
    final service = DeepLTranslationService(
      endpoint: Uri.parse(
        'http://${server.address.address}:${server.port}/v2/translate',
      ),
      apiKey: 'test-secret',
      clientFactory: _directClient,
    );

    final result = await service.translate(_request);
    final request = await received.future;

    expect(result.segmentId, _request.segmentId);
    expect(result.text, '你好，世界。');
    expect(result.provider, 'deepl');
    expect(request.authorization, 'DeepL-Auth-Key test-secret');
    expect(request.body['text'], ['Hello, world.']);
    expect(request.body['source_lang'], 'EN');
    expect(request.body['target_lang'], 'ZH');
    expect(request.body.toString(), isNot(contains('Cookie')));
    expect(request.body.toString(), isNot(contains('http://')));
  });

  test('rejects an empty DeepL translation response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'translations': []}));
      await request.response.close();
    });
    final service = DeepLTranslationService(
      endpoint: Uri.parse(
        'http://${server.address.address}:${server.port}/v2/translate',
      ),
      apiKey: 'test-secret',
      clientFactory: _directClient,
    );

    expect(service.translate(_request), throwsA(isA<FormatException>()));
  });
}

class _CapturedRequest {
  const _CapturedRequest({required this.authorization, required this.body});

  final String? authorization;
  final Map<String, Object?> body;
}
