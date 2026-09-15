import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:recognition/recognition.dart' show RecognitionState;

import '../../app/providers.dart';
import '../../domain/player/browser_media_handoff.dart';
import '../../domain/player/player_service.dart';
import '../browser/browser_screen.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../recognition/recognition_service.dart';
import '../settings/app_settings.dart';
import '../settings/settings_workspace.dart';
import '../translation/transcript_translation_queue.dart';
import 'media_kit_player_service.dart';
import 'playback_gate.dart';
import 'player_overlay.dart';

enum _ShellView { player, browser }

/// The application's single main screen: a full-window video surface with
/// the overlay drawn on top. The browser lives in an offstage layer so its
/// session survives switching back to the player; settings and diagnostics
/// are pushed as pages.
class PlayerShell extends ConsumerStatefulWidget {
  const PlayerShell({super.key, this.now = DateTime.now});

  final DateTime Function() now;

  @override
  ConsumerState<PlayerShell> createState() => _PlayerShellState();
}

class _PlayerShellState extends ConsumerState<PlayerShell> {
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();
  late final TranscriptTranslationQueue _translationQueue;
  late final AppSettingsController _settings;
  late final TranscriptStore _store;
  late final RecognitionService _recognition;
  late final PlaybackGate _gate;
  late AppSettings _lastSettings;
  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  _ShellView _view = _ShellView.player;
  bool _browserOpened = false;
  bool _openingHandoff = false;
  Timer? _gateTimer;
  String? _waitingReason;

