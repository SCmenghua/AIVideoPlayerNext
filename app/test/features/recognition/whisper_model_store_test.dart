import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/features/recognition/recognition_settings.dart';
import 'package:ai_video_player_next/features/recognition/whisper_model_catalog.dart';
import 'package:ai_video_player_next/features/recognition/whisper_model_store.dart';

/// Serves one fake model over HTTP with Range support. The first
/// [dropAfterBytes] bytes of the first request are followed by a closed
/// connection so the client must resume.
class _FlakyModelServer {
  _FlakyModelServer(this.bytes, {this.dropAfterBytes});

  final Uint8List bytes;
  final int? dropAfterBytes;
  late HttpServer _server;
  int requests = 0;
  final List<String?> ranges = [];

  Uri get baseUrl => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requests++;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      var start = 0;
      if (range != null) {
        start = int.parse(range.substring('bytes='.length, range.length - 1));
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
      }
      final drop = requests == 1 ? dropAfterBytes : null;
      final end = drop == null ? bytes.length : (start + drop).clamp(0, bytes.length).toInt();
      request.response.contentLength = bytes.length - start;
      request.response.add(bytes.sublist(start, end));
      await request.response.flush();
      if (drop != null) {
        await request.response.detachSocket().then((socket) => socket.destroy());
      } else {
        await request.response.close();
      }
    });
  }

  Future<void> stop() => _server.close(force: true);
}

WhisperModelSpec _spec(Uint8List bytes, {String host = 'huggingface.co'}) => WhisperModelSpec(
      id: 'test-model',
      fileName: 'ggml-test.bin',
      kind: WhisperModelKind.recognition,
      label: 'test',
      description: 'test',
      url: Uri.parse('https://$host/org/repo/resolve/main/ggml-test.bin'),
      sha256: sha256.convert(bytes).toString(),
      sizeBytes: bytes.length,
    );

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('model-store-test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('rewrites official URLs onto a mirror, keeping the path', () {
    final official = Uri.parse('https://huggingface.co/a/b/resolve/main/x.bin');
    expect(
      ModelDownloadSettings.rewrite(official, 'https://hf-mirror.com').toString(),
      'https://hf-mirror.com/a/b/resolve/main/x.bin',
    );
    expect(
      ModelDownloadSettings.rewrite(official, 'http://proxy.local:8080/hf/').toString(),
      'http://proxy.local:8080/hf/a/b/resolve/main/x.bin',
    );
    expect(ModelDownloadSettings.rewrite(official, 'not a url'), official);
    expect(const ModelDownloadSettings(proxy: '127.0.0.1:10808').proxyHostPort, '127.0.0.1:10808');
    expect(const ModelDownloadSettings(proxy: 'http://127.0.0.1:10808/').proxyHostPort,
        '127.0.0.1:10808');
    expect(const ModelDownloadSettings(proxy: '  ').proxyHostPort, isNull);
  });

  test('resumes after a dropped connection and verifies the file', () async {
    final bytes = Uint8List.fromList(List<int>.generate(200000, (i) => (i * 31) & 0xff));
    final server = _FlakyModelServer(bytes, dropAfterBytes: 64000);
    await server.start();
    addTearDown(server.stop);
    final spec = _spec(bytes);
    final store = WhisperModelStore(
      installDirectory: temp,
      downloadSettings: () => ModelDownloadSettings(baseUrl: server.baseUrl.toString()),
      retryDelay: Duration.zero,
      maxAttempts: 4,
    );

    final progress = await store.download(spec).toList();

    expect(progress.last.isDone, isTrue);
    expect(server.requests, 2);
    expect(server.ranges.last, 'bytes=64000-');
    expect(progress.any((p) => !p.isFailed && p.error != null), isTrue,
        reason: 'the retry is reported with the previous error');
    final installed = await store.installedFile(spec);
    expect(installed, isNotNull);
    expect(await installed!.readAsBytes(), bytes);
    expect(await File('${installed.path}.part').exists(), isFalse);
  });

  test('rejects a corrupted download and gives up after the attempt limit', () async {
    final bytes = Uint8List.fromList(List<int>.generate(1000, (i) => i & 0xff));
    final server = _FlakyModelServer(bytes);
    await server.start();
    addTearDown(server.stop);
    final wrongHash = WhisperModelSpec(
      id: 'bad',
      fileName: 'ggml-bad.bin',
      kind: WhisperModelKind.recognition,
      label: 'bad',
      description: 'bad',
      url: Uri.parse('https://huggingface.co/x/resolve/main/ggml-bad.bin'),
      sha256: 'f' * 64,
      sizeBytes: bytes.length,
    );
    final store = WhisperModelStore(
      installDirectory: temp,
      downloadSettings: () => ModelDownloadSettings(baseUrl: server.baseUrl.toString()),
      retryDelay: Duration.zero,
    );
    final progress = await store.download(wrongHash).toList();
    expect(progress.last.isFailed, isTrue);
    expect(progress.last.error, contains('SHA-256'));
    expect(await store.isInstalled(wrongHash), isFalse);
    expect(await store.partialBytes(wrongHash), 0);
  });

  test('imports a verified file and refuses a mismatching one', () async {
    final bytes = Uint8List.fromList(List<int>.generate(5000, (i) => (i * 7) & 0xff));
    final spec = _spec(bytes);
    final store = WhisperModelStore(installDirectory: Directory('${temp.path}/models'));
    final source = File('${temp.path}/downloaded.bin')..writeAsBytesSync(bytes);

    final installed = await store.importFile(spec, source.path);
    expect(installed.path, endsWith(spec.fileName));
    expect(await store.isInstalled(spec), isTrue);

    final wrong = File('${temp.path}/wrong.bin')..writeAsBytesSync(bytes.sublist(1));
    expect(() => store.importFile(spec, wrong.path), throwsA(isA<ModelInstallException>()));
  });
}
