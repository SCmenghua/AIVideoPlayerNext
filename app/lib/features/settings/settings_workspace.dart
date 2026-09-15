import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/app_build_info.dart';
import '../../domain/translation/local_translation_model.dart';
import '../../domain/translation/translation_service.dart';
import '../recognition/recognition_service.dart';
import '../recognition/recognition_settings.dart';
import '../recognition/whisper_model_catalog.dart';
import '../recognition/whisper_model_store.dart';
import '../translation/system_translation_service.dart';
import '../translation/translation_model_catalog.dart';
import 'app_settings.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: const SettingsWorkspace(),
      );
}

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
  Map<String, bool> _installed = const {};

  @override
  void initState() {
    super.initState();
    _settingsController = ref.read(appSettingsProvider);
    _settingsController!.addListener(_onSettingsChanged);
    final settings = _settingsController!.snapshot;
    _deeplKey = TextEditingController(text: settings.deeplApiKey ?? '');
    _deeplEndpoint = TextEditingController(text: settings.deeplEndpoint.toString());
    _genericEndpoint = TextEditingController(text: settings.genericEndpoint?.toString() ?? '');
    _genericKey = TextEditingController(text: settings.genericApiKey ?? '');
    _genericModel = TextEditingController(text: settings.genericModel);
    unawaited(_refreshInstalled());
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

  Future<void> _refreshInstalled() async {
    try {
      final store = await ref.read(recognitionServiceProvider).modelStore;
      final installed = <String, bool>{};
      for (final spec in WhisperModelCatalog.all) {
        installed[spec.id] = await store.isInstalled(spec);
      }
      if (mounted) setState(() => _installed = installed);
    } on Object {
      // The store may be unavailable in tests or before the platform is ready.
    }
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
    ref.read(appSettingsProvider).updateDeepL(apiKey: _deeplKey.text, endpoint: _deeplEndpoint.text);
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
    ref.read(appSettingsProvider).updateGenericApi(
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
      final models = await _modelCatalog.fetchModels(endpoint: endpoint, apiKey: _genericKey.text);
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
      if (service is SystemTranslationService) await service.readiness;
      final statusProvider =
          service is TranslationServiceStatusProvider ? service as TranslationServiceStatusProvider : null;
      final status =
          statusProvider?.status ?? const TranslationServiceStatus.available(provider: 'custom');
      if (!status.available) {
        setState(() => _testResult = status.message ?? '翻译服务不可用。');
        return;
      }
      final result = await service
          .translate(TranslationRequest(
            segmentId: 'connection-test',
            text: 'Hello',
            sourceLanguage: 'en',
            targetLanguage: settings.translationTargetLanguage,
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
    final recognition = ref.watch(recognitionServiceProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SettingsSection(
                title: '语音识别',
                icon: Icons.graphic_eq_outlined,
                child: _recognitionSection(settings.recognition, recognition),
              ),
              const SizedBox(height: 12),
              _SettingsSection(
                title: '翻译',
                icon: Icons.translate_outlined,
                child: _translationSection(settings),
              ),
              const SizedBox(height: 12),
              _SettingsSection(
                title: '字幕',
                icon: Icons.subtitles_outlined,
                child: _subtitleSection(settings),
              ),
              const SizedBox(height: 12),
              _SettingsSection(
                title: '播放',
                icon: Icons.play_circle_outline,
                child: _playbackSection(settings),
              ),
              const SizedBox(height: 12),
              _SettingsSection(
                title: '关于',
                icon: Icons.info_outline,
                child: SelectableText(AppBuildInfo.label),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recognitionSection(RecognitionSettings recognition, RecognitionService service) {
    final controller = ref.read(appSettingsProvider);
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    final models = WhisperModelCatalog.recognitionModels
        .where((spec) => WhisperModelCatalog.supports(spec, recognition.language))
        .toList();
    final selectedId = recognition.model.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: recognition.language,
          decoration: const InputDecoration(labelText: '识别原语言', border: OutlineInputBorder()),
          items: recognitionLanguageLabels.entries
              .map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value)))
              .toList(),
          onChanged: (value) {
            if (value != null) controller.setRecognitionLanguage(value);
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: selectedId,
          decoration: const InputDecoration(labelText: 'Whisper 模型', border: OutlineInputBorder()),
          items: models
              .map((spec) => DropdownMenuItem(
                    value: spec.id,
                    child: Text(
                      '${spec.label}${_installed[spec.id] == true ? '' : '（未安装）'}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ))
              .toList(),
          onChanged: (value) => controller.setWhisperModelId(value),
        ),
        const SizedBox(height: 6),
        Text(recognition.model.description, style: TextStyle(color: hint)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final spec in [...models, WhisperModelCatalog.sileroVad])
              _ModelChip(
                spec: spec,
                installed: _installed[spec.id] == true,
                progress: service.status.download?.spec.id == spec.id ? service.status.download : null,
                onInstall: () async {
                  await service.installModel(spec);
                  await _refreshInstalled();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('语音活动检测（VAD）切分窗口'),
          subtitle: const Text('用 Silero VAD 在停顿处切分识别窗口；关闭后退回能量门控。'),
          value: recognition.vadEnabled,
          onChanged: controller.setVadEnabled,
        ),
        Text(
          '模型按需下载到应用数据目录，切换语言或模型后当前媒体会从当前位置重新识别。',
          style: TextStyle(color: hint),
        ),
      ],
    );
  }

  Widget _translationSection(AppSettings settings) {
    final controller = ref.read(appSettingsProvider);
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<TranslationMode>(
          segments: const [
            ButtonSegment(value: TranslationMode.deepl, label: Text('DeepL')),
            ButtonSegment(value: TranslationMode.genericApi, label: Text('通用 API')),
            ButtonSegment(value: TranslationMode.systemTranslation, label: Text('系统翻译')),
            ButtonSegment(value: TranslationMode.localModel, label: Text('本地模型')),
          ],
          selected: {settings.translationMode},
          onSelectionChanged: (selection) {
            controller.setTranslationMode(selection.single);
            setState(() => _testResult = null);
          },
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: settings.translationTargetLanguage,
          decoration: const InputDecoration(labelText: '翻译目标语言', border: OutlineInputBorder()),
          items: translationTargetLanguageLabels.entries
              .map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value)))
              .toList(),
          onChanged: (value) {
            if (value != null) controller.setTranslationTargetLanguage(value);
          },
        ),
        const SizedBox(height: 14),
        switch (settings.translationMode) {
          TranslationMode.deepl => _deepLForm(),
          TranslationMode.genericApi => _genericApiForm(),
          TranslationMode.systemTranslation => Text(
              '使用 Apple 系统翻译（iOS 26 或更高版本）。翻译在本机完成；'
              '请先在系统设置 › 通用 › 翻译 中下载所需语言包。'
              '不支持的语言组合或未下载语言包时，字幕将保留原文并显示失败原因。',
              style: TextStyle(color: hint),
            ),
          TranslationMode.localModel => _localModelForm(settings.localTranslationModel),
        },
        if (settings.translationMode != TranslationMode.localModel) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _testing ? null : _testConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check_outlined),
                label: const Text('测试连接'),
              ),
              if (_testResult != null) ...[
                const SizedBox(width: 12),
                Expanded(child: Text(_testResult!, style: TextStyle(color: hint))),
              ],
            ],
          ),
        ],
        const SizedBox(height: 16),
        _translationSchedulingControls(settings),
      ],
    );
  }

  Widget _subtitleSection(AppSettings settings) {
    final controller = ref.read(appSettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<SubtitleDisplayMode>(
          segments: const [
            ButtonSegment(value: SubtitleDisplayMode.bilingual, label: Text('双语')),
            ButtonSegment(value: SubtitleDisplayMode.original, label: Text('原文')),
            ButtonSegment(value: SubtitleDisplayMode.translation, label: Text('译文')),
          ],
          selected: {settings.subtitleDisplayMode},
          onSelectionChanged: (selection) => controller.setSubtitleDisplayMode(selection.single),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('字号'),
            Expanded(
              child: Slider(
                value: settings.subtitleFontScale,
                min: 0.7,
                max: 1.8,
                divisions: 11,
                label: '${(settings.subtitleFontScale * 100).round()}%',
                onChanged: controller.setSubtitleFontScale,
              ),
            ),
            SizedBox(width: 48, child: Text('${(settings.subtitleFontScale * 100).round()}%')),
          ],
        ),
      ],
    );
  }

  Widget _playbackSection(AppSettings settings) {
    final controller = ref.read(appSettingsProvider);
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<PlaybackStartStrategy>(
          segments: const [
            ButtonSegment(value: PlaybackStartStrategy.subtitlePriority, label: Text('字幕优先')),
            ButtonSegment(value: PlaybackStartStrategy.translationPriority, label: Text('翻译优先')),
            ButtonSegment(value: PlaybackStartStrategy.playbackPriority, label: Text('播放优先')),
          ],
          selected: {settings.playbackStartStrategy},
          onSelectionChanged: (selection) => controller.setPlaybackStartStrategy(selection.single),
        ),
        const SizedBox(height: 6),
        Text(
          switch (settings.playbackStartStrategy) {
            PlaybackStartStrategy.subtitlePriority => '字幕落后时短暂暂停等待，最多 8 秒后继续播放。',
            PlaybackStartStrategy.translationPriority => '译文落后时短暂暂停等待，最多 8 秒后继续播放。',
            PlaybackStartStrategy.playbackPriority => '不等待字幕，播放永不因识别暂停。',
          },
          style: TextStyle(color: hint),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('打开媒体后等待首条字幕再开始播放'),
          subtitle: const Text('最多等待 10 秒；按播放键可随时跳过。'),
          value: settings.waitForSubtitlePreparation,
          onChanged: controller.setWaitForSubtitlePreparation,
        ),
      ],
    );
  }

  Widget _deepLForm() => Column(
        children: [
          TextField(
            controller: _deeplKey,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'DeepL API Key', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _deeplEndpoint,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'DeepL Endpoint', border: OutlineInputBorder()),
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
            decoration: const InputDecoration(labelText: 'Endpoint', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _genericKey,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'API Key', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _genericModel,
                  decoration: const InputDecoration(labelText: 'Model', border: OutlineInputBorder()),
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
              initialValue: _models.contains(_genericModel.text) ? _genericModel.text : null,
              decoration: const InputDecoration(labelText: '已下载模型', border: OutlineInputBorder()),
              items: _models.map((model) => DropdownMenuItem(value: model, child: Text(model))).toList(),
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

  Widget _localModelForm(LocalTranslationModel selected) {
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<LocalTranslationModel>(
          initialValue: selected,
          decoration: const InputDecoration(labelText: '本地翻译模型', border: OutlineInputBorder()),
          items: LocalTranslationModel.values
              .map((model) => DropdownMenuItem(value: model, child: Text(model.displayName)))
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
          '仓库：${selected.repository}\n格式与运行时：${selected.runtimeDescription}\n'
          '许可证：${selected.license}\n${selected.expectedWeightDescription}',
          style: TextStyle(color: hint),
        ),
        const SizedBox(height: 6),
        Text('本地翻译运行时尚未接入，此模式暂不产生译文。',
            style: TextStyle(color: Theme.of(context).colorScheme.tertiary)),
      ],
    );
  }

  Widget _translationSchedulingControls(AppSettings settings) {
    final controller = ref.read(appSettingsProvider);
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('翻译调度', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        if (settings.translationMode == TranslationMode.deepl)
          Row(
            children: [
              Expanded(
                child: _IntegerSetting(
                  label: '每批字幕数',
                  value: settings.translationBatchSize,
                  minimum: 1,
                  maximum: 20,
                  onChanged: controller.setTranslationBatchSize,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _IntegerSetting(
                  label: '并发请求数',
                  value: settings.translationMaxConcurrent,
                  minimum: 1,
                  maximum: 20,
                  onChanged: controller.setTranslationMaxConcurrent,
                ),
              ),
            ],
          )
        else if (settings.translationMode != TranslationMode.systemTranslation)
          _IntegerSetting(
            label: '并发请求数',
            value: settings.translationMaxConcurrent,
            minimum: 1,
            maximum: 20,
            onChanged: controller.setTranslationMaxConcurrent,
          )
        else
          Text('系统翻译在本机串行执行，一次翻译一句，并发设置不适用。', style: TextStyle(color: hint)),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('翻译携带上文'),
          subtitle: const Text('逐句翻译时附带最近几句原文和已定译法，提高指代和术语的一致性。'),
          value: settings.translationContextEnabled,
          onChanged: controller.setTranslationContextEnabled,
        ),
      ],
    );
  }
}

class _ModelChip extends StatelessWidget {
  const _ModelChip({
    required this.spec,
    required this.installed,
    required this.progress,
    required this.onInstall,
  });

  final WhisperModelSpec spec;
  final bool installed;
  final ModelDownloadProgress? progress;
  final Future<void> Function() onInstall;

  @override
  Widget build(BuildContext context) {
    final downloading = progress != null && !progress!.isFailed && !progress!.isDone;
    return ActionChip(
      avatar: Icon(
        installed
            ? Icons.check_circle_outline
            : downloading
                ? Icons.downloading_outlined
                : Icons.download_outlined,
        size: 18,
      ),
      label: Text(
        downloading
            ? '${spec.fileName} ${(progress!.fraction * 100).toStringAsFixed(0)}%'
            : '${spec.fileName} · ${spec.sizeLabel}',
      ),
      onPressed: installed || downloading ? null : onInstall,
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: scheme.primary),
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
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        child: Row(
          children: [
            IconButton(
              tooltip: '减少$label',
              onPressed: value <= minimum ? null : () => onChanged(value - 1),
              icon: const Icon(Icons.remove_outlined),
            ),
            Expanded(
              child: Text('$value',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
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