  @override
  void initState() {
    super.initState();
    final logs = ref.read(diagnosticsLogProvider);
    logs.info('播放器', '播放器已打开');
    _settings = ref.read(appSettingsProvider);
    _store = ref.read(transcriptStoreProvider);
    _recognition = ref.read(recognitionServiceProvider);
    _lastSettings = _settings.snapshot;
    _gate = PlaybackGate(
      now: widget.now,
      strategy: _settings.playbackStartStrategy,
      waitForPreparation: _settings.waitForSubtitlePreparation,
    );
    _translationQueue = TranscriptTranslationQueue(
      results: _store,
      service: ref.read(translationServiceProvider),
      targetLanguage: _settings.translationTargetLanguage,
      batchSize: _settings.translationBatchSize,
      maxConcurrent: _translationConcurrency(_settings.snapshot),
      contextEnabled: _settings.translationContextEnabled,
      logs: logs,
    );
    _playbackSubscription = ref.read(playerServiceProvider).snapshots.listen((snapshot) {
      if (!mounted) return;
      final positionChanged = snapshot.position != _snapshot.position;
      setState(() => _snapshot = snapshot);
      if (positionChanged) _recognition.updatePlaybackPosition(snapshot.position);
      _evaluateGate();
    });
    _settings.addListener(_onSettingsChanged);
    _store.addListener(_onTranscriptChanged);
    _recognition.addListener(_onRecognitionChanged);
    _gateTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _evaluateGate());
  }

  @override
  void dispose() {
    _gateTimer?.cancel();
    _playbackSubscription?.cancel();
    _settings.removeListener(_onSettingsChanged);
    _store.removeListener(_onTranscriptChanged);
    _recognition.removeListener(_onRecognitionChanged);
    _translationQueue.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Media

  Future<void> _openLocalMedia() async {
    final logs = ref.read(diagnosticsLogProvider);
    try {
      final source = await ref.read(mediaPickerProvider).pickLocalVideo();
      if (source == null) return;
      logs.info('播放器', '已选择本地视频', {'标题': source.title, '地址': source.uri});
      await _openSource(source);
    } catch (error) {
      logs.error('播放器', '打开本地视频失败', {'错误': error});
      _snack('无法读取所选视频，请选择本机可用的视频文件。');
    }
  }

  Future<void> _openBrowserMedia(BrowserMediaHandoff handoff) async {
    final logs = ref.read(diagnosticsLogProvider);
    if (_openingHandoff) return;
    _openingHandoff = true;
    try {
      logs.info('播放器', '接收浏览器媒体', {'标题': handoff.title, '媒体地址': handoff.mediaUri});
      await _openSource(handoff.toMediaSource());
      if (mounted) setState(() => _view = _ShellView.player);
    } catch (error) {
      logs.error('播放器', '浏览器媒体交接失败', {'错误': error});
      _snack('视频已检测到，但播放器打开失败，请查看诊断。');
    } finally {
      _openingHandoff = false;
    }
  }

  Future<void> _openSource(MediaSource source) async {
    final player = ref.read(playerServiceProvider);
    final recognition = ref.read(recognitionServiceProvider);
    _gate
      ..strategy = _settings.playbackStartStrategy
      ..waitForPreparation = _settings.waitForSubtitlePreparation
      ..beginMedia();
    _translationQueue.prioritizeFrom(Duration.zero);
    // Recognition starts first so it leads playback from the first frame.
    unawaited(recognition.open(source));
    await player.open(source);
    if (!mounted) return;
    setState(() => _view = _ShellView.player);
    _evaluateGate();
    if (!_gate.waitingForStart) await player.play();
  }

  Future<void> _seekTo(Duration position) async {
    final duration = _snapshot.duration;
    final target = position < Duration.zero
        ? Duration.zero
        : duration > Duration.zero && position > duration
            ? duration
            : position;
    _translationQueue.prioritizeFrom(target);
    _gate.onSeek();
    unawaited(ref.read(recognitionServiceProvider).seek(target));
    await ref.read(playerServiceProvider).seek(target);
  }

  Future<void> _togglePlay() async {
    final player = ref.read(playerServiceProvider);
    if (_snapshot.status == PlaybackStatus.playing) {
      _gate.userPause();
      await player.pause();
    } else {
      _gate.userPlay();
      setState(() => _waitingReason = null);
      await player.play();
    }
  }

  // ---------------------------------------------------------------------------
  // Gate

  void _evaluateGate() {
    if (!mounted || _snapshot.source == null) return;
    final recognition = ref.read(recognitionServiceProvider);
    final diagnostics = recognition.diagnostics;
    _gate.noteRecognitionProgress(diagnostics.processedThrough);
    final alive = recognition.status.availability == RecognitionAvailability.ready &&
        diagnostics.state != RecognitionState.error &&
        diagnostics.state != RecognitionState.stopped &&
        diagnostics.state != RecognitionState.idle;
    final evaluation = _gate.evaluate(
      status: _snapshot.status,
      position: _snapshot.position,
      document: ref.read(transcriptStoreProvider).document,
      targetLanguage: _settings.translationTargetLanguage,
      translationExpected: _translationQueue.serviceStatus.available,
      recognitionAlive: alive,
    );
    final reason = evaluation.waitingForStart || _gate.policyPaused ? evaluation.reason : null;
    if (reason != _waitingReason) setState(() => _waitingReason = reason);
    final player = ref.read(playerServiceProvider);
    switch (evaluation.action) {
      case GateAction.play:
        ref.read(diagnosticsLogProvider).debug('播放器', '门控放行播放', {'原因': evaluation.reason});
        unawaited(player.play());
      case GateAction.pause:
        ref.read(diagnosticsLogProvider).debug('播放器', '门控暂停等待字幕', {'原因': evaluation.reason});
        unawaited(player.pause());
      case GateAction.none:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Listeners

  void _onSettingsChanged() {
    if (!mounted) return;
    final next = _settings.snapshot;
    if (!next.sameTranslationConfiguration(_lastSettings)) {
      _translationQueue.updateConfiguration(
        service: createTranslationService(next),
        targetLanguage: next.translationTargetLanguage,
      );
    }
    if (!next.sameTranslationScheduling(_lastSettings)) {
      _translationQueue.updateScheduling(
        batchSize: next.translationBatchSize,
        maxConcurrent: _translationConcurrency(next),
        contextEnabled: next.translationContextEnabled,
      );
    }
    _gate
      ..strategy = next.playbackStartStrategy
      ..waitForPreparation = next.waitForSubtitlePreparation;
    _lastSettings = next;
    setState(() {});
    _evaluateGate();
  }

  void _onTranscriptChanged() {
    if (!mounted) return;
    setState(() {});
    _evaluateGate();
  }

  void _onRecognitionChanged() {
    if (mounted) setState(() {});
  }

  /// System translation runs through one serialized native session.
  int _translationConcurrency(AppSettings settings) =>
      settings.translationMode == TranslationMode.systemTranslation
          ? 1
          : settings.translationMaxConcurrent;

  String _statusText() {
    final recognition = ref.read(recognitionServiceProvider);
    final diagnostics = recognition.diagnostics;
    final parts = <String>[];
    switch (recognition.status.availability) {
      case RecognitionAvailability.checking:
        parts.add('识别准备中');
      case RecognitionAvailability.modelMissing:
        parts.add('识别模型未安装');
      case RecognitionAvailability.unavailable:
        parts.add('识别不可用');
      case RecognitionAvailability.ready:
        switch (diagnostics.state) {
          case RecognitionState.idle:
          case RecognitionState.opening:
            parts.add('识别启动中');
          case RecognitionState.running:
          case RecognitionState.paused:
            final lead = diagnostics.processedThrough - _snapshot.position;
            parts.add('识别领先 ${lead.isNegative ? 0 : lead.inSeconds} 秒');
          case RecognitionState.ended:
            parts.add('识别完成');
          case RecognitionState.stopped:
            parts.add('识别已停止');
          case RecognitionState.error:
            parts.add('识别错误');
        }
    }
    final translationStatus = _translationQueue.serviceStatus;
    if (!translationStatus.available) {
      parts.add('未配置翻译');
    } else if (_translationQueue.waitingCount + _translationQueue.activeCount > 0) {
      parts.add('翻译中 ${_translationQueue.waitingCount + _translationQueue.activeCount}');
    }
    return parts.join(' · ');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showBrowser() {
    setState(() {
      _browserOpened = true;
      _view = _ShellView.browser;
    });
  }

  Future<void> _showSettings() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
      );

  Future<void> _showDiagnostics() => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DiagnosticsPage(translationQueue: _translationQueue),
        ),
      );

  // ---------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      _playerView(),
      if (_browserOpened)
        _BrowserPage(
          onMediaDetected: _openBrowserMedia,
          onBack: () => setState(() => _view = _ShellView.player),
        ),
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      body: IndexedStack(
        index: _view.index.clamp(0, children.length - 1).toInt(),
        children: children,
      ),
    );
  }

  Widget _playerView() {
    final player = ref.read(playerServiceProvider);
    final hasMedia = _snapshot.source != null;
    final actions = PlayerOverlayActions(
      onTogglePlay: _togglePlay,
      onSeek: _seekTo,
      onOpenFile: _openLocalMedia,
      onOpenBrowser: _showBrowser,
      onOpenSettings: _showSettings,
      onOpenDiagnostics: _showDiagnostics,
    );
    if (!hasMedia) {
      return _EmptyState(
        actions: actions,
        message: _snapshot.message,
        statusText: _statusText(),
      );
    }
    PlayerOverlay overlay(VideoState? state) => PlayerOverlay(
          videoState: state,
          snapshot: _snapshot,
          actions: actions,
          statusText: _statusText(),
          waitingReason: _waitingReason,
        );
    if (player is! MediaKitPlayerService) {
      // Test players have no video surface; draw the overlay on black.
      return ColoredBox(color: Colors.black, child: overlay(null));
    }
    return Video(
      key: _videoKey,
      controller: player.videoController,
      fill: Colors.black,
      controls: overlay,
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState({
    required this.actions,
    required this.message,
    required this.statusText,
  });

  final PlayerOverlayActions actions;
  final String? message;
  final String statusText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_circle_outline, size: 72, color: scheme.primary),
                  const SizedBox(height: 16),
                  Text('AI 视频播放器', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(
                    '本地识别日语语音，实时生成双语字幕。',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: actions.onOpenFile,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('打开本地视频'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: actions.onOpenBrowser,
                    icon: const Icon(Icons.language_outlined),
                    label: const Text('从内置浏览器打开'),
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 18),
                    Text(message!, style: TextStyle(color: scheme.error), textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 18),
                  Text(statusText, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: MediaQuery.paddingOf(context).top + 4,
          right: 4,
          child: Row(
            children: [
              IconButton(
                tooltip: '诊断',
                onPressed: actions.onOpenDiagnostics,
                icon: const Icon(Icons.monitor_heart_outlined),
              ),
              IconButton(
                tooltip: '设置',
                onPressed: actions.onOpenSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        _ModelBannerHost(),
      ],
    );
  }
}

/// Surfaces the model-missing banner on the empty screen too, so a fresh
/// install can download the model before opening any media.
class _ModelBannerHost extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recognition = ref.watch(recognitionServiceProvider);
    final status = recognition.status;
    final spec = status.missingModel;
    if (status.availability != RecognitionAvailability.modelMissing || spec == null) {
      return const SizedBox.shrink();
    }
    final download = status.download;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('需要下载识别模型：${spec.label}（${spec.sizeLabel}）'),
                  const SizedBox(height: 4),
                  Text(spec.description, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 10),
                  if (download != null && !download.isFailed)
                    LinearProgressIndicator(value: download.fraction)
                  else
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: () => recognition.installModel(spec),
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('下载并安装'),
                        ),
                        if (download?.error != null) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              download!.error!,
                              style: TextStyle(color: Theme.of(context).colorScheme.error),
                            ),
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowserPage extends StatelessWidget {
  const _BrowserPage({required this.onMediaDetected, required this.onBack});

  final Future<void> Function(BrowserMediaHandoff handoff) onMediaDetected;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '返回播放器',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('内置浏览器'),
        ),
        body: BrowserWorkspace(onMediaDetected: onMediaDetected),
      );
}
