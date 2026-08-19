import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/app_build_info.dart';
import '../../domain/translation/translation_service.dart';
import '../../domain/translation/local_translation_model.dart';
import '../audio/recognition_controller.dart';
import 'app_settings.dart';

class SettingsWorkspace extends ConsumerStatefulWidget {
  const SettingsWorkspace({super.key});

  @override
  ConsumerState<SettingsWorkspace> createState() => _SettingsWorkspaceState();
}

class _SettingsWorkspaceState extends ConsumerState<SettingsWorkspace> {
  late final TextEditingController _deeplKey;
  late final TextEditingController _deeplEndpoint;
  late final TextEditingController _genericEndpoint;
  late final TextEditingController _genericKey;
  late final TextEditingController _genericModel;
  String? _testResult;
  bool _testing = false;
  AppSettingsController? _settingsController;

  @override
  void initState() {
    super.initState();
    _settingsController = ref.read(appSettingsProvider);
    _settingsController!.addListener(_onSettingsChanged);
    final settings = _settingsController!.snapshot;
    _deeplKey = TextEditingController(text: settings.deeplApiKey ?? '');
    _deeplEndpoint =
        TextEditingController(text: settings.deeplEndpoint.toString());
    _genericEndpoint =
        TextEditingController(text: settings.genericEndpoint?.toString() ?? '');
    _genericKey = TextEditingController(text: settings.genericApiKey ?? '');
    _genericModel = TextEditingController(text: settings.genericModel);
  }

  @override
  void dispose() {
    _settingsController?.removeListener(_onSettingsChanged);
    _deeplKey.dispose();
    _deeplEndpoint.dispose();
    _genericEndpoint.dispose();
    _genericKey.dispose();
    _genericModel.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    final settings = ref.read(appSettingsProvider).snapshot;
    _replaceText(_deeplKey, settings.deeplApiKey ?? '');
    _replaceText(_deeplEndpoint, settings.deeplEndpoint.toString());
    _replaceText(_genericEndpoint, settings.genericEndpoint?.toString() ?? '');
    _replaceText(_genericKey, settings.genericApiKey ?? '');
    _replaceText(_genericModel, settings.genericModel);
    setState(() {});
  }

