import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_build_info.dart';
import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../core/diagnostics/recognition_result_store.dart';
import '../../domain/audio/audio_models.dart';
import '../../domain/speech/speech_models.dart';
import '../../domain/subtitles/transcript_document.dart';
import '../../domain/translation/translation_service.dart';
import '../translation/transcript_translation_queue.dart';

class DiagnosticsWorkspace extends StatelessWidget {
  const DiagnosticsWorkspace({
    required this.logs,
    required this.results,
    this.recognition,
    this.translationServiceStatus,
    this.translationQueue,
    super.key,
  });

  final DiagnosticLogService logs;
  final RecognitionResultStore results;
  final RecognitionDiagnostics? recognition;
  final TranslationServiceStatus? translationServiceStatus;
  final TranscriptTranslationQueue? translationQueue;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([
          logs,
          results,
          if (translationQueue != null) translationQueue!,
        ]),
        builder: (context, _) {
          final entries = logs.entries.reversed.toList(growable: false);
          final recognitions = results.recognitions;
          final translationResults = results.translationResults;
          final translatedCount = translationResults
              .where((result) =>
                  result.translation.status ==
                  TranscriptTranslationStatus.translated)
              .length;
          final translationStatus = translationServiceStatus;
          final queue = translationQueue;
          return Column(
            children: [
              if (recognition != null)
                _RecognitionSummary(
                  diagnostics: recognition!,
                  translationQueue: queue,
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final panels = [
                      _DiagnosticsPanel(
                        title: '诊断日志',
                        icon: Icons.bug_report_outlined,
                        accent: const Color(0xFFE95636),
                        count: entries.length,
                        subtitle: AppBuildInfo.label,
                        actions: _LogActions(
                            logs: logs, enabled: entries.isNotEmpty),
                        child: entries.isEmpty
                            ? const _EmptyPanel(message: '尚无诊断日志。')
                            : ListView.separated(
                                padding: const EdgeInsets.all(10),
                                itemCount: entries.length,
                                separatorBuilder: (context, index) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, index) =>
                                    _DiagnosticEntryTile(entry: entries[index]),
                              ),
                      ),
                      _DiagnosticsPanel(
                        title: '识别结果',
                        icon: Icons.graphic_eq_outlined,
                        accent: const Color(0xFF62C96B),
                        count: recognitions.length,
                        subtitle: '后台持续推进，不跟随播放器位置筛选',
                        actions: _ResultActions(
                          logs: logs,
                          results: results,
                          kind: RecognitionResultKind.recognition,
                          enabled: recognitions.isNotEmpty,
                        ),
                        child: recognitions.isEmpty
                            ? const _EmptyPanel(message: '尚无识别结果。')
                            : ListView.separated(
                                padding: const EdgeInsets.all(10),
                                itemCount: recognitions.length,
                                separatorBuilder: (context, index) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, index) =>
                                    _RecognitionResultTile(
                                  event: recognitions[index],
                                ),
                              ),
                      ),
                      _DiagnosticsPanel(
                        title: '翻译结果',
                        icon: Icons.translate_outlined,
                        accent: const Color(0xFF4C8DF6),
                        count: translationResults.length,
                        subtitle: translationStatus == null
                            ? '翻译服务初始化中'
                            : !translationStatus.available
                                ? translationStatus.message ?? '翻译服务不可用'
                                : '后台队列：${queue?.activeCount ?? 0} 正在翻译，'
                                    '${queue?.waitingCount ?? 0} 等待中',
                        actions: _ResultActions(
                          logs: logs,
                          results: results,
                          kind: RecognitionResultKind.translation,
                          enabled: translatedCount > 0,
                        ),
                        child: translationResults.isEmpty
                            ? _EmptyPanel(
                                message: translationStatus?.available == false
                                    ? translationStatus!.message ?? '翻译服务不可用。'
                                    : '等待稳定识别结果进入翻译队列。',
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.all(10),
                                itemCount: translationResults.length,
                                separatorBuilder: (context, index) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, index) {
                                  final result = translationResults[index];
                                  return _TranslationResultTile(
                                    event: result.event,
                                    translation: result.translation,
                                  );
                                },
                              ),
                      ),
                    ];
                    if (constraints.maxWidth >= 900) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: panels[0]),
                          Expanded(child: panels[1]),
                          Expanded(child: panels[2]),
                        ],
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.all(10),
                      itemCount: panels.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (_, index) => SizedBox(
                        height: 380,
                        child: panels[index],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      );
}

