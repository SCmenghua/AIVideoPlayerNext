import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/translation/translation_service.dart';
import 'package:ai_video_player_next/features/translation/system_translation_service.dart';

const _channel = MethodChannel('ai_video_player/system_translation');

const _request = TranslationRequest(
  segmentId: 'seg-000001',
  text: 'Hello, world.',
  sourceLanguage: 'en',
  targetLanguage: 'zh-CN',
);

void _mockChannel(
    List<MethodCall> calls, Object? Function(MethodCall) handler) {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    calls.add(call);
    return handler(call);
  });
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('reports unavailable on non-iOS platforms without channel calls',
      () async {
    final calls = <MethodCall>[];
    _mockChannel(calls, (_) => throw StateError('must not be called'));

    final service = SystemTranslationService(isIOS: () => false);
    await service.readiness;

    expect(service.status.available, isFalse);
    expect(service.status.message, contains('iOS 26'));
    expect(calls, isEmpty);
    expect(
      service.translate(_request),
      throwsA(isA<StateError>()),
    );
  });

  test('becomes available when the native bridge supports translation',
      () async {
    final calls = <MethodCall>[];
    _mockChannel(calls, (call) {
      if (call.method == 'availability') return {'available': true};
      throw StateError('unexpected ${call.method}');
    });

    final service = SystemTranslationService(isIOS: () => true);
    await service.readiness;

    expect(service.status.available, isTrue);
    expect(calls, hasLength(1));
  });

  test('reports the native unavailable reason', () async {
    _mockChannel(
        <MethodCall>[],
        (_) => {
              'available': false,
              'message': '系统翻译需要 iOS 26 或更高版本。',
            });

    final service = SystemTranslationService(isIOS: () => true);
    await service.readiness;

    expect(service.status.available, isFalse);
    expect(service.status.message, '系统翻译需要 iOS 26 或更高版本。');
  });

  test('translates a segment and echoes the request id', () async {
    _mockChannel(<MethodCall>[], (call) {
      if (call.method == 'availability') return {'available': true};
      if (call.method == 'translate') {
        final args = call.arguments as Map;
        return {
          'requestId': args['requestId'],
          'text': '你好，世界。',
        };
      }
      throw StateError('unexpected ${call.method}');
    });

    final service = SystemTranslationService(isIOS: () => true);
    await service.readiness;

    final result = await service.translate(_request);

    expect(result.segmentId, 'seg-000001');
    expect(result.text, '你好，世界。');
    expect(result.provider, 'system-translation');
  });

  test('rejects a reply whose request id does not match', () async {
    _mockChannel(<MethodCall>[], (call) {
      if (call.method == 'availability') return {'available': true};
      if (call.method == 'translate') {
        return {'requestId': 'someone-else', 'text': '你好。'};
      }
      throw StateError('unexpected ${call.method}');
    });

    final service = SystemTranslationService(isIOS: () => true);
    await service.readiness;

    expect(
      service.translate(_request),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects an empty native translation', () async {
    _mockChannel(<MethodCall>[], (call) {
      if (call.method == 'availability') return {'available': true};
      if (call.method == 'translate') {
        final args = call.arguments as Map;
        return {'requestId': args['requestId'], 'text': '   '};
      }
      throw StateError('unexpected ${call.method}');
    });

    final service = SystemTranslationService(isIOS: () => true);
    await service.readiness;

    expect(
      service.translate(_request),
      throwsA(isA<FormatException>()),
    );
  });

  test('maps a missing native bridge to a clear unavailable status', () async {
    _mockChannel(<MethodCall>[], (_) => throw MissingPluginException());

    final service = SystemTranslationService(isIOS: () => true);
    await service.readiness;

    expect(service.status.available, isFalse);
    expect(service.status.message, contains('桥接未安装'));
  });

  test('request ids are unique across calls', () async {
    final seenIds = <String>[];
    _mockChannel(<MethodCall>[], (call) {
      if (call.method == 'availability') return {'available': true};
      if (call.method == 'translate') {
        final args = call.arguments as Map;
        seenIds.add(args['requestId'] as String);
        return {'requestId': args['requestId'], 'text': '你好。'};
      }
      throw StateError('unexpected ${call.method}');
    });

    final service = SystemTranslationService(isIOS: () => true);
    await service.readiness;
    await service.translate(_request);
    await service.translate(_request);

    expect(seenIds, hasLength(2));
    expect(seenIds.toSet(), hasLength(2));
  });

  test('probes availability eagerly even when nobody awaits readiness',
      () async {
    final calls = <MethodCall>[];
    _mockChannel(calls, (call) {
      if (call.method == 'availability') return {'available': true};
      throw StateError('unexpected ${call.method}');
    });

    final service = SystemTranslationService(isIOS: () => true);
    // No reference to service.readiness: the constructor must have started
    // the probe, otherwise playback gates would wait on "detecting" forever.
    await Future<void>.delayed(Duration.zero);

    expect(calls.map((call) => call.method), ['availability']);
    expect(service.status.available, isTrue);
  });

  test('treats missing language packs as a fatal provider error', () async {
    _mockChannel(<MethodCall>[], (call) {
      if (call.method == 'availability') return {'available': true};
      if (call.method == 'translate') {
        throw PlatformException(
          code: 'PREPARE',
          message: '系统翻译语言包尚未就绪',
        );
      }
      throw StateError('unexpected ${call.method}');
    });

    final service = SystemTranslationService(isIOS: () => true);
    await service.readiness;

    await expectLater(
      service.translate(_request),
      throwsA(isA<TranslationProviderException>()
          .having((error) => error.retryable, 'retryable', isFalse)),
    );
  });

  test('keeps transient session errors retryable', () async {
    _mockChannel(<MethodCall>[], (call) {
      if (call.method == 'availability') return {'available': true};
      if (call.method == 'translate') {
        throw PlatformException(
          code: 'SESSION',
          message: '系统翻译会话失败',
        );
      }
      throw StateError('unexpected ${call.method}');
    });

    final service = SystemTranslationService(isIOS: () => true);
    await service.readiness;

    await expectLater(
      service.translate(_request),
      throwsA(isA<TranslationProviderException>()
          .having((error) => error.retryable, 'retryable', isTrue)),
    );
  });
}