  void _replaceText(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
      composing: TextRange.empty,
    );
  }

  void _applyDeepL() {
    ref.read(appSettingsProvider).updateDeepL(
          apiKey: _deeplKey.text,
          endpoint: _deeplEndpoint.text,
        );
    setState(() => _testResult = 'DeepL 配置已应用。');
  }

  void _applyGeneric() {
    ref.read(appSettingsProvider).updateGenericApi(
          endpoint: _genericEndpoint.text,
          apiKey: _genericKey.text,
          model: _genericModel.text,
        );
    setState(() => _testResult = '通用 API 配置已应用。');
  }

  Future<void> _testConnection() async {
    final settings = ref.read(appSettingsProvider);
    if (settings.translationMode == TranslationMode.deepl) {
      _applyDeepL();
    } else if (settings.translationMode == TranslationMode.genericApi) {
      _applyGeneric();
    } else {
      return;
    }
    final service = createTranslationService(settings.snapshot);
    final statusProvider = service is TranslationServiceStatusProvider
        ? service as TranslationServiceStatusProvider
        : null;
    final status = statusProvider?.status ??
        const TranslationServiceStatus.available(provider: 'custom');
    if (!status.available) {
      setState(() => _testResult = status.message ?? '翻译服务不可用。');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final result = await service
          .translate(const TranslationRequest(
            segmentId: 'connection-test',
            text: 'Hello',
            sourceLanguage: 'en',
            targetLanguage: 'zh-CN',
          ))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() => _testResult = '连接成功：${result.text}');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _testResult = '连接失败：${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).snapshot;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('设置', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 18),
              _SettingsSection(
                title: '识别策略',
                icon: Icons.graphic_eq_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<RecognitionPrefetchMode>(
                      segments: const [
                        ButtonSegment(
                          value: RecognitionPrefetchMode.fullMedia,
                          label: Text('完整预识别'),
                          icon: Icon(Icons.all_inclusive_outlined),
                        ),
                        ButtonSegment(
                          value: RecognitionPrefetchMode.boundedAhead,
                          label: Text('按需预取'),
                          icon: Icon(Icons.timelapse_outlined),
                        ),
                      ],
                      selected: {settings.prefetchMode},
                      onSelectionChanged: (selection) => ref
                          .read(appSettingsProvider)
                          .setPrefetchMode(selection.single),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      settings.prefetchMode == RecognitionPrefetchMode.fullMedia
                          ? '识别会持续处理至媒体结束。'
                          : '识别保持约 20 至 45 秒的前瞻缓冲。',
                      style: const TextStyle(color: Color(0xFF9EA7AC)),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '大幅跳转时，两个策略都会优先处理当前位置附近内容，然后继续原有遍历。',
                      style: TextStyle(color: Color(0xFF9EA7AC)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SettingsSection(
                title: '翻译方式',
                icon: Icons.translate_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<TranslationMode>(
                      segments: const [
                        ButtonSegment(
                          value: TranslationMode.deepl,
                          label: Text('DeepL'),
                          icon: Icon(Icons.language_outlined),
                        ),
                        ButtonSegment(
                          value: TranslationMode.genericApi,
                          label: Text('通用 API'),
                          icon: Icon(Icons.api_outlined),
                        ),
                        ButtonSegment(
                          value: TranslationMode.localModel,
                          label: Text('本地模型'),
                          icon: Icon(Icons.memory_outlined),
                        ),
                      ],
                      selected: {settings.translationMode},
                      onSelectionChanged: (selection) {
                        ref
                            .read(appSettingsProvider)
                            .setTranslationMode(selection.single);
                        setState(() => _testResult = null);
                      },
                    ),
                    const SizedBox(height: 14),
                    if (settings.translationMode == TranslationMode.deepl)
                      _deepLForm()
                    else if (settings.translationMode ==
                        TranslationMode.genericApi)
                      _genericApiForm()
                    else
                      _localModelForm(settings.localTranslationModel),
                    if (settings.translationMode !=
                        TranslationMode.localModel) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _testing ? null : _testConnection,
                            icon: _testing
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.network_check_outlined),
                            label: const Text('测试连接'),
                          ),
                          if (_testResult != null) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _testResult!,
                                style:
                                    const TextStyle(color: Color(0xFF9EA7AC)),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SettingsSection(
                title: '应用信息',
                icon: Icons.info_outline,
                child: SelectableText(AppBuildInfo.label),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deepLForm() => Column(
        children: [
          TextField(
            controller: _deeplKey,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'DeepL API Key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _deeplEndpoint,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'DeepL Endpoint',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _applyDeepL,
              icon: const Icon(Icons.check_outlined),
              label: const Text('应用 DeepL 配置'),
            ),
          ),
        ],
      );

  Widget _genericApiForm() => Column(
        children: [
          TextField(
            controller: _genericEndpoint,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Endpoint',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _genericKey,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'API Key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _genericModel,
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _applyGeneric,
              icon: const Icon(Icons.check_outlined),
              label: const Text('应用通用 API 配置'),
            ),
          ),
        ],
      );

  Widget _localModelForm(LocalTranslationModel selected) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<LocalTranslationModel>(
            initialValue: selected,
            decoration: const InputDecoration(
              labelText: '本地翻译模型',
              border: OutlineInputBorder(),
            ),
            items: LocalTranslationModel.values
                .map((model) => DropdownMenuItem<LocalTranslationModel>(
                      value: model,
                      child: Text(model.displayName),
                    ))
                .toList(),
            onChanged: (value) {
              if (value != null) {
                ref.read(appSettingsProvider).setLocalTranslationModel(value);
                setState(() => _testResult = null);
              }
            },
          ),
          const SizedBox(height: 10),
          Text(
            '仓库：${selected.repository}\n'
            '格式与运行时：${selected.runtimeDescription}\n'
            '许可证：${selected.license}\n'
            '${selected.expectedWeightDescription}',
            style: const TextStyle(color: Color(0xFF9EA7AC)),
          ),
          const SizedBox(height: 10),
          const Text(
            'Gemma + LiteRT-LM 是当前主候选；Windows/iOS runtime spike 通过前不会开始本地推理。NLLB/CTranslate2 保留为专业备选。',
            style: TextStyle(color: Color(0xFFFFD166)),
          ),
        ],
      );
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF191C1E),
          border: Border.all(color: const Color(0xFF2C3235)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFF5ED6A0)),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      );
}