class _DiagnosticsPanel extends StatelessWidget {
  const _DiagnosticsPanel({
    required this.title,
    required this.icon,
    required this.accent,
    required this.count,
    required this.subtitle,
    required this.actions,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Color accent;
  final int count;
  final String subtitle;
  final Widget actions;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF191C1E),
          border: Border.all(color: accent, width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: accent),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$title ($count)'),
                        Text(
                          subtitle,
                          maxLines: 3,
                          overflow: TextOverflow.fade,
                          softWrap: true,
                          style: const TextStyle(
                            color: Color(0xFF9EA7AC),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions,
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: child),
          ],
        ),
      );
}

class _LogActions extends StatelessWidget {
  const _LogActions({required this.logs, required this.enabled});

  final DiagnosticLogService logs;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionButton(
            icon: Icons.content_copy_outlined,
            tooltip: '复制诊断日志',
            enabled: enabled,
            onPressed: () async {
              await logs.copyToClipboard();
              if (!context.mounted) return;
              _showExportMessage(context, '诊断日志已复制到剪贴板。');
            },
          ),
          _ActionButton(
            icon: Icons.download_outlined,
            tooltip: '导出诊断日志',
            enabled: enabled,
            onPressed: () async {
              final path = await logs.saveAsTextFile();
              if (!context.mounted) return;
              if (path != null) {
                _showExportMessage(context, '诊断日志已保存为 TXT 文件。');
              }
            },
          ),
          if (defaultTargetPlatform != TargetPlatform.windows)
            _ActionButton(
              icon: Icons.ios_share_outlined,
              tooltip: '分享诊断日志',
              enabled: enabled,
              onPressed: () async {
                final box = context.findRenderObject() as RenderBox?;
                await logs.export(
                  sharePositionOrigin: box == null
                      ? null
                      : box.localToGlobal(Offset.zero) & box.size,
                );
              },
            ),
          _ActionButton(
            icon: Icons.delete_outline,
            tooltip: '清空诊断日志',
            enabled: enabled,
            onPressed: () async => logs.clear(),
          ),
        ],
      );
}

class _ResultActions extends StatelessWidget {
  const _ResultActions({
    required this.logs,
    required this.results,
    required this.kind,
    required this.enabled,
  });

  final DiagnosticLogService logs;
  final RecognitionResultStore results;
  final RecognitionResultKind kind;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final label = kind == RecognitionResultKind.recognition ? '识别结果' : '翻译结果';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionButton(
          icon: Icons.content_copy_outlined,
          tooltip: '复制$label',
          enabled: enabled,
          onPressed: () async {
            await results.copyToClipboard(kind);
            if (!context.mounted) return;
            _showExportMessage(context, '$label已复制到剪贴板。');
          },
        ),
        _ActionButton(
          icon: Icons.download_outlined,
          tooltip: '导出$label',
          enabled: enabled,
          onPressed: () async {
            final path = await results.saveAsTextFile(kind);
            if (!context.mounted) return;
            if (path != null) {
              _showExportMessage(context, '$label已保存为 TXT 文件。');
            }
          },
        ),
        if (defaultTargetPlatform != TargetPlatform.windows)
          _ActionButton(
            icon: Icons.ios_share_outlined,
            tooltip: '分享$label',
            enabled: enabled,
            onPressed: () async {
              final box = context.findRenderObject() as RenderBox?;
              await results.export(
                kind,
                sharePositionOrigin: box == null
                    ? null
                    : box.localToGlobal(Offset.zero) & box.size,
              );
            },
          ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        onPressed: enabled
            ? () async {
                try {
                  await onPressed();
                } catch (error, stackTrace) {
                  if (!context.mounted) return;
                  logsFor(context)?.error('诊断日志', '导出区域失败', {
                    '错误类型': error.runtimeType,
                    '错误': error,
                    '堆栈': stackTrace,
                  });
                  _showExportMessage(context, '操作失败，请稍后重试。');
                }
              }
            : null,
        tooltip: tooltip,
        icon: Icon(icon),
      );
}

