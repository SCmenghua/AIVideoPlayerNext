import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recognition/recognition.dart' show RecognitionDiagnostics;

import '../../app/providers.dart';
import '../../core/app_build_info.dart';
import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../domain/subtitles/transcript_document.dart';
import '../recognition/transcript_store.dart';
import '../translation/transcript_translation_queue.dart';

class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key, required this.translationQueue});

  final TranscriptTranslationQueue translationQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('诊断'),
            bottom: const TabBar(tabs: [Tab(text: '状态'), Tab(text: '字幕'), Tab(text: '日志')]),
          ),
          body: TabBarView(
            children: [
              _StatusTab(translationQueue: translationQueue),
              const _TranscriptTab(),
              const _LogTab(),
            ],
          ),
        ),
      );
}

class _StatusTab extends ConsumerWidget {
  const _StatusTab({required this.translationQueue});

  final TranscriptTranslationQueue translationQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recognition = ref.watch(recognitionServiceProvider);
    return StreamBuilder<RecognitionDiagnostics>(
      stream: recognition.diagnosticsStream,
      initialData: recognition.diagnostics,
      builder: (context, snapshot) {
        final d = snapshot.data ?? recognition.diagnostics;
        final status = recognition.status;
        final backend = d.engineBackend ?? recognition.status.download?.spec.label;
        return ListenableBuilder(
          listenable: translationQueue,
          builder: (context, _) {
            final metrics = translationQueue.metrics;
            final service = translationQueue.serviceStatus;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _KeyValueCard(title: '识别', rows: [
                  ('可用性', status.availability.name),
                  if (status.message != null) ('说明', status.message!),
                  ('模型', recognition.settings.model.fileName),
                  ('语言', recognition.settings.language),
                  ('后端', backend?.toString() ?? '-'),
                  ('会话状态', d.state.name),
                  ('解码器', '${d.source.state.name} ${d.source.sampleRate ?? ''}Hz'),
                  ('播放位置', _clock(d.playbackPosition)),
                  ('已解码至', _clock(d.decodedThrough)),
                  ('已处理至', _clock(d.processedThrough)),
                  ('字幕覆盖至', _clock(d.recognizedThrough)),
                  ('领先', '${d.lead.inSeconds} 秒'),
                  ('待识别窗口', '${d.pendingWindows}'),
                  ('窗口 识别/跳过/失败', '${d.windowsRecognized}/${d.windowsSkipped}/${d.windowsFailed}'),
                  ('片段 接受/丢弃', '${d.segmentsAccepted}/${d.segmentsDropped}'),
                  ('上一窗口', '${d.lastWindowDuration.inMilliseconds} ms，推理 ${d.lastInference.inMilliseconds} ms，'
                      '实时倍率 ${d.lastRealtimeFactor.toStringAsFixed(3)}'),
                  ('解码暂停', d.sourcePausedForLead
                      ? '领先水位'
                      : d.sourcePausedForQueue
                          ? '队列背压'
                          : '否'),
                  if (d.message != null) ('错误', d.message!),
                ]),
                const SizedBox(height: 12),
                _KeyValueCard(title: '翻译', rows: [
                  ('Provider', service.provider),
                  ('可用', service.available ? '是' : service.message ?? '否'),
                  ('目标语言', translationQueue.targetLanguage),
                  ('等待/进行中', '${metrics.waitingSegments}/${metrics.activeRequests}'),
                  ('已完成片段', '${metrics.completedSegments}'),
                  ('失败尝试/终态失败', '${metrics.failedAttempts}/${metrics.terminalFailedSegments}'),
                  ('平均请求耗时', _ms(metrics.averageApiWait)),
                  ('P95 请求耗时', _ms(metrics.p95ApiWait)),
                  ('平均端到端', _ms(metrics.averageEndToEndWait)),
                  ('每批/并发', '${metrics.configuredBatchSize}/${metrics.configuredMaxConcurrent}'),
                ]),
                const SizedBox(height: 12),
                const _KeyValueCard(title: '应用', rows: [
                  ('版本', AppBuildInfo.version),
                  ('构建时间', AppBuildInfo.buildTime),
                  ('构建编号', AppBuildInfo.buildId),
                ]),
              ],
            );
          },
        );
      },
    );
  }

  static String _clock(Duration value) =>
      '${value.inMinutes.toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}.${(value.inMilliseconds % 1000).toString().padLeft(3, '0')}';

  static String _ms(Duration? value) => value == null ? '-' : '${value.inMilliseconds} ms';
}

