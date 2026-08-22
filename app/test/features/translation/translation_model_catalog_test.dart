import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/translation/translation_service.dart';
import 'package:ai_video_player_next/features/translation/translation_model_catalog.dart';

HttpClient _directClient() => HttpClient()..findProxy = (_) => 'DIRECT';

void main() {
  test('parses endpoint forms and rejects unsafe URLs', () {
    expect(
      parseOpenAiCompatibleEndpoint('api.example.test'),
      Uri.parse('https://api.example.test/v1/chat/completions'),
    );
    expect(
      parseOpenAiCompatibleEndpoint('http://api.example.test/v1'),
      Uri.parse('http://api.example.test/v1/chat/completions'),
    );
    expect(
      parseOpenAiCompatibleEndpoint(
          'https://api.example.test/v1/chat/completions'),
      Uri.parse('https://api.example.test/v1/chat/completions'),
    );
    expect(parseOpenAiCompatibleEndpoint('ftp://api.example.test'), isNull);
    expect(parseOpenAiCompatibleEndpoint('https://user:pass@example.test'),
        isNull);
    expect(parseOpenAiCompatibleEndpoint('https://example.test/#fragment'),
        isNull);
  });

  test('fetches model IDs in server order and removes duplicates', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requestSeen = Completer<HttpRequest>();
    server.listen((request) async {
      requestSeen.complete(request);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'data': [
            {'id': 'model-a'},
            {'id': 'model-b'},
            {'id': 'model-a'},
            {'id': '  '},
            {'id': 3},
          ],
        }));
      await request.response.close();
    });
    final catalog = TranslationModelCatalog(clientFactory: _directClient);

    final models = await catalog.fetchModels(
      endpoint: Uri.parse('http://${server.address.address}:${server.port}/v1'),
      apiKey: 'secret',
    );
    final request = await requestSeen.future;

    expect(models, ['model-a', 'model-b']);
    expect(request.uri.path, '/v1/models');
    expect(request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer secret');
  });

  test('rejects malformed and empty model responses', () {
    expect(
      () => TranslationModelCatalog.parseModelIds({'data': []}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => TranslationModelCatalog.parseModelIds({'data': 'invalid'}),
      throwsA(isA<FormatException>()),
    );
  });
}
