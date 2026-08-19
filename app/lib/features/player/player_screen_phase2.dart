import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/providers.dart';
import '../../core/diagnostics/recognition_result_store.dart';
import '../../domain/audio/audio_models.dart';
import '../../domain/player/browser_media_handoff.dart';
import '../../domain/player/player_service.dart';
import '../../domain/speech/speech_models.dart';
import '../../domain/subtitles/transcript_document.dart';
import '../browser/browser_screen.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../audio/recognition_controller.dart';
import '../settings/app_settings.dart';
import '../settings/settings_workspace.dart';
import '../translation/transcript_translation_queue.dart';
import 'media_kit_player_service.dart';
import 'startup_preparation.dart';
import 'subtitle_overlay.dart';

enum _WorkbenchView { player, browser, diagnostics, settings }

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, this.now = DateTime.now});

  final DateTime Function() now;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  final RecognitionResultStore _recognitionResults = RecognitionResultStore();
  late final TranscriptTranslationQueue _translationQueue;
  late final AppSettingsController _settings;
  late AppSettings _lastSettings;
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
  double? _scrubPositionMs;
  _StartupSession? _startup;
  Timer? _startupTimer;

  @override
  void initState() {
    super.initState();
    ref.read(diagnosticsLogProvider).info('工作台', '应用工作台已打开');
    _playbackSubscription =
        ref.read(playerServiceProvider).snapshots.listen((snapshot) {
      if (mounted) {
        setState(() => _snapshot = snapshot);
        _evaluateStartup();
      }
    });
    final recognition = ref.read(recognitionControllerProvider);
    _translationQueue = TranscriptTranslationQueue(
      results: _recognitionResults,
      service: ref.read(translationServiceProvider),
      targetLanguage: 'zh-CN',
      logs: ref.read(diagnosticsLogProvider),
    );
    _recognitionResults.addListener(_onTranscriptChanged);
    _settings = ref.read(appSettingsProvider);
    _lastSettings = _settings.snapshot;
    _settings.addListener(_onSettingsChanged);
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
      _recognitionResults.reset(sessionId: sessionId);
    }
    setState(() => _recognitionDiagnostics = diagnostics);
    _evaluateStartup();
  }

  void _onRecognitionEvent(RecognitionEvent event) {
    if (!mounted || event.sessionId != _recognitionSessionId) return;
    _recognitionResults.addRecognition(event);
  }

  void _onTranscriptChanged() {
    if (!mounted) return;
    setState(() {});
    _evaluateStartup();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    final next = _settings.snapshot;
    if (next.prefetchMode != _lastSettings.prefetchMode) {
      unawaited(
        ref
            .read(recognitionControllerProvider)
            .setPrefetchMode(next.prefetchMode),
      );
    }
    if (!next.sameTranslationConfiguration(_lastSettings)) {
      _translationQueue.updateConfiguration(
        service: createTranslationService(next),
        targetLanguage: 'zh-CN',
      );
    }
    _lastSettings = next;
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
      _recognitionResults.clear();
      final startupStarted = _beginStartup(source);
      await ref.read(playerServiceProvider).open(source);
      _evaluateStartup();
      if (!startupStarted && _startup == null) {
        await ref.read(playerServiceProvider).play();
      }
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

  void _previewSeek(double value) => setState(() => _scrubPositionMs = value);

  void _commitSeek(double value) {
    setState(() => _scrubPositionMs = null);
    unawaited(
      ref
          .read(recognitionControllerProvider)
          .seek(Duration(milliseconds: value.round())),
    );
  }

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
      _recognitionResults.clear();
      final source = handoff.toMediaSource();
      final startupStarted = _beginStartup(source);
      await player.open(source);
      if (!mounted) return;
      setState(() => _activeView = _WorkbenchView.player);
      _evaluateStartup();
      if (!startupStarted && _startup == null) await player.play();
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

  bool _beginStartup(MediaSource source) {
    if (_startup?.dialogActive == true && mounted) {
      Navigator.of(context).pop(false);
    }
    _startupTimer?.cancel();
    final serviceStatus = _translationQueue.serviceStatus;
    if (!serviceStatus.available) {
      _startup = null;
      return false;
    }
    final session = _StartupSession(
      source: source,
      startedAt: widget.now(),
      translationProvider: serviceStatus.provider,
    );
    _startup = session;
    _startupTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || _startup != session) return;
      _evaluateStartup();
      if (mounted && _startup == session) setState(() {});
    });
    if (mounted) setState(() {});
    return true;
  }

  void _evaluateStartup() {
    final session = _startup;
    if (!mounted || session == null || session.bypassed) return;
    if (!_sameMediaSource(_snapshot.source, session.source)) return;
    final now = widget.now();
    if (!session.networkReady &&
        _snapshot.status != PlaybackStatus.loading &&
        _snapshot.status != PlaybackStatus.error &&
        !_snapshot.isBuffering) {
      session.networkReadyAt = now;
    }
    if (!session.recognitionReady &&
        _recognitionDiagnostics.sessionId != null &&
        (_recognitionDiagnostics.windowsSkipped >= 4 ||
            _recognitionResults.recognitions.isNotEmpty)) {
      session.recognitionReadyAt = now;
    }
    final translationEntries = _recognitionResults.document?.translations
            .where((translation) => translation.targetLanguage == 'zh-CN')
            .toList(growable: false) ??
        const <TranscriptTranslation>[];
    final translationsReady = hasEnoughTranslatedSubtitles(translationEntries);
    final hasRecognizedSubtitle = _recognitionResults.recognitions.isNotEmpty;
    if (!session.translationReady && translationsReady) {
      session.translationReadyAt = now;
    }
    if (session.canAutoPlay(
      windowsSkipped: _recognitionDiagnostics.windowsSkipped,
      hasRecognizedSubtitle: hasRecognizedSubtitle,
    )) {
      if (session.dialogActive) {
        if (!session.dialogClosing && mounted) {
          session.dialogClosing = true;
          Navigator.of(context, rootNavigator: true).pop(true);
        }
      } else {
        unawaited(_releaseStartup(session, reason: '启动预备条件已满足'));
      }
      return;
    }
    if (session.shouldPrompt(
      now: now,
      windowsSkipped: _recognitionDiagnostics.windowsSkipped,
      hasRecognizedSubtitle: hasRecognizedSubtitle,
    )) {
      session.promptShown = true;
      session.dialogActive = true;
      unawaited(_showStartupTimeout(session));
    }
  }

  Future<void> _showStartupTimeout(_StartupSession session) async {
    if (!mounted || _startup != session) return;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _StartupTimeoutDialog(
        reasonBuilder: () => _startupReason(session),
        statusBuilder: () => _startupStatusRows(session),
      ),
    );
    if (!mounted || _startup != session) return;
    session.dialogActive = false;
    session.dialogClosing = false;
    if (result == true) {
      await _releaseStartup(session, reason: '用户选择立即播放');
    }
  }

  String _startupReason(_StartupSession session) {
    final reasons = <String>[];
    if (!session.networkReady) {
      if (_snapshot.status == PlaybackStatus.error) {
        reasons.add('播放器打开媒体失败，网络缓冲未完成。');
      } else {
        reasons.add('播放器仍在等待网络缓冲完成。');
      }
    }
    if (!session.recognitionReady) {
      final status = _recognitionDiagnostics.recognizer;
      final decoder = _recognitionDiagnostics.decoder;
      if (decoder.state == AudioDecoderState.error) {
        reasons.add(
          '音频解码失败，Whisper 尚未收到可识别的 PCM：${decoder.message ?? '请查看诊断日志'}',
        );
      } else if (_recognitionDiagnostics.mediaPreparationState == 'failed') {
        reasons.add(
          '识别媒体缓存失败：${_recognitionDiagnostics.mediaPreparationMessage ?? '请查看诊断日志'}',
        );
      } else if (status.state == WindowRecognitionState.unavailable) {
        reasons.add(
          'Whisper 没有可用的识别服务：${status.message ?? '未找到识别运行时或模型'}',
        );
      } else if (_recognitionDiagnostics.windowsFailed > 0) {
        reasons.add(
          'Whisper 识别失败，尚未得到完整字幕：${_recognitionDiagnostics.lastReason ?? '请查看诊断日志'}',
        );
      } else {
        reasons.add('Whisper 尚未识别到完整字幕，可能仍在处理音频窗口。');
      }
    }
    if (!session.translationReady) {
      reasons.add('翻译服务尚未返回 2 条完整字幕，可能是网络延迟或服务响应较慢。');
    }
    return reasons.isEmpty ? '字幕准备流程遇到其他播放器或识别错误。' : reasons.join('\n');
  }

  Future<void> _releaseStartup(
    _StartupSession session, {
    required String reason,
  }) async {
    if (!mounted || _startup != session || session.bypassed) return;
    session.bypassed = true;
    _startupTimer?.cancel();
    _startupTimer = null;
    _startup = null;
    ref.read(diagnosticsLogProvider).info('播放器', '启动等待结束', {
      '原因': reason,
      '网络缓冲耗时': _elapsedFrom(session.startedAt, session.networkReadyAt),
      '字幕识别耗时': _elapsedFrom(session.startedAt, session.recognitionReadyAt),
      '翻译字幕耗时': _elapsedFrom(session.startedAt, session.translationReadyAt),
    });
    if (mounted) setState(() {});
    await ref.read(playerServiceProvider).play();
  }

  Duration? _elapsedFrom(DateTime startedAt, DateTime? finishedAt) =>
      finishedAt?.difference(startedAt);

  bool _sameMediaSource(MediaSource? left, MediaSource right) =>
      left != null &&
      left.uri == right.uri &&
      left.kind == right.kind &&
      left.browserSessionId == right.browserSessionId;

  Future<void> _userPlay() async {
    final session = _startup;
    if (session != null) {
      ref.read(diagnosticsLogProvider).info('播放器', '启动预备期间忽略播放请求', {
        '已等待': widget.now().difference(session.startedAt),
      });
      return;
    }
    await ref.read(playerServiceProvider).play();
  }

  Future<void> _togglePlayback() async {
    if (_snapshot.status == PlaybackStatus.playing) {
      await ref.read(playerServiceProvider).pause();
    } else {
      await _userPlay();
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
            results: _recognitionResults,
            onUserPlay: _userPlay,
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
    _startupTimer?.cancel();
    _settings.removeListener(_onSettingsChanged);
    _recognitionResults.removeListener(_onTranscriptChanged);
    _translationQueue.dispose();
    _recognitionResults.dispose();
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
      return switch (_activeView) {
        _WorkbenchView.diagnostics => _diagnosticsWorkspace(),
        _WorkbenchView.settings => const SettingsWorkspace(),
        _ => playerWorkspace,
      };
    }
    return IndexedStack(
      index: _activeView.index,
      children: [
        playerWorkspace,
        BrowserWorkspace(onMediaDetected: _openBrowserMedia),
        _diagnosticsWorkspace(),
        const SettingsWorkspace(),
      ],
    );
  }

  Widget _diagnosticsWorkspace() => DiagnosticsWorkspace(
        logs: ref.read(diagnosticsLogProvider),
        recognition: _recognitionDiagnostics,
        results: _recognitionResults,
        translationServiceStatus: _translationQueue.serviceStatus,
        translationQueue: _translationQueue,
      );

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
            _viewRow(
              icon: Icons.settings_outlined,
              title: '设置',
              subtitle: '识别与翻译',
              view: _WorkbenchView.settings,
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
              _mobileViewButton(
                Icons.settings_outlined,
                '设置',
                _WorkbenchView.settings,
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
    final canControl = hasMedia &&
        _snapshot.status != PlaybackStatus.loading &&
        _startup == null;
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
                if (hasMedia)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: player is MediaKitPlayerService ? 58 : 20,
                    child: SubtitleOverlay(
                      document: _recognitionResults.document,
                      position: Duration(
                        milliseconds: (_scrubPositionMs ??
                                _snapshot.position.inMilliseconds.toDouble())
                            .round(),
                      ),
                    ),
                  ),
                if (_startup != null)
                  Positioned(
                    top: 8,
                    left: 8,
                    right: player is MediaKitPlayerService ? 56 : 8,
                    child: _startupStatusPanel(_startup!, compact: true),
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
            value: (_scrubPositionMs ?? positionMs)
                .clamp(0, durationMs > 0 ? durationMs.toDouble() : 1),
            max: durationMs > 0 ? durationMs.toDouble() : 1,
            onChanged: canControl && durationMs > 0 ? _previewSeek : null,
            onChangeEnd: canControl && durationMs > 0 ? _commitSeek : null,
          ),
          _playerControls(canControl: canControl, hasMedia: hasMedia),
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
                        : _togglePlayback
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

  Widget _startupStatusPanel(
    _StartupSession session, {
    bool compact = false,
  }) =>
      Container(
        padding: EdgeInsets.all(compact ? 8 : 12),
        decoration: BoxDecoration(
          color: const Color(0xE6191C1E),
          border: Border.all(color: const Color(0xFF3A4448)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '正在准备播放',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: compact ? 12 : null,
              ),
            ),
            SizedBox(height: compact ? 3 : 8),
            _startupStatusRows(session, compact: compact),
          ],
        ),
      );

  Widget _startupStatusRows(
    _StartupSession session, {
    bool compact = false,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _startupStatusRow(
            label: '网络缓冲',
            completedAt: session.networkReadyAt,
            session: session,
            detail: _networkStartupDetail(),
            compact: compact,
          ),
          _startupStatusRow(
            label: '字幕识别',
            completedAt: session.recognitionReadyAt,
            session: session,
            detail: _recognitionStartupDetail(),
            compact: compact,
          ),
          _startupStatusRow(
            label: '翻译字幕返回',
            completedAt: session.translationReadyAt,
            session: session,
            detail: _translationStartupDetail(),
            compact: compact,
          ),
        ],
      );

  Widget _startupStatusRow({
    required String label,
    required DateTime? completedAt,
    required _StartupSession session,
    required String detail,
    required bool compact,
  }) {
    final completed = completedAt != null;
    final elapsed = completed
        ? completedAt.difference(session.startedAt)
        : widget.now().difference(session.startedAt);
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 1 : 3),
      child: Row(
        children: [
          Icon(
            completed ? Icons.check_circle_outline : Icons.hourglass_top,
            size: compact ? 14 : 17,
            color:
                completed ? const Color(0xFF5ED6A0) : const Color(0xFFFF6B6B),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              completed
                  ? '$label 已完成 ${seconds.toStringAsFixed(2)}s'
                  : '$label 等待中: $detail',
              style: TextStyle(
                color: completed
                    ? const Color(0xFF5ED6A0)
                    : const Color(0xFFFF6B6B),
                fontSize: compact ? 11 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _networkStartupDetail() {
    if (_snapshot.status == PlaybackStatus.error) return '播放器打开媒体失败';
    if (_snapshot.isBuffering || _snapshot.status == PlaybackStatus.loading) {
      return '播放器正在缓冲媒体';
    }
    return '等待播放器缓冲状态就绪';
  }

  String _recognitionStartupDetail() {
    final decoder = _recognitionDiagnostics.decoder;
    if (decoder.state == AudioDecoderState.error) {
      return '音频解码失败: ${decoder.message ?? '未知错误'}';
    }
    switch (_recognitionDiagnostics.mediaPreparationState) {
      case 'downloading':
        return 'iOS 正在下载完整识别媒体缓存';
      case 'failed':
        return '识别媒体缓存失败';
    }
    if (decoder.state == AudioDecoderState.opening) return '正在打开音频解码器';
    if (decoder.state == AudioDecoderState.ready) return '等待首个 PCM 音频块';
    if (_recognitionDiagnostics.windowsSkipped > 0) {
      return '已跳过 ${_recognitionDiagnostics.windowsSkipped}/4 个静音窗口';
    }
    return 'Whisper 正在等待可识别的音频窗口';
  }

  String _translationStartupDetail() {
    final translations = _recognitionResults.document?.translations
            .where((translation) =>
                translation.targetLanguage == 'zh-CN' &&
                translation.status == TranscriptTranslationStatus.translated &&
                translation.text.trim().isNotEmpty)
            .length ??
        0;
    final failures = _recognitionResults.document?.translations
            .where((translation) =>
                translation.targetLanguage == 'zh-CN' &&
                translation.status == TranscriptTranslationStatus.failed)
            .length ??
        0;
    if (failures > 0) return '已有 $failures 条翻译失败，等待其他字幕返回';
    return '已返回 $translations/2 条完整翻译字幕';
  }

  String _format(Duration duration) =>
      '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  String _viewLabel(_WorkbenchView view) => switch (view) {
        _WorkbenchView.player => '播放器',
        _WorkbenchView.browser => '内置浏览器',
        _WorkbenchView.diagnostics => '诊断日志',
        _WorkbenchView.settings => '设置',
      };
}

class _StartupSession extends StartupPreparation {
  _StartupSession({
    required this.source,
    required super.startedAt,
    required this.translationProvider,
  });

  final MediaSource source;
  final String translationProvider;
}

class _StartupTimeoutDialog extends StatefulWidget {
  const _StartupTimeoutDialog({
    required this.reasonBuilder,
    required this.statusBuilder,
  });

  final String Function() reasonBuilder;
  final Widget Function() statusBuilder;

  @override
  State<_StartupTimeoutDialog> createState() => _StartupTimeoutDialogState();
}

class _StartupTimeoutDialogState extends State<_StartupTimeoutDialog> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('字幕准备时间较长'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.reasonBuilder()),
              const SizedBox(height: 16),
              widget.statusBuilder(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续等待'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.play_arrow),
            label: const Text('立即播放'),
          ),
        ],
      );
}

