import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/translation/translation_service.dart';

/// Text-only adapter for an OpenAI-compatible chat-completions endpoint.
/// Each request translates exactly one subtitle segment and the model returns
/// plain translated text; the segment mapping stays local so the model never
/// has to echo IDs or structured JSON. Connections are pooled and reused
/// across requests, and a timeout aborts only its own request.
class OpenAiCompatibleTranslationService
    implements
        TranslationService,
        TimedTranslationService,
        TranslationServiceRequestCanceller,
        TranslationServiceDiagnosticsProvider,
        TranslationServiceStatusProvider {
  OpenAiCompatibleTranslationService({
    required Uri? endpoint,
    required this.apiKey,
    required this.model,
    this.glossary = const {},
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

  static const _userAgent = 'ai-video-player-next/0.8';

  final Uri? endpoint;
  final String? apiKey;
  final String model;

  /// User-defined term mappings applied consistently to every request, e.g.
  /// character names or honorifics that must translate the same way.
  final Map<String, String> glossary;
  final HttpClient Function() _clientFactory;
  final Set<HttpClientRequest> _activeRequests = <HttpClientRequest>{};
  HttpClient? _sharedClient;

  @override
  Map<String, Object?> get diagnostics => {
        'Provider': 'openai-compatible',
        'Endpoint': endpoint?.toString() ?? '未配置',
        'Model': model,
        '术语表条数': glossary.length,
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
  Future<TranslationResult> translate(TranslationRequest request) =>
      translateWithTimeout(request, defaultTranslationRequestTimeout);

  @override
  Future<TranslationResult> translateWithTimeout(
    TranslationRequest request,
    Duration timeout,
  ) async {
    final serviceStatus = status;
    if (!serviceStatus.available) {
      throw StateError(serviceStatus.message ?? '翻译服务不可用。');
    }
    final client = _clientForRequest();
    var timedOut = false;
    HttpClientRequest? httpRequest;
    final timeoutTimer = Timer(timeout, () {
      timedOut = true;
      httpRequest?.abort(TimeoutException('翻译请求超过 ${timeout.inSeconds} 秒。'));
    });
    try {
      httpRequest = await client.postUrl(endpoint!);
      _activeRequests.add(httpRequest);
      httpRequest.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..set(HttpHeaders.userAgentHeader, _userAgent);
      httpRequest.write(jsonEncode({
        'model': model,
        'temperature': 0,
        'messages': [
          {'role': 'system', 'content': _systemPrompt()},
          {
            'role': 'user',
            'content': _userPrompt(request),
          },
        ],
      }));
      final response = await httpRequest.close();
      final body = await utf8.decoder.bind(response).join();
      final statusCode = response.statusCode;
      if (statusCode == HttpStatus.tooManyRequests ||
          statusCode == HttpStatus.serviceUnavailable ||
          statusCode == HttpStatus.badGateway ||
          statusCode == HttpStatus.gatewayTimeout ||
          statusCode == HttpStatus.requestTimeout ||
          statusCode >= 500) {
        throw TranslationProviderException(
          '翻译服务返回 HTTP $statusCode。',
          statusCode: statusCode,
          retryable: true,
          retryAfter: _retryAfter(response.headers),
        );
      }
      if (statusCode < 200 || statusCode >= 300) {
        throw TranslationProviderException(
          '翻译服务返回 HTTP $statusCode。',
          statusCode: statusCode,
          retryable: false,
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
      final text = _cleanResponseText(content is String ? content : '');
      if (text.isEmpty) throw const FormatException('翻译响应为空。');
      _validateResponseShape(text, request);
      return TranslationResult(
        segmentId: request.segmentId,
        text: text,
        provider: 'openai-compatible',
      );
    } on Object {
      if (timedOut) {
        throw TimeoutException('翻译请求超过 ${timeout.inSeconds} 秒。');
      }
      rethrow;
    } finally {
      timeoutTimer.cancel();
      if (httpRequest != null) _activeRequests.remove(httpRequest);
    }
  }

  /// One pooled client survives across requests; keep-alive connections are
  /// reused instead of paying DNS/TCP/TLS (and proxy tunnel) per request.
  HttpClient _clientForRequest() => _sharedClient ??= (_clientFactory()
    ..connectionTimeout = defaultTranslationRequestTimeout
    ..idleTimeout = const Duration(seconds: 90));

  /// Server-requested retry delay, honored up to one minute so a large
  /// Retry-After cannot stall the queue indefinitely.
  static Duration? _retryAfter(HttpHeaders headers) {
    final raw = headers.value(HttpHeaders.retryAfterHeader);
    final seconds = raw == null ? null : int.tryParse(raw.trim());
    if (seconds == null || seconds <= 0) return null;
    return Duration(seconds: seconds.clamp(1, 60));
  }

  /// System prompt. The glossary is applied for every request of the session
  /// so names, honorifics and recurring terms stay consistent.
  String _systemPrompt() {
    const base = 'You translate subtitle text. Return only the '
        'translated text. Preserve meaning, names, punctuation and '
        'line breaks. Do not add explanations, quotes or markdown. '
        'When previous lines are given as context, use them only to '
        'resolve meaning and keep terminology consistent; never '
        'translate, repeat or summarize the context lines.';
    if (glossary.isEmpty) return base;
    final terms = StringBuffer()
      ..writeln()
      ..writeln('Glossary (translate these exactly as given, consistently):');
    for (final entry in glossary.entries) {
      terms.writeln('- ${entry.key} = ${entry.value}');
    }
    return base + terms.toString();
  }

  /// Builds the user message. Without context this is the plain single-line
  /// form; with context the preceding lines are fenced off with explicit
  /// markers so the model translates only the marked line.
  static String _userPrompt(TranslationRequest request) {
    final buffer = StringBuffer()
      ..writeln('Source language: ${request.sourceLanguage}')
      ..writeln('Target language: ${request.targetLanguage}');
    if (request.context.isEmpty) {
      buffer
        ..writeln('Text:')
        ..writeln(request.text);
      return buffer.toString();
    }
    buffer
      ..writeln('Previous lines (context only, do NOT translate them):')
      ..writeln('<<<CONTEXT');
    for (final line in request.context) {
      final previous =
          line.translation == null || line.translation!.trim().isEmpty
              ? ''
              : '  [已定译法：${line.translation!.trim()}]';
      buffer.writeln('${line.text}$previous');
    }
    buffer
      ..writeln('CONTEXT>>>')
      ..writeln('Translate only this line:')
      ..writeln('<<<TEXT')
      ..writeln(request.text)
      ..writeln('TEXT>>>');
    return buffer.toString();
  }

  /// Rejects responses whose shape suggests the model translated the context
  /// block instead of the single marked line: more lines than the source, or
  /// a length far beyond any reasonable translation of it.
  static void _validateResponseShape(String text, TranslationRequest request) {
    final sourceLineCount = request.text.trim().split(RegExp(r'\r?\n')).length;
    final responseLineCount = text.trim().split(RegExp(r'\r?\n')).length;
    if (responseLineCount > sourceLineCount) {
      throw const FormatException('译文行数多于源句，疑似翻译了上下文。');
    }
    final maximumLength = request.text.length * 6 + 40;
    if (text.length > maximumLength) {
      throw const FormatException('译文长度异常，疑似翻译了上下文。');
    }
  }

  static String _cleanResponseText(String raw) {
    var text = raw.trim();
    final fenced =
        RegExp(r'^```(?:[a-zA-Z]+)?\s*([\s\S]*?)\s*```$').firstMatch(text);
    if (fenced != null) text = fenced.group(1)!.trim();
    const quotePairs = [('“', '”'), ('"', '"'), ("'", "'"), ('‘', '’')];
    for (final (open, close) in quotePairs) {
      if (text.length >= 2 && text.startsWith(open) && text.endsWith(close)) {
        final inner = text.substring(1, text.length - 1).trim();
        if (inner.isNotEmpty) {
          text = inner;
          break;
        }
      }
    }
    return text;
  }

  @override
  void cancelActiveRequests() {
    for (final request in List<HttpClientRequest>.of(_activeRequests)) {
      request.abort();
    }
    _activeRequests.clear();
    _sharedClient?.close(force: true);
    _sharedClient = null;
  }
}
