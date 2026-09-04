import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/speech/whisper_model_catalog.dart';
import 'package:ai_video_player_next/features/speech/whisper_model_store.dart';

/// Stands in for a published weight: a few kilobytes with the same contract as
/// the real ones - exact size and hash known in advance.
final Uint8List _payload =
    Uint8List.fromList(List<int>.generate(8192, (index) => index % 251));

WhisperModelDescriptor _model(Uri source) => WhisperModelDescriptor(
      id: 'ggml-test-model',
      label: 'test',
      sizeBytes: _payload.length,
      sha256: sha256.convert(_payload).toString(),
      source: source.toString(),
      license: 'MIT',
    );

void main() {
  late Directory temporary;
  late HttpServer server;
  var rangeRequests = <String>[];
  var ignoreRange = false;
  var corrupt = false;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('whisper-model-store');
    rangeRequests = <String>[];
    ignoreRange = false;
    corrupt = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) rangeRequests.add(range);
      final body = corrupt
          ? Uint8List.fromList(List<int>.filled(_payload.length, 7))
          : _payload;
      if (range != null && !ignoreRange) {
        final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.add(body.sublist(from));
      } else {
        request.response.add(body);
      }
      await request.response.close();
    }));
  });

  tearDown(() async {
    await server.close(force: true);
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  Uri url() => Uri.parse('http://${server.address.host}:${server.port}/model.bin');

  WhisperModelStore store() => WhisperModelStore(directory: temporary);

  test('downloads, verifies and installs a weight', () async {
    final model = _model(url());
    final phases = <WhisperModelPhase>[];
    await for (final progress in store().download(model)) {
      phases.add(progress.phase);
    }

    expect(phases, contains(WhisperModelPhase.verifying));
    expect(phases.last, WhisperModelPhase.installed);
    expect(await store().installedPath(model), isNotNull);
    expect(File('${temporary.path}/${model.fileName}').readAsBytesSync(), _payload);
  });

  test('a partial file is resumed rather than fetched again', () async {
    final model = _model(url());
    // An interrupted attempt left the first half on disk.
    File('${temporary.path}/${model.fileName}${WhisperModelStore.partialSuffix}')
        .writeAsBytesSync(_payload.sublist(0, 4096));

    final progress = await store().download(model).toList();

    expect(rangeRequests, ['bytes=4096-']);
    expect(progress.first.receivedBytes, 4096);
    expect(progress.last.phase, WhisperModelPhase.installed);
    expect(File('${temporary.path}/${model.fileName}').readAsBytesSync(), _payload);
  });

  test('a server that ignores the range restarts instead of concatenating',
      () async {
    ignoreRange = true;
    final model = _model(url());
    File('${temporary.path}/${model.fileName}${WhisperModelStore.partialSuffix}')
        .writeAsBytesSync(_payload.sublist(0, 4096));

    await store().download(model).toList();

    // Appending the full body to the existing half would have produced a file
    // of the wrong length and a hash mismatch.
    expect(File('${temporary.path}/${model.fileName}').readAsBytesSync(), _payload);
  });

  test('content that fails its hash is rejected and not left behind', () async {
    corrupt = true;
    final model = _model(url());

    await expectLater(
      store().download(model).toList(),
      throwsA(isA<WhisperModelException>()),
    );
    expect(await store().installedPath(model), isNull);
    expect(
      File('${temporary.path}/${model.fileName}${WhisperModelStore.partialSuffix}')
          .existsSync(),
      isFalse,
    );
  });

  test('an HTTP failure is reported and installs nothing', () async {
    final model = _model(url());
    await server.close(force: true);

    await expectLater(
      store().download(model).toList(),
      throwsA(isA<WhisperModelException>()),
    );
    expect(await store().installedPath(model), isNull);
  });

  test('a truncated file on disk does not count as installed', () async {
    final model = _model(url());
    File('${temporary.path}/${model.fileName}')
        .writeAsBytesSync(_payload.sublist(0, 100));

    expect(await store().installedPath(model), isNull);
  });

  test('deleting removes both the weight and any partial', () async {
    final model = _model(url());
    await store().download(model).toList();
    File('${temporary.path}/${model.fileName}${WhisperModelStore.partialSuffix}')
        .writeAsBytesSync(const [1, 2, 3]);

    await store().delete(model);

    expect(await store().installedPath(model), isNull);
    expect(await store().partialBytes(model), 0);
    expect(await store().usedBytes(), 0);
  });
}
