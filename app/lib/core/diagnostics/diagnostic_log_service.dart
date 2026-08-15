import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum DiagnosticLogLevel { info, warning, error }

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

/// In-memory, privacy-aware diagnostic timeline for user initiated export.
class DiagnosticLogService extends ChangeNotifier {
  static const _maximumEntries = 800;
  final List<DiagnosticLogEntry> _entries = [];

  UnmodifiableListView<DiagnosticLogEntry> get entries =>
      UnmodifiableListView(_entries);

  void info(
    String category,
    String action, [
    Map<String, Object?> details = const {},
  ]) {
    _add(DiagnosticLogLevel.info, category, action, details);
  }

  void warning(
    String category,
    String action, [
    Map<String, Object?> details = const {},
  ]) {
    _add(DiagnosticLogLevel.warning, category, action, details);
  }

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
    final safeDetails = <String, String>{};
    details.forEach((key, value) {
      if (value == null) return;
      safeDetails[key] = _sanitize(key, value.toString());
    });
    _entries.add(DiagnosticLogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: category,
      action: action,
      details: UnmodifiableMapView(safeDetails),
    ));
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
      ..writeln('导出时间：${_formatTime(DateTime.now())}')
      ..writeln('日志条数：${_entries.length}')
      ..writeln('隐私说明：URL 查询参数、Cookie、授权信息和本地完整路径已脱敏。')
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

  Future<void> export() async {
    final directory = await getTemporaryDirectory();
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'ai-video-player-diagnostics-$timestamp.txt',
    );
    await file.writeAsString(formatForExport(), flush: true);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/plain')],
      subject: 'AI 视频播放器诊断日志',
      text: 'AI 视频播放器诊断日志（已自动脱敏）',
    );
  }

  static String _sanitize(String key, String value) {
    final lowerKey = key.toLowerCase();
    if (lowerKey.contains('cookie') || lowerKey.contains('authorization') ||
        lowerKey.contains('token') || lowerKey.contains('header')) {
      return '[已脱敏]';
    }
    if (lowerKey.contains('url') || lowerKey.contains('uri') ||
        lowerKey.contains('source') || lowerKey.contains('page')) {
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
        DiagnosticLogLevel.info => '信息',
        DiagnosticLogLevel.warning => '警告',
        DiagnosticLogLevel.error => '错误',
      };
}
