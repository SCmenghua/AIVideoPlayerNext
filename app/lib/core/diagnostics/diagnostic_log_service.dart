import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_build_info.dart';

/// Log severity. Ordered from most verbose to least; [off] may only be used
/// as the recording threshold and is never assigned to an entry.
enum DiagnosticLogLevel { debug, info, warning, error, off }

/// Human labels for the switchable recording levels shown in the UI and in
/// exported files. `off` disables recording entirely.
const diagnosticLogLevelLabels = {
  DiagnosticLogLevel.debug: '调试',
  DiagnosticLogLevel.info: '信息',
  DiagnosticLogLevel.warning: '警告',
  DiagnosticLogLevel.error: '错误',
  DiagnosticLogLevel.off: '关闭',
};

/// One run's log file on disk.
class DiagnosticLogFile {
  const DiagnosticLogFile({
    required this.file,
    required this.modified,
    required this.sizeBytes,
    required this.isCurrent,
  });

  final File file;
  final DateTime modified;
  final int sizeBytes;
  final bool isCurrent;

  /// `session-20260917-143022`, used as the exported file name.
  String get label => file.uri.pathSegments.last.replaceAll('.log', '');

  String get sizeLabel => sizeBytes >= 1 << 20
      ? '${(sizeBytes / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(sizeBytes / (1 << 10)).toStringAsFixed(0)} KB';
}

class DiagnosticLogEntry {
  const DiagnosticLogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.action,
    required this.details,
  });

  final DateTime timestamp;
  final DiagnosticLogLevel level;
  final String category;
  final String action;
  final Map<String, String> details;
}

/// In-memory diagnostic timeline for user initiated export. Entries below
/// [minimumLevel] are dropped before recording; the level is switchable at
/// runtime from the diagnostics workspace.
class DiagnosticLogService extends ChangeNotifier {
  DiagnosticLogService({
    bool? preserveSensitiveDetails,
    this.minimumLevel = DiagnosticLogLevel.info,
    this.logRetention = const Duration(days: 1),
  }) : preserveSensitiveDetails = preserveSensitiveDetails ?? !kReleaseMode;
  static const _maximumEntries = 800;
  final bool preserveSensitiveDetails;
  DiagnosticLogLevel minimumLevel;

  final List<DiagnosticLogEntry> _entries = [];

  // Crash survival: the in-memory ring dies with the process, which is exactly
  // when the log matters — and inside a sideloading container there is no
  // system crash report to fall back on. Every run writes its own file and
  // files older than [logRetention] are purged at startup.
  File? _sink;
  Directory? _logDirectory;
  final StringBuffer _pending = StringBuffer();
  Timer? _flushTimer;

  /// How long past runs are kept.
  final Duration logRetention;

  /// Starts a new session file under `<directory>/diagnostics` and deletes
  /// runs older than [logRetention]. Safe to call once at startup; failures
  /// leave logging in memory only.
  Future<void> attachFile(Directory directory) async {
    try {
      final logs = Directory('${directory.path}${Platform.pathSeparator}diagnostics');
      await logs.create(recursive: true);
      _logDirectory = logs;
      await purgeExpiredLogs();
      final file = File('${logs.path}${Platform.pathSeparator}session-${_timestamp()}.log');
      await file.writeAsString(
        '# ${_formatTime(DateTime.now())} 会话开始 '
        '${AppBuildInfo.version} / ${AppBuildInfo.buildTime} / ${AppBuildInfo.buildId}\n',
        flush: true,
      );
      _sink = file;
    } on Object {
      _sink = null;
    }
  }

  Future<void> purgeExpiredLogs() async {
    final logs = _logDirectory;
    if (logs == null) return;
    final cutoff = DateTime.now().subtract(logRetention);
    try {
      await for (final entity in logs.list()) {
        if (entity is! File || !entity.path.endsWith('.log')) continue;
        if ((await entity.stat()).modified.isBefore(cutoff)) await entity.delete();
      }
    } on Object {
      // Housekeeping must never take down the session.
    }
  }

