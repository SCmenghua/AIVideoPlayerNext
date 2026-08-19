import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app_build_info.dart';

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

/// In-memory diagnostic timeline for user initiated export.
class DiagnosticLogService extends ChangeNotifier {
  DiagnosticLogService({bool? preserveSensitiveDetails})
      : preserveSensitiveDetails = preserveSensitiveDetails ?? !kReleaseMode;

  static const _maximumEntries = 800;
  final bool preserveSensitiveDetails;
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
      safeDetails[key] = preserveSensitiveDetails
          ? value.toString()
          : _sanitize(key, value.toString());
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
      ..writeln('应用版本：${AppBuildInfo.version}')
      ..writeln('构建时间：${AppBuildInfo.buildTime}')
      ..writeln('构建编号：${AppBuildInfo.buildId}')
      ..writeln('导出时间：${_formatTime(DateTime.now())}')
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

  static String _fileName() {
    final now = DateTime.now();
    final timestamp = '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    return 'ai-video-player-diagnostics-$timestamp.txt';
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
        DiagnosticLogLevel.info => '信息',
        DiagnosticLogLevel.warning => '警告',
        DiagnosticLogLevel.error => '错误',
      };
}
