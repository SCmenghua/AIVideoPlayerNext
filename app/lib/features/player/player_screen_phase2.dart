import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/providers.dart';
import '../../domain/audio/audio_models.dart';
import '../../domain/player/browser_media_handoff.dart';
import '../../domain/player/player_service.dart';
import '../../domain/speech/speech_models.dart';
import '../../domain/subtitles/subtitle_timeline.dart';
import '../browser/browser_screen.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../audio/recognition_controller.dart';
import 'media_kit_player_service.dart';

enum _WorkbenchView { player, browser, diagnostics }

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  final SubtitleTimeline _timeline = SubtitleTimeline();
  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  StreamSubscription<RecognitionEvent>? _recognitionSubscription;
  StreamSubscription<RecognitionDiagnostics>?
      _recognitionDiagnosticsSubscription;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  RecognitionDiagnostics _recognitionDiagnostics =
      const RecognitionDiagnostics.idle();
  String? _recognitionSessionId;
  _WorkbenchView _activeView = _WorkbenchView.player;
  bool _browserHasBeenOpened = false;
  bool _isOpeningBrowserMedia = false;
  bool _isFullscreenOpen = false;

  @override
  void initState() {
    super.initState();
    ref.read(diagnosticsLogProvider).info('工作台', '应用工作台已打开');
    _playbackSubscription =
        ref.read(playerServiceProvider).snapshots.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
    final recognition = ref.read(recognitionControllerProvider);
    _recognitionDiagnostics = recognition.diagnostic;
    _recognitionSubscription = recognition.events.listen(_onRecognitionEvent);
    _recognitionDiagnosticsSubscription =
        recognition.diagnostics.listen(_onRecognitionDiagnostics);
  }

  void _onRecognitionDiagnostics(RecognitionDiagnostics diagnostics) {
    if (!mounted) return;
    final sessionId = diagnostics.sessionId;
    if (sessionId != null && sessionId != _recognitionSessionId) {
      _recognitionSessionId = sessionId;
      _timeline.reset(sessionId: sessionId);
    }
    setState(() => _recognitionDiagnostics = diagnostics);
  }

  void _onRecognitionEvent(RecognitionEvent event) {
    if (!mounted || event.sessionId != _recognitionSessionId) return;
    _timeline.apply(event);
    setState(() {});
  }

  Future<void> _openLocalMedia() async {
    final logs = ref.read(diagnosticsLogProvider);
    logs.info('工作台', '用户点击打开本地视频');
    try {
      final source = await ref.read(mediaPickerProvider).pickLocalVideo();
      if (source == null) {
        logs.info('工作台', '用户取消选择本地视频');
        return;
      }
      logs.info('工作台', '已选择本地视频', {
        '标题': source.title,
        '地址': source.uri,
      });
      _timeline.reset(
          sessionId: 'media-${DateTime.now().millisecondsSinceEpoch}');
      await ref.read(playerServiceProvider).open(source);
      if (mounted) setState(() => _activeView = _WorkbenchView.player);
    } catch (error) {
      logs.error('工作台', '打开本地视频失败', {'错误': error});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法读取所选视频，请在“文件”中选择本机可用的视频文件。')),
      );
    }
  }

  Future<void> _seekBy(Duration offset) =>
      ref.read(recognitionControllerProvider).seek(_snapshot.position + offset);

  void _showView(_WorkbenchView view) {
    if (_activeView == view &&
        (view != _WorkbenchView.browser || _browserHasBeenOpened)) {
      return;
    }
    ref.read(diagnosticsLogProvider).info('工作台', '用户切换工作区', {
      '从': _viewLabel(_activeView),
      '到': _viewLabel(view),
    });
    setState(() {
      if (view == _WorkbenchView.browser) _browserHasBeenOpened = true;
      _activeView = view;
    });
  }

  Future<void> _openBrowserMedia(BrowserMediaHandoff handoff) async {
    final logs = ref.read(diagnosticsLogProvider);
    if (_isOpeningBrowserMedia) {
      logs.warning('工作台', '忽略重复的浏览器媒体交接');
      return;
    }
    logs.info('工作台', '开始接收浏览器媒体', {
      '标题': handoff.title,
      '媒体地址': handoff.mediaUri,
      '来源页面': handoff.originPage,
    });
    _isOpeningBrowserMedia = true;
    try {
      final player = ref.read(playerServiceProvider);
      _timeline.reset(
          sessionId: 'media-${DateTime.now().millisecondsSinceEpoch}');
      await player.open(handoff.toMediaSource());
      if (!mounted) return;
      setState(() => _activeView = _WorkbenchView.player);
      await player.play();
      logs.info('工作台', '浏览器媒体已切换到播放器');
    } catch (error) {
      logs.error('工作台', '浏览器媒体交接失败', {'错误': error});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('视频已检测到，但内置播放器打开失败。请导出诊断日志。')),
        );
      }
    } finally {
      _isOpeningBrowserMedia = false;
    }
  }

  Future<void> _openFullscreen() async {
    final player = ref.read(playerServiceProvider);
    if (_snapshot.source == null || player is! MediaKitPlayerService) return;
    ref.read(diagnosticsLogProvider).info('播放器', '用户进入全屏');
    setState(() => _isFullscreenOpen = true);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _FullscreenPlayerScreen(
            player: player,
            recognition: ref.read(recognitionControllerProvider),
          ),
        ),
      );
    } finally {
      if (mounted) {
        ref.read(diagnosticsLogProvider).info('播放器', '用户退出全屏');
        setState(() => _isFullscreenOpen = false);
      }
    }
  }

  @override
  void dispose() {
    _playbackSubscription?.cancel();
    _recognitionSubscription?.cancel();
    _recognitionDiagnosticsSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 980;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 视频播放器'),
      ),
      body: isWide ? _desktopLayout() : _mobileLayout(),
    );
  }

  Widget _desktopLayout() => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 240, child: _sourcePanel()),
          Expanded(child: _workspace()),
        ],
      );

  Widget _mobileLayout() => Column(
        children: [
          _mobileNavigation(),
          Expanded(child: _workspace()),
        ],
      );

  Widget _workspace() {
    final playerWorkspace = SingleChildScrollView(
      child: _playerPanel(),
    );
    if (!_browserHasBeenOpened) {
      return _activeView == _WorkbenchView.diagnostics
          ? DiagnosticsWorkspace(
              logs: ref.read(diagnosticsLogProvider),
              recognition: _recognitionDiagnostics,
            )
          : playerWorkspace;
    }
    return IndexedStack(
      index: _activeView.index,
      children: [
        playerWorkspace,
        BrowserWorkspace(onMediaDetected: _openBrowserMedia),
        DiagnosticsWorkspace(
          logs: ref.read(diagnosticsLogProvider),
          recognition: _recognitionDiagnostics,
        ),
      ],
    );
  }

  Widget _sourcePanel() => _Panel(
        title: '媒体来源',
        icon: Icons.video_library_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _viewRow(
              icon: Icons.play_circle_outline,
              title: '播放器',
              subtitle: '当前工作区',
              view: _WorkbenchView.player,
            ),
            _viewRow(
              icon: Icons.language_outlined,
              title: '内置浏览器',
              subtitle: '单标签会话',
              view: _WorkbenchView.browser,
            ),
            _viewRow(
              icon: Icons.bug_report_outlined,
              title: '诊断日志',
              subtitle: '操作与媒体桥接记录',
              view: _WorkbenchView.diagnostics,
            ),
            _sourceRow(Icons.movie_outlined, '本地文件', '打开', _openLocalMedia),
            _sourceRow(Icons.cloud_outlined, '网络媒体', '第 4 阶段'),
            _sourceRow(Icons.folder_shared_outlined, 'WebDAV', '第 12 阶段'),
          ],
        ),
      );

  Widget _viewRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required _WorkbenchView view,
  }) {
    final selected = _activeView == view;
    return Material(
      color: selected ? const Color(0xFF24382F) : Colors.transparent,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: Icon(
          icon,
          size: 20,
          color: selected ? const Color(0xFF5ED6A0) : const Color(0xFF8A939A),
        ),
        title: Text(title),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: selected ? const Color(0xFF5ED6A0) : const Color(0xFF8A939A),
          ),
        ),
        trailing: selected ? const Icon(Icons.chevron_right) : null,
        selected: selected,
        onTap: () => _showView(view),
      ),
    );
  }

  Widget _sourceRow(IconData icon, String title, String status,
          [VoidCallback? onTap]) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20, color: const Color(0xFF8A939A)),
        title: Text(title),
        subtitle: Text(
          status,
          style: const TextStyle(fontSize: 12, color: Color(0xFF8A939A)),
        ),
        onTap: onTap,
      );

  Widget _mobileNavigation() => Material(
        color: const Color(0xFF191C1E),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              _mobileViewButton(
                Icons.play_circle_outline,
                '播放器',
                _WorkbenchView.player,
              ),
              _mobileViewButton(
                Icons.language_outlined,
                '内置浏览器',
                _WorkbenchView.browser,
              ),
              _mobileViewButton(
                Icons.bug_report_outlined,
                '诊断日志',
                _WorkbenchView.diagnostics,
              ),
              const Spacer(),
              IconButton(
                onPressed: _openLocalMedia,
                tooltip: '打开本地视频',
                icon: const Icon(Icons.folder_open_outlined),
              ),
            ],
          ),
        ),
      );

  Widget _mobileViewButton(
    IconData icon,
    String label,
    _WorkbenchView view,
  ) =>
      TextButton.icon(
        onPressed: () => _showView(view),
        icon: Icon(icon),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: _activeView == view
              ? const Color(0xFF5ED6A0)
              : const Color(0xFF9EA7AC),
        ),
      );

  Widget _playerPanel() {
    final hasMedia = _snapshot.source != null;
    final canControl = hasMedia && _snapshot.status != PlaybackStatus.loading;
    final durationMs = _snapshot.duration.inMilliseconds;
    final positionMs = _snapshot.position.inMilliseconds
        .clamp(0, durationMs > 0 ? durationMs : 0)
        .toDouble();
    final player = ref.read(playerServiceProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xFF202427)),
                  child: hasMedia &&
                          !_isFullscreenOpen &&
                          player is MediaKitPlayerService
                      ? Video(
                          controller: player.videoController,
                          controls: NoVideoControls,
                        )
                      : _emptyVideoSurface(),
                ),
                if (hasMedia && player is MediaKitPlayerService) ...[
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton.filledTonal(
                      onPressed: _openFullscreen,
                      tooltip: '进入全屏',
                      icon: const Icon(Icons.fullscreen),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: _videoVolumeControl(hasMedia: hasMedia),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  _snapshot.source?.title ?? '尚未选择媒体',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_snapshot.isBuffering)
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
          if (_snapshot.message != null) ...[
            const SizedBox(height: 8),
            Text(
              _snapshot.message!,
              style: const TextStyle(color: Color(0xFFFFAA8A)),
            ),
          ],
          const SizedBox(height: 8),
          Slider(
            value: positionMs,
            max: durationMs > 0 ? durationMs.toDouble() : 1,
            onChanged: canControl && durationMs > 0
                ? (value) => ref
                    .read(recognitionControllerProvider)
                    .seek(Duration(milliseconds: value.round()))
                : null,
          ),
          _playerControls(canControl: canControl, hasMedia: hasMedia),
          _subtitlePanel(),
        ],
      ),
    );
  }

  Widget _playerControls({required bool canControl, required bool hasMedia}) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final controls = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: canControl
                    ? () => _seekBy(const Duration(seconds: -10))
                    : null,
                tooltip: '后退 10 秒',
                icon: const Icon(Icons.replay_10),
              ),
              IconButton.filled(
                onPressed: canControl
                    ? _snapshot.status == PlaybackStatus.playing
                        ? () => ref.read(playerServiceProvider).pause()
                        : () => ref.read(playerServiceProvider).play()
                    : null,
                tooltip: _snapshot.status == PlaybackStatus.playing
                    ? '暂停播放'
                    : '开始播放',
                icon: Icon(_snapshot.status == PlaybackStatus.playing
                    ? Icons.pause
                    : Icons.play_arrow),
              ),
              IconButton(
                onPressed: canControl
                    ? () => _seekBy(const Duration(seconds: 10))
                    : null,
                tooltip: '前进 10 秒',
                icon: const Icon(Icons.forward_10),
              ),
              PopupMenuButton<double>(
                enabled: canControl,
                tooltip: '播放速度',
                initialValue: _snapshot.rate,
                onSelected: ref.read(playerServiceProvider).setRate,
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 0.5, child: Text('0.5 倍速')),
                  PopupMenuItem(value: 1.0, child: Text('1.0 倍速')),
                  PopupMenuItem(value: 1.25, child: Text('1.25 倍速')),
                  PopupMenuItem(value: 1.5, child: Text('1.5 倍速')),
                  PopupMenuItem(value: 2.0, child: Text('2.0 倍速')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('${_snapshot.rate.toStringAsFixed(2)}x'),
                ),
              ),
              IconButton(
                onPressed: canControl ? _openFullscreen : null,
                tooltip: '进入全屏',
                icon: const Icon(Icons.fullscreen),
              ),
            ],
          );
          final time = Text(
            '${_format(_snapshot.position)} / ${_format(_snapshot.duration)}',
            style: const TextStyle(color: Color(0xFF9EA7AC)),
          );
          if (constraints.maxWidth >= 700) {
            return Row(
              children: [
                time,
                const Spacer(),
                controls,
              ],
            );
          }
          return Row(
            children: [
              time,
              const Spacer(),
              controls,
            ],
          );
        },
      );

  Widget _videoVolumeControl({required bool hasMedia}) => Material(
        color: const Color(0xCC111516),
        borderRadius: BorderRadius.circular(4),
        child: Row(
          children: [
            Icon(
              _snapshot.volume == 0
                  ? Icons.volume_off_outlined
                  : Icons.volume_up_outlined,
              size: 18,
              color: Colors.white,
            ),
            SizedBox(
              width: 160,
              child: Slider(
                value: _snapshot.volume,
                max: 100,
                onChanged:
                    hasMedia ? ref.read(playerServiceProvider).setVolume : null,
              ),
            ),
          ],
        ),
      );

  Widget _emptyVideoSurface() => Center(
        child: FilledButton.icon(
          onPressed: _openLocalMedia,
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('打开本地视频'),
        ),
      );

  Widget _subtitlePanel() {
    final active = _timeline.at(_snapshot.position);
    final latest = _timeline.finals.isEmpty ? null : _timeline.finals.last;
    final lag = latest == null
        ? null
        : _snapshot.position > latest.end
            ? _snapshot.position - latest.end
            : Duration.zero;
    final entries =
        active.isNotEmpty ? active : (latest == null ? const [] : [latest]);
    return _Panel(
      title: '字幕',
      icon: Icons.subtitles_outlined,
      child: _timeline.finals.isEmpty
          ? Text(
              _subtitleWaitingLabel(),
              style: const TextStyle(color: Color(0xFF9EA7AC)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (active.isEmpty &&
                    lag != null &&
                    lag > const Duration(seconds: 2))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '识别结果落后当前播放位置 ${_formatDuration(lag)}',
                      style: const TextStyle(
                          color: Color(0xFFFFD166), fontSize: 12),
                    ),
                  ),
                ...entries.map((entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '${_format(entry.start)} - ${_format(entry.end)}\n${entry.original}',
                      ),
                    )),
              ],
            ),
    );
  }

  String _formatDuration(Duration duration) =>
      '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  String _subtitleWaitingLabel() =>
      switch (_recognitionDiagnostics.recognizer.state) {
        WindowRecognitionState.unavailable =>
          'Whisper 不可用：${_recognitionDiagnostics.recognizer.message ?? '缺少模型或 DLL'}',
        WindowRecognitionState.loading => 'Whisper 正在加载模型',
        WindowRecognitionState.recognizing => 'Whisper 正在识别音频',
        WindowRecognitionState.error =>
          'Whisper 识别失败：${_recognitionDiagnostics.recognizer.message ?? '请查看诊断日志'}',
        _ => '尚无真实识别字幕',
      };

  String _format(Duration duration) =>
      '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  String _viewLabel(_WorkbenchView view) => switch (view) {
        _WorkbenchView.player => '播放器',
        _WorkbenchView.browser => '内置浏览器',
        _WorkbenchView.diagnostics => '诊断日志',
      };
}

