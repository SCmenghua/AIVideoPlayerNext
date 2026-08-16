import 'dart:convert';
import 'dart:io';

void printUsage(IOSink output) {
  output.writeln(
    'usage: dart run tool/verify_speech_regression.dart '
    '--manifest PATH --result PATH [--asset-id ID]',
  );
}

Never usage(String message) {
  stderr.writeln(message);
  printUsage(stderr);
  exitCode = 2;
  exit(2);
}

String normalizeText(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

Map<String, dynamic> asObject(Object? value, String description) {
  if (value is! Map<String, dynamic>) {
    usage('$description must be a JSON object');
  }
  return value;
}

int asInt(Object? value, String description) {
  if (value is! num) {
    usage('$description must be a number');
  }
  return value.toInt();
}

Future<void> main(List<String> arguments) async {
  String? manifestPath;
  String? resultPath;
  String? assetId;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--help' || argument == '-h') {
      printUsage(stdout);
      return;
    } else if (argument == '--manifest' && index + 1 < arguments.length) {
      manifestPath = arguments[++index];
    } else if (argument == '--result' && index + 1 < arguments.length) {
      resultPath = arguments[++index];
    } else if (argument == '--asset-id' && index + 1 < arguments.length) {
      assetId = arguments[++index];
    } else {
      usage('Unknown or incomplete argument: $argument');
    }
  }
  if (manifestPath == null || resultPath == null) {
    usage('Both --manifest and --result are required');
  }

  final manifestFile = File(manifestPath);
  final resultFile = File(resultPath);
  if (!await manifestFile.exists()) usage('Manifest file does not exist');
  if (!await resultFile.exists()) usage('Result file does not exist');

  final manifest = asObject(
    jsonDecode(await manifestFile.readAsString()),
    'manifest',
  );
  final assets = manifest['assets'];
  if (assets is! List || assets.isEmpty) usage('manifest.assets is empty');
  final asset = assets
      .map((value) => asObject(value, 'asset'))
      .where((value) => assetId == null || value['assetId'] == assetId)
      .cast<Map<String, dynamic>>()
      .firstOrNull;
  if (asset == null) usage('No matching asset in manifest');

  final expectedText = asset['expectedText'];
  final expectedLanguage = asset['language'];
  if (expectedText is! String || expectedLanguage is! String) {
    usage('asset requires expectedText and language');
  }
  final durationMs = asInt(asset['durationMs'], 'asset.durationMs');
  final timingErrorMs =
      asInt(asset['allowedTimingErrorMs'], 'asset.allowedTimingErrorMs');

  final segments = <Map<String, dynamic>>[];
  Map<String, dynamic>? diagnostic;
  final lines = await resultFile.readAsLines();
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final event = asObject(jsonDecode(line), 'JSONL line');
    switch (event['type']) {
      case 'segment':
        segments.add(event);
        break;
      case 'diagnostic':
        diagnostic = event;
        break;
      default:
        usage('Unexpected JSONL event type: ${event['type']}');
    }
  }

  final failures = <String>[];
  if (segments.isEmpty) failures.add('Expected at least one segment');
  final transcript = normalizeText(
    segments.map((segment) => segment['text'] as String? ?? '').join(' '),
  );
  if (transcript != normalizeText(expectedText)) {
    failures.add('Transcript does not match manifest expectedText');
  }
  for (final segment in segments) {
    if (segment['kind'] != 'final') {
      failures.add('Segment kind must be final');
      break;
    }
    if (segment['source'] != 'whisperCpp') {
      failures.add('Segment source must be whisperCpp');
      break;
    }
    if (segment['sessionId'] is! String || segment['segmentId'] is! String) {
      failures.add('Segment is missing sessionId or segmentId');
      break;
    }
    if (segment['text'] is! String || (segment['text'] as String).trim().isEmpty) {
      failures.add('Segment text is missing or empty');
      break;
    }
    final language = segment['language'];
    if (language != expectedLanguage) {
      failures.add('Unexpected segment language: $language');
      break;
    }
    final startMs = asInt(segment['startMs'], 'segment.startMs');
    final endMs = asInt(segment['endMs'], 'segment.endMs');
    if (startMs < 0 || endMs <= startMs || endMs > durationMs + timingErrorMs) {
      failures.add('Invalid segment timing: $startMs-$endMs ms');
      break;
    }
  }
  if (diagnostic == null) {
    failures.add('Missing diagnostic event');
  } else {
    final segmentCount = asInt(diagnostic['segmentCount'], 'diagnostic.segmentCount');
    if (diagnostic['sessionId'] is! String ||
        asInt(diagnostic['audioSamples'], 'diagnostic.audioSamples') <= 0 ||
        asInt(diagnostic['inputSampleRate'], 'diagnostic.inputSampleRate') != 16000 ||
        asInt(diagnostic['outputSampleRate'], 'diagnostic.outputSampleRate') != 16000 ||
        asInt(diagnostic['inputChannels'], 'diagnostic.inputChannels') != 1 ||
        asInt(diagnostic['outputChannels'], 'diagnostic.outputChannels') != 1 ||
        diagnostic['inferenceMs'] is! num ||
        diagnostic['realtimeFactor'] is! num) {
      failures.add('Diagnostic event is missing required normalized-audio fields');
    }
    if (segmentCount != segments.length) {
    failures.add(
        'Diagnostic segmentCount $segmentCount does not match $segments.length segments',
      );
    }
  }

  if (failures.isNotEmpty) {
    for (final failure in failures) {
      stderr.writeln('FAIL: $failure');
    }
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'PASS: ${asset['assetId']} (${segments.length} segments, '
    '$expectedLanguage, $durationMs ms fixture)',
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
