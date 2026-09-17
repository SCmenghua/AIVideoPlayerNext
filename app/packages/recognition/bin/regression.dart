// End-to-end recognition regression: concatenates a labelled clip set into
// one stream, runs the production pipeline (normaliser, VAD segmenter, engine,
// gate, assembler) and reports CER plus timestamp deviation.
//
// dart run recognition:regression --library speech_core.dll --model X.bin \
//   --vad-model silero.bin --dataset DIR [--threads N] [--backend cpu] \
//   [--gap 2.0] [--no-context] \
//   [--summary FILE] [--json FILE] [--max-cer 0.2] [--max-start-deviation-ms 500]
//
// DIR/manifest.json: {"clips":[{"file":"0001.wav","text":"..."}, ...]}
//
// The clips are concatenated into one stream with `--gap` seconds of silence
// between them, so the whole streaming pipeline is exercised. The gap must
// exceed SegmenterOptions.longSilence, otherwise a window spans several clips
// and the per-clip attribution below reports the model's output against the
// wrong reference. `windowDeficit` guards that invariant.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:recognition/recognition.dart';
import 'package:recognition/src/native_bindings.dart';

class Clip {
  Clip(this.file, this.text);

  final String file;
  final String text;
  late Duration offset;
  late Duration duration;
}

class MemorySource implements PcmSource {
  MemorySource(this.samples);

  final Float32List samples;
  final StreamController<RawPcmChunk> _chunks = StreamController.broadcast();
  final StreamController<PcmSourceStatus> _statuses = StreamController.broadcast();
  PcmSourceStatus _status = const PcmSourceStatus.idle();
  int _position = 0;
  bool _running = false;
  bool _scheduled = false;

  @override
  Stream<RawPcmChunk> get chunks => _chunks.stream;
  @override
  Stream<PcmSourceStatus> get statuses => _statuses.stream;
  @override
  PcmSourceStatus get status => _status;

  @override
  Future<void> open(Uri uri, {Duration start = Duration.zero}) async {
    _position = start.inMicroseconds * speechSampleRate ~/ 1000000;
    _set(const PcmSourceStatus(state: PcmSourceState.ready, sampleRate: 16000, channels: 1));
  }

  @override
  Future<void> start() async {
    _running = true;
    _set(_status.copyWith(state: PcmSourceState.running));
    _schedule();
  }

  @override
  Future<void> pause() async {
    _running = false;
    _set(_status.copyWith(state: PcmSourceState.paused));
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position.inMicroseconds * speechSampleRate ~/ 1000000;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _set(_status.copyWith(state: PcmSourceState.stopped));
  }

  @override
  Future<void> dispose() async {
    await _chunks.close();
    await _statuses.close();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    Future<void>.delayed(Duration.zero, () {
      _scheduled = false;
      if (!_running) return;
      const chunkSamples = speechSampleRate ~/ 2;
      final end = (_position + chunkSamples).clamp(0, samples.length).toInt();
      final mediaStart = Duration(microseconds: _position * 1000000 ~/ speechSampleRate);
      final isLast = end >= samples.length;
      _chunks.add(RawPcmChunk(
        samples: Float32List.sublistView(samples, _position, end),
        sampleRate: speechSampleRate,
        channels: 1,
        mediaStart: mediaStart,
        isLast: isLast,
      ));
      _position = end;
      if (isLast) {
        _running = false;
        _set(_status.copyWith(state: PcmSourceState.ended));
      } else {
        _schedule();
      }
    });
  }

  void _set(PcmSourceStatus status) {
    _status = status;
    _statuses.add(status);
  }
}

Float32List loadWav(SpeechCoreBindings bindings, File file) {
  final bytes = file.readAsBytesSync();
  final input = calloc<Uint8>(bytes.length);
  final buffer = calloc<PcmBufferStruct>();
  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    bindings.check(bindings.wavToPcm(input, bytes.length, buffer, nullptr), file.path);
    final samples = Float32List.fromList(buffer.ref.samples.asTypedList(buffer.ref.sampleCount));
    bindings.pcmBufferFree(buffer);
    return samples;
  } finally {
    calloc.free(input);
    calloc.free(buffer);
  }
}

