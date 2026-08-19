import '../../domain/translation/local_translation_model.dart';
import '../../domain/translation/translation_service.dart';

/// Reports the Gemma candidate until its official native runtime bridge exists.
class LocalModelTranslationService
    implements TranslationService, TranslationServiceStatusProvider {
  LocalModelTranslationService({required this.model});

  final LocalTranslationModel model;

  @override
  TranslationServiceStatus get status => TranslationServiceStatus.unavailable(
        provider: 'local-${model.directoryName}',
        message:
            '${model.displayName} 是本地翻译主候选，等待 LiteRT-LM Windows/iOS runtime spike；.safetensors 不能直接作为运行包。',
      );

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    throw StateError(status.message ?? '本地模型翻译运行时不可用。');
  }
}
