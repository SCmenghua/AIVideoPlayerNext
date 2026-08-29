import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/app_build_info.dart';
import '../../domain/translation/translation_service.dart';
import '../../domain/translation/local_translation_model.dart';
import '../audio/recognition_controller.dart';
import '../translation/system_translation_service.dart';
import '../translation/translation_model_catalog.dart';
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
  bool _loadingModels = false;
  List<String> _models = const [];
  int _modelRequestGeneration = 0;
  final TranslationModelCatalog _modelCatalog = TranslationModelCatalog();
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
    if (parseOpenAiCompatibleEndpoint(_genericEndpoint.text) == null) {
      setState(() => _testResult = '通用 API 配置未应用：Endpoint 不是合法的 HTTP(S) 地址。');
      return;
    }
    ref.read(appSettingsProvider).updateGenericApi(
          endpoint: _genericEndpoint.text,
          apiKey: _genericKey.text,
          model: _genericModel.text,
        );
    setState(() => _testResult = '通用 API 配置已应用。');
  }

  Future<void> _loadModels() async {
    final endpoint = parseOpenAiCompatibleEndpoint(_genericEndpoint.text);
    if (endpoint == null) {
      setState(() => _testResult = '模型列表下载失败：Endpoint 不是合法的 HTTP(S) 地址。');
      return;
    }
    final controller = ref.read(appSettingsProvider);
    controller.updateGenericApi(
      endpoint: _genericEndpoint.text,
      apiKey: _genericKey.text,
      model: _genericModel.text,
    );
    final generation = ++_modelRequestGeneration;
    setState(() {
      _loadingModels = true;
      _testResult = null;
    });
    try {
      final models = await _modelCatalog.fetchModels(
        endpoint: endpoint,
        apiKey: _genericKey.text,
      );
      if (!mounted || generation != _modelRequestGeneration) return;
      setState(() {
        _models = models;
        _testResult = '已下载 ${models.length} 个模型。';
      });
    } on Object catch (error) {
      if (!mounted || generation != _modelRequestGeneration) return;
      setState(() => _testResult = '模型列表下载失败：${_errorMessage(error)}');
    } finally {
      if (mounted && generation == _modelRequestGeneration) {
        setState(() => _loadingModels = false);
      }
    }
  }

  String _errorMessage(Object error) {
    if (error is TranslationProviderException) return error.message;
    if (error is HttpException) return error.message;
    if (error is FormatException) return error.message;
    if (error is TimeoutException) return '翻译请求超时';
    return error.runtimeType.toString();
  }

  Future<void> _testConnection() async {
    final settings = ref.read(appSettingsProvider);
    if (settings.translationMode == TranslationMode.deepl) {
      _applyDeepL();
    } else if (settings.translationMode == TranslationMode.genericApi) {
      _applyGeneric();
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final service = createTranslationService(settings.snapshot);
      // The system-translation probe runs asynchronously; the status only
      // becomes meaningful once it has settled.
      if (service is SystemTranslationService) {
        await service.readiness;
      }
      final statusProvider = service is TranslationServiceStatusProvider
          ? service as TranslationServiceStatusProvider
          : null;
      final status = statusProvider?.status ??
          const TranslationServiceStatus.available(provider: 'custom');
      if (!status.available) {
        setState(() => _testResult = status.message ?? '翻译服务不可用。');
        return;
      }
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
      setState(() => _testResult = '连接失败：${_errorMessage(error)}');
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
                          value: TranslationMode.systemTranslation,
                          label: Text('系统翻译'),
                          icon: Icon(Icons.phone_iphone),
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
                    else if (settings.translationMode ==
                        TranslationMode.systemTranslation)
                      _systemTranslationForm()
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
                    const SizedBox(height: 16),
                    _translationSchedulingControls(settings),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SettingsSection(
                title: '字幕显示',
                icon: Icons.subtitles_outlined,
                child: SegmentedButton<SubtitleDisplayMode>(
                  segments: const [
                    ButtonSegment(
                      value: SubtitleDisplayMode.bilingual,
                      label: Text('双语'),
                      icon: Icon(Icons.view_agenda_outlined),
                    ),
                    ButtonSegment(
                      value: SubtitleDisplayMode.original,
                      label: Text('原文'),
                      icon: Icon(Icons.text_fields_outlined),
                    ),
                    ButtonSegment(
                      value: SubtitleDisplayMode.translation,
                      label: Text('翻译'),
                      icon: Icon(Icons.translate_outlined),
                    ),
                  ],
                  selected: {settings.subtitleDisplayMode},
                  onSelectionChanged: (selection) => ref
                      .read(appSettingsProvider)
                      .setSubtitleDisplayMode(selection.single),
                ),
              ),
              const SizedBox(height: 12),
              _SettingsSection(
                title: '播放启动策略',
                icon: Icons.play_circle_outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<PlaybackStartStrategy>(
                      segments: const [
                        ButtonSegment(
                          value: PlaybackStartStrategy.subtitlePriority,
                          label: Text('字幕优先'),
                          icon: Icon(Icons.subtitles_outlined),
                        ),
                        ButtonSegment(
                          value: PlaybackStartStrategy.translationPriority,
                          label: Text('翻译优先'),
                          icon: Icon(Icons.translate_outlined),
                        ),
                        ButtonSegment(
                          value: PlaybackStartStrategy.playbackPriority,
                          label: Text('播放优先'),
                          icon: Icon(Icons.play_arrow_outlined),
                        ),
                      ],
                      selected: {settings.playbackStartStrategy},
                      onSelectionChanged: (selection) => ref
                          .read(appSettingsProvider)
                          .setPlaybackStartStrategy(selection.single),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('等待前两条翻译或跳过四个窗口'),
                      subtitle: const Text('仅控制自动开始播放前的翻译准备门槛。'),
                      value: settings.waitForSubtitlePreparation,
                      onChanged: (value) => ref
                          .read(appSettingsProvider)
                          .setWaitForSubtitlePreparation(value),
                    ),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _genericModel,
                  decoration: const InputDecoration(
                    labelText: 'Model',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                tooltip: '下载模型列表',
                onPressed: _loadingModels ? null : _loadModels,
                icon: _loadingModels
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
              ),
            ],
          ),
          if (_models.isNotEmpty) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _models.contains(_genericModel.text)
                  ? _genericModel.text
                  : null,
              decoration: const InputDecoration(
                labelText: '已下载模型',
                border: OutlineInputBorder(),
              ),
              items: _models
                  .map((model) => DropdownMenuItem<String>(
                        value: model,
                        child: Text(model),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                _genericModel.text = value;
                ref.read(appSettingsProvider).setGenericModel(value);
                setState(() {});
              },
            ),
          ],
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

  Widget _systemTranslationForm() => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '使用 Apple 系统翻译（iOS 26 或更高版本）。翻译在本机完成；'
            '请先在系统设置 › 通用 › 翻译 中下载所需语言包，'
            '后台字幕翻译不会弹出系统的下载确认。'
            '不支持的语言组合或未下载语言包时，字幕将保留原文并显示失败原因。'
            'Windows 与 Android 上此模式不可用。',
            style: TextStyle(color: Color(0xFF9EA7AC)),
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

  Widget _translationSchedulingControls(AppSettings settings) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('翻译调度', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          if (settings.translationMode == TranslationMode.deepl) ...[
            Row(
              children: [
                Expanded(
                  child: _IntegerSetting(
                    label: '每批字幕数',
                    value: settings.translationBatchSize,
                    minimum: 1,
                    maximum: 20,
                    onChanged:
                        ref.read(appSettingsProvider).setTranslationBatchSize,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _IntegerSetting(
                    label: '并发请求数',
                    value: settings.translationMaxConcurrent,
                    minimum: 1,
                    maximum: 20,
                    onChanged:
                        ref.read(appSettingsProvider).setTranslationMaxConcurrent,
                  ),
                ),
              ],
            ),
          ] else if (settings.translationMode !=
              TranslationMode.systemTranslation) ...[
            _IntegerSetting(
              label: '并发请求数',
              value: settings.translationMaxConcurrent,
              minimum: 1,
              maximum: 20,
              onChanged:
                  ref.read(appSettingsProvider).setTranslationMaxConcurrent,
            ),
          ] else ...[
            const Text(
              '系统翻译在本机串行执行，一次翻译一句，并发设置不适用。',
              style: TextStyle(color: Color(0xFF9EA7AC)),
            ),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('翻译携带上文'),
            subtitle: const Text(
              '通用 API 逐句翻译时附带最近几句原文和已定译法作为参考，'
              '提高指代和术语的准确性；不影响并发。',
            ),
            value: settings.translationContextEnabled,
            onChanged: (value) => ref
                .read(appSettingsProvider)
                .setTranslationContextEnabled(value),
          ),
          Text(
            settings.translationMode == TranslationMode.deepl
                ? '设置会立即应用到后续翻译请求；批次不足时最多等待约 300 ms 后发送。'
                : settings.translationMode == TranslationMode.systemTranslation
                    ? '系统翻译由 iOS 在本机完成，串行返回；语言包需已在系统设置中下载。'
                    : '通用 API 逐句翻译、直接并发，不组批；设置会立即应用到后续翻译请求。',
            style: const TextStyle(color: Color(0xFF9EA7AC)),
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
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF191C1E),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xFF2C3235)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
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
        ),
      );
}

class _IntegerSetting extends StatelessWidget {
  const _IntegerSetting({
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int minimum;
  final int maximum;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: '减少$label',
              onPressed: value <= minimum ? null : () => onChanged(value - 1),
              icon: const Icon(Icons.remove_outlined),
            ),
            Expanded(
              child: Text(
                '$value',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: '增加$label',
              onPressed: value >= maximum ? null : () => onChanged(value + 1),
              icon: const Icon(Icons.add_outlined),
            ),
          ],
        ),
      );
}