DiagnosticLogService? logsFor(BuildContext context) {
  final workspace =
      context.findAncestorWidgetOfExactType<DiagnosticsWorkspace>();
  return workspace?.logs;
}

void _showExportMessage(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF9EA7AC)),
          ),
        ),
      );
}

class _RecognitionResultTile extends StatelessWidget {
  const _RecognitionResultTile({required this.event});

  final RecognitionEvent event;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_formatMediaTime(event.start)} - ${_formatMediaTime(event.end)}',
              style: const TextStyle(color: Color(0xFF76DA82), fontSize: 11),
            ),
            const SizedBox(height: 4),
            Text(event.text),
          ],
        ),
      );
}

class _TranslationResultTile extends StatelessWidget {
  const _TranslationResultTile({
    required this.event,
    required this.translation,
  });

  final RecognitionEvent event;
  final TranscriptTranslation translation;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_formatMediaTime(event.start)} - ${_formatMediaTime(event.end)}',
              style: const TextStyle(color: Color(0xFF7EAAFA), fontSize: 11),
            ),
            const SizedBox(height: 4),
            Text(
              _translationLabel(translation),
              style: TextStyle(
                color: _translationColor(translation.status),
                fontSize: 11,
              ),
            ),
            if (translation.text.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(translation.text),
            ],
          ],
        ),
      );
}

String _translationLabel(TranscriptTranslation translation) =>
    switch (translation.status) {
      TranscriptTranslationStatus.pending => '等待翻译',
      TranscriptTranslationStatus.translating => '翻译中',
      TranscriptTranslationStatus.translated =>
        '已翻译${translation.provider == null ? '' : ' · ${translation.provider}'}',
      TranscriptTranslationStatus.failed =>
        '翻译失败${translation.error == null ? '' : ' · ${translation.error}'}',
    };

Color _translationColor(TranscriptTranslationStatus status) => switch (status) {
      TranscriptTranslationStatus.pending => const Color(0xFF9EA7AC),
      TranscriptTranslationStatus.translating => const Color(0xFFFFD166),
      TranscriptTranslationStatus.translated => const Color(0xFF7EAAFA),
      TranscriptTranslationStatus.failed => const Color(0xFFFF8A80),
    };

String _formatMediaTime(Duration value) =>
    '${value.inMinutes.toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}.${(value.inMilliseconds % 1000).toString().padLeft(3, '0')}';

class _RecognitionSummary extends StatelessWidget {
  const _RecognitionSummary({
    required this.diagnostics,
    required this.translationQueue,
  });

  final RecognitionDiagnostics diagnostics;
  final TranscriptTranslationQueue? translationQueue;

