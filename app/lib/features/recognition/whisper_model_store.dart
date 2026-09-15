import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'whisper_model_catalog.dart';

class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.spec,
    required this.receivedBytes,
    required this.totalBytes,
    this.phase = ModelDownloadPhase.downloading,
    this.error,
  });

  final WhisperModelSpec spec;
  final int receivedBytes;
  final int totalBytes;
  final ModelDownloadPhase phase;
  final String? error;

  double get fraction =>
      totalBytes == 0 ? 0.0 : (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  bool get isDone => phase == ModelDownloadPhase.done;
  bool get isFailed => phase == ModelDownloadPhase.failed;
}

enum ModelDownloadPhase { downloading, verifying, done, failed }

/// Installs model weights into a writable models directory with resumable
/// range downloads, then verifies size and SHA-256 before the file is moved
/// into place. Read-only directories (a Release package's `models/` folder)
/// are searched first so a pre-provisioned weight is honoured.
class WhisperModelStore {
  WhisperModelStore({
    required this.installDirectory,
    List<Directory> searchDirectories = const [],
    HttpClient Function()? clientFactory,
  })  : searchDirectories = [installDirectory, ...searchDirectories],
        _clientFactory = clientFactory ?? HttpClient.new;

  final Directory installDirectory;
  final List<Directory> searchDirectories;
  final HttpClient Function() _clientFactory;
  final Map<String, Future<void>> _downloads = {};

  static Future<WhisperModelStore> platformDefault() async {
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
    return WhisperModelStore(installDirectory: install, searchDirectories: search);
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

  Future<void> delete(WhisperModelSpec spec) async {
    final file = File('${installDirectory.path}${Platform.pathSeparator}${spec.fileName}');
    if (await file.exists()) await file.delete();
    final part = File('${file.path}.part');
    if (await part.exists()) await part.delete();
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
      if (progress.isFailed) throw StateError(progress.error ?? '下载失败');
    }
    final installed = await installedFile(spec);
    if (installed == null) throw StateError('模型安装后仍未找到：${spec.fileName}');
    return installed;
  }

  Future<void> _run(WhisperModelSpec spec, void Function(ModelDownloadProgress) report) async {
    if (await isInstalled(spec)) return;
    await installDirectory.create(recursive: true);
    final target = File('${installDirectory.path}${Platform.pathSeparator}${spec.fileName}');
    final part = File('${target.path}.part');
    var received = await part.exists() ? await part.length() : 0;
    if (received > spec.sizeBytes) {
      await part.delete();
      received = 0;
    }
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 30)
      ..userAgent = 'AIVideoPlayerNext';
    try {
      if (received < spec.sizeBytes) {
        final request = await client.getUrl(spec.url);
        if (received > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
        final response = await request.close();
        if (response.statusCode == HttpStatus.ok && received > 0) {
          // The origin ignored the range; start over.
          await part.writeAsBytes(const [], flush: true);
          received = 0;
        } else if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          throw HttpException('HTTP ${response.statusCode}', uri: spec.url);
        }
        final sink = part.openWrite(mode: FileMode.append);
        try {
          var lastReport = DateTime.now();
          await for (final bytes in response) {
            sink.add(bytes);
            received += bytes.length;
            final now = DateTime.now();
            if (now.difference(lastReport) > const Duration(milliseconds: 200)) {
              lastReport = now;
              report(ModelDownloadProgress(
                spec: spec,
                receivedBytes: received,
                totalBytes: spec.sizeBytes,
              ));
            }
          }
        } finally {
          await sink.close();
        }
      }
    } finally {
      client.close(force: true);
    }
    if (await part.length() != spec.sizeBytes) {
      throw StateError('下载大小不符：${await part.length()} / ${spec.sizeBytes}');
    }
    report(ModelDownloadProgress(
      spec: spec,
      receivedBytes: received,
      totalBytes: spec.sizeBytes,
      phase: ModelDownloadPhase.verifying,
    ));
    final digest = await sha256.bind(part.openRead()).first;
    if (digest.toString() != spec.sha256) {
      await part.delete();
      throw StateError('SHA-256 校验失败，已删除下载文件');
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  }
}
