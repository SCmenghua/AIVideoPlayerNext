import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/core/diagnostics/diagnostic_log_service.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('diagnostic-log-test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Directory logsDir() => Directory('${root.path}${Platform.pathSeparator}diagnostics');

  test('each run writes its own file and records below the display level', () async {
    final first = DiagnosticLogService(minimumLevel: DiagnosticLogLevel.info);
    await first.attachFile(root);
    first.debug('识别', '窗口已切出', {'窗口': 'w1'});
    first.error('识别', '识别窗口失败');

    // The list honours the level, the file does not.
    expect(first.entries.map((e) => e.action), ['识别窗口失败']);
    final sessions = await first.sessionLogs();
    expect(sessions, hasLength(1));
    expect(sessions.single.isCurrent, isTrue);
    final content = await first.readSessionLog(sessions.single);
    expect(content, contains('窗口已切出'));
    expect(content, contains('识别窗口失败'));
    first.dispose();

    // A second run does not overwrite the first.
    await Future<void>.delayed(const Duration(seconds: 1));
    final second = DiagnosticLogService();
    await second.attachFile(root);
    second.info('应用', '第二次运行');
    final all = await second.sessionLogs();
    expect(all, hasLength(2));
    expect(all.first.isCurrent, isTrue, reason: 'newest first');
    expect(all.last.isCurrent, isFalse);
    expect(await second.readSessionLog(all.last), contains('识别窗口失败'),
        reason: 'the crashed run stays readable');
    second.dispose();
  });

  test('runs older than the retention window are purged at startup', () async {
    final stale = DiagnosticLogService();
    await stale.attachFile(root);
    stale.info('应用', '旧会话');
    stale.dispose();
    final staleFile = (await stale.sessionLogs()).single.file;
    await staleFile.setLastModified(DateTime.now().subtract(const Duration(days: 2)));

    final fresh = DiagnosticLogService(logRetention: const Duration(days: 1));
    await fresh.attachFile(root);
    final remaining = await fresh.sessionLogs();

    expect(remaining, hasLength(1));
    expect(remaining.single.isCurrent, isTrue);
    expect(await staleFile.exists(), isFalse);
    fresh.dispose();
  });

  test('logging keeps working when the directory cannot be used', () async {
    final service = DiagnosticLogService();
    final blocked = Directory('${root.path}/file-not-a-directory');
    await File(blocked.path).writeAsString('x');

    await service.attachFile(blocked);
    service.info('应用', '仍然记录');

    expect(service.hasSessionLogs, isFalse);
    expect(service.entries.single.action, '仍然记录');
    expect(await logsDir().exists(), isFalse);
    service.dispose();
  });
}