  @override
  Widget build(BuildContext context) {
    final window = diagnostics.lastWindow;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
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
              const Icon(Icons.graphic_eq_outlined, size: 18),
              const SizedBox(width: 8),
              const Text('实时识别'),
              const Spacer(),
              Text(_decoderLabel(diagnostics.decoder.state)),
            ],
          ),
          const SizedBox(height: 8),
          _WhisperStatusLine(status: diagnostics.recognizer),
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              _Metric(
                label: '请求后端',
                value: diagnostics.recognizer.backendStatus.requestedLabel,
              ),
              _Metric(
                label: '实际后端',
                value: diagnostics.recognizer.backendStatus.actualLabel,
              ),
              _Metric(
                label: 'GPU 已启用',
                value:
                    diagnostics.recognizer.backendStatus.gpuEnabled ? '是' : '否',
              ),
              _Metric(
                label: '设备',
                value: diagnostics.recognizer.backendStatus.deviceName.isEmpty
                    ? '未报告'
                    : diagnostics.recognizer.backendStatus.deviceName,
              ),
              _Metric(
                label: '回退原因',
                value: diagnostics.recognizer.backendStatus.fallbackLabel,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              _Metric(label: '队列', value: '${diagnostics.queueDepth}'),
              _Metric(label: '已识别', value: '${diagnostics.windowsRecognized}'),
              _Metric(label: '已跳过', value: '${diagnostics.windowsSkipped}'),
              _Metric(label: '失败', value: '${diagnostics.windowsFailed}'),
              _Metric(
                label: '播放位置',
                value: _formatDuration(diagnostics.playbackPosition),
              ),
              if (window != null)
                _Metric(
                  label: '最近窗口',
                  value:
                      '${_formatDuration(window.mediaStart)} / ${_formatDuration(window.duration)}',
                ),
              _Metric(
                label: '推理',
                value: '${diagnostics.lastInference.inMilliseconds} ms',
              ),
              _Metric(
                label: '实时倍率',
                value: diagnostics.lastRealtimeFactor.toStringAsFixed(2),
              ),
              _Metric(
                label: '结果数',
                value: '${diagnostics.lastResultCount}',
              ),
              _Metric(
                label: '识别落后',
                value: _formatDuration(diagnostics.recognitionLag),
              ),
              _Metric(
                label: '已解码至',
                value: _formatDuration(diagnostics.decodedThrough),
              ),
              _Metric(
                label: '已处理至',
                value: _formatDuration(diagnostics.processedThrough),
              ),
              _Metric(
                label: '处理领先',
                value: _formatDuration(_lead(diagnostics)),
              ),
              _Metric(
                label: '字幕覆盖至',
                value: _formatDuration(diagnostics.recognizedThrough),
              ),
              _Metric(
                label: '字幕领先',
                value: _formatDuration(_recognizedLead(diagnostics)),
              ),
              const _Metric(label: '预取水位', value: '20s - 45s'),
              _Metric(
                label: '翻译调度',
                value: _formatTranslationScheduling(translationQueue?.metrics),
              ),
              _Metric(
                label: '翻译队列',
                value: _formatTranslationQueue(translationQueue?.metrics),
              ),
              _Metric(
                label: '请求批量',
                value: _formatTranslationBatch(translationQueue?.metrics),
              ),
              _Metric(
                label: 'API 往返',
                value: _formatTranslationApiWait(translationQueue?.metrics),
              ),
              _Metric(
                label: 'API P95',
                value:
                    _formatDurationMetric(translationQueue?.metrics.p95ApiWait),
              ),
              _Metric(
                label: '排队等待',
                value: _formatDurationMetric(
                    translationQueue?.metrics.averageQueueWait),
              ),
              _Metric(
                label: '端到端翻译',
                value: _formatDurationMetric(
                    translationQueue?.metrics.averageEndToEndWait),
              ),
              _Metric(
                label: '翻译完成',
                value: _formatTranslationCompleted(translationQueue?.metrics),
              ),
            ],
          ),
          if (diagnostics.lastReason != null) ...[
            const SizedBox(height: 8),
            Text(
              '最近原因：${diagnostics.lastReason}',
              style: const TextStyle(color: Color(0xFFFFD166), fontSize: 12),
            ),
          ],
          if (diagnostics.recognizer.lastOutput.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '最近输出：${diagnostics.recognizer.lastOutput.join(' | ')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB7C0C5), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  String _decoderLabel(AudioDecoderState state) => switch (state) {
        AudioDecoderState.idle => '待机',
        AudioDecoderState.opening => '打开中',
        AudioDecoderState.ready => '就绪',
        AudioDecoderState.running => '运行中',
        AudioDecoderState.paused => '已暂停',
        AudioDecoderState.seeking => '跳转中',
        AudioDecoderState.ended => '已结束',
        AudioDecoderState.stopped => '已停止',
        AudioDecoderState.error => '错误',
        AudioDecoderState.disposed => '已释放',
      };

  String _formatDuration(Duration value) =>
      '${value.inMinutes.toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  Duration _lead(RecognitionDiagnostics diagnostics) {
    final lead = diagnostics.processedThrough - diagnostics.playbackPosition;
    return lead.isNegative ? Duration.zero : lead;
  }

  Duration _recognizedLead(RecognitionDiagnostics diagnostics) {
    final lead = diagnostics.recognizedThrough - diagnostics.playbackPosition;
    return lead.isNegative ? Duration.zero : lead;
  }

  String _formatTranslationScheduling(TranslationQueueMetrics? metrics) {
    if (metrics == null) return '暂无数据';
    return '每批 ${metrics.configuredBatchSize} 条 / 并发 ${metrics.configuredMaxConcurrent}';
  }

  String _formatTranslationQueue(TranslationQueueMetrics? metrics) {
    if (metrics == null) return '暂无数据';
    return '${metrics.waitingSegments} 等待 / ${metrics.activeRequests} 请求中';
  }

  String _formatTranslationBatch(TranslationQueueMetrics? metrics) {
    if (metrics == null) return '暂无数据';
    final average = metrics.averageBatchSize;
    return '均值 ${average == null ? '暂无数据' : average.toStringAsFixed(1)} 条'
        ' / 峰值并发 ${metrics.maxObservedActiveRequests}';
  }

  String _formatTranslationApiWait(TranslationQueueMetrics? metrics) {
    if (metrics?.averageApiWait == null) return '暂无数据';
    return '均值 ${_formatDurationMetric(metrics!.averageApiWait)}'
        ' / 最近 ${_formatDurationMetric(metrics.lastApiWait)}';
  }

  String _formatTranslationCompleted(TranslationQueueMetrics? metrics) {
    if (metrics == null) return '暂无数据';
    return '${metrics.completedSegments} 成功 / '
        '${metrics.terminalFailedSegments} 最终失败 / '
        '${metrics.timeoutAttempts} 超时 / '
        '${metrics.failedAttempts} 失败尝试 / '
        '${metrics.retriedSegments} 重试';
  }

  String _formatDurationMetric(Duration? duration) {
    if (duration == null) return '暂无数据';
    return '${duration.inMilliseconds} ms';
  }
}