  /// Past and current runs, newest first. The first entry is the running
  /// session; after a crash the one before it holds the evidence.
  Future<List<DiagnosticLogFile>> sessionLogs() async {
    final logs = _logDirectory;
    if (logs == null) return const [];
    final result = <DiagnosticLogFile>[];
    try {
      await for (final entity in logs.list()) {
        if (entity is! File || !entity.path.endsWith('.log')) continue;
        final stat = await entity.stat();
        result.add(DiagnosticLogFile(
          file: entity,
          modified: stat.modified,
          sizeBytes: stat.size,
          isCurrent: entity.path == _sink?.path,
        ));
      }
    } on Object {
      return const [];
    }
    result.sort((left, right) => right.modified.compareTo(left.modified));
    return result;
  }

  bool get hasSessionLogs => _sink != null;

  /// Reads one session file, flushing first when it is the running one.
  Future<String> readSessionLog(DiagnosticLogFile log) async {
    if (log.isCurrent) _flush();
    return log.file.readAsString();
  }

  Future<String?> saveSessionLog(DiagnosticLogFile log) async {
    final content = await readSessionLog(log);
    final name = 'ai-video-player-${log.label}.txt';
    if (Platform.isIOS) {
      final directory = await getApplicationDocumentsDirectory();
      final path = '${directory.path}${Platform.pathSeparator}$name';
      await File(path).writeAsString(content, encoding: utf8);
      return path;
    }
    final location = await getSaveLocation(
      acceptedTypeGroups: const [XTypeGroup(label: '文本文件', extensions: ['txt'])],
      suggestedName: name,
      confirmButtonText: '保存',
    );
    if (location == null) return null;
    final path =
        location.path.toLowerCase().endsWith('.txt') ? location.path : '${location.path}.txt';
    await File(path).writeAsString(content, encoding: utf8);
    return path;
  }

  Future<ShareResult> shareSessionLog(
    DiagnosticLogFile log, {
    Rect? sharePositionOrigin,
  }) async {
    final content = await readSessionLog(log);
    final name = 'ai-video-player-${log.label}.txt';
    return Share.shareXFiles(
      [XFile.fromData(Uint8List.fromList(utf8.encode(content)), name: name, mimeType: 'text/plain')],
      subject: 'AI 视频播放器运行日志',
      sharePositionOrigin: sharePositionOrigin,
      fileNameOverrides: [name],
    );
  }

