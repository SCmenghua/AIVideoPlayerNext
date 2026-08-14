import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/player/player_service.dart';
import '../../domain/speech/speech_models.dart';
import '../../domain/subtitles/subtitle_timeline.dart';
import '../../domain/translation/translation_service.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  final SubtitleTimeline _timeline = SubtitleTimeline();
  StreamSubscription<RecognitionEvent>? _speechSubscription;
  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  String _sessionId = 'session-1';
  String _providerStatus = 'Mock providers active';

  @override
  void initState() {
    super.initState();
    final player = ref.read(playerServiceProvider);
    _speechSubscription = ref.read(speechRecognitionServiceProvider).events.listen(_onRecognitionEvent);
    _playbackSubscription = player.snapshots.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
  }

  void _onRecognitionEvent(RecognitionEvent event) {
    if (event.sessionId != _sessionId) return;
    setState(() {
      _timeline.apply(event);
      _providerStatus = event.kind == RecognitionKind.finalResult ? 'Final subtitle received' : 'Listening...';
    });
    if (event.kind == RecognitionKind.finalResult) {
      ref.read(translationServiceProvider).translate(TranslationRequest(
        segmentId: event.segmentId,
        text: event.text,
        targetLanguage: 'zh',
      )).then((result) {
        if (mounted && result.segmentId == event.segmentId) {
          setState(() => _timeline.applyTranslation(result.segmentId, result.text));
        }
      });
    }
  }

  Future<void> _openMockMedia() async {
    final nextSession = 'session-${DateTime.now().millisecondsSinceEpoch}';
    _sessionId = nextSession;
    _timeline.reset(sessionId: _sessionId);
    await ref.read(playerServiceProvider).open(const MediaSource(path: 'mock://sample.mp4', title: 'Sample interview.mp4'));
    await ref.read(speechRecognitionServiceProvider).start(RecognitionRequest(sessionId: _sessionId, from: Duration.zero));
    if (mounted) setState(() => _providerStatus = 'Mock media loaded');
  }

  @override
  void dispose() {
    _speechSubscription?.cancel();
    _playbackSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 980;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Video Player Next'),
        actions: [
          IconButton(onPressed: _openMockMedia, tooltip: 'Open mock media', icon: const Icon(Icons.folder_open_outlined)),
          IconButton(onPressed: () {}, tooltip: 'Settings', icon: const Icon(Icons.tune_outlined)),
          const SizedBox(width: 12),
        ],
      ),
      body: isWide ? _desktopLayout() : _mobileLayout(),
    );
  }

  Widget _desktopLayout() => Row(
        children: [
          SizedBox(width: 240, child: _sourcePanel()),
          Expanded(child: _playerPanel()),
          SizedBox(width: 300, child: _subtitlePanel()),
        ],
      );

  Widget _mobileLayout() => ListView(
        padding: const EdgeInsets.all(16),
        children: [_playerPanel(), const SizedBox(height: 16), _subtitlePanel(), const SizedBox(height: 16), _sourcePanel()],
      );

  Widget _sourcePanel() => _Panel(
        title: 'Sources',
        icon: Icons.video_library_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sourceRow(Icons.movie_outlined, 'Local files', 'Ready'),
          _sourceRow(Icons.cloud_outlined, 'Network media', 'Phase 10'),
          _sourceRow(Icons.folder_shared_outlined, 'WebDAV', 'Phase 10'),
        ]),
      );

  Widget _sourceRow(IconData icon, String title, String status) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20, color: const Color(0xFF8A939A)),
        title: Text(title),
        subtitle: Text(status, style: const TextStyle(fontSize: 12, color: Color(0xFF8A939A))),
      );

  Widget _playerPanel() => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(aspectRatio: 16 / 9, child: Container(
            color: const Color(0xFF202427),
            child: Center(child: Icon(_snapshot.source == null ? Icons.play_circle_outline : Icons.ondemand_video_outlined, size: 64, color: const Color(0xFF5ED6A0))),
          )),
          const SizedBox(height: 14),
          Text(_snapshot.source?.title ?? 'No media selected', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _snapshot.progress, minHeight: 3),
          Row(children: [
            IconButton(onPressed: _snapshot.status == PlaybackStatus.playing ? () => ref.read(playerServiceProvider).pause() : () => ref.read(playerServiceProvider).play(), tooltip: 'Play or pause', icon: Icon(_snapshot.status == PlaybackStatus.playing ? Icons.pause : Icons.play_arrow)),
            Text('${_format(_snapshot.position)} / ${_format(_snapshot.duration)}', style: const TextStyle(color: Color(0xFF9EA7AC))),
            const Spacer(),
            IconButton(onPressed: () {}, tooltip: 'More playback controls', icon: const Icon(Icons.more_horiz)),
          ]),
        ]),
      );

  Widget _subtitlePanel() {
    final entries = _timeline.finals;
    return _Panel(
      title: 'Subtitles',
      icon: Icons.subtitles_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_providerStatus, style: const TextStyle(color: Color(0xFF5ED6A0), fontSize: 12)),
        const SizedBox(height: 14),
        if (_timeline.partial != null) _subtitleText(_timeline.partial!.original, muted: true),
        if (entries.isEmpty && _timeline.partial == null) const Text('Open mock media to preview the Phase 1 flow.'),
        ...entries.reversed.take(3).map((entry) => Padding(padding: const EdgeInsets.only(top: 12), child: _subtitleText('${entry.original}\n${entry.translation ?? 'Translation pending'}'))),
      ]),
    );
  }

  Widget _subtitleText(String text, {bool muted = false}) => Text(text, style: TextStyle(color: muted ? const Color(0xFF87928B) : Colors.white, height: 1.4));

  String _format(Duration duration) => '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xFF191C1E), border: Border.all(color: const Color(0xFF2C3235)), borderRadius: BorderRadius.circular(6)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(icon, size: 18, color: const Color(0xFF5ED6A0)), const SizedBox(width: 8), Text(title, style: Theme.of(context).textTheme.titleSmall)]),
          const SizedBox(height: 16),
          child,
        ]),
      );
}
