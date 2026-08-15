import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/core/diagnostics/diagnostic_log_service.dart';

void main() {
  test('stores entries and exports a readable privacy-safe timeline', () {
    final logs = DiagnosticLogService();
    logs.info('网页媒体桥接', '用户点击网页播放按钮', {
      '网页地址': 'https://example.com/watch?id=secret&token=private',
      '视频状态': '{"currentSrc":"https://cdn.example.com/a.mp4?sig=secret"}',
      'Cookie': 'session=private',
      '本地文件': r'C:\Users\20592\Videos\sample.mp4',
    });

    final exported = logs.formatForExport();

    expect(logs.entries, hasLength(1));
    expect(exported, contains('AI 视频播放器诊断日志'));
    expect(exported, contains('网页媒体桥接 · 用户点击网页播放按钮'));
    expect(exported, contains('example.com/watch?[2 个参数已脱敏]'));
    expect(exported, contains('cdn.example.com/a.mp4?[1 个参数已脱敏]'));
    expect(exported, contains('[已脱敏]'));
    expect(exported, isNot(contains('secret')));
    expect(exported, isNot(contains('private')));
    expect(exported, isNot(contains(r'C:\Users\20592')));
    expect(exported, contains('[本地路径已脱敏]/sample.mp4'));
  });

  test('keeps only the most recent entries and can clear them', () {
    final logs = DiagnosticLogService();
    for (var index = 0; index < 805; index += 1) {
      logs.info('测试', '事件 $index');
    }

    expect(logs.entries, hasLength(800));
    expect(logs.entries.first.action, '事件 5');

    logs.clear();
    expect(logs.entries, isEmpty);
  });
}