  void _mirror(DiagnosticLogEntry entry) {
    final sink = _sink;
    if (sink == null) return;
    _pending.writeln(
      '[${_formatTime(entry.timestamp)}] ${_levelLabel(entry.level)} · '
      '${entry.category} · ${entry.action}'
      '${entry.details.isEmpty ? '' : ' · ${entry.details}'}',
    );
    // A kill gives no warning, so anything worth acting on is flushed at once;
    // routine detail is batched so logging cannot stall the UI isolate.
    if (entry.level.index >= DiagnosticLogLevel.warning.index || _pending.length > 4096) {
      _flush();
      return;
    }
    _flushTimer ??= Timer(const Duration(milliseconds: 100), _flush);
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final sink = _sink;
    if (sink == null || _pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();
    try {
      sink.writeAsStringSync(text, mode: FileMode.append, flush: true);
    } on Object {
      // Losing the mirror must never take down the session.
    }
  }

  @override
  void dispose() {
    _flush();
    super.dispose();
  }

  UnmodifiableListView<DiagnosticLogEntry> get entries =>
      UnmodifiableListView(_entries);

  /// Runtime-switchable recording threshold. Lowering it does not restore
  /// entries that were already dropped.
  set level(DiagnosticLogLevel value) {
    if (value == minimumLevel) return;
    minimumLevel = value;
    notifyListeners();
  }

  /// High-frequency diagnostic detail: per-window audio/PCM data, network
  /// Range activity, player state transitions, routine user interactions.
  void debug(
    String category,
    String action, [
    Map<String, Object?> details = const {},
  ]) {
    _add(DiagnosticLogLevel.debug, category, action, details);
  }

  /// Key lifecycle events and milestones: initialization, media open, model
  /// load, first PCM/subtitle, handoff, settings changes.
  void info(
    String category,
    String action, [
    Map<String, Object?> details = const {},
  ]) {
    _add(DiagnosticLogLevel.info, category, action, details);
  }

  /// Degradations and recoverable problems: unsupported media, invalid input,
  /// retryable failures, ignored duplicates.
  void warning(
    String category,
    String action, [
    Map<String, Object?> details = const {},
  ]) {
    _add(DiagnosticLogLevel.warning, category, action, details);
  }

  /// Failures that lose a capability or require user attention.
  void error(
    String category,
    String action, [
    Map<String, Object?> details = const {},
  ]) {
    _add(DiagnosticLogLevel.error, category, action, details);
  }

  void _add(
    DiagnosticLogLevel level,
    String category,
    String action,
    Map<String, Object?> details,
  ) {
    if (minimumLevel == DiagnosticLogLevel.off) return;
    // The file keeps everything: the level control is a filter on what the
    // list shows, not on what a later crash investigation gets to see.
    final visible = level.index >= minimumLevel.index;
    final safeDetails = <String, String>{};
    details.forEach((key, value) {
      if (value == null) return;
      safeDetails[key] = preserveSensitiveDetails
          ? value.toString()
          : _sanitize(key, value.toString());
    });
    final entry = DiagnosticLogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: category,
      action: action,
      details: UnmodifiableMapView(safeDetails),
    );
    _mirror(entry);
    if (!visible) return;
    _entries.add(entry);
    if (_entries.length > _maximumEntries) _entries.removeAt(0);
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String formatForExport() {
    final buffer = StringBuffer()
      ..writeln('# AI 视频播放器诊断日志')
      ..writeln('应用版本：${AppBuildInfo.version}')
      ..writeln('构建时间：${AppBuildInfo.buildTime}')
      ..writeln('构建编号：${AppBuildInfo.buildId}')
      ..writeln('导出时间：${_formatTime(DateTime.now())}')
      ..writeln('日志级别：${_levelSettingLabel(minimumLevel)}')
      ..writeln('日志条数：${_entries.length}')
      ..writeln(preserveSensitiveDetails
          ? '隐私说明：测试日志保留完整本机媒体、请求与会话信息；不会自动上传，请勿提交到 Git。'
          : '隐私说明：URL 查询参数、Cookie、授权信息和本地完整路径已脱敏。')
      ..writeln();
    for (final entry in _entries) {
      buffer.writeln(
        '[${_formatTime(entry.timestamp)}] ${_levelLabel(entry.level)} · '
        '${entry.category} · ${entry.action}',
      );
      entry.details.forEach((key, value) => buffer.writeln('  $key：$value'));
    }
    return buffer.toString();
  }

  Future<void> copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: formatForExport()));
    info('诊断日志', '日志已复制到剪贴板', {'日志条数': _entries.length});
  }

  Future<String?> saveAsTextFile() async {
    if (Platform.isIOS) {
      final directory = await getApplicationDocumentsDirectory();
      final path = '${directory.path}${Platform.pathSeparator}${_fileName()}';
      await File(path).writeAsString(formatForExport(), encoding: utf8);
      info('诊断日志', '日志已导出为 TXT 文件', {
        '路径': path,
        '日志条数': _entries.length,
      });
      return path;
    }
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: '文本文件', extensions: ['txt']),
      ],
      suggestedName: _fileName(),
      confirmButtonText: '保存',
    );
    if (location == null) return null;

    final path = location.path.toLowerCase().endsWith('.txt')
        ? location.path
        : '${location.path}.txt';
    await File(path).writeAsString(formatForExport(), encoding: utf8);
    info('诊断日志', '日志已导出为 TXT', {
      '路径': path,
      '日志条数': _entries.length,
    });
    return path;
  }

  Future<ShareResult> export({Rect? sharePositionOrigin}) async {
    final content = formatForExport();
    final fileName = _fileName();
    final file = XFile.fromData(
      Uint8List.fromList(utf8.encode(content)),
      name: fileName,
      mimeType: 'text/plain',
    );
    try {
      return await Share.shareXFiles(
        [file],
        subject: 'AI 视频播放器诊断日志',
        sharePositionOrigin: sharePositionOrigin,
        fileNameOverrides: [fileName],
      );
    } catch (error) {
      warning('诊断日志', '文件分享失败，改用纯文本分享', {
        '错误类型': error.runtimeType,
        '错误': error,
      });
      return Share.share(
        content,
        subject: 'AI 视频播放器诊断日志',
        sharePositionOrigin: sharePositionOrigin,
      );
    }
  }

  static String _fileName() => 'ai-video-player-diagnostics-${_timestamp()}.txt';

  static String _timestamp() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
  }

  static String _sanitize(String key, String value) {
    final lowerKey = key.toLowerCase();
    if (lowerKey.contains('cookie') ||
        lowerKey.contains('authorization') ||
        lowerKey.contains('token') ||
        lowerKey.contains('header')) {
      return '[已脱敏]';
    }
    if (lowerKey.contains('url') ||
        lowerKey.contains('uri') ||
        lowerKey.contains('source') ||
        lowerKey.contains('page')) {
      return _sanitizeUrl(value);
    }
    if (value.startsWith('file:') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
        value.startsWith('/')) {
      return _sanitizeLocalPath(value);
    }
    final sanitized = value
        .replaceAll(
          RegExp(r'(bearer\s+)[^\s,;]+', caseSensitive: false),
          r'$1[已脱敏]',
        )
        .replaceAll(
          RegExp(
            r'(cookie|token|authorization)=?[^\s,;]+',
            caseSensitive: false,
          ),
          r'$1=[已脱敏]',
        );
    return sanitized.replaceAllMapped(
      RegExp(r'https?://[^\s,}\]]+'),
      (match) => _sanitizeUrl(match.group(0)!),
    );
  }

  static String _sanitizeUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) {
      return value.length > 300 ? '${value.substring(0, 300)}...' : value;
    }
    if (uri.scheme == 'file') {
      final name = uri.pathSegments.isEmpty ? '本地媒体' : uri.pathSegments.last;
      return 'file:///[本地路径已脱敏]/$name';
    }
    if (uri.hasAuthority) {
      final path = uri.path.isEmpty ? '/' : uri.path;
      final query = uri.queryParameters.isEmpty
          ? ''
          : '?[${uri.queryParameters.length} 个参数已脱敏]';
      return '${uri.scheme}://${uri.authority}$path$query';
    }
    return value.length > 300 ? '${value.substring(0, 300)}...' : value;
  }

  static String _sanitizeLocalPath(String value) {
    final uri = Uri.tryParse(value);
    final path = uri?.path ?? value;
    final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty);
    final name = parts.isEmpty ? null : parts.last;
    return '[本地路径已脱敏]${name == null ? '' : '/$name'}';
  }

  static String _formatTime(DateTime value) =>
      value.toLocal().toIso8601String().replaceFirst('T', ' ').split('.').first;

  static String _levelLabel(DiagnosticLogLevel level) => switch (level) {
        DiagnosticLogLevel.debug => '调试',
        DiagnosticLogLevel.info => '信息',
        DiagnosticLogLevel.warning => '警告',
        DiagnosticLogLevel.error => '错误',
        DiagnosticLogLevel.off => '关闭',
      };

  /// The recording threshold label for export headers, including what is
  /// being dropped at the current level.
  static String _levelSettingLabel(DiagnosticLogLevel level) => switch (level) {
        DiagnosticLogLevel.debug => '调试（全部事件）',
        DiagnosticLogLevel.info => '信息及以上（调试级事件未记录）',
        DiagnosticLogLevel.warning => '警告及以上（信息、调试级事件未记录）',
        DiagnosticLogLevel.error => '仅错误',
        DiagnosticLogLevel.off => '关闭（未记录任何日志）',
      };
}
