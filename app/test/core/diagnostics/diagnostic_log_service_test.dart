import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/core/diagnostics/diagnostic_log_service.dart';

void main() {
  test('stores entries and exports a readable privacy-safe timeline', () {
    final logs = DiagnosticLogService(preserveSensitiveDetails: false);
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

  test('keeps complete details in the default testing mode', () {
    final logs = DiagnosticLogService();
    logs.info('网页媒体桥接', '测试媒体上下文', {
      '网页地址': 'https://example.com/watch?id=secret',
      'Cookie': 'session=private',
      '本地文件': r'C:\Users\20592\Videos\sample.mp4',
    });

    final exported = logs.formatForExport();

    expect(exported, contains('id=secret'));
    expect(exported, contains('session=private'));
    expect(exported, contains(r'C:\Users\20592\Videos\sample.mp4'));
    expect(exported, contains('测试日志保留完整本机媒体'));
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

  test('drops entries below the configured level', () {
    final logs = DiagnosticLogService(
      minimumLevel: DiagnosticLogLevel.warning,
    );

    logs.debug('测试', '调试事件');
    logs.info('测试', '信息事件');
    logs.warning('测试', '警告事件');
    logs.error('测试', '错误事件');

    expect(logs.entries.map((entry) => entry.action),
        containsAllInOrder(['警告事件', '错误事件']));
  });

  test('defaults to info level and hides debug events', () {
    final logs = DiagnosticLogService();

    expect(logs.minimumLevel, DiagnosticLogLevel.info);
    logs.debug('测试', '调试事件');
    logs.info('测试', '信息事件');

    expect(logs.entries.map((entry) => entry.action), ['信息事件']);
  });

  test('records all events at debug level', () {
    final logs = DiagnosticLogService(minimumLevel: DiagnosticLogLevel.debug);

    logs.debug('测试', '调试事件');
    logs.warning('测试', '警告事件');

    expect(logs.entries, hasLength(2));
    expect(logs.entries.first.level, DiagnosticLogLevel.debug);
  });

  test('records nothing when the level is off', () {
    final logs = DiagnosticLogService(minimumLevel: DiagnosticLogLevel.off);

    logs.debug('测试', '调试事件');
    logs.error('测试', '错误事件');

    expect(logs.entries, isEmpty);
    expect(logs.formatForExport(), contains('关闭（未记录任何日志）'));
  });

  test('switching the level at runtime changes what is recorded', () {
    final logs = DiagnosticLogService();

    logs.debug('测试', '升级前调试事件');
    logs.level = DiagnosticLogLevel.debug;
    logs.debug('测试', '升级后调试事件');
    logs.level = DiagnosticLogLevel.error;
    logs.warning('测试', '降级后警告事件');
    logs.error('测试', '错误事件');

    expect(logs.entries.map((entry) => entry.action),
        containsAllInOrder(['升级后调试事件', '错误事件']));
    expect(logs.formatForExport(), contains('仅错误'));
  });

  test('export header states the recording level', () {
    final logs = DiagnosticLogService();
    logs.info('测试', '信息事件');

    final exported = logs.formatForExport();

    expect(exported, contains('日志级别：信息及以上'));
    expect(exported, contains('信息 · 测试 · 信息事件'));
  });
}