class _FullscreenPlayerScreen extends StatefulWidget {
  const _FullscreenPlayerScreen({
    required this.player,
    required this.recognition,
  });

  final MediaKitPlayerService player;
  final RecognitionController recognition;

  @override
  State<_FullscreenPlayerScreen> createState() =>
      _FullscreenPlayerScreenState();
}

class _FullscreenPlayerScreenState extends State<_FullscreenPlayerScreen> {
  StreamSubscription<PlaybackSnapshot>? _subscription;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();

  @override
  void initState() {
    super.initState();
    _snapshot = widget.player.snapshot;
    _subscription = widget.player.snapshots.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  Future<void> _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          top: false,
          bottom: false,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Video(
                    controller: widget.player.videoController,
                    controls: NoVideoControls,
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: IconButton.filledTonal(
                  onPressed: _close,
                  tooltip: '退出全屏',
                  icon: const Icon(Icons.fullscreen_exit),
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: Material(
                  color: const Color(0xCC111516),
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    children: [
                      Icon(
                        _snapshot.volume == 0
                            ? Icons.volume_off_outlined
                            : Icons.volume_up_outlined,
                        color: Colors.white,
                      ),
                      SizedBox(
                        width: 180,
                        child: Slider(
                          value: _snapshot.volume,
                          max: 100,
                          onChanged: widget.player.setVolume,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 56,
                child: Slider(
                  value: _snapshot.position.inMilliseconds.toDouble().clamp(
                        0,
                        _snapshot.duration.inMilliseconds > 0
                            ? _snapshot.duration.inMilliseconds.toDouble()
                            : 1,
                      ),
                  max: _snapshot.duration.inMilliseconds > 0
                      ? _snapshot.duration.inMilliseconds.toDouble()
                      : 1,
                  onChanged: _snapshot.duration > Duration.zero
                      ? (value) => widget.recognition
                          .seek(Duration(milliseconds: value.round()))
                      : null,
                ),
              ),
              Positioned(
                left: 72,
                top: 12,
                child: IconButton.filledTonal(
                  onPressed: _snapshot.status == PlaybackStatus.playing
                      ? widget.player.pause
                      : widget.player.play,
                  tooltip: _snapshot.status == PlaybackStatus.playing
                      ? '暂停播放'
                      : '开始播放',
                  icon: Icon(_snapshot.status == PlaybackStatus.playing
                      ? Icons.pause
                      : Icons.play_arrow),
                ),
              ),
            ],
          ),
        ),
      );
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
        decoration: BoxDecoration(
          color: const Color(0xFF191C1E),
          border: Border.all(color: const Color(0xFF2C3235)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFF5ED6A0)),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      );
}
