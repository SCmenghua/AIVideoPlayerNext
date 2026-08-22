import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/translation/translation_service.dart';

/// Fetches and validates model identifiers from an OpenAI-compatible server.
class TranslationModelCatalog {
  TranslationModelCatalog({HttpClient Function()? clientFactory})
      : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  Future<List<String>> fetchModels({
    required Uri endpoint,
    String? apiKey,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final normalized = parseOpenAiCompatibleEndpoint(endpoint.toString());
    if (normalized == null) {
      throw const FormatException('Endpoint 必须是合法的 HTTP(S) 地址。');
    }
    final client = _clientFactory();
    try {
      final request =
          await client.getUrl(_modelsEndpoint(normalized)).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, ContentType.json.value);
      final key = apiKey?.trim();
      if (key != null && key.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      }
      final response = await request.close().timeout(timeout);
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          '模型服务返回 HTTP ${response.statusCode}。',
          uri: _modelsEndpoint(normalized),
        );
      }
      return parseModelIds(jsonDecode(body));
    } finally {
      client.close(force: true);
    }
  }

  static List<String> parseModelIds(Object? decoded) {
    if (decoded is! Map) {
      throw const FormatException('模型响应不是 JSON 对象。');
    }
    final data = decoded['data'];
    if (data is! List) {
      throw const FormatException('模型响应缺少 data 数组。');
    }
    final models = <String>[];
    final seen = <String>{};
    for (final item in data) {
      if (item is! Map) continue;
      final id = item['id'];
      if (id is String && id.trim().isNotEmpty) {
        final value = id.trim();
        if (seen.add(value)) models.add(value);
      }
    }
    if (models.isEmpty) {
      throw const FormatException('模型列表为空或不包含有效模型 ID。');
    }
    return models;
  }

  static Uri _modelsEndpoint(Uri endpoint) {
    final path = endpoint.path;
    if (path.endsWith('/v1/chat/completions')) {
      final base = path.substring(0, path.length - '/chat/completions'.length);
      return endpoint.replace(
        path: '$base/models',
      );
    }
    if (path.endsWith('/v1')) {
      return endpoint.replace(path: '$path/models');
    }
    return endpoint.replace(path: '/v1/models');
  }
}