class _WhisperStatusLine extends StatelessWidget {
  const _WhisperStatusLine({required this.status});

  final WindowRecognitionStatus status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status.state) {
      WindowRecognitionState.unavailable => '不可用',
      WindowRecognitionState.notLoaded => '未加载',
      WindowRecognitionState.loading => '加载中',
      WindowRecognitionState.ready => '已加载，可识别',
      WindowRecognitionState.recognizing => '识别中',
      WindowRecognitionState.error => '加载或识别失败',
      WindowRecognitionState.stopped => '已停止',
    };
    final color = switch (status.state) {
      WindowRecognitionState.ready => const Color(0xFF5ED6A0),
      WindowRecognitionState.recognizing => const Color(0xFF7DD3FC),
      WindowRecognitionState.error => const Color(0xFFFF8A80),
      _ => const Color(0xFFFFD166),
    };
    return Row(
      children: [
        Icon(Icons.memory_outlined, size: 16, color: color),
        const SizedBox(width: 6),
        Text('Whisper：$label', style: TextStyle(color: color, fontSize: 12)),
        if (status.modelName != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status.modelName!,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF9EA7AC), fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: const TextStyle(color: Color(0xFF9EA7AC), fontSize: 12),
            ),
            TextSpan(text: value),
          ],
        ),
      );
}

class _DiagnosticEntryTile extends StatelessWidget {
  const _DiagnosticEntryTile({required this.entry});

  final DiagnosticLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) {
      DiagnosticLogLevel.info => const Color(0xFF5ED6A0),
      DiagnosticLogLevel.warning => const Color(0xFFFFD166),
      DiagnosticLogLevel.error => const Color(0xFFFF8A80),
    };
    final time = entry.timestamp
        .toLocal()
        .toIso8601String()
        .replaceFirst('T', ' ')
        .split('.')
        .first;
    return Container(
      padding: const EdgeInsets.all(12),
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
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text('${entry.category} · ${entry.action}')),
              Text(time,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF9EA7AC))),
            ],
          ),
          if (entry.details.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...entry.details.entries.map(
              (detail) => Padding(
                padding: const EdgeInsets.only(top: 3),
                child: SelectableText(
                  '${detail.key}：${detail.value}',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFFB7C0C5)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
