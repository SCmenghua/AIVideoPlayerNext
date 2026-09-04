import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/speech/whisper_model_catalog.dart';
import '../speech/whisper_model_store.dart';

/// Install state of every catalog entry, and the downloads in flight.
///
/// Builds ship without weights, so this is what stands between a fresh install
/// and working recognition. It owns the subscriptions rather than the widget so
/// a download survives leaving the settings screen.
class WhisperModelInstallController extends ChangeNotifier {
  WhisperModelInstallController(this.store);

  final WhisperModelStore store;
  final Map<String, WhisperModelProgress> _active = {};
  final Map<String, String> _errors = {};
  final Map<String, StreamSubscription<WhisperModelProgress>> _subscriptions = {};
  Set<String> _installed = const {};
  Map<String, int> _partials = const {};
  bool _loading = true;
  bool _disposed = false;

  bool get loading => _loading;
  Set<String> get installed => _installed;

  bool isInstalled(WhisperModelDescriptor model) => _installed.contains(model.id);
  WhisperModelProgress? progressFor(WhisperModelDescriptor model) =>
      _active[model.id];
  String? errorFor(WhisperModelDescriptor model) => _errors[model.id];

  /// Bytes of an interrupted download still on disk, so the button can say
  /// "继续下载" instead of pretending nothing happened.
  int partialBytesFor(WhisperModelDescriptor model) => _partials[model.id] ?? 0;

  Future<void> refresh() async {
    final installed = await store.installedIds();
    final partials = <String, int>{};
    for (final model in whisperModelCatalog) {
      final bytes = await store.partialBytes(model);
      if (bytes > 0) partials[model.id] = bytes;
    }
    if (_disposed) return;
    _installed = installed;
    _partials = partials;
    _loading = false;
    notifyListeners();
  }

  void download(WhisperModelDescriptor model) {
    if (_disposed || _subscriptions.containsKey(model.id)) return;
    _errors.remove(model.id);
    _active[model.id] = WhisperModelProgress(
      model: model,
      phase: WhisperModelPhase.downloading,
      receivedBytes: partialBytesFor(model),
    );
    notifyListeners();
    _subscriptions[model.id] = store.download(model).listen(
      (progress) {
        if (_disposed) return;
        _active[model.id] = progress;
        notifyListeners();
      },
      onError: (Object error) {
        if (_disposed) return;
        _errors[model.id] = error.toString();
        _active.remove(model.id);
        unawaited(_finish(model));
      },
      onDone: () {
        if (_disposed) return;
        _active.remove(model.id);
        unawaited(_finish(model));
      },
      cancelOnError: true,
    );
  }

  /// Stops a download and keeps what has arrived, so it can be resumed later.
  Future<void> cancel(WhisperModelDescriptor model) async {
    final subscription = _subscriptions.remove(model.id);
    if (subscription == null) return;
    await subscription.cancel();
    _active.remove(model.id);
    await refresh();
  }

  Future<void> delete(WhisperModelDescriptor model) async {
    await cancel(model);
    await store.delete(model);
    _errors.remove(model.id);
    await refresh();
  }

  Future<void> _finish(WhisperModelDescriptor model) async {
    await _subscriptions.remove(model.id)?.cancel();
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions.values) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    super.dispose();
  }
}

/// Settings block listing every installable weight.
class WhisperModelSection extends StatelessWidget {
  const WhisperModelSection({
    super.key,
    required this.controller,
    required this.selectedFileName,
    required this.onSelect,
  });

  final WhisperModelInstallController controller;
  final String selectedFileName;
  final ValueChanged<WhisperModelDescriptor> onSelect;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (controller.installed.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '尚未安装识别模型。下载任意一个后即可开始识别，模型只需下载一次。',
                  style: TextStyle(color: Color(0xFFE0A030)),
                ),
              ),
            for (final model in whisperModelCatalog)
              _WhisperModelTile(
                model: model,
                controller: controller,
                selected: model.fileName == selectedFileName,
                onSelect: () => onSelect(model),
              ),
          ],
        );
      },
    );
  }
}

class _WhisperModelTile extends StatelessWidget {
  const _WhisperModelTile({
    required this.model,
    required this.controller,
    required this.selected,
    required this.onSelect,
  });

  final WhisperModelDescriptor model;
  final WhisperModelInstallController controller;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final installed = controller.isInstalled(model);
    final progress = controller.progressFor(model);
    final error = controller.errorFor(model);
    final partial = controller.partialBytesFor(model);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(model.label,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('${model.sizeLabel} · ${model.license}',
                          style: const TextStyle(color: Color(0xFF9EA7AC))),
                    ],
                  ),
                ),
                if (installed && selected)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text('使用中', style: TextStyle(color: Color(0xFF4CAF50))),
                  )
                else if (installed)
                  TextButton(onPressed: onSelect, child: const Text('使用')),
                if (installed)
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => controller.delete(model),
                  )
                else if (progress != null)
                  TextButton(
                    onPressed: () => controller.cancel(model),
                    child: const Text('取消'),
                  )
                else
                  FilledButton(
                    onPressed: () => controller.download(model),
                    child: Text(partial > 0 ? '继续下载' : '下载'),
                  ),
              ],
            ),
            if (progress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress.phase == WhisperModelPhase.verifying
                    ? null
                    : progress.fraction,
              ),
              const SizedBox(height: 4),
              Text(
                progress.phase == WhisperModelPhase.verifying
                    ? '校验中…'
                    : '${(progress.fraction * 100).toStringAsFixed(1)}%',
                style: const TextStyle(color: Color(0xFF9EA7AC)),
              ),
            ] else if (partial > 0 && !installed) ...[
              const SizedBox(height: 6),
              Text(
                '已下载 ${(partial / model.sizeBytes * 100).toStringAsFixed(1)}%，可继续。',
                style: const TextStyle(color: Color(0xFF9EA7AC)),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 6),
              Text(error, style: const TextStyle(color: Color(0xFFE06C60))),
            ],
          ],
        ),
      ),
    );
  }
}
