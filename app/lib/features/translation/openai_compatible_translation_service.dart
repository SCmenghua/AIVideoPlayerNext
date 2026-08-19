import 'dart:convert';
import 'dart:io';

import '../../domain/translation/translation_service.dart';

/// Text-only adapter for an OpenAI-compatible chat-completions endpoint.
/// Media URLs, audio, browser headers and session credentials are deliberately
/// outside this contract and cannot enter the request payload.
class OpenAiCompatibleTranslationService
    implements TranslationService, TranslationServiceStatusProvider {
  OpenAiCompatibleTranslationService({
    required Uri? endpoint,
    required this.apiKey,
    required this.model,
    HttpClient Function()? clientFactory,
  })  : endpoint = endpoint == null
            ? null
            : normalizeOpenAiCompatibleEndpoint(endpoint),
        _clientFactory = clientFactory ?? HttpClient.new;

  factory OpenAiCompatibleTranslationService.fromEnvironment() {
    final rawEndpoint = Platform.environment['AI_VIDEO_TRANSLATION_ENDPOINT'];
    final endpoint = rawEndpoint == null ? null : Uri.tryParse(rawEndpoint);
    final configuredModel =
        Platform.environment['AI_VIDEO_TRANSLATION_MODEL']?.trim();
    return OpenAiCompatibleTranslationService(
      endpoint: endpoint,
      apiKey: Platform.environment['AI_VIDEO_TRANSLATION_API_KEY']?.trim(),
      model: configuredModel == null || configuredModel.isEmpty
          ? 'gpt-4.1-mini'
          : configuredModel,
    );
  }

  final Uri? endpoint;
  final String? apiKey;
  final String model;
  final HttpClient Function() _clientFactory;

  @override
  TranslationServiceStatus get status {
    if (endpoint == null ||
        (endpoint!.scheme != 'https' && endpoint!.scheme != 'http')) {
      return const TranslationServiceStatus.unavailable(
        provider: 'openai-compatible',
        message: '未配置 AI_VIDEO_TRANSLATION_ENDPOINT。',
      );
    }
    if (apiKey == null || apiKey!.isEmpty) {
      return const TranslationServiceStatus.unavailable(
        provider: 'openai-compatible',
        message: '未配置 AI_VIDEO_TRANSLATION_API_KEY。',
      );
    }
    return const TranslationServiceStatus.available(
      provider: 'openai-compatible',
    );
  }

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    final serviceStatus = status;
    if (!serviceStatus.available) {
      throw StateError(serviceStatus.message ?? '翻译服务不可用。');
    }
    final client = _clientFactory();
    try {
      final httpRequest = await client.postUrl(endpoint!);
      httpRequest.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      httpRequest.write(jsonEncode({
        'model': model,
        'temperature': 0,
        'messages': [
          {
            'role': 'system',
            'content': 'You translate subtitle text. Return only the translated '
                'text. Preserve meaning, names, punctuation and line breaks. '
                'Do not add explanations.',
          },
          {
            'role': 'user',
            'content': 'Source language: ${request.sourceLanguage}\n'
                'Target language: ${request.targetLanguage}\n'
                'Text:\n${request.text}',
          },
        ],
      }));
      final response = await httpRequest.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          '翻译服务返回 HTTP ${response.statusCode}。',
          uri: endpoint,
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('翻译响应不是 JSON 对象。');
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        throw const FormatException('翻译响应缺少 choices。');
      }
      final message = (choices.first as Map)['message'];
      if (message is! Map) throw const FormatException('翻译响应缺少 message。');
      final content = message['content'];
      final text = content is String ? content.trim() : '';
      if (text.isEmpty) throw const FormatException('翻译响应为空。');
      return TranslationResult(
        segmentId: request.segmentId,
        text: text,
        provider: 'openai-compatible',
      );
    } finally {
      client.close(force: true);
    }
  }
}
