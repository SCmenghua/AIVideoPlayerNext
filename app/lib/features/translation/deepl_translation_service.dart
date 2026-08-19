import 'dart:convert';
import 'dart:io';

import '../../domain/translation/translation_service.dart';

class DeepLTranslationService
    implements TranslationService, TranslationServiceStatusProvider {
  DeepLTranslationService({
    required this.endpoint,
    required this.apiKey,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final Uri? endpoint;
  final String? apiKey;
  final HttpClient Function() _clientFactory;

  @override
  TranslationServiceStatus get status {
    if (endpoint == null ||
        (endpoint!.scheme != 'https' && endpoint!.scheme != 'http')) {
      return const TranslationServiceStatus.unavailable(
        provider: 'deepl',
        message: '未配置 DeepL Endpoint。',
      );
    }
    if (apiKey == null || apiKey!.trim().isEmpty) {
      return const TranslationServiceStatus.unavailable(
        provider: 'deepl',
        message: '未配置 DeepL API Key。',
      );
    }
    return const TranslationServiceStatus.available(provider: 'deepl');
  }

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    final serviceStatus = status;
    if (!serviceStatus.available) {
      throw StateError(serviceStatus.message ?? 'DeepL 翻译服务不可用。');
    }
    final client = _clientFactory();
    try {
      final httpRequest = await client.postUrl(endpoint!);
      httpRequest.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'DeepL-Auth-Key $apiKey');
      final payload = <String, Object>{
        'text': [request.text],
        'target_lang': _targetLanguage(request.targetLanguage),
      };
      final sourceLanguage = _sourceLanguage(request.sourceLanguage);
      if (sourceLanguage != null) payload['source_lang'] = sourceLanguage;
      httpRequest.write(jsonEncode(payload));
      final response = await httpRequest.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'DeepL 返回 HTTP ${response.statusCode}。',
          uri: endpoint,
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('DeepL 响应不是 JSON 对象。');
      final translations = decoded['translations'];
      if (translations is! List ||
          translations.isEmpty ||
          translations.first is! Map) {
        throw const FormatException('DeepL 响应缺少 translations。');
      }
      final text = (translations.first as Map)['text'];
      if (text is! String || text.trim().isEmpty) {
        throw const FormatException('DeepL 翻译结果为空。');
      }
      return TranslationResult(
        segmentId: request.segmentId,
        text: text.trim(),
        provider: 'deepl',
      );
    } finally {
      client.close(force: true);
    }
  }

  static String? _sourceLanguage(String language) {
    final normalized = language.trim().toLowerCase().replaceAll('_', '-');
    final base = normalized.split('-').first;
    return switch (base) {
      'en' => 'EN',
      'ja' => 'JA',
      'ko' => 'KO',
      'zh' => 'ZH',
      _ => null,
    };
  }

  static String _targetLanguage(String language) {
    final normalized = language.trim().toLowerCase().replaceAll('_', '-');
    return switch (normalized) {
      'zh' || 'zh-cn' || 'zh-hans' => 'ZH',
      'en-us' => 'EN-US',
      'en-gb' => 'EN-GB',
      _ => normalized.split('-').first.toUpperCase(),
    };
  }
}