double median(List<num> values) {
  if (values.isEmpty) return 0;
  final sorted = List<num>.of(values)..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle].toDouble()
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (!argument.startsWith('--')) continue;
    final key = argument.substring(2);
    options[key] = i + 1 < arguments.length && !arguments[i + 1].startsWith('--')
        ? arguments[++i]
        : 'true';
  }
  final library = options['library'];
  final model = options['model'];
  final dataset = options['dataset'];
  if (library == null || model == null || dataset == null) {
    stderr.writeln('usage: --library PATH --model PATH --dataset DIR [--vad-model PATH] '
        '[--threads N] [--backend auto|cpu|vulkan|metal] [--language ja] '
        '[--summary FILE] [--json FILE] [--max-cer X] [--max-start-deviation-ms N]');
    exitCode = 2;
    return;
  }
  final threads = int.tryParse(options['threads'] ?? '') ?? Platform.numberOfProcessors;
  final backend = SpeechBackend.values.firstWhere(
    (value) => value.name == (options['backend'] ?? 'auto'),
    orElse: () => SpeechBackend.auto,
  );
  final language = options['language'] ?? 'ja';
  const segmenter = SegmenterOptions();
  // Long enough for the segmenter's longSilence cut to fire inside every gap,
  // so one clip becomes exactly one window.
  final minimumGap = segmenter.longSilence.inMilliseconds / 1000 + 0.5;
  final gapSeconds = double.tryParse(options['gap'] ?? '') ?? minimumGap;
  if (gapSeconds < minimumGap) {
    stderr.writeln('--gap $gapSeconds is below the segmenter cut threshold '
        '(${minimumGap.toStringAsFixed(1)} s); windows would span several clips');
    exitCode = 2;
    return;
  }
  final contextEnabled = options['no-context'] == null;

  final manifest = jsonDecode(File('$dataset/manifest.json').readAsStringSync())
      as Map<String, Object?>;
  final clips = (manifest['clips'] as List<Object?>)
      .map((raw) => raw as Map<String, Object?>)
      .map((raw) => Clip(raw['file'] as String, raw['text'] as String))
      .toList();
  if (clips.isEmpty) {
    stderr.writeln('dataset has no clips');
    exitCode = 2;
    return;
  }

  final bindings = SpeechCoreBindings.open(library);
  final gap = Float32List((gapSeconds * speechSampleRate).round());
  final pieces = <Float32List>[];
  var offsetSamples = 0;
  for (final clip in clips) {
    final samples = loadWav(bindings, File('$dataset/${clip.file}'));
    clip.offset = Duration(microseconds: offsetSamples * 1000000 ~/ speechSampleRate);
    clip.duration = Duration(microseconds: samples.length * 1000000 ~/ speechSampleRate);
    pieces.add(samples);
    pieces.add(gap);
    offsetSamples += samples.length + gap.length;
  }
  final all = Float32List(offsetSamples);
  var cursor = 0;
  for (final piece in pieces) {
    all.setAll(cursor, piece);
    cursor += piece.length;
  }

  final engine = WhisperEngine(libraryPath: library, modelPath: model, backend: backend);
  final vadModel = options['vad-model'];
  final SpeechProbabilityProvider vad = vadModel == null
      ? EnergyVad()
      : VadDetector(libraryPath: library, modelPath: vadModel, threads: 2);
  final config = RecognitionConfig(
    modelPath: model,
    vadModelPath: vadModel,
    language: language,
    backend: backend,
    threads: threads,
    segmenter: segmenter,
    contextEnabled: contextEnabled,
    leadPause: null,
    maxPendingWindows: 1000,
  );
  final source = MemorySource(all);
  final windows = <Map<String, Object?>>[];
  final dropped = <String>[];
  final session = RecognitionSession(
    source: source,
    engine: engine,
    vad: vad,
    config: config,
    converter: PassthroughConverter(),
    onLog: (event) {
      if (event.message == '识别窗口完成') {
        windows.add(event.details);
        dropped.addAll((event.details['丢弃'] as List<Object?>).map((e) => e.toString()));
      }
      if (event.level == RecognitionLogLevel.error) {
        stderr.writeln('${event.message} ${event.details}');
      }
    },
  );

  final started = DateTime.now();
  await session.prepare();
  stdout.writeln('engine: ${engine.backendInfo}');
  await session.open(Uri.parse('memory://dataset'));
  while (session.diagnostics.state != RecognitionState.ended &&
      session.diagnostics.state != RecognitionState.error) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final wall = DateTime.now().difference(started);
  if (session.diagnostics.state == RecognitionState.error) {
    stderr.writeln('session error: ${session.diagnostics.message}');
    exitCode = 5;
  }
  final transcript = session.transcript;

  final results = <Map<String, Object?>>[];
  final cers = <double>[];
  final startDeviations = <int>[];
  final claimed = <String>{};
  var totalReferenceChars = 0;
  var totalEdits = 0.0;
  for (final clip in clips) {
    final from = clip.offset - Duration(milliseconds: (gapSeconds * 500).round());
    final to = clip.offset + clip.duration + Duration(milliseconds: (gapSeconds * 500).round());
    final segments = transcript.segments.where((segment) {
      final midpoint = (segment.startMs + segment.endMs) ~/ 2;
      return midpoint >= from.inMilliseconds && midpoint < to.inMilliseconds;
    }).toList();
    claimed.addAll(segments.map((segment) => segment.id));
    final hypothesis = segments.map((segment) => segment.text).join();
    final cer = characterErrorRate(clip.text, hypothesis);
    final referenceLength = normalizeForComparison(clip.text).runes.length;
    totalReferenceChars += referenceLength;
    totalEdits += cer * referenceLength;
    cers.add(cer);
    final firstStart = segments.isEmpty ? null : segments.first.startMs - clip.offset.inMilliseconds;
    if (firstStart != null) startDeviations.add(firstStart.abs());
    results.add({
      'file': clip.file,
      'reference': clip.text,
      'hypothesis': hypothesis,
      'cer': cer,
      'segments': segments.length,
      'startDeviationMs': firstStart,
    });
  }
  final overallCer = totalReferenceChars == 0 ? 1.0 : totalEdits / totalReferenceChars;
  final medianStart = median(startDeviations);
  final totalAudio = Duration(microseconds: all.length * 1000000 ~/ speechSampleRate);
  // Fewer windows than clips means at least one window spanned a gap, so its
  // text is scored against whichever clip the segment midpoints happened to
  // land in. Any such run is measuring the harness, not the model.
  final windowDeficit = clips.length - windows.length;
  final unclaimed = transcript.segments
      .where((segment) => !claimed.contains(segment.id))
      .map((segment) => '${segment.startMs}-${segment.endMs}ms:${segment.text}')
      .toList(growable: false);
  final dropReasons = <String, int>{};
  for (final entry in dropped) {
    final reason = entry.split('@').first;
    dropReasons[reason] = (dropReasons[reason] ?? 0) + 1;
  }
  final inferenceMs = windows.fold<int>(
      0, (sum, window) => sum + (window['推理耗时'] as Duration).inMilliseconds);
  final summary = {
    'model': model,
    'vadModel': vadModel,
    'language': language,
    'gapSeconds': gapSeconds,
    'contextEnabled': contextEnabled,
    'backend': engine.backendInfo?.toMap(),
    'clips': clips.length,
    'audioSeconds': totalAudio.inMilliseconds / 1000,
    'overallCer': overallCer,
    'medianCer': median(cers),
    'medianStartDeviationMs': medianStart,
    'missingClips': results.where((r) => r['segments'] == 0).length,
    'windows': windows.length,
    'windowDeficit': windowDeficit,
    'segments': transcript.segments.length,
    'unclaimedSegments': unclaimed,
    'droppedSegments': dropped.length,
    'dropReasons': dropReasons,
    'dropped': dropped,
    'inferenceSeconds': inferenceMs / 1000,
    'realtimeFactor': totalAudio.inMilliseconds == 0 ? 0 : inferenceMs / totalAudio.inMilliseconds,
    'wallSeconds': wall.inMilliseconds / 1000,
    'results': results,
  };

  final json = options['json'];
  if (json != null) {
    File(json).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
  }
  final markdown = StringBuffer()
    ..writeln('## Recognition regression')
    ..writeln()
    ..writeln('| Metric | Value |')
    ..writeln('|---|---|')
    ..writeln('| Model | `${model.split(RegExp(r'[\\/]')).last}` |')
    ..writeln('| VAD | `${vadModel?.split(RegExp(r'[\\/]')).last ?? 'energy'}` |')
    ..writeln('| Backend | ${engine.backendInfo?.actual} |')
    ..writeln('| Gap / context | ${gapSeconds.toStringAsFixed(1)}s / '
        '${contextEnabled ? 'on' : 'off'} |')
    ..writeln('| Clips / audio | ${clips.length} / ${totalAudio.inSeconds}s |')
    ..writeln('| Overall CER | ${(overallCer * 100).toStringAsFixed(2)}% |')
    ..writeln('| Median clip CER | ${(median(cers) * 100).toStringAsFixed(2)}% |')
    ..writeln('| Median start deviation | ${medianStart.toStringAsFixed(0)} ms |')
    ..writeln('| Clips without output | ${summary['missingClips']} |')
    ..writeln('| Windows / segments / dropped | ${windows.length} / ${transcript.segments.length} / ${dropped.length} |')
    ..writeln('| Window deficit (clips - windows) | $windowDeficit |')
    ..writeln('| Segments claimed by no clip | ${unclaimed.length} |')
    ..writeln('| Drop reasons | ${dropReasons.isEmpty ? '-' : dropReasons.entries.map((e) => '${e.key} ${e.value}').join(', ')} |')
    ..writeln('| Inference / realtime factor | ${(inferenceMs / 1000).toStringAsFixed(1)}s / ${(summary['realtimeFactor'] as num).toStringAsFixed(3)} |')
    ..writeln();
  if (unclaimed.isNotEmpty || dropped.isNotEmpty) {
    markdown
      ..writeln('<details><summary>Unclaimed and dropped</summary>')
      ..writeln()
      ..writeln('```');
    for (final entry in unclaimed) {
      markdown.writeln('unclaimed $entry');
    }
    for (final entry in dropped) {
      markdown.writeln('dropped   $entry');
    }
    markdown
      ..writeln('```')
      ..writeln()
      ..writeln('</details>')
      ..writeln();
  }
  markdown
    ..writeln('<details><summary>Per clip</summary>')
    ..writeln()
    ..writeln('| Clip | CER | Δstart | Hypothesis |')
    ..writeln('|---|---|---|---|');
  for (final result in results) {
    markdown.writeln('| ${result['file']} | ${((result['cer'] as double) * 100).toStringAsFixed(1)}% '
        '| ${result['startDeviationMs'] ?? '-'} | ${(result['hypothesis'] as String).replaceAll('|', '¦')} |');
  }
  markdown
    ..writeln()
    ..writeln('</details>');
  stdout.writeln(markdown);
  final summaryPath = options['summary'];
  if (summaryPath != null) {
    File(summaryPath).writeAsStringSync(markdown.toString(), mode: FileMode.append);
  }

  await session.dispose();
  await source.dispose();
  await engine.dispose();
  await vad.dispose();

  if (windowDeficit > 0) {
    stderr.writeln('${windows.length} window(s) for ${clips.length} clips: a window '
        'spanned a gap or failed to decode, so per-clip CER is not attributable');
    exitCode = 1;
  }
  final maxCer = double.tryParse(options['max-cer'] ?? '');
  if (maxCer != null && overallCer > maxCer) {
    stderr.writeln('CER ${overallCer.toStringAsFixed(3)} exceeds $maxCer');
    exitCode = 1;
  }
  final maxStart = int.tryParse(options['max-start-deviation-ms'] ?? '');
  if (maxStart != null && medianStart > maxStart) {
    stderr.writeln('median start deviation ${medianStart.toStringAsFixed(0)} ms exceeds $maxStart');
    exitCode = 1;
  }
}
