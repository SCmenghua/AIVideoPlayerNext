import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/translation/translation_service.dart';

/// Text-only adapter for an OpenAI-compatible chat-completions endpoint.
/// Media URLs, audio, browser headers and session credentials are deliberately
/// outside this contract and cannot enter the request payload.
class OpenAiCompatibleTranslationService
    implements
        TranslationService,
        TimedBatchTranslationService,
        TranslationServiceRequestCanceller,
        TranslationServiceDiagnosticsProvider,
        TranslationServiceStatusProvider {
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
  final Set<HttpClient> _activeClients = <HttpClient>{};

  @override
  Map<String, Object?> get diagnostics => {
        'Provider': 'openai-compatible',
        'Endpoint': endpoint?.toString() ?? '未配置',
        'Model': model,
      };

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
    final results = await translateBatchWithTimeout(
      [request],
      defaultTranslationRequestTimeout,
    );
    return results.single;
  }

  @override
  Future<List<TranslationResult>> translateBatch(
    List<TranslationRequest> requests,
  ) =>
      translateBatchWithTimeout(requests, defaultTranslationRequestTimeout);

  @override
  Future<List<TranslationResult>> translateBatchWithTimeout(
    List<TranslationRequest> requests,
    Duration timeout,
  ) async {
    if (requests.isEmpty) return const [];
    final serviceStatus = status;
    if (!serviceStatus.available) {
      throw StateError(serviceStatus.message ?? '翻译服务不可用。');
    }
    final client = _clientFactory();
    _activeClients.add(client);
    client.connectionTimeout = timeout;
    var timedOut = false;
    final timeoutTimer = Timer(timeout, () {
      timedOut = true;
      client.close(force: true);
    });
    try {
      final httpRequest = await client.postUrl(endpoint!);
      httpRequest.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      final isBatch = requests.length > 1;
      httpRequest.write(jsonEncode({
        'model': model,
        'temperature': 0,
        'messages': [
          {
            'role': 'system',
            'content': isBatch
                ? 'Translate subtitle segments. Return ONLY a valid JSON '
                    'array, with no markdown fences and no explanation. '
                    'Each input segment must produce exactly one object. '
                    'Every object MUST contain exactly these string keys: '
                    '"id" (copied exactly from the input) and '
                    '"translation" (the translated subtitle). NEVER use '
                    '"text", "source", or "translatedText" as the output '
                    'key. Preserve meaning, names, punctuation and line '
                    'breaks. Do not omit, merge, reorder, or duplicate '
                    'segments. Required shape: '
                    '[{"id":"segment-id","translation":"translated text"}]'
                : 'You translate subtitle text. Return only the translated '
                    'text. Preserve meaning, names, punctuation and line breaks. '
                    'Do not add explanations.',
          },
          {
            'role': 'user',
            'content': isBatch
                ? _batchPrompt(requests)
                : 'Source language: ${requests.single.sourceLanguage}\n'
                    'Target language: ${requests.single.targetLanguage}\n'
                    'Text:\n${requests.single.text}',
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
      if (timedOut) {
        throw TimeoutException('翻译请求超过 ${timeout.inSeconds} 秒。');
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
      if (!isBatch) {
        return [
          TranslationResult(
            segmentId: requests.single.segmentId,
            text: text,
            provider: 'openai-compatible',
          ),
        ];
      }
      return _decodeBatch(text, requests);
    } on Object {
      if (timedOut) {
        throw TimeoutException('翻译请求超过 ${timeout.inSeconds} 秒。');
      }
      rethrow;
    } finally {
      timeoutTimer.cancel();
      client.close(force: true);
      _activeClients.remove(client);
    }
  }

  @override
  void cancelActiveRequests() {
    for (final client in List<HttpClient>.of(_activeClients)) {
      client.close(force: true);
    }
  }

  String _batchPrompt(List<TranslationRequest> requests) => jsonEncode({
        'sourceLanguage': requests.first.sourceLanguage,
        'targetLanguage': requests.first.targetLanguage,
        'segments': requests
            .map((request) => {'id': request.segmentId, 'text': request.text})
            .toList(),
      });

  List<TranslationResult> _decodeBatch(
    String content,
    List<TranslationRequest> requests,
  ) {
    final decoded = jsonDecode(_normalizeBatchJson(content));
    if (decoded is! List) {
      throw const FormatException('批量翻译响应不是 JSON 数组。');
    }
    final expected = {for (final request in requests) request.segmentId};
    final seen = <String>{};
    final results = <TranslationResult>[];
    for (final item in decoded) {
      if (item is! Map || item['id'] is! String) {
        throw const FormatException('批量翻译响应项目格式无效。');
      }
      final id = item['id'] as String;
      final rawTranslation = item['translation'] ?? item['text'];
      if (rawTranslation is! String) {
        throw const FormatException('批量翻译响应项目格式无效。');
      }
      final translation = rawTranslation.trim();
      if (!expected.contains(id) || !seen.add(id) || translation.isEmpty) {
        throw const FormatException('批量翻译响应缺少、重复或未知片段。');
      }
      results.add(TranslationResult(
        segmentId: id,
        text: translation,
        provider: 'openai-compatible',
      ));
    }
    if (seen.length != expected.length) {
      throw const FormatException('批量翻译响应缺少片段。');
    }
    return results;
  }

  String _normalizeBatchJson(String content) {
    final trimmed = content.trim();
    final fenced = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$',
            caseSensitive: false)
        .firstMatch(trimmed);
    return fenced?.group(1)?.trim() ?? trimmed;
  }
}
