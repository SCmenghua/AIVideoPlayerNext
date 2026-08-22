import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/translation/translation_service.dart';

/// Apple Translation provider for iOS 26+. Dart sends only subtitle text,
/// language codes and a request ID over the platform channel; the reply must
/// echo the same request ID or it is rejected.
///
/// On non-iOS platforms, or when the native side reports an unsupported OS,
/// the service reports a clear unavailable status and never fabricates
/// results.
class SystemTranslationService
    implements TranslationService, TranslationServiceStatusProvider {
  SystemTranslationService({bool Function()? isIOS})
      : _isIOS = isIOS ?? _platformIsIOS;

  static const _channel = MethodChannel('ai_video_player/system_translation');

  final bool Function() _isIOS;
  int _requestCounter = 0;
  bool? _nativeAvailable;
  String? _nativeUnavailableMessage;

  /// Completes when the native availability probe has finished. The queue
  /// re-reads [status] on every recognition change, so callers normally do
  /// not need to await this; tests use it for deterministic assertions.
  late final Future<void> readiness = _probeAvailability();

  @override
  TranslationServiceStatus get status {
    if (!_isIOS()) {
      return const TranslationServiceStatus.unavailable(
        provider: 'system-translation',
        message: '系统翻译仅在 iOS 26 或更高版本的设备上可用。',
      );
    }
    final available = _nativeAvailable;
    if (available == null) {
      return const TranslationServiceStatus.unavailable(
        provider: 'system-translation',
        message: '正在检测系统翻译能力……',
      );
    }
    if (!available) {
      return TranslationServiceStatus.unavailable(
        provider: 'system-translation',
        message: _nativeUnavailableMessage ?? '此设备不支持系统翻译。',
      );
    }
    return const TranslationServiceStatus.available(
      provider: 'system-translation',
    );
  }

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    final serviceStatus = status;
    if (!serviceStatus.available) {
      throw StateError(serviceStatus.message ?? '系统翻译不可用。');
    }
    final requestId = 'sys-${_requestCounter++}';
    // The standard codec always decodes maps as Map<Object?, Object?>, so the
    // reply is read defensively instead of relying on a typed cast.
    final reply = await _channel.invokeMethod<Object?>('translate', {
      'requestId': requestId,
      'text': request.text,
      'sourceLanguage': request.sourceLanguage,
      'targetLanguage': request.targetLanguage,
    });
    final values = reply is Map ? reply : const <Object?, Object?>{};
    final echoedRequestId = values['requestId'];
    if (echoedRequestId != requestId) {
      throw StateError('系统翻译响应与请求不匹配。');
    }
    final text = values['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const FormatException('系统翻译返回了空结果。');
    }
    return TranslationResult(
      segmentId: request.segmentId,
      text: text.trim(),
      provider: 'system-translation',
    );
  }

  Future<void> _probeAvailability() async {
    if (!_isIOS()) return;
    try {
      final reply = await _channel.invokeMethod<Object?>('availability');
      final values = reply is Map ? reply : const <Object?, Object?>{};
      _nativeAvailable = values['available'] == true;
      final message = values['message'];
      _nativeUnavailableMessage = message is String ? message : null;
    } on PlatformException catch (error) {
      _nativeAvailable = false;
      _nativeUnavailableMessage = error.message ?? '系统翻译通道不可用。';
    } on MissingPluginException {
      _nativeAvailable = false;
      _nativeUnavailableMessage = '系统翻译桥接未安装（需要更新后的 iOS 构建）。';
    }
  }

  static bool _platformIsIOS() => Platform.isIOS;
}