class _KeyValueCard extends StatelessWidget {
  const _KeyValueCard({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            for (final (key, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 150, child: Text(key, style: TextStyle(color: hint))),
                    Expanded(child: SelectableText(value)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TranscriptTab extends ConsumerWidget {
  const _TranscriptTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(transcriptStoreProvider);
    final settings = ref.watch(appSettingsProvider);
    final document = store.document;
    final segments = document?.orderedSegments ?? const <TranscriptSegment>[];
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text('${segments.length} 条', style: TextStyle(color: hint)),
              const Spacer(),
              _ExportButtons(store: store, kind: TranscriptExportKind.recognition, label: '原文'),
              const SizedBox(width: 6),
              _ExportButtons(store: store, kind: TranscriptExportKind.translation, label: '译文'),
            ],
          ),
        ),
        Expanded(
          child: segments.isEmpty
              ? Center(child: Text('还没有识别结果', style: TextStyle(color: hint)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: segments.length,
                  itemBuilder: (context, index) {
                    final segment = segments[index];
                    final translation =
                        store.translationFor(segment.id, settings.translationTargetLanguage);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_StatusTab._clock(segment.start)} → ${_StatusTab._clock(segment.end)}',
                            style: TextStyle(color: hint, fontSize: 12),
                          ),
                          SelectableText(segment.text),
                          if (translation != null)
                            SelectableText(
                              translation.status == TranscriptTranslationStatus.translated
                                  ? translation.text
                                  : translation.status == TranscriptTranslationStatus.failed
                                      ? '翻译失败：${translation.error ?? ''}'
                                      : '翻译中…',
                              style: TextStyle(color: Theme.of(context).colorScheme.primary),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ExportButtons extends StatelessWidget {
  const _ExportButtons({required this.store, required this.kind, required this.label});

  final TranscriptStore store;
  final TranscriptExportKind kind;
  final String label;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: '导出$label',
        onSelected: (action) async {
          final messenger = ScaffoldMessenger.of(context);
          switch (action) {
            case 'copy':
              await store.copyToClipboard(kind);
              messenger.showSnackBar(SnackBar(content: Text('$label已复制')));
            case 'save':
              final path = await store.saveAsTextFile(kind);
              if (path != null) messenger.showSnackBar(SnackBar(content: Text('已保存到 $path')));
            case 'share':
              await store.share(kind);
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'copy', child: Text('复制')),
          const PopupMenuItem(value: 'save', child: Text('保存为 TXT')),
          if (Platform.isIOS) const PopupMenuItem(value: 'share', child: Text('分享')),
        ],
        child: Chip(label: Text(label), avatar: const Icon(Icons.ios_share_outlined, size: 16)),
      );
}

/// Lists the runs kept on disk so the one that crashed can be exported.
class _SessionLogDialog extends StatelessWidget {
  const _SessionLogDialog({required this.logs});

  final DiagnosticLogService logs;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('历史运行日志'),
        content: SizedBox(
          width: 420,
          child: FutureBuilder<List<DiagnosticLogFile>>(
            future: logs.sessionLogs(),
            builder: (context, snapshot) {
              final sessions = snapshot.data;
              if (sessions == null) {
                return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
              }
              if (sessions.isEmpty) return const Text('还没有日志文件。');
              return ListView.builder(
                shrinkWrap: true,
                itemCount: sessions.length,
                itemBuilder: (context, index) {
                  final session = sessions[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      session.isCurrent ? Icons.play_circle_outline : Icons.history,
                    ),
                    title: Text(_time(session.modified)),
                    subtitle: Text(
                      '${session.sizeLabel}${session.isCurrent ? ' · 当前运行' : ''}',
                    ),
                    trailing: IconButton(
                      tooltip: Platform.isIOS ? '分享' : '保存',
                      icon: Icon(
                        Platform.isIOS ? Icons.ios_share_outlined : Icons.save_outlined,
                      ),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        if (Platform.isIOS) {
                          await logs.shareSessionLog(session);
                        } else {
                          final path = await logs.saveSessionLog(session);
                          if (path != null) {
                            messenger?.showSnackBar(SnackBar(content: Text('已保存到 $path')));
                          }
                        }
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          Text('保留 1 天', style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
        ],
      );

  static String _time(DateTime value) {
    final local = value.toLocal();
    return '${local.month}/${local.day} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }
}

class _LogTab extends ConsumerWidget {
  const _LogTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(diagnosticsLogProvider);
    return ListenableBuilder(
      listenable: logs,
      builder: (context, _) {
        final entries = logs.entries.reversed.toList(growable: false);
        final hint = Theme.of(context).colorScheme.onSurfaceVariant;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<DiagnosticLogLevel>(
                        showSelectedIcon: false,
                        segments: [
                          for (final level in DiagnosticLogLevel.values)
                            ButtonSegment(
                              value: level,
                              label: Text(diagnosticLogLevelLabels[level]!),
                            ),
                        ],
                        selected: {logs.minimumLevel},
                        onSelectionChanged: (selection) => logs.level = selection.single,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '日志操作',
                    onSelected: (action) async {
                      final messenger = ScaffoldMessenger.of(context);
                      switch (action) {
                        case 'copy':
                          await logs.copyToClipboard();
                          messenger.showSnackBar(const SnackBar(content: Text('日志已复制')));
                        case 'save':
                          final path = await logs.saveAsTextFile();
                          if (path != null) {
                            messenger.showSnackBar(SnackBar(content: Text('已保存到 $path')));
                          }
                        case 'share':
                          await logs.export();
                        case 'sessions':
                          await showDialog<void>(
                            context: context,
                            builder: (_) => _SessionLogDialog(logs: logs),
                          );
                        case 'clear':
                          logs.clear();
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'copy', child: Text('复制')),
                      const PopupMenuItem(value: 'save', child: Text('保存为 TXT')),
                      if (Platform.isIOS) const PopupMenuItem(value: 'share', child: Text('分享')),
                      if (logs.hasSessionLogs) ...[
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'sessions',
                          child: Text('历史运行日志（含崩溃前）…'),
                        ),
                      ],
                      const PopupMenuItem(value: 'clear', child: Text('清空')),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_time(entry.timestamp)} · ${diagnosticLogLevelLabels[entry.level]} · '
                          '${entry.category} · ${entry.action}',
                          style: TextStyle(
                            color: entry.level == DiagnosticLogLevel.error
                                ? Theme.of(context).colorScheme.error
                                : entry.level == DiagnosticLogLevel.warning
                                    ? Theme.of(context).colorScheme.tertiary
                                    : null,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        for (final detail in entry.details.entries)
                          Text('${detail.key}：${detail.value}',
                              style: TextStyle(color: hint, fontSize: 12)),
                      ],
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

  static String _time(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}.${(local.millisecond ~/ 100)}';
  }
}
