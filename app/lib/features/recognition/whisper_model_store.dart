import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'recognition_settings.dart';
import 'whisper_model_catalog.dart';

enum ModelDownloadPhase { downloading, verifying, done, failed }

class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.spec,
    required this.receivedBytes,
    required this.totalBytes,
    this.phase = ModelDownloadPhase.downloading,
    this.attempt = 1,
    this.bytesPerSecond = 0,
    this.source,
    this.error,
  });

  final WhisperModelSpec spec;
  final int receivedBytes;
  final int totalBytes;
  final ModelDownloadPhase phase;
  final int attempt;
  final double bytesPerSecond;

  /// Host the current attempt downloads from.
  final String? source;

  /// The last attempt's error while retrying, or the terminal error.
  final String? error;

  double get fraction =>
      totalBytes == 0 ? 0.0 : (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  bool get isDone => phase == ModelDownloadPhase.done;
  bool get isFailed => phase == ModelDownloadPhase.failed;

  String get speedLabel {
    if (bytesPerSecond >= 1 << 20) return '${(bytesPerSecond / (1 << 20)).toStringAsFixed(1)} MB/s';
    if (bytesPerSecond >= 1 << 10) return '${(bytesPerSecond / (1 << 10)).toStringAsFixed(0)} KB/s';
    return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  }
}

class ModelInstallException implements Exception {
  const ModelInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Installs model weights into a writable models directory.
///
/// Downloads resume from a `.part` file across attempts, alternate between the
/// configured source and the mirror when the official host is failing, and
/// are verified by size and SHA-256 before the file is moved into place.
/// Files obtained elsewhere can be imported through [importFile]. Read-only
/// directories (a Release package's `models/` folder) are searched first.
class WhisperModelStore {
  WhisperModelStore({
    required this.installDirectory,
    List<Directory> searchDirectories = const [],
    ModelDownloadSettings Function()? downloadSettings,
    HttpClient Function()? clientFactory,
    this.maxAttempts = 12,
    this.stallTimeout = const Duration(seconds: 30),
    this.retryDelay = const Duration(seconds: 2),
  })  : searchDirectories = [installDirectory, ...searchDirectories],
        _downloadSettings = downloadSettings ?? (() => const ModelDownloadSettings()),
        _clientFactory = clientFactory ?? HttpClient.new;

  final Directory installDirectory;
  final List<Directory> searchDirectories;
  final int maxAttempts;
  final Duration stallTimeout;
  final Duration retryDelay;
  final ModelDownloadSettings Function() _downloadSettings;
  final HttpClient Function() _clientFactory;
  final Map<String, Future<void>> _downloads = {};

  static Future<WhisperModelStore> platformDefault({
    ModelDownloadSettings Function()? downloadSettings,
  }) async {
    final support = await getApplicationSupportDirectory();
    final install = Directory('${support.path}${Platform.pathSeparator}models');
    final search = <Directory>[];
    if (Platform.isWindows) {
      final executableDirectory = File(Platform.resolvedExecutable).parent.path;
      search.add(Directory('$executableDirectory\\models'));
    } else if (Platform.isIOS || Platform.isMacOS) {
      // The application bundle carries the small VAD model.
      search.add(File(Platform.resolvedExecutable).parent);
    }
    final configured = Platform.environment['AI_VIDEO_MODELS_DIR'];
    if (configured != null && configured.isNotEmpty) search.insert(0, Directory(configured));
    return WhisperModelStore(
      installDirectory: install,
      searchDirectories: search,
      downloadSettings: downloadSettings,
    );
  }

  /// The installed file for [spec], or null. A file with the wrong size is
  /// treated as absent (an interrupted copy or an older revision).
  Future<File?> installedFile(WhisperModelSpec spec) async {
    final override = Platform.environment['AI_VIDEO_WHISPER_MODEL'];
    if (spec.kind == WhisperModelKind.recognition && override != null && override.isNotEmpty) {
      final file = File(override);
      if (await file.exists()) return file;
    }
    for (final directory in searchDirectories) {
      final file = File('${directory.path}${Platform.pathSeparator}${spec.fileName}');
      if (await file.exists() && await file.length() == spec.sizeBytes) return file;
    }
    return null;
  }

  Future<bool> isInstalled(WhisperModelSpec spec) async => await installedFile(spec) != null;

  /// Bytes already held in the resumable partial download, if any.
  Future<int> partialBytes(WhisperModelSpec spec) async {
    final part = _partFile(spec);
    return await part.exists() ? await part.length() : 0;
  }

  Future<void> delete(WhisperModelSpec spec) async {
    final file = _targetFile(spec);
    if (await file.exists()) await file.delete();
    final part = _partFile(spec);
    if (await part.exists()) await part.delete();
  }

  /// Copies a file obtained elsewhere into the store after verifying it.
  /// Returns the installed file.
  Future<File> importFile(WhisperModelSpec spec, String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw const ModelInstallException('文件不存在。');
    final length = await source.length();
    if (length != spec.sizeBytes) {
      throw ModelInstallException(
        '文件大小不符：$length 字节，${spec.fileName} 应为 ${spec.sizeBytes} 字节。',
      );
    }
    final digest = await sha256.bind(source.openRead()).first;
    if (digest.toString() != spec.sha256) {
      throw const ModelInstallException('SHA-256 校验失败，文件可能损坏或不是该模型。');
    }
    await installDirectory.create(recursive: true);
    final target = _targetFile(spec);
    if (target.path == source.path) return target;
    final part = _partFile(spec);
    if (await part.exists()) await part.delete();
    final staged = File('${target.path}.import');
    await source.copy(staged.path);
    if (await target.exists()) await target.delete();
    await staged.rename(target.path);
    return target;
  }

