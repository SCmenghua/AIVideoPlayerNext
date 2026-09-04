import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/domain/speech/whisper_model_catalog.dart';

void main() {
  test('catalog matches the qualified models in the speech manifest', () {
    // The manifest records which weights were qualified against which
    // whisper.cpp build, and the app downloads by size and hash. If the two
    // ever disagree the app would verify a download against the wrong digest,
    // so registering a model in one place has to fail here until it is
    // registered in both.
    final manifest = jsonDecode(
      File('../test_assets/speech/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final models = <String, Map<String, dynamic>>{
      for (final entry in manifest['models'] as List<dynamic>)
        (entry as Map<String, dynamic>)['modelId'] as String: entry,
    };

    expect(whisperModelCatalog.map((model) => model.id).toSet(), models.keys.toSet());

    for (final descriptor in whisperModelCatalog) {
      final entry = models[descriptor.id]!;
      expect(descriptor.sizeBytes, entry['sizeBytes'],
          reason: '${descriptor.id} size');
      expect(descriptor.sha256, (entry['sha256'] as String).toLowerCase(),
          reason: '${descriptor.id} sha256');
      expect(descriptor.source, entry['source'],
          reason: '${descriptor.id} source');
      expect(descriptor.license, entry['license'], reason: '${descriptor.id} license');
    }
  });

  test('hashes are lowercase hex of the right width', () {
    for (final descriptor in whisperModelCatalog) {
      expect(descriptor.sha256, matches(RegExp(r'^[0-9a-f]{64}$')),
          reason: descriptor.id);
    }
  });

  test('resolves a stored settings value back to its catalog entry', () {
    expect(whisperModelByFileName('ggml-large-v3-turbo-q5_0.bin')?.id,
        'ggml-large-v3-turbo-q5_0');
    expect(whisperModelByFileName('ggml-nonexistent.bin'), isNull);
  });

  test('the catalog is ordered smallest first', () {
    final sizes = whisperModelCatalog.map((model) => model.sizeBytes).toList();
    expect(sizes, orderedEquals(List<int>.of(sizes)..sort()));
  });
}
