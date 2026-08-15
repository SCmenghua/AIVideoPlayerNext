import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/diagnostics/diagnostic_log_service.dart';

class DiagnosticsWorkspace extends StatelessWidget {
  const DiagnosticsWorkspace({required this.logs, super.key});

  final DiagnosticLogService logs;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: logs,
        builder: (context, _) {
          final entries = logs.entries.reversed.toList(growable: false);
          return Column(
            children: [
              Material(
                color: const Color(0xFF191C1E),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.bug_report_outlined, size: 20),
                      const SizedBox(width: 8),
                      Text('诊断日志 (${entries.length})'),
                      const Spacer(),
                      Builder(
                        builder: (buttonContext) => IconButton(
                          onPressed: entries.isEmpty
                              ? null
                              : () async {
                                  final box = buttonContext.findRenderObject()
                                      as RenderBox?;
                                  final origin = box == null
                                      ? null
                                      : box.localToGlobal(Offset.zero) &
                                          box.size;
                                  logs.info('诊断日志', '用户点击导出日志');
                                  try {
                                    final result = await logs.export(
                                      sharePositionOrigin: origin,
                                    );
                                    if (result.status == ShareResultStatus.dismissed) {
                                      logs.info('诊断日志', '用户取消导出日志');
                                    } else {
                                      logs.info('诊断日志', '日志导出已调用系统分享', {
                                        '结果': result.status.name,
                                      });
                                    }
                                  } catch (error, stackTrace) {
                                    logs.error('诊断日志', '日志导出失败', {
                                      '错误类型': error.runtimeType,
                                      '错误': error,
                                      '堆栈': stackTrace,
                                    });
                                    if (buttonContext.mounted) {
                                      ScaffoldMessenger.of(buttonContext)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text('导出日志失败，请稍后重试。'),
                                        ),
                                      );
                                    }
                                  }
                                },
                          tooltip: '导出诊断日志',
                          icon: const Icon(Icons.ios_share_outlined),
                        ),
                      ),
                      IconButton(
                        onPressed: entries.isEmpty ? null : logs.clear,
                        tooltip: '清空诊断日志',
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(
                        child: Text('尚无诊断日志。浏览网页、点击播放或切换工作区后，操作会显示在这里。'),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: entries.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) => _DiagnosticEntryTile(
                          entry: entries[index],
                        ),
                      ),
              ),
            ],
          );
        },
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
    final time = entry.timestamp.toLocal().toIso8601String().replaceFirst('T', ' ').split('.').first;
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
              Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF9EA7AC))),
            ],
          ),
          if (entry.details.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...entry.details.entries.map(
              (detail) => Padding(
                padding: const EdgeInsets.only(top: 3),
                child: SelectableText(
                  '${detail.key}：${detail.value}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFB7C0C5)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