class _FullscreenPlayerScreen extends StatefulWidget {
  const _FullscreenPlayerScreen({
    required this.player,
    required this.recognition,
    required this.results,
    required this.onUserPlay,
  });

  final MediaKitPlayerService player;
  final RecognitionController recognition;
  final RecognitionResultStore results;
  final Future<void> Function() onUserPlay;

  @override
  State<_FullscreenPlayerScreen> createState() =>
      _FullscreenPlayerScreenState();
}

class _FullscreenPlayerScreenState extends State<_FullscreenPlayerScreen> {
  StreamSubscription<PlaybackSnapshot>? _subscription;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  double? _scrubPositionMs;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.player.snapshot;
    _subscription = widget.player.snapshots.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
    widget.results.addListener(_onTranscriptChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    widget.results.removeListener(_onTranscriptChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  Future<void> _close() => Navigator.of(context).maybePop();

  void _onTranscriptChanged() {
    if (mounted) setState(() {});
  }

  void _previewSeek(double value) => setState(() => _scrubPositionMs = value);

  void _commitSeek(double value) {
    setState(() => _scrubPositionMs = null);
    unawaited(
      widget.recognition.seek(Duration(milliseconds: value.round())),
    );
  }

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
                left: 32,
                right: 32,
                bottom: 112,
                child: SubtitleOverlay(
                  document: widget.results.document,
                  position: Duration(
                    milliseconds: (_scrubPositionMs ??
                            _snapshot.position.inMilliseconds.toDouble())
                        .round(),
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
                  value: (_scrubPositionMs ??
                          _snapshot.position.inMilliseconds.toDouble())
                      .clamp(
                    0,
                    _snapshot.duration.inMilliseconds > 0
                        ? _snapshot.duration.inMilliseconds.toDouble()
                        : 1,
                  ),
                  max: _snapshot.duration.inMilliseconds > 0
                      ? _snapshot.duration.inMilliseconds.toDouble()
                      : 1,
                  onChanged:
                      _snapshot.duration > Duration.zero ? _previewSeek : null,
                  onChangeEnd:
                      _snapshot.duration > Duration.zero ? _commitSeek : null,
                ),
              ),
              Positioned(
                left: 72,
                top: 12,
                child: IconButton.filledTonal(
                  onPressed: _snapshot.status == PlaybackStatus.playing
                      ? widget.player.pause
                      : widget.onUserPlay,
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
