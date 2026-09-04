import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/speech/whisper_model_catalog.dart';

/// Where an installed weight is, and how a missing one is fetched.
///
/// Weights are not shipped inside the application any more: a build carries no
/// model at all and the user installs the ones they want. The files are large
/// enough (half a gigabyte to three) that the download has to survive being
/// interrupted, so a partial file is kept beside the target and resumed with a
/// range request rather than started again.
class WhisperModelStore {
  WhisperModelStore({Directory? directory, HttpClient Function()? httpClient})
      : _directory = directory,
        _httpClient = httpClient ?? _defaultClient;

  final Directory? _directory;
  final HttpClient Function() _httpClient;
  Directory? _resolved;

  /// Suffix of the file a download writes into before it has been verified.
  /// A partial file must never be loadable as a model, so it does not carry
  /// the final name until its hash matches.
  static const partialSuffix = '.part';

  static HttpClient _defaultClient() {
    final client = HttpClient();
    // The only proxy configuration honoured. On desktop this picks up
    // HTTP_PROXY/HTTPS_PROXY; iOS sets no such variables, so downloads there
    // go direct, which is what the platform does for its own traffic anyway.
    client.findProxy = HttpClient.findProxyFromEnvironment;
    return client;
  }

  Future<Directory> directory() async {
    final existing = _resolved ?? _directory;
    if (existing != null) {
      if (!existing.existsSync()) await existing.create(recursive: true);
      return _resolved = existing;
    }
    final support = await getApplicationSupportDirectory();
    final models = Directory('${support.path}${Platform.pathSeparator}models');
    if (!models.existsSync()) await models.create(recursive: true);
    return _resolved = models;
  }

  Future<File> fileFor(WhisperModelDescriptor model) async {
    final dir = await directory();
    return File('${dir.path}${Platform.pathSeparator}${model.fileName}');
  }

  /// Path of [model] when it is installed and the right size, else null.
  ///
  /// The size is re-checked on every lookup because the file can be truncated
  /// by a device running out of space long after it was verified, and loading
  /// a truncated weight crashes inside whisper.cpp rather than failing here.
  Future<String?> installedPath(WhisperModelDescriptor model) async {
    final file = await fileFor(model);
    if (!file.existsSync()) return null;
    return file.lengthSync() == model.sizeBytes ? file.path : null;
  }

  Future<Set<String>> installedIds() async {
    final ids = <String>{};
    for (final model in whisperModelCatalog) {
      if (await installedPath(model) != null) ids.add(model.id);
    }
    return ids;
  }

  /// Bytes already fetched for an unfinished download, zero when there is none.
  Future<int> partialBytes(WhisperModelDescriptor model) async {
    final file = await fileFor(model);
    final partial = File('${file.path}$partialSuffix');
    return partial.existsSync() ? partial.lengthSync() : 0;
  }

  Future<void> delete(WhisperModelDescriptor model) async {
    final file = await fileFor(model);
    if (file.existsSync()) await file.delete();
    final partial = File('${file.path}$partialSuffix');
    if (partial.existsSync()) await partial.delete();
  }

  /// Total bytes held by installed weights and unfinished downloads.
  Future<int> usedBytes() async {
    final dir = await directory();
    var total = 0;
    for (final entity in dir.listSync()) {
      if (entity is File) total += entity.lengthSync();
    }
    return total;
  }

  /// Fetches [model], resuming an interrupted attempt when one is on disk.
  ///
  /// The returned stream reports progress and closes when the weight is
  /// installed; it emits an error if the download fails or the file does not
  /// match the catalog. Cancelling the subscription abandons the download and
  /// keeps what has arrived so far, so a later call resumes it.
  Stream<WhisperModelProgress> download(WhisperModelDescriptor model) {
    late StreamController<WhisperModelProgress> controller;
    var cancelled = false;
    controller = StreamController<WhisperModelProgress>(
      onCancel: () => cancelled = true,
    );
    unawaited(_run(model, controller, () => cancelled));
    return controller.stream;
  }

  Future<void> _run(
    WhisperModelDescriptor model,
    StreamController<WhisperModelProgress> controller,
    bool Function() cancelled,
  ) async {
    final client = _httpClient();
    File? partial;
    try {
      final target = await fileFor(model);
      if (target.existsSync() && target.lengthSync() == model.sizeBytes) {
        controller.add(WhisperModelProgress(
          model: model,
          phase: WhisperModelPhase.installed,
          receivedBytes: model.sizeBytes,
        ));
        return;
      }
      partial = File('${target.path}$partialSuffix');
      var have = partial.existsSync() ? partial.lengthSync() : 0;
      if (have > model.sizeBytes) {
        // A partial longer than the published file is not a prefix of it.
        await partial.delete();
        have = 0;
      }

      final request = await client.getUrl(model.sourceUri);
      if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw WhisperModelException(
            '下载失败：服务器返回 ${response.statusCode}。');
      }
      // A server that ignores the range restarts the file; anything already on
      // disk is then a prefix of a different response and must go.
      final resumed = response.statusCode == HttpStatus.partialContent;
      if (!resumed) have = 0;

      final sink = partial.openWrite(
        mode: resumed ? FileMode.writeOnlyAppend : FileMode.writeOnly,
      );
      var received = have;
      controller.add(WhisperModelProgress(
        model: model,
        phase: WhisperModelPhase.downloading,
        receivedBytes: received,
      ));
      try {
        await for (final chunk in response) {
          if (cancelled()) {
            await sink.flush();
            return;
          }
          sink.add(chunk);
          received += chunk.length;
          controller.add(WhisperModelProgress(
            model: model,
            phase: WhisperModelPhase.downloading,
            receivedBytes: received,
          ));
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (cancelled()) return;

      final size = partial.lengthSync();
      if (size != model.sizeBytes) {
        throw WhisperModelException(
            '下载不完整：得到 $size 字节，应为 ${model.sizeBytes} 字节。');
      }

      controller.add(WhisperModelProgress(
        model: model,
        phase: WhisperModelPhase.verifying,
        receivedBytes: size,
      ));
      final digest = await _sha256OfFile(partial);
      if (digest != model.sha256) {
        // Keeping a file that failed its hash would let a corrupted or
        // substituted weight be loaded on the next launch.
        await partial.delete();
        throw const WhisperModelException('校验失败：文件内容与登记的 SHA-256 不一致。');
      }

      await partial.rename(target.path);
      controller.add(WhisperModelProgress(
        model: model,
        phase: WhisperModelPhase.installed,
        receivedBytes: size,
      ));
    } on Object catch (error, stackTrace) {
      controller.addError(
        error is WhisperModelException
            ? error
            : WhisperModelException('下载失败：$error'),
        stackTrace,
      );
    } finally {
      client.close(force: true);
      await controller.close();
    }
  }

  /// Hashes the file in chunks: these weights do not fit in memory.
  static Future<String> _sha256OfFile(File file) async {
    final output = _DigestSink();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return output.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late final Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

enum WhisperModelPhase { downloading, verifying, installed }

class WhisperModelProgress {
  const WhisperModelProgress({
    required this.model,
    required this.phase,
    required this.receivedBytes,
  });

  final WhisperModelDescriptor model;
  final WhisperModelPhase phase;
  final int receivedBytes;

  double get fraction => model.sizeBytes == 0
      ? 0
      : (receivedBytes / model.sizeBytes).clamp(0.0, 1.0);
}

class WhisperModelException implements Exception {
  const WhisperModelException(this.message);

  final String message;

  @override
  String toString() => message;
}