  /// Downloads [spec] unless already installed, reporting progress. Concurrent
  /// callers for the same model share one download.
  Stream<ModelDownloadProgress> download(WhisperModelSpec spec) {
    final controller = StreamController<ModelDownloadProgress>();
    final pending = _downloads[spec.id];
    final run = pending ?? _run(spec, controller.add);
    _downloads[spec.id] = run;
    run.then((_) {
      controller.add(ModelDownloadProgress(
        spec: spec,
        receivedBytes: spec.sizeBytes,
        totalBytes: spec.sizeBytes,
        phase: ModelDownloadPhase.done,
      ));
    }).catchError((Object error) {
      controller.add(ModelDownloadProgress(
        spec: spec,
        receivedBytes: 0,
        totalBytes: spec.sizeBytes,
        phase: ModelDownloadPhase.failed,
        error: error.toString(),
      ));
    }).whenComplete(() {
      if (identical(_downloads[spec.id], run)) _downloads.remove(spec.id);
      controller.close();
    });
    return controller.stream;
  }

  Future<File> ensureInstalled(WhisperModelSpec spec) async {
    final existing = await installedFile(spec);
    if (existing != null) return existing;
    await for (final progress in download(spec)) {
      if (progress.isFailed) throw ModelInstallException(progress.error ?? '下载失败');
    }
    final installed = await installedFile(spec);
    if (installed == null) throw ModelInstallException('模型安装后仍未找到：${spec.fileName}');
    return installed;
  }

  File _targetFile(WhisperModelSpec spec) =>
      File('${installDirectory.path}${Platform.pathSeparator}${spec.fileName}');

  File _partFile(WhisperModelSpec spec) => File('${_targetFile(spec).path}.part');

  Future<void> _run(WhisperModelSpec spec, void Function(ModelDownloadProgress) report) async {
    if (await isInstalled(spec)) return;
    await installDirectory.create(recursive: true);
    final part = _partFile(spec);
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final settings = _downloadSettings();
      // Alternate between the configured source and the public mirror so a
      // blocked or throttled origin does not burn every attempt.
      final base = settings.isOfficial && attempt.isEven
          ? ModelDownloadSettings.mirrorBaseUrl
          : settings.baseUrl;
      final url = ModelDownloadSettings.rewrite(spec.url, base);
      try {
        await _attempt(spec, part, url, settings.proxyHostPort, attempt, lastError, report);
        lastError = null;
        break;
      } on Object catch (error) {
        lastError = error;
        if (attempt == maxAttempts) rethrow;
        final delay = retryDelay * math.min(1 << (attempt - 1), 16);
        report(ModelDownloadProgress(
          spec: spec,
          receivedBytes: await partialBytes(spec),
          totalBytes: spec.sizeBytes,
          attempt: attempt,
          source: url.host,
          error: '$error（${delay.inSeconds} 秒后重试）',
        ));
        await Future<void>.delayed(delay);
      }
    }
    if (await part.length() != spec.sizeBytes) {
      throw ModelInstallException('下载大小不符：${await part.length()} / ${spec.sizeBytes}');
    }
    report(ModelDownloadProgress(
      spec: spec,
      receivedBytes: spec.sizeBytes,
      totalBytes: spec.sizeBytes,
      phase: ModelDownloadPhase.verifying,
    ));
    final digest = await sha256.bind(part.openRead()).first;
    if (digest.toString() != spec.sha256) {
      await part.delete();
      throw const ModelInstallException('SHA-256 校验失败，已删除下载文件，请重试。');
    }
    final target = _targetFile(spec);
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  }

  Future<void> _attempt(
    WhisperModelSpec spec,
    File part,
    Uri url,
    String? proxy,
    int attempt,
    Object? previousError,
    void Function(ModelDownloadProgress) report,
  ) async {
    var received = await part.exists() ? await part.length() : 0;
    if (received > spec.sizeBytes) {
      await part.delete();
      received = 0;
    }
    if (received == spec.sizeBytes) return;
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'AIVideoPlayerNext';
    if (proxy != null) {
      client.findProxy = (_) => 'PROXY $proxy';
    } else {
      client.findProxy = HttpClient.findProxyFromEnvironment;
    }
    try {
      final request = await client.getUrl(url);
      if (received > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      final response = await request.close().timeout(stallTimeout);
      if (response.statusCode == HttpStatus.ok && received > 0) {
        // The origin ignored the range; start over.
        await part.writeAsBytes(const [], flush: true);
        received = 0;
      } else if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      final sink = part.openWrite(mode: FileMode.append);
      var windowStart = DateTime.now();
      var windowBytes = 0;
      var speed = 0.0;
      var lastReport = windowStart;
      try {
        await for (final bytes in response.timeout(stallTimeout)) {
          sink.add(bytes);
          received += bytes.length;
          windowBytes += bytes.length;
          final now = DateTime.now();
          final windowElapsed = now.difference(windowStart);
          if (windowElapsed >= const Duration(seconds: 2)) {
            speed = windowBytes * 1000 / windowElapsed.inMilliseconds;
            windowStart = now;
            windowBytes = 0;
          }
          if (now.difference(lastReport) > const Duration(milliseconds: 250)) {
            lastReport = now;
            report(ModelDownloadProgress(
              spec: spec,
              receivedBytes: received,
              totalBytes: spec.sizeBytes,
              attempt: attempt,
              bytesPerSecond: speed,
              source: url.host,
              error: previousError?.toString(),
            ));
          }
        }
      } finally {
        await sink.close();
      }
      if (received < spec.sizeBytes) {
        throw HttpException('连接在 $received / ${spec.sizeBytes} 字节处中断', uri: url);
      }
    } finally {
      client.close(force: true);
    }
  }
}
