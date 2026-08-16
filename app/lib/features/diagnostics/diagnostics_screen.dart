import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_build_info.dart';
import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../domain/audio/audio_models.dart';

class DiagnosticsWorkspace extends StatelessWidget {
  const DiagnosticsWorkspace({required this.logs, this.recognition, super.key});

  final DiagnosticLogService logs;
  final RecognitionDiagnostics? recognition;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: logs,
        builder: (context, _) {
          final entries = logs.entries.reversed.toList(growable: false);
          return Column(
            children: [
              if (recognition != null)
                _RecognitionSummary(diagnostics: recognition!),
              Material(
                color: const Color(0xFF191C1E),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.bug_report_outlined, size: 20),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('诊断日志 (${entries.length})'),
                            Text(
                              AppBuildInfo.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF9EA7AC),
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (defaultTargetPlatform == TargetPlatform.windows) ...[
                        Builder(
                          builder: (buttonContext) => IconButton(
                            onPressed: entries.isEmpty
                                ? null
                                : () async {
                                    logs.info('诊断日志', '用户点击复制日志');
                                    try {
                                      await logs.copyToClipboard();
                                      if (buttonContext.mounted) {
                                        ScaffoldMessenger.of(buttonContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('诊断日志已复制到剪贴板。'),
                                          ),
                                        );
                                      }
                                    } catch (error, stackTrace) {
                                      logs.error('诊断日志', '复制日志失败', {
                                        '错误类型': error.runtimeType,
                                        '错误': error,
                                        '堆栈': stackTrace,
                                      });
                                      if (buttonContext.mounted) {
                                        ScaffoldMessenger.of(buttonContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('复制日志失败，请稍后重试。'),
                                          ),
                                        );
                                      }
                                    }
                                  },
                            tooltip: '复制诊断日志',
                            style: IconButton.styleFrom(
                              foregroundColor: const Color(0xFFE8EEF2),
                              backgroundColor: const Color(0xFF2C3235),
                              disabledForegroundColor: const Color(0xFF687277),
                              fixedSize: const Size(40, 40),
                            ),
                            icon: const _DiagnosticActionIcon(
                              kind: _DiagnosticActionIconKind.copy,
                            ),
                          ),
                        ),
                        Builder(
                          builder: (buttonContext) => IconButton(
                            onPressed: entries.isEmpty
                                ? null
                                : () async {
                                    logs.info('诊断日志', '用户点击导出 TXT 日志');
                                    try {
                                      final path = await logs.saveAsTextFile();
                                      if (!buttonContext.mounted) return;
                                      if (path == null) {
                                        logs.info('诊断日志', '用户取消导出 TXT 日志');
                                        return;
                                      }
                                      ScaffoldMessenger.of(buttonContext)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text('诊断日志已保存为 TXT 文件。'),
                                        ),
                                      );
                                    } catch (error, stackTrace) {
                                      logs.error('诊断日志', '导出 TXT 日志失败', {
                                        '错误类型': error.runtimeType,
                                        '错误': error,
                                        '堆栈': stackTrace,
                                      });
                                      if (buttonContext.mounted) {
                                        ScaffoldMessenger.of(buttonContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('导出 TXT 日志失败，请稍后重试。'),
                                          ),
                                        );
                                      }
                                    }
                                  },
                            tooltip: '导出 TXT 日志',
                            style: IconButton.styleFrom(
                              foregroundColor: const Color(0xFFE8EEF2),
                              backgroundColor: const Color(0xFF2C3235),
                              disabledForegroundColor: const Color(0xFF687277),
                              fixedSize: const Size(40, 40),
                            ),
                            icon: const _DiagnosticActionIcon(
                              kind: _DiagnosticActionIconKind.download,
                            ),
                          ),
                        ),
                      ] else
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
                                    logs.info('诊断日志', '用户点击分享日志');
                                    try {
                                      final result = await logs.export(
                                        sharePositionOrigin: origin,
                                      );
                                      if (result.status ==
                                          ShareResultStatus.dismissed) {
                                        logs.info('诊断日志', '用户取消分享日志');
                                      } else {
                                        logs.info('诊断日志', '日志已调用系统分享', {
                                          '结果': result.status.name,
                                        });
                                      }
                                    } catch (error, stackTrace) {
                                      logs.error('诊断日志', '分享日志失败', {
                                        '错误类型': error.runtimeType,
                                        '错误': error,
                                        '堆栈': stackTrace,
                                      });
                                      if (buttonContext.mounted) {
                                        ScaffoldMessenger.of(buttonContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('分享日志失败，请稍后重试。'),
                                          ),
                                        );
                                      }
                                    }
                                  },
                            tooltip: '分享诊断日志',
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

class _RecognitionSummary extends StatelessWidget {
  const _RecognitionSummary({required this.diagnostics});

  final RecognitionDiagnostics diagnostics;

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

enum _DiagnosticActionIconKind { copy, download }

class _DiagnosticActionIcon extends StatelessWidget {
  const _DiagnosticActionIcon({required this.kind});

  final _DiagnosticActionIconKind kind;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? const Color(0xFFE8EEF2);
    return CustomPaint(
      size: const Size.square(20),
      painter: _DiagnosticActionIconPainter(kind: kind, color: color),
    );
  }
}

class _DiagnosticActionIconPainter extends CustomPainter {
  const _DiagnosticActionIconPainter({required this.kind, required this.color});

  final _DiagnosticActionIconKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final center = size.center(Offset.zero);

    if (kind == _DiagnosticActionIconKind.copy) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(6, 3, 10, 12),
          const Radius.circular(1.5),
        ),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(3, 6, 10, 11),
          const Radius.circular(1.5),
        ),
        paint,
      );
      return;
    }

    canvas.drawLine(Offset(center.dx, 3), Offset(center.dx, 13), paint);
    canvas.drawLine(const Offset(6, 10), const Offset(10, 14), paint);
    canvas.drawLine(const Offset(10, 14), const Offset(14, 10), paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3, 15, 14, 3),
        const Radius.circular(1),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_DiagnosticActionIconPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color;
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
